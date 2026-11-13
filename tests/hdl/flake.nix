{
  description = "flazel HDL (Verilator) integration test";

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

        # The default Bazel and every other supported version, each with its own
        # lockfile (nix run .#update-locks regenerates locks/).
        variants = flazel.lib.bazelVariants {
          inherit pkgs;
          root = ./.;
        };
        otherVariants = removeAttrs variants [ "default" ];
        cachesFor =
          variant:
          flazel.lib.mkBcrCaches {
            inherit pkgs;
            lockFile = flazel.lib.parseLockFile variant.lockFile;
          };

        moduleOverrides.verilator = flazel.lib.hdl.mkVerilatorModule {
          inherit pkgs;
          inherit (pkgs) verilator;
        };

        gccCfg = flazel.lib.cc.mkConfig { inherit pkgs; };
        clangCfg = flazel.lib.cc.mkConfig {
          inherit pkgs;
          compiler = "clang";
        };

        # Every test compares RTL against a C++ model, except the mutant one,
        # which passes only if that comparison catches a wrong tap.
        mkHdlCheck =
          {
            name,
            cfg,
            variant ? variants.default,
          }:
          flazel.lib.cc.mkDerivation {
            inherit
              pkgs
              name
              cfg
              moduleOverrides
              ;
            caches = cachesFor variant;
            inherit (variant) bazel;
            lockFile = variant.lockOverride;
            src = ./.;
            bazelCommand = "test --test_output=all //...";
            installPhase = ''
              mkdir -p $out
              echo ok > $out/result
            '';
          };

        mkShell =
          variant:
          flazel.lib.cc.mkDevShell {
            inherit pkgs moduleOverrides;
            inherit (variant) bazel lockfileMode;
            caches = cachesFor variant;
            toolchains.default = gccCfg;
          };
      in
      {
        checks = {
          gcc = mkHdlCheck {
            name = "flazel-hdl-gcc";
            cfg = gccCfg;
          };
          clang = mkHdlCheck {
            name = "flazel-hdl-clang";
            cfg = clangCfg;
          };
        }
        // pkgs.lib.concatMapAttrs (_: variant: {
          "gcc${variant.suffix}" = mkHdlCheck {
            name = "flazel-hdl-gcc${variant.suffix}";
            cfg = gccCfg;
            inherit variant;
          };
        }) otherVariants;

        # nix develop, then `bazel test //...`.
        devShells = builtins.mapAttrs (_: mkShell) variants;

        # nix run .#update-locks regenerates locks/ (run in this directory).
        apps.update-locks = flazel.lib.mkUpdateLocksApp {
          inherit pkgs;
          shells = builtins.attrNames otherVariants;
        };
      }
    );
}
