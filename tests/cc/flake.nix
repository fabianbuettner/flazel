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
          {
            name,
            cfg,
            pkg ? "hello",
            bin ? "hello",
            expect ? "flazel cc ok",
            runTest ? true,
          }:
          flazel.lib.cc.mkDerivation {
            inherit
              pkgs
              name
              cfg
              caches
              ;
            src = ./.;
            bazelCommand = "build //${pkg}:${bin}" + (if runTest then " //${pkg}:${bin}_test" else "");
            installPhase = ''
              mkdir -p $out/bin
              cp -L bazel-bin/${pkg}/${bin} $out/bin/${bin}

              greeting=$(./bazel-bin/${pkg}/${bin})
              echo "binary output: $greeting"
              [ "$greeting" = "${expect}" ] || {
                echo "FAIL: unexpected binary output (got: $greeting)" >&2
                exit 1
              }
              ${pkgs.lib.optionalString runTest ''
                ./bazel-bin/${pkg}/${bin}_test || {
                  echo "FAIL: cc_test returned non-zero" >&2
                  exit 1
                }
              ''}
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

        # Fully static (musl) toolchain: the other axis of static-vs-dynamic.
        # Produces a binary with no dynamic dependencies at all.
        staticCfg = flazel.lib.cc.mkConfig {
          inherit pkgs;
          static = true;
        };

        # Freestanding (no libc) toolchain: -ffreestanding compile side +
        # -nostdlib link side. Kept on the x86_64-linux triple so the resulting
        # bare binary still runs in the build sandbox via raw syscalls.
        freestandingCfg = flazel.lib.cc.mkConfig {
          inherit pkgs;
          target = {
            triple = "x86_64-unknown-linux-gnu";
            libc = null;
            libcName = "none";
            freestanding = true;
          };
        };
      in
      {
        # nix flake check builds all; nix build .#checks.<system>.clang runs one.
        checks = {
          gcc = mkCcCheck {
            name = "flazel-cc-gcc";
            cfg = gccCfg;
          };
          clang = mkCcCheck {
            name = "flazel-cc-clang";
            cfg = clangCfg;
          };
          static = mkCcCheck {
            name = "flazel-cc-static";
            cfg = staticCfg;
          };
          freestanding = mkCcCheck {
            name = "flazel-cc-freestanding";
            cfg = freestandingCfg;
            pkg = "freestanding";
            bin = "freestanding";
            expect = "flazel freestanding ok";
            runTest = false;
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
