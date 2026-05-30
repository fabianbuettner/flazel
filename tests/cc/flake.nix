{
  description = "flazel CC vertical integration test";

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

        caches = flazel.lib.mkBcrCaches {
          inherit pkgs;
          lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
        };

        # Each check builds the same project hermetically with a different CC
        # toolchain symlinked in as "default", then runs the freshly built
        # binary and test so the assertion is behavioral, not just "it linked".
        mkCcCheck =
          { name, cfg }:
          flazel.lib.cc.mkDerivation {
            inherit
              pkgs
              name
              cfg
              caches
              ;
            src = ./.;
            bazelCommand = "build //hello:hello //hello:hello_test";
            installPhase = ''
              mkdir -p $out/bin
              cp -L bazel-bin/hello/hello $out/bin/hello

              greeting=$(./bazel-bin/hello/hello)
              echo "binary output: $greeting"
              [ "$greeting" = "flazel cc ok" ] || {
                echo "FAIL: unexpected binary output" >&2
                exit 1
              }

              ./bazel-bin/hello/hello_test || {
                echo "FAIL: cc_test returned non-zero" >&2
                exit 1
              }
              echo "ok" > $out/result
            '';
          };

        gccCfg = flazel.lib.cc.mkConfig {
          inherit pkgs;
        };

        clangCfg = flazel.lib.cc.mkConfig {
          inherit pkgs;
          compiler = "clang";
        };
      in
      {
        # nix flake check builds both; nix build .#checks.<system>.clang runs one.
        checks = {
          gcc = mkCcCheck {
            name = "flazel-cc-gcc";
            cfg = gccCfg;
          };
          clang = mkCcCheck {
            name = "flazel-cc-clang";
            cfg = clangCfg;
          };
        };

        # Manual exploration: nix develop, then `bazel build //...`.
        devShells.default = flazel.lib.cc.mkDevShell {
          inherit pkgs caches;
          toolchains.default = gccCfg;
        };
      }
    );
}
