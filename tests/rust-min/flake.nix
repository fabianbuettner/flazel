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
          rustVersion = "1.85.0";
        };

        caches = flazel.lib.mkBcrCaches {
          inherit pkgs;
          lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
        };
      in
      {
        # Hermetic build of a rust binary through mkDerivation, then run it.
        # Verifies the Nix rustc + the CC linker wiring end to end.
        checks.rust = flazel.lib.rust.mkDerivation {
          inherit pkgs caches;
          cfg = rustCfg;
          ccToolchains = {
            default = ccCfg;
          };
          name = "flazel-rust-min";
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

        # Manual exploration: nix develop, then `bazel build //...`.
        devShells.default = flazel.lib.rust.mkDevShell {
          inherit pkgs caches;
          toolchains = {
            default = rustCfg;
          };
          ccToolchains = {
            default = ccCfg;
          };
        };
      }
    );
}
