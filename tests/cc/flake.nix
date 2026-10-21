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
            # Shared libraries of the package the binary loads at run time.
            sharedLibs ? [ ],
            # Extra bazel flags, e.g. the platform of a cross toolchain.
            bazelFlags ? "",
            # File name extension of executables (".exe" on Windows).
            exe ? "",
            # Command that runs a built executable (e.g. wine for Windows).
            runner ? "",
          }:
          flazel.lib.cc.mkDerivation {
            inherit
              pkgs
              name
              cfg
              caches
              ;
            src = ./.;
            bazelCommand =
              "build ${bazelFlags} //${pkg}:${bin}" + (if runTest then " //${pkg}:${bin}_test" else "");
            installPhase = ''
              mkdir -p $out/bin
              cp -L bazel-bin/${pkg}/${bin}${exe} $out/bin/${bin}${exe}
              ${pkgs.lib.concatMapStrings (lib: ''
                mkdir -p $out/lib
                cp -L bazel-bin/${pkg}/${lib} $out/lib/${lib}
              '') sharedLibs}

              greeting=$(${runner} ./bazel-bin/${pkg}/${bin}${exe} | tr -d '\r')
              echo "binary output: $greeting"
              [ "$greeting" = "${expect}" ] || {
                echo "FAIL: unexpected binary output (got: $greeting)" >&2
                exit 1
              }
              ${pkgs.lib.optionalString runTest ''
                ${runner} ./bazel-bin/${pkg}/${bin}_test${exe} || {
                  echo "FAIL: cc_test returned non-zero" >&2
                  exit 1
                }
              ''}
              echo "ok" > $out/result
            '';
          };

        # 32-bit Windows (mingw-w64), the binaries run under Wine.
        mingw32 = pkgs.pkgsCross.mingw32;
        mingw32Cfg = flazel.lib.cc.mkConfig {
          inherit pkgs;
          gcc = mingw32.buildPackages.gcc;
          target = {
            triple = "i686-w64-mingw32";
            libc = mingw32.windows.mingw_w64;
            libcName = "mingw";
            threads = mingw32.windows.mcfgthreads;
          };
        };
        # Runs a Windows executable under Wine: headless, throwaway prefix.
        wineRunner = pkgs.writeShellScript "wine-run" ''
          export WINEPREFIX="$TMPDIR/wine" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
          export HOME="$TMPDIR" XDG_RUNTIME_DIR="$TMPDIR/runtime"
          mkdir -p "$XDG_RUNTIME_DIR"
          unset DISPLAY WAYLAND_DISPLAY
          exec ${pkgs.wineWow64Packages.stable}/bin/wine "$@" 2>/dev/null
        '';

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
          # A cc_shared_library loaded at run time (supports_pic).
          shared-gcc = mkCcCheck {
            name = "flazel-cc-shared-gcc";
            cfg = gccCfg;
            pkg = "shared";
            bin = "shared";
            runTest = false;
            sharedLibs = [ "libprinter.so" ];
          };
          shared-clang = mkCcCheck {
            name = "flazel-cc-shared-clang";
            cfg = clangCfg;
            pkg = "shared";
            bin = "shared";
            runTest = false;
            sharedLibs = [ "libprinter.so" ];
          };
          mingw32 = mkCcCheck {
            name = "flazel-cc-mingw32";
            cfg = mingw32Cfg;
            bazelFlags = "--platforms=@local_config_cc_default//:platform";
            exe = ".exe";
            runner = "${wineRunner}";
          };
          # std::thread and std::mutex, natively and on Windows (mcfgthread).
          threads-gcc = mkCcCheck {
            name = "flazel-cc-threads-gcc";
            cfg = gccCfg;
            pkg = "threads";
            bin = "threads";
            runTest = false;
          };
          threads-mingw32 = mkCcCheck {
            name = "flazel-cc-threads-mingw32";
            cfg = mingw32Cfg;
            pkg = "threads";
            bin = "threads";
            runTest = false;
            bazelFlags = "--platforms=@local_config_cc_default//:platform";
            exe = ".exe";
            runner = "${wineRunner}";
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
        # nix develop .#mingw32, then
        # `bazel build --platforms=@local_config_cc_default//:platform //hello:hello`.
        devShells.mingw32 = flazel.lib.cc.mkDevShell {
          inherit pkgs caches;
          toolchains.default = mingw32Cfg;
        };
      }
    );
}
