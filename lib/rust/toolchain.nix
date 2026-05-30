# Rust Toolchain configuration for hermetic Bazel builds
#
# Creates a complete build configuration including:
# - Rust toolchain from rust-overlay (rustc, cargo, clippy, rustfmt)
# - Bazel rust_toolchain wiring via Nix store paths
# - Cross-compilation support via target triples
# - Configurable linker selection
#
# Usage:
#   cfg = flazel.lib.rust.mkConfig {
#     inherit pkgs;
#     rustVersion = "1.85.0";
#     targets = [ "x86_64-unknown-linux-gnu" "aarch64-apple-ios" ];
#   };
#
# Architectural decision (§17.3 of notes-rs SPEC.md):
#   Nix-provided rustc threaded into Bazel, not rules_rust-managed download.
#   Pre-built rustc from rules_rust does not run on NixOS (no /lib64/ld-linux-x86-64.so.2).
#   This mirrors lib/cc/'s approach: single source of truth for the compiler binary.
#
{
  pkgs,
  toolchainName ? "default",
  rustVersion ? "1.85.0",
  rustChannel ? "stable",
  targets ? [ "x86_64-unknown-linux-gnu" ],
  linker ? "bfd",
  extraExtensions ? [ ],
}:
let
  platform = import ../core/platform.nix;

  extensions = [
    "rust-src"
    "llvm-tools-preview"
    "clippy"
    "rustfmt"
  ]
  ++ extraExtensions;

  rustToolchain = pkgs.rust-bin.${rustChannel}.${rustVersion}.default.override {
    inherit extensions targets;
  };

  # Host (exec) triple and platform constraints, derived from the build
  # platform rather than assuming x86_64-linux.
  execTriple = pkgs.stdenv.buildPlatform.config;
  execCpuConstraint = platform.cpuConstraint pkgs.stdenv.buildPlatform.parsed.cpu.name;
  execOsConstraint = platform.osConstraint pkgs.stdenv.buildPlatform.parsed.kernel.name;

  # Map a rust target triple to Bazel [cpu, os] constraints. Rust triples are
  # irregular: "x86_64-unknown-linux-gnu" (arch-vendor-os-env), "aarch64-apple-ios"
  # (arch-vendor-os), and bare-metal ones like "thumbv7em-none-eabi" or
  # "riscv32imac-unknown-none-elf" where the system is the literal "none" and the
  # arch is a fine-grained family name. So detect bare metal by the "none"
  # component, and fold embedded arch families into a platform cpu.
  rustTargetConstraints =
    target:
    let
      components = pkgs.lib.splitString "-" target;
      arch = builtins.head components;

      cpu =
        if pkgs.lib.hasPrefix "thumb" arch || pkgs.lib.hasPrefix "armv" arch || arch == "arm" then
          "arm"
        else if pkgs.lib.hasPrefix "riscv64" arch then
          "riscv64"
        else if pkgs.lib.hasPrefix "riscv32" arch then
          "riscv32"
        else if pkgs.lib.hasPrefix "mips64" arch then
          "mips64"
        else
          arch; # x86_64, aarch64, ... pass straight through

      # Non-bare-metal: keep the existing positional heuristic (3rd component is
      # the OS), with the musl-without-vendor special case.
      parts = builtins.match "([^-]+)-([^-]+)-([^-]+)(-.*)?" target;
      positionalOs = if parts != null then builtins.elemAt parts 2 else "linux";
      os =
        if builtins.elem "none" components then
          "none"
        else if positionalOs == "unknown" && builtins.match ".*musl.*" target != null then
          "linux"
        else
          positionalOs;
    in
    ''"${platform.cpuConstraint cpu}", "${platform.osConstraint os}"'';

  rustToolchainBuild = pkgs.writeText "BUILD.bazel" ''
    load("@rules_rust//rust:toolchain.bzl", "rust_toolchain", "rust_stdlib_filegroup")

    package(default_visibility = ["//visibility:public"])

    filegroup(
        name = "rustc",
        srcs = ["bin/rustc"],
    )

    filegroup(
        name = "rustdoc",
        srcs = ["bin/rustdoc"],
    )

    filegroup(
        name = "cargo",
        srcs = ["bin/cargo"],
    )

    filegroup(
        name = "clippy_driver",
        srcs = ["bin/clippy-driver"],
    )

    filegroup(
        name = "rustfmt",
        srcs = ["bin/rustfmt"],
    )

    filegroup(
        name = "rustc_lib",
        srcs = glob(["lib/rustlib/${execTriple}/lib/*.so", "lib/rustlib/${execTriple}/lib/*.dylib", "lib/*.so", "lib/*.dylib"]),
    )

    filegroup(
        name = "llvm_cov",
        srcs = glob(["lib/rustlib/${execTriple}/bin/llvm-cov"]),
    )

    filegroup(
        name = "llvm_profdata",
        srcs = glob(["lib/rustlib/${execTriple}/bin/llvm-profdata"]),
    )

    ${builtins.concatStringsSep "\n" (
      map (
        target:
        let
          sanitized = builtins.replaceStrings [ "-" ] [ "_" ] target;
        in
        ''
          rust_stdlib_filegroup(
              name = "rust_std_${sanitized}",
              srcs = glob(["lib/rustlib/${target}/lib/*.rlib", "lib/rustlib/${target}/lib/*.a", "lib/rustlib/${target}/lib/*.so", "lib/rustlib/${target}/lib/*.dylib"]),
          )

          rust_toolchain(
              name = "rust_toolchain_${sanitized}_impl",
              rustc = ":rustc",
              rust_doc = ":rustdoc",
              cargo = ":cargo",
              clippy_driver = ":clippy_driver",
              rustfmt = ":rustfmt",
              rustc_lib = ":rustc_lib",
              rust_std = ":rust_std_${sanitized}",
              llvm_cov = ":llvm_cov",
              llvm_profdata = ":llvm_profdata",
              exec_triple = "${execTriple}",
              target_triple = "${target}",
              binary_ext = "",
              staticlib_ext = ".a",
              dylib_ext = ".so",
              stdlib_linkflags = ["-lpthread", "-ldl"],
              default_edition = "2021",
          )

          toolchain(
              name = "rust_toolchain_${sanitized}",
              exec_compatible_with = ["${execCpuConstraint}", "${execOsConstraint}"],
              target_compatible_with = [${rustTargetConstraints target}],
              toolchain = ":rust_toolchain_${sanitized}_impl",
              toolchain_type = "@rules_rust//rust:toolchain_type",
          )
        ''
      ) targets
    )}
  '';

  # Selective lib/ tree: only std library binaries, not rust-src.
  # cargo-bazel discovers Cargo.toml files in rust-src and rejects them.
  localConfigRust = pkgs.runCommand "local_config_rust_${toolchainName}" { } ''
    mkdir -p $out

    cp ${rustToolchainBuild} $out/BUILD.bazel
    ln -s ${rustToolchain}/bin $out/bin

    # Recreate lib/ structure with only what Bazel needs
    mkdir -p $out/lib/rustlib
    # Symlink top-level .so/.dylib files (rustc's own libraries)
    for f in ${rustToolchain}/lib/*.so ${rustToolchain}/lib/*.dylib; do
      [ -e "$f" ] && ln -s "$f" $out/lib/
    done
    # Symlink each target's lib/ and bin/ directories
    for target_dir in ${rustToolchain}/lib/rustlib/*/; do
      target=$(basename "$target_dir")
      if [ -d "$target_dir/lib" ]; then
        mkdir -p $out/lib/rustlib/$target
        ln -s "$target_dir/lib" $out/lib/rustlib/$target/lib
      fi
      # bin/ contains llvm-cov, llvm-profdata (from llvm-tools-preview)
      if [ -d "$target_dir/bin" ]; then
        mkdir -p $out/lib/rustlib/$target
        ln -s "$target_dir/bin" $out/lib/rustlib/$target/bin
      fi
    done
  '';

  bazelNixDeps = pkgs.runCommand "bazel-nix-rust-deps-${toolchainName}" { } ''
    mkdir -p $out/toolchains/${toolchainName}
    ln -s ${localConfigRust} $out/toolchains/${toolchainName}/rust
  '';
in
{
  inherit
    rustToolchain
    rustVersion
    targets
    toolchainName
    bazelNixDeps
    ;
}
