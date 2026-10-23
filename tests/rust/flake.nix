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

        # The default Bazel and every other supported version, each with its own
        # lockfile and archive manifest (nix run .#update-locks regenerates
        # locks/; the default ones come from flazel-lock-archives).
        variants = flazel.lib.bazelVariants {
          inherit pkgs;
          root = ./.;
        };
        inputsFor =
          variant:
          let
            lockFile = flazel.lib.parseLockFile variant.lockFile;
          in
          {
            caches = flazel.lib.mkBcrCaches {
              inherit pkgs lockFile;
              # Downloads hidden from the lockfile by reproducible module
              # extensions (rules_rust internal crates).
              extraArchives = flazel.lib.parseArchiveManifest variant.archives;
            };
            # The variant's lockfile is written by a dev shell that already
            # needs cargo-bazel; until then the default one, which declares
            # the same rules_rust, determines its version.
            cargoBazel = flazel.lib.rust.mkCargoBazel {
              inherit pkgs;
              lockFile = flazel.lib.parseLockFile (
                if builtins.pathExists variant.lockFile then variant.lockFile else variants.default.lockFile
              );
            };
          };

        # Hermetic OFFLINE build of the crate_universe binary (serde/tokio etc.),
        # using the committed vendored defs + crate archives from the Nix cache.
        mkCheck =
          variant:
          flazel.lib.rust.mkDerivation {
            inherit pkgs;
            inherit (variant) bazel;
            inherit (inputsFor variant) caches cargoBazel;
            lockFile = variant.lockOverride;
            cfg = rustCfg;
            ccToolchains.default = ccCfg;
            name = "flazel-rust-crates${variant.suffix}";
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

        mkShell =
          variant:
          flazel.lib.rust.mkDevShell {
            inherit pkgs;
            inherit (variant) bazel lockfileMode;
            inherit (inputsFor variant) caches cargoBazel;
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
