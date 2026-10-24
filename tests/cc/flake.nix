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
        caches = cachesFor variants.default;

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
            # Shared libraries the binary loads at run time, relative to its
            # package's output directory.
            sharedLibs ? [ ],
            # Extra bazel flags, e.g. the platform of a cross toolchain.
            bazelFlags ? "",
            # File name extension of executables (".exe" on Windows).
            exe ? "",
            # Command that runs a built executable (e.g. wine for Windows).
            runner ? "",
            variant ? variants.default,
          }:
          let
            # Native tests run under `bazel test`, which also exercises Bazel's
            # test runner; a cross-compiled test runs through `runner` instead.
            bazelTest = runTest && runner == "";
          in
          flazel.lib.cc.mkDerivation {
            inherit
              pkgs
              name
              cfg
              ;
            caches = cachesFor variant;
            inherit (variant) bazel;
            lockFile = variant.lockOverride;
            src = ./.;
            bazelCommand =
              (if bazelTest then "test" else "build")
              + " ${bazelFlags} //${pkg}:${bin}"
              + (if runTest then " //${pkg}:${bin}_test" else "");
            installPhase = ''
              mkdir -p $out/bin
              cp -L bazel-bin/${pkg}/${bin}${exe} $out/bin/${bin}${exe}
              ${pkgs.lib.concatMapStrings (lib: ''
                mkdir -p $out/lib
                cp -L bazel-bin/${pkg}/${lib} $out/lib/
              '') sharedLibs}

              greeting=$(${runner} ./bazel-bin/${pkg}/${bin}${exe} | tr -d '\r')
              echo "binary output: $greeting"
              [ "$greeting" = "${expect}" ] || {
                echo "FAIL: unexpected binary output (got: $greeting)" >&2
                exit 1
              }
              ${pkgs.lib.optionalString (runTest && !bazelTest) ''
                ${runner} ./bazel-bin/${pkg}/${bin}_test${exe} || {
                  echo "FAIL: cc_test returned non-zero" >&2
                  exit 1
                }
              ''}
              echo "ok" > $out/result
            '';
          };

        # Windows (mingw-w64) from a nixpkgs cross package set.
        mkMingwCfg =
          cross:
          flazel.lib.cc.mkConfig {
            inherit pkgs;
            gcc = cross.buildPackages.gcc;
            target = {
              triple = cross.stdenv.hostPlatform.config;
              libc = cross.windows.mingw_w64;
              libcName = "mingw";
              threads = cross.windows.mcfgthreads;
            };
          };
        mingw32Cfg = mkMingwCfg pkgs.pkgsCross.mingw32;
        mingw64Cfg = mkMingwCfg pkgs.pkgsCross.mingwW64;
        # Runs a Windows executable under Wine: headless, throwaway prefix.
        wineRunner = pkgs.writeShellScript "wine-run" ''
          export WINEPREFIX="$TMPDIR/wine" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
          export HOME="$TMPDIR" XDG_RUNTIME_DIR="$TMPDIR/runtime"
          mkdir -p "$XDG_RUNTIME_DIR"
          unset DISPLAY WAYLAND_DISPLAY
          exec ${pkgs.wineWow64Packages.stable}/bin/wine "$@" 2>/dev/null
        '';

        # A header-only package whose public header includes a .inc fragment and
        # an extensionless header, as LLVM and the C++ standard library do, and
        # warns unless included as a system header.
        headersProbe = pkgs.runCommand "flazel-headers-probe" { } ''
          mkdir -p $out/include/probe
          cat > $out/include/probe/probe.h <<'EOF'
          #pragma once
          #include "probe/message.inc"
          #include "probe/Suffix"
          #define PROBE_MESSAGE PROBE_PREFIX " " PROBE_SUFFIX
          inline int probe_unused(int unused) { return 0; }
          EOF
          echo '#define PROBE_PREFIX "flazel headers"' > $out/include/probe/message.inc
          echo '#define PROBE_SUFFIX "ok"' > $out/include/probe/Suffix
        '';

        gccCfg = flazel.lib.cc.mkConfig {
          inherit pkgs;
          nixpkgsLibs = {
            headers_probe = headersProbe;
            zlib = pkgs.zlib;
          };
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

        # Three toolchains for one triple, each with its own zlib; clang's
        # differs from gcc's only in the store path the probe's RUNPATH names.
        clangZlib = pkgs.zlib.overrideAttrs { FLAZEL_VARIANT = "clang"; };
        selectionToolchains = {
          default = gccCfg;
          clang = flazel.lib.cc.mkConfig {
            inherit pkgs;
            toolchainName = "clang";
            compiler = "clang";
            clang = pkgs.clang;
            nixpkgsLibs.zlib = clangZlib;
          };
          musl = flazel.lib.cc.mkConfig {
            inherit pkgs;
            toolchainName = "musl";
            static = true;
            nixpkgsLibs.zlib = pkgs.pkgsStatic.zlib;
          };
        };
        major = version: builtins.head (pkgs.lib.splitString "." version);
        # Expected probe output per toolchain; zlib is a store path or "static".
        probeIdentity = {
          default = "gcc ${major gccCfg.gcc.version} glibc";
          clang = "clang ${major pkgs.clang.cc.version} glibc";
          musl = "gcc ${major selectionToolchains.musl.gcc.version} no-glibc";
        };
        probeZlib = {
          default = "${pkgs.zlib}/lib";
          clang = "${clangZlib}/lib";
          musl = "static";
        };

        # Runs a dev shell's hook in the sandbox, then `script`.
        mkShellCheck =
          {
            name,
            variant,
            shell,
            script,
          }:
          pkgs.stdenv.mkDerivation {
            name = "flazel-cc-${name}${variant.suffix}";
            src = ./.;
            nativeBuildInputs = [
              variant.bazel
              pkgs.jq
            ];
            buildPhase = ''
              export HOME=$TMPDIR
              ${pkgs.lib.optionalString (variant.lockOverride != null) ''
                cp ${variant.lockOverride} MODULE.bazel.lock
                chmod u+w MODULE.bazel.lock
              ''}
              ${(flazel.lib.cc.mkDevShell (
                {
                  inherit pkgs;
                  inherit (variant) bazel lockfileMode;
                  caches = cachesFor variant;
                  startupOptions = [ "--output_user_root=$TMPDIR/bazel" ];
                }
                // shell
              )).shellHook
              }
              patchShebangs --build "$(bazel info install_base)/embedded_tools" >/dev/null
              failed=0
              fail() {
                echo "FAIL: $*" >&2
                failed=1
              }
              # Compiler repos of the actions aquery lists; $1: exec or target.
              compilers() {
                local want=$1
                shift
                bazel aquery "$@" --output=text \
                  | awk -v RS= -v want="$want" '(want == "exec") == /Configuration: [^\n]*-exec/' \
                  | { grep -o 'local_config_cc_[a-z0-9_]*/bin/gcc' || true; } | sort -u | tr '\n' ' '
              }
              ${script}
              [ "$failed" = 0 ]
            '';
            installPhase = "echo ok > $out";
          };

        # Per platform: which toolchain compiles the probe and its exec copy,
        # what the probe prints, and which zlib it links.
        mkSelectionCheck =
          {
            name,
            variant,
            shell,
            # Toolchain the exec platform resolves to.
            execToolchain,
            # [ platform toolchain ], "" for no --platforms.
            cases,
          }:
          mkShellCheck {
            inherit name variant shell;
            script = ''
              expect() {
                local platform=$1 tc=$2 want=$3 zlib=$4 flags=() used exec inputs got tool dyn linked
                [ -n "$platform" ] && flags=("--platforms=$platform")
                used=$(compilers target "''${flags[@]}" 'mnemonic("CppCompile", //:probe)')
                exec=$(compilers exec "''${flags[@]}" 'mnemonic("CppCompile", //:probe_exec + deps(//:probe_exec))')
                # Target configuration only; the exec copy has the host's zlib.
                inputs=$(bazel cquery "''${flags[@]}" --notool_deps 'deps(config(//:probe, target))' \
                  | { grep -o 'zlib_[a-z0-9]*//' || true; } | sort -u | tr '\n' ' ')
                bazel build "''${flags[@]}" //:probe //:probe_exec
                got=$(./bazel-bin/probe)
                tool=$(cat bazel-bin/probe_exec.txt)
                dyn=$(readelf -dW bazel-bin/probe 2>&1 || true)
                if grep -q NEEDED <<<"$dyn"; then
                  grep -q 'NEEDED.*\[libz\.so' <<<"$dyn" || fail "no libz NEEDED"
                  linked=$(grep -o "RUNPATH.*" <<<"$dyn" | tr ':[]' '\n\n\n' | grep -m1 '/nix/store/.*/lib$' | grep zlib || true)
                elif ! readelf -lW bazel-bin/probe | grep -q INTERP; then
                  linked=static
                else
                  linked=none
                fi
                echo "platform ''${platform:-<none>}: compiler $used-> $got, links $inputs-> zlib $linked; exec tool compiler $exec-> $tool"
                [ "$used" = "local_config_cc_$tc/bin/gcc " ] || fail "compiled by $used, want local_config_cc_$tc"
                [ "$exec" = "local_config_cc_${execToolchain}/bin/gcc " ] \
                  || fail "exec tool compiled by $exec, want local_config_cc_${execToolchain}"
                [ "$got" = "$want" ] || fail "probe says $got, want $want"
                [ "$tool" = "${probeIdentity.${execToolchain}}" ] \
                  || fail "exec tool says $tool, want ${probeIdentity.${execToolchain}}"
                [ "$inputs" = "zlib_$tc// " ] || fail "depends on $inputs, want zlib_$tc only"
                [ "$linked" = "$zlib" ] || fail "zlib $linked, want $zlib"
                if [ "$zlib" = static ]; then
                  # The archive linked holds pkgsStatic's libz.a, member for member.
                  local linked_a want_a=${pkgs.pkgsStatic.zlib}/lib/libz.a m
                  linked_a=$(echo "$(bazel info output_base)/external/"*"zlib_$tc/lib/"*.a)
                  [ "$(ar t "$linked_a" | sort)" = "$(ar t $want_a | sort)" ] \
                    || fail "linked archive members differ from $want_a"
                  for m in $(ar t $want_a); do
                    cmp -s <(ar p "$linked_a" $m) <(ar p $want_a $m) || fail "$m differs from $want_a"
                  done
                fi
              }

              ${pkgs.lib.concatMapStrings (
                case:
                let
                  tc = builtins.elemAt case 1;
                in
                ''
                  expect "${builtins.elemAt case 0}" ${tc} "${probeIdentity.${tc}}" "${probeZlib.${tc}}"
                ''
              ) cases}
            '';
          };

        # The host platform and each toolchain's own platform.
        selectionCases =
          host: tcs:
          [
            [
              "@bazel_tools//tools:host_platform"
              host
            ]
          ]
          ++ map (tc: [
            "@local_config_cc_${tc}//:platform"
            tc
          ]) tcs;
        allSelection = [
          "default"
          "clang"
          "musl"
        ];

        # Each toolchain by its platform; the one named "default" by none.
        mkSelection =
          variant:
          mkSelectionCheck {
            name = "selection";
            inherit variant;
            shell.toolchains = selectionToolchains;
            execToolchain = "default";
            cases = selectionCases "default" allSelection ++ [
              [
                "//:inherits_clang"
                "clang"
              ]
            ];
          };

        # An explicit default wins over the name and, being native, is the host.
        explicitDefault = mkSelectionCheck {
          name = "explicit-default";
          variant = variants.default;
          shell = {
            toolchains = selectionToolchains;
            defaultToolchain = "musl";
          };
          execToolchain = "musl";
          cases = selectionCases "musl" allSelection;
        };

        # A subset without the toolchain named "default"; with subset-derivation
        # the only check of a host that is not "default".
        subsetShell = mkSelectionCheck {
          name = "subset-shell";
          variant = variants.default;
          shell.toolchains = { inherit (selectionToolchains) clang; };
          execToolchain = "clang";
          cases = selectionCases "clang" [ "clang" ];
        };

        # A cross default: the native toolchain builds exec tools, never PATH's.
        crossDefault = mkShellCheck {
          name = "cross-default";
          variant = variants.default;
          shell.toolchains = {
            default = mingw64Cfg;
            inherit (selectionToolchains) clang;
          };
          script = ''
            target=$(compilers target 'mnemonic("CppCompile", //hello:hello)')
            exec=$(compilers exec 'mnemonic("CppCompile", //:probe_exec + deps(//:probe_exec))')
            bazel build //hello:hello //:probe_exec
            tool=$(cat bazel-bin/probe_exec.txt)
            magic=$(head -c2 bazel-bin/hello/hello.exe)
            echo "target compiler $target-> $magic executable; exec tool compiler $exec-> $tool"
            [ "$target" = "local_config_cc_default/bin/gcc " ] || fail "target compiled by $target"
            [ "$magic" = MZ ] || fail "hello.exe is not a Windows executable"
            [ "$exec" = "local_config_cc_clang/bin/gcc " ] || fail "exec tool compiled by $exec"
            [ "$tool" = "${probeIdentity.clang}" ] || fail "exec tool says $tool"
          '';
        };

        # No native toolchain: no exec tools, reported in toolchain resolution
        # (the wording differs between Bazel versions).
        mkCrossOnly =
          variant:
          mkShellCheck {
            name = "cross-only";
            inherit variant;
            shell.toolchains.default = mingw64Cfg;
            script = ''
              if bazel build //:probe_exec 2>$TMPDIR/err; then
                fail "built an exec tool without a toolchain for the build machine"
              fi
              grep -m1 -E 'Unable to find a CC toolchain|No matching toolchains found' $TMPDIR/err || true
              grep -qE 'Unable to find a CC toolchain using toolchain resolution|No matching toolchains found for types' $TMPDIR/err \
                || { tail $TMPDIR/err; fail "no toolchain-resolution error"; }
              if grep -q 'cc_configure_extension' $TMPDIR/err; then
                fail "rules_cc's autodetected toolchain took part"
              fi
            '';
          };

        # A missing library fails naming toolchain and library, never borrowing
        # another's; an unconfigured query must still succeed.
        missingLibrary = mkShellCheck {
          name = "missing-library";
          variant = variants.default;
          shell.toolchains = selectionToolchains // {
            clang = flazel.lib.cc.mkConfig {
              inherit pkgs;
              toolchainName = "clang";
              compiler = "clang";
              clang = pkgs.clang;
            };
          };
          script = ''
            msg="CC toolchain 'clang' does not provide zlib; add it to that toolchain's nixpkgsLibs."
            if bazel query 'deps(//:probe)' >/dev/null 2>$TMPDIR/query.err; then
              echo "query deps(//:probe): ok"
            else
              grep -m1 'ERROR\|Error' $TMPDIR/query.err || true
              fail "unconfigured query failed"
            fi
            for cmd in "cquery deps(//:probe)" "build //:probe"; do
              if bazel $cmd --platforms=@local_config_cc_clang//:platform 2>$TMPDIR/err; then
                fail "$cmd: used a zlib that toolchain clang does not provide"
              fi
              echo "$cmd: $(grep -m1 -oF "$msg" $TMPDIR/err || true)"
              grep -qF "$msg" $TMPDIR/err || fail "$cmd: the error does not name the toolchain and the library"
            done
          '';
        };

        # Flipping the host toolchain within one server re-runs the repo rules.
        mkMarkerFlip =
          variant:
          mkShellCheck {
            name = "marker-flip";
            inherit variant;
            shell.toolchains = selectionToolchains;
            script = ''
              kind() { bazel query --output=label_kind "@local_config_cc_$1//constraint:cc_toolchain" | cut -d' ' -f1; }
              pid=$(bazel info server_pid)
              before="$(kind default) $(kind clang)"
              jq '.host = "clang"' .nix-bazel-deps/cc_toolchains.json > $TMPDIR/flipped
              rm .nix-bazel-deps/cc_toolchains.json
              cp $TMPDIR/flipped .nix-bazel-deps/cc_toolchains.json
              after="$(kind default) $(kind clang)"
              echo "default, clang: $before -> $after"
              [ "$(bazel info server_pid)" = "$pid" ] || fail "the server restarted"
              [ "$before" = "alias constraint_value" ] || fail "before the flip: $before"
              [ "$after" = "constraint_value alias" ] || fail "after the flip: $after"
            '';
          };

        # PATH's tools come from the host, not the first toolchain by name.
        pathTools =
          let
            cross = pkgs.pkgsCross.mingwW64;
            windows = flazel.lib.cc.mkConfig {
              inherit pkgs;
              toolchainName = "a_windows";
              gcc = cross.buildPackages.gcc;
              target = {
                triple = cross.stdenv.hostPlatform.config;
                libc = cross.windows.mingw_w64;
                libcName = "mingw";
                threads = cross.windows.mcfgthreads;
              };
            };
            # As mkShell lists a package once it has spliced it.
            spliced = pkg: toString (builtins.head (pkgs.mkShell { packages = [ pkg ]; }).nativeBuildInputs);
            onPath =
              toolchains: cfg:
              let
                inputs =
                  map toString
                    (flazel.lib.cc.mkDevShell { inherit pkgs caches toolchains; }).nativeBuildInputs;
              in
              builtins.elem (spliced cfg.gcc) inputs && builtins.elem (spliced cfg.binutils) inputs;
            # The default can build for the build machine: it is the host.
            nativeDefault = onPath {
              a_windows = windows;
              default = gccCfg;
            } gccCfg;
            # A cross default: the only native toolchain is the host.
            crossDefault = onPath {
              default = mingw64Cfg;
              musl = selectionToolchains.musl;
            } selectionToolchains.musl;
          in
          pkgs.runCommand "flazel-cc-path-tools" { } (
            if nativeDefault && crossDefault then
              "touch $out"
            else
              ''
                echo "FAIL: host toolchain's gcc and binutils on PATH: native default ${pkgs.lib.boolToString nativeDefault}, cross default ${pkgs.lib.boolToString crossDefault}" >&2
                exit 1
              ''
          );

        # A shell without CC toolchains says so when a library is asked for.
        noToolchain = mkShellCheck {
          name = "no-toolchain";
          variant = variants.default;
          shell.toolchains = { };
          script = ''
            if bazel query @zlib//:zlib 2>$TMPDIR/err; then
              fail "resolved a library without a CC toolchain"
            fi
            grep -m1 'Error in fail' $TMPDIR/err || true
            grep -q 'This dev shell or build provides no CC toolchain' $TMPDIR/err \
              || fail "the error does not say the shell provides no CC toolchain"
          '';
        };

        # Several toolchains, no choice: an evaluation error, not an order pick.
        ambiguousShell =
          extra:
          flazel.lib.cc.mkDevShell (
            {
              inherit pkgs caches;
              toolchains = { inherit (selectionToolchains) clang musl; };
            }
            // extra
          );
        ambiguousDefault =
          let
            refused = !(builtins.tryEval (ambiguousShell { }).drvPath).success;
            chosen = (builtins.tryEval (ambiguousShell { defaultToolchain = "clang"; }).drvPath).success;
          in
          pkgs.runCommand "flazel-cc-ambiguous-default" { } (
            if refused && chosen then
              "touch $out"
            else
              ''
                echo "FAIL: ambiguous refused=${pkgs.lib.boolToString refused}, explicit accepted=${pkgs.lib.boolToString chosen}" >&2
                exit 1
              ''
          );

        # A host toolchain MODULE.bazel does not declare fails, naming it.
        undeclaredDefault = mkShellCheck {
          name = "undeclared-default";
          variant = variants.default;
          shell.toolchains.other = flazel.lib.cc.mkConfig {
            inherit pkgs;
            toolchainName = "other";
          };
          script = ''
            if bazel build //:probe 2>$TMPDIR/build.err; then
              fail "built without a declared host toolchain"
            fi
            grep -m1 ERROR $TMPDIR/build.err || true
            grep -q "local_config_cc_other" $TMPDIR/build.err || fail "the build error does not name the toolchain"
            if bazel query @zlib//:zlib 2>$TMPDIR/fetch.err; then
              fail "fetched a library without a declared host toolchain"
            fi
            grep -m1 ERROR $TMPDIR/fetch.err || true
            grep -qF 'nix_cc.toolchain(name = "other")' $TMPDIR/fetch.err \
              || fail "the fetch error does not name the undeclared host toolchain"
          '';
        };

        # layering_check and parse_headers under clang, and parse_headers under
        # GCC, asserted from the actions aquery lists and from builds that must
        # fail.
        mkClangCheck =
          variant:
          mkShellCheck {
            name = "clang-check";
            inherit variant;
            shell.toolchains = selectionToolchains;
            script = ''
              clang=--platforms=@local_config_cc_clang//:platform
              layering=--features=layering_check
              parse=(--features=parse_headers --process_headers_in_dependencies)
              argv() { bazel aquery "$@" --output=jsonproto | jq -r '(.actions // [])[].arguments | join(" ")' | sort; }
              must_fail() {
                local want=$1
                shift
                if bazel build "$@" 2>$TMPDIR/err; then
                  fail "built $*"
                elif grep -qF "$want" $TMPDIR/err; then
                  echo "fails as wanted: $want"
                else
                  grep -m3 error $TMPDIR/err || true
                  fail "$* did not fail with: $want"
                fi
              }

              # layering_check: module maps on the command line, a transitive
              # include refused, a direct one accepted.
              good=$(argv $clang $layering 'mnemonic("CppCompile", //clang_check:good)')
              for flag in -fmodules-strict-decluse '-fmodule-name=//clang_check:good' \
                '-fmodule-map-file=[^ ]*local_config_cc_clang/module.modulemap' \
                '-fmodule-map-file=[^ ]*/clang_check/base.cppmap'; do
                grep -q -- "$flag" <<<"$good" || fail "layering_check compile lacks $flag"
              done
              bazel build $clang $layering //clang_check:good || fail "layering_check refused a direct dependency"
              must_fail "module //clang_check:undeclared does not depend on a module exporting 'clang_check/base.h'" \
                $clang $layering //clang_check:undeclared

              # parse_headers: a .h.processed per header, a header that is not
              # self-contained refused.
              bazel build $clang "''${parse[@]}" //clang_check:self_contained || fail "parse_headers refused a self-contained header"
              [ -f bazel-bin/clang_check/_objs/self_contained/self_contained.h.processed ] \
                || fail "no self_contained.h.processed"
              must_fail "not_self_contained.h:3:8: error: use of undeclared identifier 'std'" \
                $clang "''${parse[@]}" //clang_check:not_self_contained
              # parse_headers_as_c parses a C header as C, with the C standard.
              bazel build $clang "''${parse[@]}" //clang_check:c_header || fail "parse_headers_as_c refused a C header"
              must_fail "c_only.h:4:45: error: cannot initialize return object of type 'int *'" \
                $clang "''${parse[@]}" //clang_check:c_header_as_cxx
              as_c=$(argv $clang "''${parse[@]}" 'mnemonic("CppCompile", //clang_check:c_header)')
              grep -q -- '-xc-header .*-std=c17\|-std=c17.*-xc-header' <<<"$as_c" || fail "parse_headers_as_c lacks -xc-header or -std=c17"
              if grep -q -- '-std=c++' <<<"$as_c"; then fail "parse_headers_as_c passes the C++ standard"; fi

              # Header parsing under -c opt sees the compile's -O and -D flags,
              # _FORTIFY_SOURCE included, and passes under -Werror.
              actions=$(argv -c opt $clang "''${parse[@]}" 'mnemonic("CppCompile", //clang_check:base)')
              defines() { { grep -- "$1" <<<"$actions" || true; } | { grep -oE -- ' -(O[0-9a-z]*|[DU][^ ]*)' || true; } | sort; }
              parsed=$(defines ' -fsyntax-only')
              compiled=$(defines ' -c clang_check/base.cc -o [^ ]*base.pic.o')
              echo "header parse: $(echo $parsed); compile: $(echo $compiled)"
              grep -q -- '-D_FORTIFY_SOURCE=3' <<<"$parsed" || fail "header parse lacks _FORTIFY_SOURCE"
              [ "$parsed" = "$compiled" ] || fail "header parse and compile differ in -O/-D flags"
              bazel build -c opt $clang "''${parse[@]}" $layering --features=treat_warnings_as_errors \
                //clang_check:base //clang_check:good //clang_check:self_contained \
                || fail "header parsing failed under -c opt and -Werror"

              # A nixpkgs library's headers are not parsed, while the project's are.
              parsing=$(bazel aquery $clang "''${parse[@]}" \
                'mnemonic("CppCompile", deps(//:probe) + //clang_check:self_contained)' --output=text)
              grep -q 'self_contained\.h\.processed' <<<"$parsing" || fail "header parsing is off"
              if grep -q 'zlib_clang/.*\.h\.processed' <<<"$parsing"; then
                fail "zlib's headers are parsed"
              fi
              bazel build $clang "''${parse[@]}" $layering //:probe || fail "the probe failed with both features"

              # Requesting nothing adds nothing: a plain compile equals one with
              # every feature of this change off, module_maps included. (Identity
              # with the previous flazel was measured once, outside this check.)
              targets='mnemonic("CppCompile|CppLink|CppArchive", //clang_check/... + //:probe)'
              off=(--features=-module_maps --features=-parse_headers --features=-layering_check)
              for platform in $clang ""; do
                plain=$(argv $platform "$targets")
                [ "$plain" = "$(argv $platform "''${off[@]}" "$targets")" ] \
                  || fail "''${platform:-gcc}: a plain build differs from one with the features off"
                if grep -qE -- '-fmodule|-fno-cxx-modules|-fsyntax-only|-xc\+\+-header' <<<"$plain"; then
                  fail "''${platform:-gcc}: a plain compile has a module or header-parse flag"
                fi
              done

              # GCC 15+: parse_headers as under clang; layering_check, which
              # needs clang modules, is ignored.
              gcc_plain=$(argv 'mnemonic("CppCompile", //clang_check/...)')
              [ "$gcc_plain" = "$(argv $layering 'mnemonic("CppCompile", //clang_check/...)')" ] \
                || fail "GCC compiles changed under layering_check"
              bazel build $layering //clang_check:undeclared || fail "GCC enforced layering_check"
              bazel build "''${parse[@]}" //clang_check:self_contained || fail "GCC refused a self-contained header"
              [ -f bazel-bin/clang_check/_objs/self_contained/self_contained.h.processed ] \
                || fail "GCC: no self_contained.h.processed"
              must_fail "not_self_contained.h:3:13: error:" \
                "''${parse[@]}" //clang_check:not_self_contained
              bazel build "''${parse[@]}" //clang_check:c_header || fail "GCC parse_headers_as_c refused a C header"
              bazel build "''${parse[@]}" --features=hidden_visibility --features=treat_warnings_as_errors \
                //clang_check:c_header || fail "GCC parse_headers_as_c got a C++-only flag"
              must_fail "c_only.h:4:45: error: invalid conversion from 'void*' to 'int*'" \
                "''${parse[@]}" //clang_check:c_header_as_cxx
              actions=$(argv -c opt "''${parse[@]}" 'mnemonic("CppCompile", //clang_check:base)')
              parsed=$(defines ' -fsyntax-only')
              compiled=$(defines ' -c clang_check/base.cc -o [^ ]*base.pic.o')
              echo "GCC header parse: $(echo $parsed); compile: $(echo $compiled)"
              grep -q -- '-D_FORTIFY_SOURCE=3' <<<"$parsed" || fail "GCC header parse lacks _FORTIFY_SOURCE"
              [ "$parsed" = "$compiled" ] || fail "GCC header parse and compile differ in -O/-D flags"
              bazel build -c opt "''${parse[@]}" --features=treat_warnings_as_errors \
                //clang_check:base //clang_check:good //clang_check:self_contained \
                || fail "GCC header parsing failed under -c opt and -Werror"
            '';
          };

        # GCC 14 cannot parse a #pragma once header cleanly, so its toolchain
        # does not offer parse_headers, and requesting it changes nothing.
        mkGcc14Check =
          variant:
          mkShellCheck {
            name = "gcc14-no-parse-headers";
            inherit variant;
            shell.toolchains.default = flazel.lib.cc.mkConfig {
              inherit pkgs;
              gcc = pkgs.gcc14;
            };
            script = ''
              parse=(--features=parse_headers --process_headers_in_dependencies)
              argv() { bazel aquery "$@" --output=jsonproto | jq -r '(.actions // [])[].arguments | join(" ")' | sort; }
              echo "compiler: $(.nix-bazel-deps/toolchains/default/cc/bin/gcc --version | head -1)"
              bazel query --output=build @local_config_cc_default//:local_config_cc_toolchain \
                | grep -q 'supports_header_parsing = False' || fail "the GCC 14 toolchain declares header parsing"
              targets='mnemonic("CppCompile", //clang_check/...)'
              requested=$(argv "''${parse[@]}" "$targets")
              [ "$requested" = "$(argv "$targets")" ] || fail "parse_headers changed GCC 14 compiles"
              if grep -q -- '-fsyntax-only' <<<"$requested"; then fail "GCC 14 has a header-parse action"; fi
              bazel build "''${parse[@]}" //clang_check:self_contained //clang_check:not_self_contained \
                || fail "GCC 14 parsed headers"
              if [ -e bazel-bin/clang_check/_objs/self_contained/self_contained.h.processed ]; then
                fail "GCC 14 wrote a .h.processed"
              fi
            '';
          };

        # Tests under a toolchain's platform run on the host, as do exec tools.
        # Failing-first only on Bazel 9: earlier versions have no default test
        # toolchain, and their tests ran on the host already.
        mkTestToolchainCheck =
          variant:
          mkShellCheck {
            name = "test-toolchain";
            inherit variant;
            shell.toolchains = selectionToolchains;
            script = ''
              clang=--platforms=@local_config_cc_clang//:platform
              bazel test $clang //:script_test //hello:hello_test || fail "tests under the clang platform"
              if bazel query @bazel_tools//tools/test:default_test_toolchain_type >/dev/null 2>&1; then
                bazel cquery $clang //:script_test --toolchain_resolution_debug=default_test_toolchain_type \
                  2>$TMPDIR/debug >/dev/null || true
                grep -A1 'local_config_cc_clang//test:test_toolchain' $TMPDIR/debug || true
                grep -A1 'local_config_cc_clang//test:test_toolchain .*is compatible' $TMPDIR/debug \
                  | grep -q 'Compatible execution platform @@platforms//host' \
                  || fail "the test toolchain did not resolve to the host"
                bazel cquery $clang --use_target_platform_for_tests //:script_test \
                  --toolchain_resolution_debug=default_test_toolchain_type 2>$TMPDIR/debug >/dev/null || true
                grep -q 'Rejected toolchain @@[^ ]*local_config_cc_clang//test:test_toolchain; mismatching target_settings' \
                  $TMPDIR/debug || fail "the test toolchain ignored --use_target_platform_for_tests"
              fi
              runner=$(bazel aquery $clang 'mnemonic("TestRunner", //:script_test)' --output=text \
                | grep -m1 -o 'Execution platform: .*')
              echo "test action: $runner"
              [[ $runner =~ ^Execution\ platform:\ @+platforms//host:host$ ]] || fail "the test runs on $runner"
              exec=$(compilers exec $clang 'mnemonic("CppCompile", //:probe_exec + deps(//:probe_exec))')
              echo "exec tool compiler: $exec"
              [ "$exec" = "local_config_cc_default/bin/gcc " ] || fail "exec tool compiled by $exec"
            '';
          };

        mkVersionShell =
          variant:
          flazel.lib.cc.mkDevShell {
            inherit pkgs;
            inherit (variant) bazel lockfileMode;
            caches = cachesFor variant;
            toolchains.default = gccCfg;
          };

        # A representative check per toolchain kind, for every extra Bazel version.
        versionedChecks = pkgs.lib.concatMapAttrs (_: variant: {
          "gcc${variant.suffix}" = mkCcCheck {
            name = "flazel-cc-gcc${variant.suffix}";
            cfg = gccCfg;
            inherit variant;
          };
          "clang${variant.suffix}" = mkCcCheck {
            name = "flazel-cc-clang${variant.suffix}";
            cfg = clangCfg;
            inherit variant;
          };
          "asan-clang${variant.suffix}" = mkCcCheck {
            name = "flazel-cc-asan-clang${variant.suffix}";
            cfg = clangCfg;
            bazelFlags = "--features=asan";
            inherit variant;
          };
          "static${variant.suffix}" = mkCcCheck {
            name = "flazel-cc-static${variant.suffix}";
            cfg = staticCfg;
            inherit variant;
          };
          "headers${variant.suffix}" = mkCcCheck {
            name = "flazel-cc-headers${variant.suffix}";
            cfg = gccCfg;
            pkg = "headers";
            bin = "headers";
            expect = "flazel headers ok";
            runTest = false;
            inherit variant;
          };
          "selection${variant.suffix}" = mkSelection variant;
          "clang-check${variant.suffix}" = mkClangCheck variant;
          "test-toolchain${variant.suffix}" = mkTestToolchainCheck variant;
          "gcc14-no-parse-headers${variant.suffix}" = mkGcc14Check variant;
          "marker-flip${variant.suffix}" = mkMarkerFlip variant;
          "cross-only${variant.suffix}" = mkCrossOnly variant;
          "mingw64${variant.suffix}" = mkCcCheck {
            name = "flazel-cc-mingw64${variant.suffix}";
            cfg = mingw64Cfg;
            bazelFlags = "--platforms=@local_config_cc_default//:platform";
            exe = ".exe";
            runner = "${wineRunner}";
            inherit variant;
          };
        }) otherVariants;
      in
      {
        # nix flake check builds all; nix build .#checks.<system>.clang runs one.
        checks = versionedChecks // {
          gcc = mkCcCheck {
            name = "flazel-cc-gcc";
            cfg = gccCfg;
          };
          clang = mkCcCheck {
            name = "flazel-cc-clang";
            cfg = clangCfg;
          };
          # Clang reads its sanitizer ignorelist from the resource directory.
          asan-clang = mkCcCheck {
            name = "flazel-cc-asan-clang";
            cfg = clangCfg;
            bazelFlags = "--features=asan";
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
            sharedLibs = [ "printer/libprinter.so" ];
          };
          shared-clang = mkCcCheck {
            name = "flazel-cc-shared-clang";
            cfg = clangCfg;
            pkg = "shared";
            bin = "shared";
            runTest = false;
            sharedLibs = [ "printer/libprinter.so" ];
          };
          mingw32 = mkCcCheck {
            name = "flazel-cc-mingw32";
            cfg = mingw32Cfg;
            bazelFlags = "--platforms=@local_config_cc_default//:platform";
            exe = ".exe";
            runner = "${wineRunner}";
          };
          # The DLL is copied beside the program, where Windows finds it.
          shared-mingw32 = mkCcCheck {
            name = "flazel-cc-shared-mingw32";
            cfg = mingw32Cfg;
            pkg = "shared";
            bin = "shared";
            runTest = false;
            sharedLibs = [ "printer.dll" ];
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
          mingw64 = mkCcCheck {
            name = "flazel-cc-mingw64";
            cfg = mingw64Cfg;
            bazelFlags = "--platforms=@local_config_cc_default//:platform";
            exe = ".exe";
            runner = "${wineRunner}";
          };
          threads-mingw64 = mkCcCheck {
            name = "flazel-cc-threads-mingw64";
            cfg = mingw64Cfg;
            pkg = "threads";
            bin = "threads";
            runTest = false;
            bazelFlags = "--platforms=@local_config_cc_default//:platform";
            exe = ".exe";
            runner = "${wineRunner}";
          };
          # --platforms picks exactly that toolchain and its libraries.
          selection = mkSelection variants.default;
          clang-check = mkClangCheck variants.default;
          test-toolchain = mkTestToolchainCheck variants.default;
          gcc14-no-parse-headers = mkGcc14Check variants.default;
          explicit-default = explicitDefault;
          subset-shell = subsetShell;
          cross-default = crossDefault;
          cross-only = mkCrossOnly variants.default;
          missing-library = missingLibrary;
          marker-flip = mkMarkerFlip variants.default;
          no-toolchain = noToolchain;
          path-tools = pathTools;
          ambiguous-default = ambiguousDefault;
          undeclared-default = undeclaredDefault;
          # The derivation's one toolchain, not named "default", is the host.
          subset-derivation = mkCcCheck {
            name = "flazel-cc-subset-derivation";
            cfg = selectionToolchains.clang;
            pkg = "";
            bin = "probe";
            expect = probeIdentity.clang;
            runTest = false;
            bazelFlags = "--platforms=@bazel_tools//tools:host_platform";
          };
          # Every file under a nixpkgs library's include/ reaches the sandbox.
          headers = mkCcCheck {
            name = "flazel-cc-headers";
            cfg = gccCfg;
            pkg = "headers";
            bin = "headers";
            expect = "flazel headers ok";
            runTest = false;
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

        # nix develop .#bazel8 (or another of otherVariants) runs that Bazel.
        devShells = builtins.mapAttrs (_: mkVersionShell) otherVariants // {
          # Manual exploration: nix develop, then `bazel build //...`.
          default = flazel.lib.cc.mkDevShell {
            inherit pkgs caches;
            toolchains.default = gccCfg;
          };
          # nix develop .#mingw32 (or .#mingw64), then
          # `bazel build --platforms=@local_config_cc_default//:platform //hello:hello`.
          mingw32 = flazel.lib.cc.mkDevShell {
            inherit pkgs caches;
            toolchains.default = mingw32Cfg;
          };
          mingw64 = flazel.lib.cc.mkDevShell {
            inherit pkgs caches;
            toolchains.default = mingw64Cfg;
          };
        };

        # nix run .#update-locks regenerates locks/ (run in this directory).
        apps.update-locks = flazel.lib.mkUpdateLocksApp {
          inherit pkgs;
          shells = builtins.attrNames otherVariants;
        };
      }
    );
}
