{
  description = "flazel Rust vertical integration test";

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
          targets = [
            "x86_64-unknown-linux-gnu"
            "aarch64-apple-ios"
            "aarch64-unknown-linux-musl"
          ];
        };

        caches = flazel.lib.mkBcrCaches {
          inherit pkgs;
          lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
          # Downloads hidden from the lockfile by reproducible module
          # extensions (rules_rust internal crates). Regenerate with
          # `flazel-lock-archives` after a dependency change.
          extraArchives = flazel.lib.parseArchiveManifest ./flazel-archives.json;
        };

        cargoBazel = flazel.lib.rust.mkCargoBazel { inherit pkgs; };
      in
      {
        # Hermetic OFFLINE build of the crate_universe binary (serde/tokio etc.),
        # using the committed vendored defs + crate archives from the Nix cache.
        checks.rust = flazel.lib.rust.mkDerivation {
          inherit pkgs caches cargoBazel;
          cfg = rustCfg;
          ccToolchains.default = ccCfg;
          name = "flazel-rust-crates";
          src = ./.;
          bazelCommand = "build //hello:hello_bin";
          installPhase = ''
            got=$(./bazel-bin/hello/hello_bin)
            echo "binary: $got"
            [ "$got" = "Hello, flazel!" ] || {
              echo "FAIL: $got" >&2
              exit 1
            }
            mkdir -p "$out"
            echo ok > "$out/result"
          '';
        };

        devShells.default = flazel.lib.rust.mkDevShell {
          inherit pkgs caches cargoBazel;
          flazelPath = flazel.outPath;
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
