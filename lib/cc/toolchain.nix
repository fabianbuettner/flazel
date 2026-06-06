# CC Toolchain configuration for hermetic Bazel builds
#
# Creates a complete build configuration including:
# - GCC or Clang toolchain with configurable version
# - Static (musl) or dynamic (glibc) linking
# - Cross-compilation support via target parameter
# - Configurable C/C++ standards
# - Bazel repository generation for nixpkgs libraries
# - Clang-only features: module_maps, layering_check, parse_headers
#
# Usage (native build with GCC):
#   cfg = flazel.lib.cc.mkConfig {
#     inherit pkgs;
#     static = true;  # optional, defaults to false
#     gcc = pkgs.pkgsStatic.gcc14;  # optional
#     nixpkgsLibs = { openssl = pkgs.openssl; };
#   };
#
# Usage (native build with Clang):
#   cfg = flazel.lib.cc.mkConfig {
#     inherit pkgs;
#     toolchainName = "clang";
#     compiler = "clang";
#     clang = pkgs.clang_19;
#     nixpkgsLibs = { openssl = pkgs.openssl; };
#   };
#
# Usage (cross-compilation to bare metal MIPS64):
#   cfg = flazel.lib.cc.mkConfig {
#     inherit pkgs;
#     toolchainName = "mips64";  # Name for this toolchain
#     gcc = pkgs.pkgsCross.mips64-unknown-linux-gnuabi64.buildPackages.gcc;
#     target = {
#       triple = "mips64-unknown-elf";
#       cpu = "mips64";
#       os = "none";
#       libc = null;  # bare metal - static is auto-inferred
#     };
#   };
#
{
  pkgs,
  # Name for this toolchain (used in Bazel repo names: local_config_cc_<name>)
  toolchainName ? "default",
  static ? false,
  # Compiler selection: "gcc" (default) or "clang"
  compiler ? "gcc",
  # GCC package to use (caller provides appropriate version for target)
  # Also used by Clang toolchains for libstdc++ headers
  gcc ? null,
  # Clang package to use (only when compiler = "clang")
  clang ? null,
  # LLVM bintools package (only when compiler = "clang", auto-derived if not provided)
  llvmBintools ? null,
  # Linker selection: "bfd" (default for gcc), "lld" (default for clang), "gold", "mold"
  # When null, auto-selects based on compiler
  linker ? null,
  cStandard ? "c17",
  cxxStandard ? "c++23",
  # Target configuration for cross-compilation
  # If not provided, defaults based on `static` parameter
  target ? { },
  # Mapping of bazel repo name -> nixpkgs package
  nixpkgsLibs ? { },
}:
let
  mkNixpkgsRepo = import ./nixpkgs-repo.nix;
  getTransitiveDeps = import ../core/utils.nix pkgs;
  platform = import ../core/platform.nix;

  # Compiler mode
  isClang = compiler == "clang";

  # Check if this is a bare metal target (no libc)
  isBaremetal = target ? libc && target.libc == null;

  # Bare metal implies static linking - no dynamic linker available
  effectiveStatic = static || isBaremetal;

  buildPkgs = if effectiveStatic then pkgs.pkgsStatic else pkgs;

  # Use provided gcc or default from buildPkgs
  # For Clang toolchains, gcc is still needed for libstdc++ headers
  effectiveGcc = if gcc != null then gcc else buildPkgs.gcc;
  binutils = target.binutils or buildPkgs.binutils;
  gccVersion = effectiveGcc.version;

  # Clang-specific bindings
  effectiveClang = if clang != null then clang else buildPkgs.clang;
  # clang.cc is the unwrapped clang (has the actual clang binary)
  clangUnwrapped = effectiveClang.cc;
  # clang.cc.lib has the resource directory with builtin headers
  clangLib = clangUnwrapped.lib;
  # LLVM major version for resource directory path (e.g., "19" from "19.1.7")
  clangMajorVersion = builtins.head (pkgs.lib.splitString "." clangUnwrapped.version);
  # LLVM bintools (ar, nm, objdump, etc.) taken from the LLVM release that
  # matches the clang in use, so the resource-dir version and the bintools
  # cannot disagree. Override via llvmBintools for a clang nixpkgs has no
  # matching llvmPackages_<major> for.
  effectiveLlvmBintools =
    if llvmBintools != null then
      llvmBintools
    else
      pkgs."llvmPackages_${clangMajorVersion}".bintools-unwrapped
        or (throw "nixpkgs has no llvmPackages_${clangMajorVersion} (from clang ${clangUnwrapped.version}); pass llvmBintools explicitly to lib.cc.mkConfig");

  # Linker resolution
  effectiveLinker =
    if linker != null then
      linker
    else if isClang then
      "lld"
    else
      "bfd";

  # Linker integration via bintools override
  #
  # The Nix GCC/Clang wrappers prepend bintools-wrapper/bin to PATH, which is
  # how collect2 finds the linker. To use an alternative linker (mold, lld, gold),
  # we override the bintools wrapper to include the linker binary (e.g. ld.mold),
  # then override the compiler to use the new bintools. This works WITH the Nix
  # wrapper model: collect2 finds ld.mold via PATH, no -B hacks needed.
  #
  # bfd and gold are already in standard binutils, so no override needed.
  # lld needs a symlink for GCC toolchains (Clang toolchains already have it).
  # mold always needs a symlink (external package).
  linkerBintoolsOverride =
    {
      mold = "ln -sf ${pkgs.mold}/bin/ld.mold $out/bin/ld.mold";
      lld = "ln -sf ${effectiveLlvmBintools}/bin/ld.lld $out/bin/ld.lld";
    }
    .${effectiveLinker} or null;

  # Override a compiler's bintools to include the chosen linker
  withLinker =
    cc:
    if linkerBintoolsOverride != null then
      cc.override {
        bintools = cc.bintools.override {
          extraBuildCommands = linkerBintoolsOverride;
        };
      }
    else
      cc;

  toolchainGcc = withLinker effectiveGcc;
  toolchainClang = withLinker effectiveClang;

  # -fuse-ld flag for non-default linkers (tells the compiler which linker flavor to use)
  fuseLinkerFlag =
    {
      mold = ''"-fuse-ld=mold",'';
      lld = ''"-fuse-ld=lld",'';
      gold = ''"-fuse-ld=gold",'';
    }
    .${effectiveLinker} or "";

  # Default target configuration based on effectiveStatic parameter
  defaultTarget =
    if effectiveStatic then
      {
        triple = "x86_64-unknown-linux-musl";
        cpu = "x86_64";
        os = "linux";
        libc = effectiveGcc.libc;
        libcName = "musl";
        fortifyHeaders = buildPkgs.fortify-headers;
      }
    else
      {
        triple = "x86_64-unknown-linux-gnu";
        cpu = "x86_64";
        os = "linux";
        libc = pkgs.glibc;
        libcName = "glibc";
        fortifyHeaders = null;
      };

  # Merge user-provided target with defaults
  effectiveTarget = defaultTarget // target;

  # Extract target values
  targetTriple = effectiveTarget.triple;
  targetCpu = effectiveTarget.cpu;
  targetOs = effectiveTarget.os;
  libc = effectiveTarget.libc or null;
  libcDev = if libc != null then libc.dev else null;
  libcName = effectiveTarget.libcName or (if libc == null then "none" else "unknown");

  # Extract fortify-headers path from GCC wrapper's libc-cflags if it exists
  # The GCC wrapper injects -isystem paths that include fortify-headers
  gccWrapperIncludePaths =
    let
      libcCflagsPath = "${effectiveGcc}/nix-support/libc-cflags";
      hasLibcCflags = builtins.pathExists libcCflagsPath;
      cflagsContent = if hasLibcCflags then builtins.readFile libcCflagsPath else "";
      # Split by space and filter for /nix/store paths (these are include directories)
      parts = pkgs.lib.splitString " " cflagsContent;
      nixStorePaths = builtins.filter (p: builtins.match "/nix/store/.*" p != null) parts;
    in
    nixStorePaths;

  # User-provided fortifyHeaders takes precedence, otherwise extract from GCC wrapper
  fortifyHeaders = effectiveTarget.fortifyHeaders or null;

  # Determine if we need the dynamic linker (only for non-static, non-baremetal Linux)
  needsDynamicLinker = !effectiveStatic && !isBaremetal && targetOs == "linux";

  # Target dynamic linker, read from the cc-wrapper (so it is per-arch:
  # ld-linux-x86-64.so.2, ld-linux-aarch64.so.1, ...) instead of hardcoded.
  # Only forced for dynamic Linux targets, so static/baremetal never hit it.
  dynamicLinker =
    let
      f = "${effectiveGcc}/nix-support/dynamic-linker";
    in
    if builtins.pathExists f then
      pkgs.lib.removeSuffix "\n" (builtins.readFile f)
    else
      throw "flazel: ${effectiveGcc} has no nix-support/dynamic-linker; set target.linkFlags for this toolchain";

  # Deps repo name (parameterized by toolchain name)
  depsRepoName = "local_config_cc_${toolchainName}_deps";

  # Link flags - can be overridden via target.linkFlags
  # Clang on NixOS uses GCC's libstdc++ by default, so link flags reference gcc-lib
  defaultLinkFlags =
    if isBaremetal then
      ''
        "-nostdlib",
        "-static",
        "-Lexternal/${depsRepoName}/gcc-lib/lib/gcc/${targetTriple}/${gccVersion}",
        "-Bexternal/${depsRepoName}/binutils/bin",
        "-lgcc",
        "-no-canonical-prefixes",
      ''
    else if effectiveStatic then
      ''
        ${fuseLinkerFlag}"-static",
        "-Lexternal/${depsRepoName}/gcc-lib/lib/gcc/${targetTriple}/${gccVersion}",
        "-Lexternal/${depsRepoName}/gcc-lib/lib",
        "-Lexternal/${depsRepoName}/libc/lib",
        "-Bexternal/${depsRepoName}/binutils/bin",
        "-lstdc++",
        "-no-canonical-prefixes",
      ''
    else if isClang then
      ''
        ${fuseLinkerFlag}"-Lexternal/${depsRepoName}/gcc-lib-shared/lib",
        "-Lexternal/${depsRepoName}/gcc-lib/lib",
        "-Lexternal/${depsRepoName}/libc/lib",
        "-Wl,-rpath,${effectiveGcc.cc.lib or effectiveGcc.cc}/lib",
        "-Wl,-rpath,${effectiveGcc.cc}/lib",
        "-Wl,-rpath,${libc}/lib",
        "-Wl,--dynamic-linker=${dynamicLinker}",
        "-Bexternal/${depsRepoName}/binutils/bin",
        "-lstdc++",
        "-lm",
        "-no-canonical-prefixes",
      ''
    else
      ''
        ${fuseLinkerFlag}"-Lexternal/${depsRepoName}/gcc/lib/gcc/${targetTriple}/${gccVersion}",
        "-Lexternal/${depsRepoName}/gcc-lib-shared/lib",
        "-Lexternal/${depsRepoName}/gcc-lib/lib",
        "-Lexternal/${depsRepoName}/libc/lib",
        "-Wl,-rpath,${effectiveGcc.cc.lib or effectiveGcc.cc}/lib",
        "-Wl,-rpath,${effectiveGcc.cc}/lib",
        "-Wl,-rpath,${libc}/lib",
        "-Wl,--dynamic-linker=${dynamicLinker}",
        "-Bexternal/${depsRepoName}/binutils/bin",
        "-lstdc++",
        "-lm",
        "-no-canonical-prefixes",
      '';

  linkFlags = effectiveTarget.linkFlags or defaultLinkFlags;

  # Include directories for libc (empty if bare metal)
  libcIncludeDirs =
    if libcDev != null then
      ''
        "${libcDev}/include",
      ''
    else
      "";

  libcIsystemFlags =
    if libcDev != null then
      ''
        "-isystem", "external/${depsRepoName}/libc-dev/include",
      ''
    else
      "";

  fortifyIncludeDirs =
    if fortifyHeaders != null then
      ''
        "${fortifyHeaders}/include",
      ''
    else
      "";

  # Format GCC wrapper include paths as Starlark list items
  gccWrapperIncludeList = pkgs.lib.concatMapStrings (p: ''
    "${p}",
  '') gccWrapperIncludePaths;

  # Bazel platform constraints
  cpuConstraint = platform.cpuConstraint targetCpu;
  osConstraint = platform.osConstraint targetOs;

  # Exec platform = the host that runs the compiler, derived from the build
  # platform instead of assuming x86_64-linux.
  execCpuConstraint = platform.cpuConstraint pkgs.stdenv.buildPlatform.parsed.cpu.name;
  execOsConstraint = platform.osConstraint pkgs.stdenv.buildPlatform.parsed.kernel.name;

  # Generate Bazel repos for each nixpkgs library
  nixpkgsRepos = builtins.mapAttrs (
    name: pkg:
    mkNixpkgsRepo {
      inherit
        pkgs
        name
        pkg
        ;
      static = effectiveStatic;
      inherit getTransitiveDeps;
    }
  ) nixpkgsLibs;

  # CC toolchain binaries
  # Cross-compilers use prefixed names (e.g., aarch64-unknown-linux-musl-gcc)
  # Native compilers use unprefixed names (e.g., gcc)
  # Bazel tool_path names are canonical (gcc, g++, ar, etc.) regardless of actual compiler.
  # gcov wrapper: Bazel's collect_cc_coverage.sh uses gcov -i, but GCC 15+
  # removed the -i flag (replaced by -j/--json-format, available since GCC 9).
  # This wrapper translates -i to -j for GCC >= 9 so both old and new GCC work.
  mkGcovWrapper =
    realGcov:
    pkgs.writeShellScript "gcov-wrapper" ''
      REAL_GCOV="${realGcov}"
      major=$("$REAL_GCOV" --version | sed -n -E 's/^.*\s([0-9]+)\.[0-9]+\.[0-9]+\s?.*$/\1/p')
      if [ "''${major:-0}" -ge 9 ]; then
        args=()
        for arg in "$@"; do
          [ "$arg" = "-i" ] && arg="-j"
          args+=("$arg")
        done
        exec "$REAL_GCOV" "''${args[@]}"
      fi
      exec "$REAL_GCOV" "$@"
    '';

  ccToolchainBinaries = pkgs.runCommand "cc-toolchain-bin" { } (
    if isClang then
      ''
        mkdir -p $out/bin

        link_or_stub() {
          if [ -e "$1" ]; then ln -s "$1" "$out/bin/$2"
          else ln -s "${pkgs.coreutils}/bin/false" "$out/bin/$2"; fi
        }

        ln -s ${toolchainClang}/bin/clang $out/bin/gcc
        ln -s ${toolchainClang}/bin/clang++ $out/bin/g++
        ln -s ${toolchainClang}/bin/clang-cpp $out/bin/cpp
        ln -s ${effectiveLlvmBintools}/bin/ar $out/bin/ar
        ln -s ${effectiveLlvmBintools}/bin/llvm-nm $out/bin/nm
        ln -s ${effectiveLlvmBintools}/bin/llvm-objdump $out/bin/objdump
        ln -s ${effectiveLlvmBintools}/bin/llvm-objcopy $out/bin/objcopy
        ln -s ${effectiveLlvmBintools}/bin/llvm-strip $out/bin/strip
        ln -s ${effectiveLlvmBintools}/bin/ld.lld $out/bin/ld
        link_or_stub "${effectiveLlvmBintools}/bin/llvm-cov" gcov
        link_or_stub "${effectiveLlvmBintools}/bin/llvm-dwp" dwp
        link_or_stub "${effectiveLlvmBintools}/bin/llvm-profdata" llvm-profdata
      ''
    else
      ''
        mkdir -p $out/bin

        link_prefixed() {
          local dir=$1 name=$2
          if [ -e "$dir/${targetTriple}-$name" ]; then
            ln -s "$dir/${targetTriple}-$name" "$out/bin/$name"
          elif [ -e "$dir/$name" ]; then
            ln -s "$dir/$name" "$out/bin/$name"
          else
            ln -s "${pkgs.coreutils}/bin/false" "$out/bin/$name"
          fi
        }

        for name in gcc g++ cpp; do link_prefixed "${toolchainGcc}/bin" "$name"; done
        for name in ar nm objdump objcopy strip ld dwp; do link_prefixed "${binutils}/bin" "$name"; done

        # gcov wrapper for Bazel coverage compatibility (see mkGcovWrapper)
        if [ -e "${effectiveGcc.cc}/bin/${targetTriple}-gcov" ]; then
          ln -s ${mkGcovWrapper "${effectiveGcc.cc}/bin/${targetTriple}-gcov"} $out/bin/gcov
        elif [ -e "${effectiveGcc.cc}/bin/gcov" ]; then
          ln -s ${mkGcovWrapper "${effectiveGcc.cc}/bin/gcov"} $out/bin/gcov
        else
          ln -s ${pkgs.coreutils}/bin/false $out/bin/gcov
        fi

        ln -s ${pkgs.coreutils}/bin/false $out/bin/llvm-profdata
      ''
  );

  # Builtin include directories: Clang needs both its own resource headers
  # and GCC's libstdc++ headers (Clang on NixOS uses libstdc++, not libc++)
  builtinIncludeDirs =
    if isClang then
      ''
                  "${toolchainClang}/resource-root/include",
                  "${effectiveGcc.cc}/include/c++/${gccVersion}",
                  "${effectiveGcc.cc}/include/c++/${gccVersion}/${targetTriple}",
        ${libcIncludeDirs}${fortifyIncludeDirs}${gccWrapperIncludeList}''
    else
      ''
                  "${effectiveGcc.cc}/include/c++/${gccVersion}",
                  "${effectiveGcc.cc}/include/c++/${gccVersion}/${targetTriple}",
                  "${effectiveGcc.cc}/lib/gcc/${targetTriple}/${gccVersion}/include",
                  "${effectiveGcc.cc}/lib/gcc/${targetTriple}/${gccVersion}/include-fixed",
                  "${effectiveGcc.cc}/${targetTriple}/sys-include",
                  "${effectiveGcc.cc}/${targetTriple}/include",
        ${libcIncludeDirs}${fortifyIncludeDirs}${gccWrapperIncludeList}'';

  # Sandbox -isystem flags: within Bazel's sandbox, headers are accessed
  # through the deps repo symlinks, not direct Nix store paths
  compileIsystemFlags =
    if isClang then
      ''
        "-isystem", "external/${depsRepoName}/clang-lib/lib/clang/${clangMajorVersion}/include",
        "-isystem", "external/${depsRepoName}/gcc-lib/include/c++/${gccVersion}",
        "-isystem", "external/${depsRepoName}/gcc-lib/include/c++/${gccVersion}/${targetTriple}",
        ${libcIsystemFlags}"-no-canonical-prefixes",
      ''
    else
      ''
        "-isystem", "external/${depsRepoName}/gcc-lib/include/c++/${gccVersion}",
        "-isystem", "external/${depsRepoName}/gcc-lib/include/c++/${gccVersion}/${targetTriple}",
        "-isystem", "external/${depsRepoName}/gcc-lib/lib/gcc/${targetTriple}/${gccVersion}/include",
        "-isystem", "external/${depsRepoName}/gcc-lib/lib/gcc/${targetTriple}/${gccVersion}/include-fixed",
        ${libcIsystemFlags}"-no-canonical-prefixes",
        "-fno-canonical-system-headers",
      '';

  # Clang-only features: module_maps, layering_check, parse_headers
  ccToolchainBuild = pkgs.writeText "BUILD.bazel" ''
    load("@rules_cc//cc:defs.bzl", "cc_toolchain")
    load(":cc_toolchain_config.bzl", "cc_toolchain_config")

    package(default_visibility = ["//visibility:public"])

    filegroup(name = "empty")
    filegroup(name = "all_files", srcs = glob(["bin/*"]) + ["@${depsRepoName}//:all"])
    filegroup(name = "compiler_files", srcs = glob(["bin/*"]) + ["@${depsRepoName}//:all"])
    filegroup(name = "linker_files", srcs = glob(["bin/*"]) + ["@${depsRepoName}//:all"])

    cc_toolchain_config(
        name = "local_config_cc_toolchain_config",
        target_system_name = "${targetTriple}",
        target_cpu = "${targetCpu}",
        target_libc = "${libcName}",
        compiler = "${compiler}",
        builtin_include_directories = [
    ${builtinIncludeDirs}    ],
        compile_isystem_flags = [
    ${compileIsystemFlags}    ],
        link_flags = [${linkFlags}],
        cxx_standard = "${cxxStandard}",
        c_standard = "${cStandard}",
        is_clang = ${if isClang then "True" else "False"},
        lto_flag = "${if isClang then "-flto=thin" else "-flto=auto"}",
    )

    cc_toolchain(
        name = "local_config_cc_toolchain",
        all_files = ":all_files",
        ar_files = ":all_files",
        as_files = ":all_files",
        compiler_files = ":compiler_files",
        dwp_files = ":empty",
        linker_files = ":linker_files",
        objcopy_files = ":all_files",
        strip_files = ":all_files",
        toolchain_config = ":local_config_cc_toolchain_config",
    )

    toolchain(
        name = "cc_toolchain",
        exec_compatible_with = ["${execCpuConstraint}", "${execOsConstraint}"],
        target_compatible_with = ["${cpuConstraint}", "${osConstraint}"],
        toolchain = ":local_config_cc_toolchain",
        toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    )

    # Platform for --platforms flag selection
    platform(
        name = "platform",
        constraint_values = ["${cpuConstraint}", "${osConstraint}"],
    )
  '';

  # Checked-in static rule (buildifier/parse covered); the BUILD below
  # instantiates it with this toolchain's dynamic values as attributes.
  ccToolchainConfigBzl = ./cc_toolchain_config.bzl;

  localConfigCc = pkgs.runCommand "local_config_cc" { } ''
    mkdir -p $out/bin
    cp ${ccToolchainBuild} $out/BUILD.bazel
    cp ${ccToolchainConfigBzl} $out/cc_toolchain_config.bzl
    cp -r ${ccToolchainBinaries}/bin/* $out/bin/
  '';

  # Toolchain dependencies - conditionally include libc
  # Both GCC and Clang toolchains need gcc-lib (for libstdc++ headers)
  # Clang additionally needs clang-lib (for builtin headers like stdarg.h)
  localConfigCcDeps = pkgs.runCommand "local_config_cc_toolchain_deps" { } ''
    mkdir -p $out
    echo 'package(default_visibility = ["//visibility:public"])' > $out/BUILD.bazel
    echo 'filegroup(name = "all", srcs = glob(["**/*"]))' >> $out/BUILD.bazel
    ln -s ${effectiveGcc} $out/gcc
    ln -s ${effectiveGcc.cc} $out/gcc-lib
    # gcc's "lib" output holds the shared libstdc++.so (the "out" output above
    # has only the static .a). Exposed so the link search path can prefer the
    # shared C++ runtime for both gcc and clang.
    ln -s ${effectiveGcc.cc.lib or effectiveGcc.cc} $out/gcc-lib-shared
    ${if isClang then "ln -s ${clangLib} $out/clang-lib" else ""}
    ${if libc != null then "ln -s ${libc} $out/libc" else ""}
    ${if libcDev != null then "ln -s ${libcDev} $out/libc-dev" else ""}
    ln -s ${if isClang then effectiveLlvmBintools else binutils} $out/binutils
  '';

  # Nix store paths for toolchain and libs (read-only)
  # Structure: toolchains/<name>/cc/, toolchains/<name>/deps/, libs/
  bazelNixDeps = pkgs.runCommand "bazel-nix-deps-${toolchainName}" { } ''
    mkdir -p $out/toolchains/${toolchainName} $out/libs
    ln -s ${localConfigCc} $out/toolchains/${toolchainName}/cc
    ln -s ${localConfigCcDeps} $out/toolchains/${toolchainName}/deps
    ${builtins.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (name: repo: ''
        ln -s ${repo} $out/libs/${name}
        ln -s ${repo} $out/libs/${name}_${toolchainName}
      '') nixpkgsRepos
    )}
  '';
in
{
  inherit
    buildPkgs
    binutils
    libc
    libcDev
    nixpkgsLibs
    nixpkgsRepos
    bazelNixDeps
    isBaremetal
    toolchainName
    ;
  # Export effectiveStatic as 'static' so consumers see the resolved value
  static = effectiveStatic;
  gcc = effectiveGcc;
  target = effectiveTarget;
}
