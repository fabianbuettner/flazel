{
  description = "flazel vendored crate_universe offline test";

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

        ccCfg = flazel.lib.cc.mkConfig { inherit pkgs; };
        rustCfg = flazel.lib.rust.mkConfig {
          inherit pkgs;
          rustVersion = "1.85.0";
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
        # Hermetic OFFLINE build of a binary using a vendored crate. Added once
        # 3rdparty/crates is generated (nix develop -c bazel run //:crate_vendor).
        checks.vendor = flazel.lib.rust.mkDerivation {
          inherit pkgs caches;
          cfg = rustCfg;
          ccToolchains.default = ccCfg;
          name = "flazel-rust-vendor";
          src = ./.;
          bazelCommand = "build //:vendor_hello";
          installPhase = ''
            got=$(./bazel-bin/vendor_hello)
            echo "binary: $got"
            [ "$got" = "itoa: 42" ] || {
              echo "FAIL: $got" >&2
              exit 1
            }
            mkdir -p "$out"
            echo ok > "$out/result"
          '';
        };

        # Used to (re)vendor and to generate locks: nix develop, then
        # `bazel run //:crate_vendor`.
        devShells.default = flazel.lib.rust.mkDevShell {
          inherit pkgs caches cargoBazel;
          toolchains.default = rustCfg;
          ccToolchains.default = ccCfg;
        };
      }
    );
}
