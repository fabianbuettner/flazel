# CC Toolchain configuration for hermetic Bazel builds
#
# Creates a complete build configuration including:
# - GCC toolchain with configurable version
# - Static (musl) or dynamic (glibc) linking
# - Cross-compilation support via target parameter
# - Configurable C/C++ standards
# - Bazel repository generation for nixpkgs libraries
#
# Usage (native build):
#   cfg = flazel.lib.cc.mkConfig {
#     inherit pkgs;
#     static = true;  # optional, defaults to false
#     gcc = pkgs.pkgsStatic.gcc14;  # optional
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
  # GCC package to use (caller provides appropriate version for target)
  gcc ? null,
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

  # Check if this is a bare metal target (no libc)
  isBaremetal = target ? libc && target.libc == null;

  # Bare metal implies static linking - no dynamic linker available
  effectiveStatic = static || isBaremetal;

  buildPkgs = if effectiveStatic then pkgs.pkgsStatic else pkgs;

  # Use provided gcc or default from buildPkgs
  effectiveGcc = if gcc != null then gcc else buildPkgs.gcc;
  binutils = target.binutils or buildPkgs.binutils;
  gccVersion = effectiveGcc.version;

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

  # Deps repo name (parameterized by toolchain name)
  depsRepoName = "local_config_cc_${toolchainName}_deps";

  # Link flags - can be overridden via target.linkFlags
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
        "-static",
        "-Lexternal/${depsRepoName}/gcc-lib/lib/gcc/${targetTriple}/${gccVersion}",
        "-Lexternal/${depsRepoName}/gcc-lib/lib",
        "-Lexternal/${depsRepoName}/libc/lib",
        "-Bexternal/${depsRepoName}/binutils/bin",
        "-lstdc++",
        "-no-canonical-prefixes",
      ''
    else
      ''
        "-Lexternal/${depsRepoName}/gcc/lib/gcc/${targetTriple}/${gccVersion}",
        "-Lexternal/${depsRepoName}/gcc-lib/lib",
        "-Lexternal/${depsRepoName}/libc/lib",
        "-Wl,-rpath,${effectiveGcc.cc}/lib",
        "-Wl,-rpath,${libc}/lib",
        "-Wl,--dynamic-linker=${libc}/lib/ld-linux-x86-64.so.2",
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
  cpuConstraint =
    if targetCpu == "x86_64" then
      "@platforms//cpu:x86_64"
    else if targetCpu == "mips64" then
      "@platforms//cpu:mips64"
    else if targetCpu == "aarch64" then
      "@platforms//cpu:aarch64"
    else if targetCpu == "arm" then
      "@platforms//cpu:arm"
    else if targetCpu == "riscv64" then
      "@platforms//cpu:riscv64"
    else
      throw "Unsupported CPU '${targetCpu}'. Supported: x86_64, aarch64, arm, mips64, riscv64";

  osConstraint =
    if targetOs == "linux" then
      "@platforms//os:linux"
    else if targetOs == "none" then
      "@platforms//os:none"
    else if targetOs == "macos" then
      "@platforms//os:macos"
    else
      throw "Unsupported OS '${targetOs}'. Supported: linux, macos, none";

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
  ccToolchainBinaries = pkgs.runCommand "cc-toolchain-bin" { } ''
    mkdir -p $out/bin
    # Try prefixed first (cross-compiler), then unprefixed (native)
    if [ -e ${effectiveGcc}/bin/${targetTriple}-gcc ]; then
      ln -s ${effectiveGcc}/bin/${targetTriple}-gcc $out/bin/gcc
      ln -s ${effectiveGcc}/bin/${targetTriple}-g++ $out/bin/g++
      ln -s ${effectiveGcc}/bin/${targetTriple}-cpp $out/bin/cpp
      if [ -e ${effectiveGcc}/bin/${targetTriple}-gcov ]; then
        ln -s ${effectiveGcc}/bin/${targetTriple}-gcov $out/bin/gcov
      else
        ln -s ${pkgs.coreutils}/bin/false $out/bin/gcov
      fi
    else
      ln -s ${effectiveGcc}/bin/gcc $out/bin/gcc
      ln -s ${effectiveGcc}/bin/g++ $out/bin/g++
      ln -s ${effectiveGcc}/bin/cpp $out/bin/cpp
      if [ -e ${effectiveGcc}/bin/gcov ]; then
        ln -s ${effectiveGcc}/bin/gcov $out/bin/gcov
      else
        ln -s ${pkgs.coreutils}/bin/false $out/bin/gcov
      fi
    fi
    # Binutils - try prefixed first, then unprefixed
    if [ -e ${binutils}/bin/${targetTriple}-ar ]; then
      ln -s ${binutils}/bin/${targetTriple}-ar $out/bin/ar
      ln -s ${binutils}/bin/${targetTriple}-nm $out/bin/nm
      ln -s ${binutils}/bin/${targetTriple}-objdump $out/bin/objdump
      ln -s ${binutils}/bin/${targetTriple}-objcopy $out/bin/objcopy
      ln -s ${binutils}/bin/${targetTriple}-strip $out/bin/strip
      ln -s ${binutils}/bin/${targetTriple}-ld $out/bin/ld
      if [ -e ${binutils}/bin/${targetTriple}-dwp ]; then
        ln -s ${binutils}/bin/${targetTriple}-dwp $out/bin/dwp
      else
        ln -s ${pkgs.coreutils}/bin/false $out/bin/dwp
      fi
    else
      ln -s ${binutils}/bin/ar $out/bin/ar
      ln -s ${binutils}/bin/nm $out/bin/nm
      ln -s ${binutils}/bin/objdump $out/bin/objdump
      ln -s ${binutils}/bin/objcopy $out/bin/objcopy
      ln -s ${binutils}/bin/strip $out/bin/strip
      ln -s ${binutils}/bin/ld $out/bin/ld
      if [ -e ${binutils}/bin/dwp ]; then
        ln -s ${binutils}/bin/dwp $out/bin/dwp
      else
        ln -s ${pkgs.coreutils}/bin/false $out/bin/dwp
      fi
    fi
    ln -s ${pkgs.coreutils}/bin/false $out/bin/llvm-profdata
  '';

  ccToolchainBuild = pkgs.writeText "BUILD.bazel" ''
    load("@rules_cc//cc:defs.bzl", "cc_toolchain", "cc_toolchain_suite")
    load(":cc_toolchain_config.bzl", "cc_toolchain_config")

    package(default_visibility = ["//visibility:public"])

    filegroup(name = "empty")
    filegroup(name = "all_files", srcs = glob(["bin/*"]) + ["@${depsRepoName}//:all"])
    filegroup(name = "compiler_files", srcs = glob(["bin/*"]) + ["@${depsRepoName}//:all"])
    filegroup(name = "linker_files", srcs = glob(["bin/*"]) + ["@${depsRepoName}//:all"])

    cc_toolchain_config(name = "local_config_cc_toolchain_config")

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

    cc_toolchain_suite(
        name = "toolchain",
        toolchains = {"k8": ":local_config_cc_toolchain", "k8|gcc": ":local_config_cc_toolchain"},
    )

    toolchain(
        name = "cc_toolchain",
        exec_compatible_with = ["@platforms//cpu:x86_64", "@platforms//os:linux"],
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

  ccToolchainConfigBzl = pkgs.writeText "cc_toolchain_config.bzl" ''
    load("@bazel_tools//tools/cpp:cc_toolchain_config_lib.bzl", "feature", "flag_group", "flag_set", "tool_path")
    load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "ACTION_NAMES")

    _COMPILE_ACTIONS = [
        ACTION_NAMES.c_compile, ACTION_NAMES.cpp_compile, ACTION_NAMES.cpp_header_parsing,
        ACTION_NAMES.cpp_module_compile, ACTION_NAMES.cpp_module_codegen,
        ACTION_NAMES.linkstamp_compile, ACTION_NAMES.assemble, ACTION_NAMES.preprocess_assemble,
    ]
    _CXX_ACTIONS = [
        ACTION_NAMES.cpp_compile, ACTION_NAMES.cpp_header_parsing,
        ACTION_NAMES.cpp_module_compile, ACTION_NAMES.cpp_module_codegen, ACTION_NAMES.linkstamp_compile,
    ]
    _LINK_ACTIONS = [
        ACTION_NAMES.cpp_link_executable, ACTION_NAMES.cpp_link_dynamic_library,
        ACTION_NAMES.cpp_link_nodeps_dynamic_library,
    ]

    def _impl(ctx):
        return cc_common.create_cc_toolchain_config_info(
            ctx = ctx,
            toolchain_identifier = "local_${targetTriple}",
            host_system_name = "local",
            target_system_name = "${targetTriple}",
            target_cpu = "${targetCpu}",
            target_libc = "${libcName}",
            compiler = "gcc",
            abi_version = "local",
            abi_libc_version = "local",
            cxx_builtin_include_directories = [
                "${effectiveGcc.cc}/include/c++/${gccVersion}",
                "${effectiveGcc.cc}/include/c++/${gccVersion}/${targetTriple}",
                "${effectiveGcc.cc}/lib/gcc/${targetTriple}/${gccVersion}/include",
                "${effectiveGcc.cc}/lib/gcc/${targetTriple}/${gccVersion}/include-fixed",
                "${effectiveGcc.cc}/${targetTriple}/sys-include",
                "${effectiveGcc.cc}/${targetTriple}/include",
    ${libcIncludeDirs}${fortifyIncludeDirs}${gccWrapperIncludeList}        ],
            tool_paths = [
                tool_path(name = "gcc", path = "bin/gcc"),
                tool_path(name = "g++", path = "bin/g++"),
                tool_path(name = "cpp", path = "bin/cpp"),
                tool_path(name = "ar", path = "bin/ar"),
                tool_path(name = "nm", path = "bin/nm"),
                tool_path(name = "objdump", path = "bin/objdump"),
                tool_path(name = "objcopy", path = "bin/objcopy"),
                tool_path(name = "strip", path = "bin/strip"),
                tool_path(name = "ld", path = "bin/ld"),
                tool_path(name = "gcov", path = "bin/gcov"),
                tool_path(name = "dwp", path = "bin/dwp"),
                tool_path(name = "llvm-profdata", path = "bin/llvm-profdata"),
            ],
            features = [
                feature(
                    name = "compile_flags",
                    enabled = True,
                    flag_sets = [flag_set(
                        actions = _COMPILE_ACTIONS,
                        flag_groups = [flag_group(flags = [
                            "-isystem", "external/${depsRepoName}/gcc-lib/include/c++/${gccVersion}",
                            "-isystem", "external/${depsRepoName}/gcc-lib/include/c++/${gccVersion}/${targetTriple}",
                            "-isystem", "external/${depsRepoName}/gcc-lib/lib/gcc/${targetTriple}/${gccVersion}/include",
                            "-isystem", "external/${depsRepoName}/gcc-lib/lib/gcc/${targetTriple}/${gccVersion}/include-fixed",
                            ${libcIsystemFlags}"-no-canonical-prefixes",
                            "-fno-canonical-system-headers",
                        ])],
                    )],
                ),
                feature(
                    name = "cxx_flags",
                    enabled = True,
                    flag_sets = [flag_set(
                        actions = _CXX_ACTIONS,
                        flag_groups = [flag_group(flags = ["-std=${cxxStandard}"])],
                    )],
                ),
                feature(
                    name = "c_flags",
                    enabled = True,
                    flag_sets = [flag_set(
                        actions = [ACTION_NAMES.c_compile],
                        flag_groups = [flag_group(flags = ["-std=${cStandard}"])],
                    )],
                ),
                feature(
                    name = "link_flags",
                    enabled = True,
                    flag_sets = [flag_set(
                        actions = _LINK_ACTIONS,
                        flag_groups = [flag_group(flags = [${linkFlags}])],
                    )],
                ),
                feature(
                    name = "opt",
                    flag_sets = [flag_set(
                        actions = [ACTION_NAMES.c_compile, ACTION_NAMES.cpp_compile],
                        flag_groups = [flag_group(flags = ["-O2", "-DNDEBUG"])],
                    )],
                ),
                feature(
                    name = "dbg",
                    flag_sets = [flag_set(
                        actions = [ACTION_NAMES.c_compile, ACTION_NAMES.cpp_compile],
                        flag_groups = [flag_group(flags = ["-g", "-O0"])],
                    )],
                ),
            ],
        )

    cc_toolchain_config = rule(implementation = _impl, attrs = {}, provides = [CcToolchainConfigInfo])
  '';

  localConfigCc = pkgs.runCommand "local_config_cc" { } ''
    mkdir -p $out/bin
    cp ${ccToolchainBuild} $out/BUILD.bazel
    cp ${ccToolchainConfigBzl} $out/cc_toolchain_config.bzl
    cp -r ${ccToolchainBinaries}/bin/* $out/bin/
  '';

  # Toolchain dependencies - conditionally include libc
  localConfigCcDeps = pkgs.runCommand "local_config_cc_toolchain_deps" { } ''
    mkdir -p $out
    echo 'package(default_visibility = ["//visibility:public"])' > $out/BUILD.bazel
    echo 'filegroup(name = "all", srcs = glob(["**/*"]))' >> $out/BUILD.bazel
    ln -s ${effectiveGcc} $out/gcc
    ln -s ${effectiveGcc.cc} $out/gcc-lib
    ${if libc != null then "ln -s ${libc} $out/libc" else ""}
    ${if libcDev != null then "ln -s ${libcDev} $out/libc-dev" else ""}
    ln -s ${binutils} $out/binutils
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
