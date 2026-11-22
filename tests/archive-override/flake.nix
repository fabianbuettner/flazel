{
  description = "flazel offline build of a module taken from an archive_override";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flazel = {
      url = "path:../..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      flazel,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        ccCfg = flazel.lib.cc.mkConfig { inherit pkgs; };

        # The default Bazel and every other supported version, each with its own
        # lockfile and archive manifest (nix run .#update-locks regenerates them).
        variants = flazel.lib.bazelVariants {
          inherit pkgs;
          root = ./.;
        };
        cachesFor =
          variant:
          flazel.lib.mkBcrCaches {
            inherit pkgs;
            lockFile = flazel.lib.parseLockFile variant.lockFile;
            archives = flazel.lib.parseArchiveManifest variant.archives;
          };

        mkCheck =
          variant:
          flazel.lib.cc.mkDerivation {
            inherit pkgs;
            inherit (variant) bazel;
            caches = cachesFor variant;
            lockFile = variant.lockOverride;
            cfg = ccCfg;
            name = "flazel-archive-override${variant.suffix}";
            src = ./.;
            bazelCommand = "build //:hello //:downloads";
            installPhase = ''
              mkdir -p $out/bin
              cp -L bazel-bin/hello $out/bin/hello

              [ -s bazel-bin/downloads.txt ] || {
                echo "FAIL: no downloads" >&2
                exit 1
              }

              got=$(./bazel-bin/hello)
              echo "binary output: $got"
              [ "$got" = "flazel archive_override ok" ] || {
                echo "FAIL: unexpected binary output" >&2
                exit 1
              }
            '';
          };

        mkShell =
          variant:
          flazel.lib.cc.mkDevShell {
            inherit pkgs;
            inherit (variant) bazel lockfileMode;
            caches = cachesFor variant;
            toolchains.default = ccCfg;
          };
      in
      {
        checks = pkgs.lib.mapAttrs' (
          _: variant: pkgs.lib.nameValuePair "archive-override${variant.suffix}" (mkCheck variant)
        ) variants;

        devShells = builtins.mapAttrs (_: mkShell) variants;

        # nix run .#update-locks regenerates locks/ and the manifests (run in
        # this directory).
        apps.update-locks = flazel.lib.mkUpdateLocksApp {
          inherit pkgs;
          shells = builtins.attrNames (removeAttrs variants [ "default" ]);
          probes = [ [ "//..." ] ];
        };
      }
    );
}
