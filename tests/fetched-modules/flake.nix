{
  description = "flazel offline builds that cache only the modules a build fetches";

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

        # Each configuration fetches a module the other does not; the manifest
        # holds both because update-locks probes both.
        configurations = {
          zlib = {
            flags = [ ];
            expect = "flazel fetched modules ok: 1.3.1";
          };
          lz4 = {
            flags = [ "--define=compressor=lz4" ];
            expect = "flazel fetched modules ok: 1.10.0";
          };
        };

        mkCheck =
          variant: configuration:
          let
            c = configurations.${configuration};
          in
          flazel.lib.cc.mkDerivation {
            inherit pkgs;
            inherit (variant) bazel;
            caches = cachesFor variant;
            lockFile = variant.lockOverride;
            cfg = ccCfg;
            name = "flazel-fetched-modules-${configuration}${variant.suffix}";
            src = ./.;
            bazelCommand = "build ${toString c.flags} //:hello";
            installPhase = ''
              mkdir -p $out/bin
              cp -L bazel-bin/hello $out/bin/hello

              got=$(./bazel-bin/hello)
              echo "binary output: $got"
              [ "$got" = "${c.expect}" ] || {
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
        checks = builtins.listToAttrs (
          pkgs.lib.concatMap (
            variant:
            map (configuration: {
              name = "fetched-modules-${configuration}${variant.suffix}";
              value = mkCheck variant configuration;
            }) (builtins.attrNames configurations)
          ) (builtins.attrValues variants)
        );

        devShells = builtins.mapAttrs (_: mkShell) variants;

        # nix run .#update-locks regenerates locks/ and the manifests (run in
        # this directory).
        apps.update-locks = flazel.lib.mkUpdateLocksApp {
          inherit pkgs;
          shells = builtins.attrNames (removeAttrs variants [ "default" ]);
          probes = pkgs.lib.mapAttrsToList (_: c: c.flags ++ [ "//..." ]) configurations;
        };
      }
    );
}
