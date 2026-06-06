# Rust-specific Flazel derivation builder
#
# Wraps the core mkFlazelDerivation with Rust toolchain configuration.
#
# Usage:
#   cfg = flazel.lib.rust.mkConfig { inherit pkgs; };
#   build = flazel.lib.rust.mkDerivation {
#     inherit pkgs cfg caches;
#     name = "my-project";
#     src = ./.;
#     bazelCommand = "build --config=nix //...";
#     installPhase = "cp -rL bazel-bin/* $out/";
#   };
#
{
  pkgs,
  name,
  cfg,
  caches,
  src,
  bazelCommand,
  installPhase,
  bazel ? pkgs.bazel,
  flazelPath ? null,
  cargoBazel ? null,
  # CC toolchains for linking (rust binaries need a linker; on NixOS it must
  # come from Nix). Keyed by name, same shape as cc.mkDevShell's toolchains.
  ccToolchains ? { },
  extraNativeBuildInputs ? [ ],
  extraBuildInputs ? [ ],
}:
let
  coreDeriv = import ../core/derivation.nix;
  inherit (import ../core/constants.nix) nixDepsDir;

  ccToolchainNames = pkgs.lib.attrNames ccToolchains;

  rustDepsSetup = ''
    mkdir -p ${nixDepsDir}/toolchains/${cfg.toolchainName}
    ln -sfn ${cfg.bazelNixDeps}/toolchains/${cfg.toolchainName}/rust ${nixDepsDir}/toolchains/${cfg.toolchainName}/rust

    # Symlink each CC toolchain (provides the linker) alongside the rust one.
    ${pkgs.lib.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (name: ccCfg: ''
        mkdir -p ${nixDepsDir}/toolchains/${name}
        ln -sfn ${ccCfg.bazelNixDeps}/toolchains/${name}/cc ${nixDepsDir}/toolchains/${name}/cc
        ln -sfn ${ccCfg.bazelNixDeps}/toolchains/${name}/deps ${nixDepsDir}/toolchains/${name}/deps
      '') ccToolchains
    )}

    ${pkgs.lib.optionalString (cargoBazel != null) ''
      export CARGO_BAZEL_GENERATOR_URL="file://${cargoBazel}/bin/cargo-bazel"
    ''}
  '';
in
coreDeriv.mkFlazelDerivation {
  inherit
    pkgs
    name
    src
    caches
    bazel
    flazelPath
    bazelCommand
    installPhase
    ;

  toolchainLines =
    pkgs.lib.concatMapStrings (
      name: "build --extra_toolchains=@local_config_cc_${name}//:cc_toolchain\n"
    ) ccToolchainNames
    + pkgs.lib.concatMapStrings (
      target:
      "build --extra_toolchains=@local_config_rust_${cfg.toolchainName}//:rust_toolchain_${
        builtins.replaceStrings [ "-" ] [ "_" ] target
      }\n"
    ) cfg.targets
    # rules_rust bootstraps its process_wrapper via a #!/usr/bin/env bash script,
    # which the offline nix sandbox lacks. Embed the hermetic sh_toolchain bash
    # instead so the bootstrap runs without /usr/bin/env.
    + "build --@rules_rust//rust/settings:experimental_use_sh_toolchain_for_bootstrap_process_wrapper=True\n";
  extraDepsSetup = rustDepsSetup;

  nativeBuildInputs = [
    cfg.rustToolchain
  ]
  ++ extraNativeBuildInputs;

  buildInputs = extraBuildInputs;
}
