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

  execTriple = "x86_64-unknown-linux-gnu";

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

    ${builtins.concatStringsSep "\n" (
      map (target: ''
        rust_stdlib_filegroup(
            name = "rust_std_${builtins.replaceStrings [ "-" ] [ "_" ] target}",
            srcs = glob(["lib/rustlib/${target}/lib/*.rlib", "lib/rustlib/${target}/lib/*.a", "lib/rustlib/${target}/lib/*.so", "lib/rustlib/${target}/lib/*.dylib"]),
        )

        rust_toolchain(
            name = "rust_toolchain_${builtins.replaceStrings [ "-" ] [ "_" ] target}_impl",
            rustc = ":rustc",
            rust_doc = ":rustdoc",
            cargo = ":cargo",
            clippy_driver = ":clippy_driver",
            rustfmt = ":rustfmt",
            rustc_lib = ":rustc_lib",
            rust_std = ":rust_std_${builtins.replaceStrings [ "-" ] [ "_" ] target}",
            exec_triple = "${execTriple}",
            target_triple = "${target}",
            binary_ext = "",
            staticlib_ext = ".a",
            dylib_ext = ".so",
            stdlib_linkflags = ["-lpthread", "-ldl"],
            default_edition = "2021",
        )

        toolchain(
            name = "rust_toolchain_${builtins.replaceStrings [ "-" ] [ "_" ] target}",
            exec_compatible_with = ["@platforms//cpu:x86_64", "@platforms//os:linux"],
            target_compatible_with = [${
              let
                parts = builtins.match "([^-]+)-([^-]+)-([^-]+)(-.*)?" target;
                cpu = builtins.elemAt parts 0;
                vendor = builtins.elemAt parts 1;
                os = builtins.elemAt parts 2;
                cpuConstraint =
                  if cpu == "x86_64" then
                    "@platforms//cpu:x86_64"
                  else if cpu == "aarch64" then
                    "@platforms//cpu:aarch64"
                  else
                    throw "Unsupported CPU '${cpu}' in target triple '${target}'";
                osConstraint =
                  if os == "linux" then
                    "@platforms//os:linux"
                  else if os == "apple" then
                    "@platforms//os:macos"
                  else if os == "unknown" && builtins.match ".*musl.*" target != null then
                    "@platforms//os:linux"
                  else
                    throw "Unsupported OS '${os}' in target triple '${target}'";
              in
              ''"${cpuConstraint}", "${osConstraint}"''
            }],
            toolchain = ":rust_toolchain_${builtins.replaceStrings [ "-" ] [ "_" ] target}_impl",
            toolchain_type = "@rules_rust//rust:toolchain_type",
        )
      '') targets
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
    # Symlink each target's lib/ directory (contains .rlib, .a, .so)
    for target_dir in ${rustToolchain}/lib/rustlib/*/; do
      target=$(basename "$target_dir")
      # Skip src/ and other non-target directories
      if [ -d "$target_dir/lib" ]; then
        mkdir -p $out/lib/rustlib/$target
        ln -s "$target_dir/lib" $out/lib/rustlib/$target/lib
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
