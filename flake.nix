# flazel - Hermetic Bazel builds with Nix
#
# This flake provides a library of functions for integrating Nix with Bazel.
# It enables hermetic builds with configurable toolchains, static/dynamic
# linking, and automatic BCR dependency caching.
#
# Structure:
#   lib/core/  - Language-agnostic core (BCR caching, generic derivations)
#   lib/cc/    - C/C++ specific (toolchain, library repos)
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
      # Automatically inject flazelPath into functions that need it
      withFlazelPath = fn: args: fn (args // { flazelPath = self.outPath; });

      # Import core modules once
      coreDeriv = import ./lib/core/derivation.nix;

      # Core library functions (language-agnostic)
      coreLib = {
        # BCR cache generation
        inherit (import ./lib/core/bcr-cache.nix) mkBcrCaches parseLockFile;

        # Utility functions
        getTransitiveDeps = import ./lib/core/utils.nix;

        # Generic derivation builders (auto-inject flazelPath)
        mkFlazelDerivation = withFlazelPath coreDeriv.mkFlazelDerivation;
        mkFlazelDepsSetup = withFlazelPath coreDeriv.mkFlazelDepsSetup;

        # Generic dev shell (auto-inject flazelPath)
        mkFlazelDevShell = withFlazelPath (import ./lib/core/dev-shell.nix);
      };

      # C/C++ specific library functions
      ccLib = {
        # CC toolchain configuration
        mkConfig = import ./lib/cc/toolchain.nix;

        # CC library repo generation
        mkNixpkgsRepo = import ./lib/cc/nixpkgs-repo.nix;

        # CC-specific derivation (auto-inject flazelPath)
        mkDerivation = withFlazelPath (import ./lib/cc/derivation.nix);

        # CC-specific dev shell (auto-inject flazelPath)
        mkDevShell = withFlazelPath (import ./lib/cc/dev-shell.nix);
      };

      # Rust specific library functions
      rustLib = {
        # Rust toolchain configuration
        mkConfig = import ./lib/rust/toolchain.nix;

        # Rust-specific derivation (auto-inject flazelPath)
        mkDerivation = withFlazelPath (import ./lib/rust/derivation.nix);

        # Rust-specific dev shell (auto-inject flazelPath)
        mkDevShell = withFlazelPath (import ./lib/rust/dev-shell.nix);
      };
    in
    {
      # Expose library functions and rust-overlay for consumers
      lib = coreLib // {
        cc = ccLib;
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
            echo "  nix flake check - run checks"
          '';
        };

        # Formatting
        formatter = treefmtEval.config.build.wrapper;

        # Provide checks/tests for flazel itself
        checks = {
          formatting = treefmtEval.config.build.check self;

          # Basic syntax check - ensure all lib files are valid Nix
          libSyntax = pkgs.runCommand "flazel-lib-syntax-check" { } ''
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/core/utils.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/core/bcr-cache.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/core/derivation.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/core/dev-shell.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/core/platform.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/cc/toolchain.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/cc/nixpkgs-repo.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/cc/derivation.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/cc/dev-shell.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/rust/toolchain.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/rust/dev-shell.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/rust/derivation.nix} > /dev/null
            ${pkgs.nix}/bin/nix-instantiate --parse ${./lib/rust/cargo-bazel.nix} > /dev/null
            touch $out
          '';
        };
      }
    );
}
