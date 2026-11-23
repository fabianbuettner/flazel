# flazel - Hermetic Bazel builds with Nix
#
# This flake provides a library of functions for integrating Nix with Bazel.
# It enables hermetic builds with configurable toolchains, static/dynamic
# linking, and automatic BCR dependency caching.
#
# Structure:
#   lib/core/  - Language-agnostic core (BCR caching, generic derivations)
#   lib/cc/    - C/C++ specific (toolchain, library repos)
#   lib/hdl/   - HDL specific (Verilator module)
#   lib/rust/  - Rust specific (toolchain, crate universe integration)
#
# Usage in consuming flakes:
#   inputs.flazel.url = "github:fabianbuettner/flazel";
#
{
  description = "Hermetic Bazel builds with Nix - toolchain and library integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      rust-overlay,
    }:
    let
      # Every builder overrides the flazel module with this source; a caller's
      # own moduleOverrides come on top.
      withFlazelModule =
        fn: args:
        fn (
          args
          // {
            moduleOverrides = {
              flazel = self.outPath;
            }
            // (args.moduleOverrides or { });
          }
        );

      # Import core modules once
      coreDeriv = import ./lib/core/derivation.nix;

      # Core library functions (language-agnostic)
      coreLib = {
        # BCR cache generation
        inherit (import ./lib/core/bcr-cache.nix)
          mkBcrCaches
          parseLockFile
          parseArchiveManifest
          ;

        # Utility functions
        getTransitiveDeps = import ./lib/core/utils.nix;

        # Testing against several Bazel versions
        bazelVersions = import ./lib/core/bazel-versions.nix;
        bazelVariants = import ./lib/core/bazel-variants.nix;
        mkUpdateLocksApp = import ./lib/core/update-locks.nix;

        # Bazel whose actions find /usr/bin/env in a Nix build sandbox
        bazelWithUsrBinEnv = import ./lib/core/bazel-with-usr-bin-env.nix;

        # Generic derivation builders (auto-inject the flazel module override)
        mkFlazelDerivation = withFlazelModule coreDeriv.mkFlazelDerivation;
        mkFlazelDepsSetup = withFlazelModule coreDeriv.mkFlazelDepsSetup;

        # Generic dev shell (auto-inject the flazel module override)
        mkFlazelDevShell = withFlazelModule (import ./lib/core/dev-shell.nix);
      };

      # C/C++ specific library functions
      ccLib = {
        # CC toolchain configuration
        mkConfig = import ./lib/cc/toolchain.nix;

        # CC library repo generation
        mkNixpkgsRepo = import ./lib/cc/nixpkgs-repo.nix;

        # CC-specific derivation (auto-inject the flazel module override)
        mkDerivation = withFlazelModule (import ./lib/cc/derivation.nix);

        # CC-specific dev shell (auto-inject the flazel module override)
        mkDevShell = withFlazelModule (import ./lib/cc/dev-shell.nix);
      };

      # HDL specific library functions
      hdlLib = {
        # A Bazel module of a nixpkgs Verilator, for moduleOverrides
        mkVerilatorModule = import ./lib/hdl/verilator-module.nix;
      };

      # Rust specific library functions
      rustLib = {
        # Rust toolchain configuration
        mkConfig = import ./lib/rust/toolchain.nix;

        # Build cargo-bazel from source for crate_universe on NixOS
        mkCargoBazel = import ./lib/rust/cargo-bazel.nix;

        # Rust-specific derivation (auto-inject the flazel module override)
        mkDerivation = withFlazelModule (import ./lib/rust/derivation.nix);

        # Rust-specific dev shell (auto-inject the flazel module override)
        mkDevShell = withFlazelModule (import ./lib/rust/dev-shell.nix);
      };
    in
    {
      # Expose library functions and rust-overlay for consumers
      lib = coreLib // {
        cc = ccLib;
        hdl = hdlLib;
        rust = rustLib;
      };

      # Re-export rust-overlay so consumers can apply it to their pkgs
      inherit (rust-overlay) overlays;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";

          programs.nixfmt.enable = true;

          settings.formatter.buildifier = {
            command = "${pkgs.buildifier}/bin/buildifier";
            includes = [
              "BUILD"
              "BUILD.bazel"
              "*/BUILD"
              "*/BUILD.bazel"
              "*/MODULE.bazel"
              "MODULE.bazel"
              "*.bzl"
            ];
          };
        };
      in
      {
        # Development shell for working on flazel itself
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.buildifier
            pkgs.nixfmt
          ];
          shellHook = ''
            echo "flazel development shell"
            echo "  nix fmt    - format all files"
            echo "  nix flake check    - formatting"
            echo "  nix run .#check-all - the test projects"
          '';
        };

        # Formatting
        formatter = treefmtEval.config.build.wrapper;

        # Provide checks/tests for flazel itself
        checks = {
          formatting = treefmtEval.config.build.check self;

          # flazel-lock-archives' parsing, over recorded Bazel output: the
          # sandbox has no network for Bazel to produce it.
          archive-manifest = pkgs.runCommand "flazel-archive-manifest-test" { } ''
            ${pkgs.python3}/bin/python3 -I ${./lib/core/archive_manifest_test.py} \
              ${./lib/core/archive_manifest.py} ${./lib/core/testdata}
            touch $out
          '';

          # Each branch of bazelWithUsrBinEnv, around a fake Bazel.
          bazel-with-usr-bin-env =
            let
              fakeBazel = pkgs.writeShellScriptBin "bazel" ''
                if [ -n "''${FAKE_PIDFILE:-}" ]; then
                  echo $$ > "$FAKE_PIDFILE"
                  exec sleep 1000
                fi
                echo "ns=$(readlink /proc/self/ns/user) env=$(/usr/bin/env echo ok) args=$*"
                exit "''${FAKE_RC:-0}"
              '';
            in
            pkgs.runCommand "flazel-bazel-with-usr-bin-env-test"
              {
                nativeBuildInputs = [ pkgs.util-linux ];
                wrapper = "${
                  coreLib.bazelWithUsrBinEnv {
                    inherit pkgs;
                    bazel = fakeBazel;
                  }
                }/bin/bazel";
                coreutilsEnv = "${pkgs.coreutils}/bin/env";
                bwrap = "${pkgs.bubblewrap}/bin/bwrap";
              }
              ''
                bash ${./lib/core/bazel-with-usr-bin-env-test.sh}
                touch $out
              '';

          # bubblewrap is Linux-only, and other build platforms keep Bazel as is.
          bazel-with-usr-bin-env-darwin =
            let
              darwinPkgs = import nixpkgs { system = "aarch64-darwin"; };
              bazel = darwinPkgs.writeShellScriptBin "bazel" "";
            in
            assert
              coreLib.bazelWithUsrBinEnv {
                pkgs = darwinPkgs;
                inherit bazel;
              } == bazel;
            pkgs.runCommand "flazel-bazel-with-usr-bin-env-darwin-test" { } "touch $out";

          # How update-locks stops a command that starts with TERM ignored.
          update-locks-stop-marker =
            let
              inherit (import ./lib/core/stop-marker.nix { inherit pkgs; }) forwardTerm nsInit;
            in
            pkgs.runCommand "flazel-update-locks-stop-marker-test"
              {
                nativeBuildInputs = [ pkgs.util-linux ];
                inherit forwardTerm nsInit;
                coreutilsEnv = "${pkgs.coreutils}/bin/env";
              }
              ''
                bash ${./lib/core/stop-marker-test.sh}
                touch $out
              '';

          # Variants need bubblewrap, so on darwin an app with Bazel-version
          # shells is the refusal, with the status of a namespace that cannot
          # be made, and one without them is not. Bubblewrap is allowed to
          # evaluate there, so only the app keeps it out. Pure evaluation
          # cannot read a derivation, so the build reads each.
          update-locks-darwin =
            let
              app =
                shells:
                coreLib.mkUpdateLocksApp {
                  pkgs = import nixpkgs {
                    system = "aarch64-darwin";
                    config.allowUnsupportedSystem = true;
                  };
                  inherit shells;
                  probes = [ [ "//..." ] ];
                };
              # The derivation a program's string refers to.
              drvOf =
                program:
                let
                  drvs = builtins.attrNames (builtins.getContext program);
                  drv = builtins.head drvs;
                in
                assert builtins.length drvs == 1;
                builtins.appendContext drv { ${drv}.path = true; };
            in
            pkgs.runCommand "flazel-update-locks-darwin-test"
              {
                withShells = drvOf (app [ "bazel8" ]).program;
                withoutShells = drvOf (app [ ]).program;
              }
              ''
                refusal="Bazel-version shells need Linux"
                grep -qF "$refusal" "$withShells" || {
                  echo "FAIL: an app with shells is not the refusal" >&2
                  exit 1
                }
                grep -qF "exit 6" "$withShells" || {
                  echo "FAIL: the refusal does not exit 6" >&2
                  exit 1
                }
                if grep -qF -- -bubblewrap- "$withShells"; then
                  echo "FAIL: an app with shells needs bubblewrap" >&2
                  exit 1
                fi
                if grep -qF "$refusal" "$withoutShells"; then
                  echo "FAIL: an app without shells refuses" >&2
                  exit 1
                fi
                touch $out
              '';
        };

        # The gate. Every test project under tests/ is a flake of its own,
        # because that is how a consumer reaches flazel: through `flazel.url`
        # and `flazel.lib`. A check defined here would reach flazel's internals
        # instead and test less, and `nix flake check` cannot reach theirs,
        # since each takes this flake as an input. So the gate is an app that
        # enters each and runs its own checks, from the flazel root.
        apps.check-all = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "flazel-check-all" ''
              set -eu
              projects=$(${pkgs.findutils}/bin/find tests -mindepth 2 -maxdepth 2 \
                -name flake.nix -printf '%h\n' | ${pkgs.coreutils}/bin/sort)
              # An empty glob would otherwise report success for nothing.
              [ -n "$projects" ] || {
                echo "no tests/*/flake.nix: run this from the flazel root" >&2
                exit 1
              }
              failed=
              for d in $projects; do
                echo "=== $d"
                (cd "$d" && nix flake check "$@") || failed="$failed $d"
              done
              [ -z "$failed" ] || {
                echo "FAILED:$failed" >&2
                exit 1
              }
              echo "all test projects passed"
            ''
          );
        };
      }
    );
}
