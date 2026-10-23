{
  description = "flazel hermetic rust mkDerivation test (no crate_universe)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flazel = {
      url = "path:../..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      flazel,
      rust-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        ccCfg = flazel.lib.cc.mkConfig {
          inherit pkgs;
        };

        rustCfg = flazel.lib.rust.mkConfig {
          inherit pkgs;
          # >= 1.95 deliberately: std ships stub rlibs + separate .rmeta there,
          # so this test covers the toolchain's .rmeta glob (the other rust
          # tests stay on 1.85 to keep covering the embedded-metadata layout).
          rustVersion = "1.95.0";
        };

        # The default Bazel and every other supported version, each with its own
        # lockfile and archive manifest (nix run .#update-locks regenerates
        # locks/; the default ones come from flazel-lock-archives).
        variants = flazel.lib.bazelVariants {
          inherit pkgs;
          root = ./.;
        };
        cachesFor =
          variant:
          flazel.lib.mkBcrCaches {
            inherit pkgs;
            lockFile = flazel.lib.parseLockFile variant.lockFile;
            # Downloads hidden from the lockfile by reproducible module
            # extensions (rules_rust internal crates).
            extraArchives = flazel.lib.parseArchiveManifest variant.archives;
          };

        # Hermetic build of a rust binary through mkDerivation, then run it.
        # Verifies the Nix rustc + the CC linker wiring end to end.
        mkCheck =
          variant:
          flazel.lib.rust.mkDerivation {
            inherit pkgs;
            inherit (variant) bazel;
            caches = cachesFor variant;
            lockFile = variant.lockOverride;
            cfg = rustCfg;
            ccToolchains.default = ccCfg;
            name = "flazel-rust-min${variant.suffix}";
            src = ./.;
            bazelCommand = "build //:hello";
            installPhase = ''
              mkdir -p $out/bin
              cp -L bazel-bin/hello $out/bin/hello

              got=$(./bazel-bin/hello)
              echo "binary output: $got"
              [ "$got" = "flazel rust ok" ] || {
                echo "FAIL: unexpected binary output" >&2
                exit 1
              }
            '';
          };

        # Manual exploration: nix develop (or .#bazel8, ...), then `bazel build //...`.
        mkShell =
          variant:
          flazel.lib.rust.mkDevShell {
            inherit pkgs;
            inherit (variant) bazel lockfileMode;
            caches = cachesFor variant;
            toolchains.default = rustCfg;
            ccToolchains.default = ccCfg;
          };
      in
      {
        checks = pkgs.lib.mapAttrs' (
          _: variant: pkgs.lib.nameValuePair "rust${variant.suffix}" (mkCheck variant)
        ) variants;

        devShells = builtins.mapAttrs (_: mkShell) variants;

        # nix run .#update-locks regenerates locks/ (run in this directory).
        apps.update-locks = flazel.lib.mkUpdateLocksApp {
          inherit pkgs;
          shells = builtins.attrNames (removeAttrs variants [ "default" ]);
          archives = true;
        };
      }
    );
}
