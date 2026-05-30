# CC-specific Flazel derivation builder
#
# Wraps the core mkFlazelDerivation with C/C++ toolchain configuration.
#
# Usage:
#   cfg = flazel.lib.cc.mkConfig { toolchainName = "default"; ... };
#   build = flazel.lib.cc.mkDerivation {
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
  # Bazel package to use (defaults to latest stable)
  bazel ? pkgs.bazel,
  # Path to flazel source (auto-injected, used for --override_module in .bazelrc.nix)
  flazelPath ? null,
  extraNativeBuildInputs ? [ ],
  extraBuildInputs ? [ ],
}:
let
  coreDeriv = import ../core/derivation.nix;
  inherit (import ../core/constants.nix) nixDepsDir toolchainMarker;

  # CC-specific setup: symlink toolchain and libs
  # Uses new directory structure: toolchains/<name>/cc, toolchains/<name>/deps
  ccDepsSetup = ''
    mkdir -p ${nixDepsDir}/toolchains
    ln -s ${cfg.bazelNixDeps}/toolchains/${cfg.toolchainName} ${nixDepsDir}/toolchains/${cfg.toolchainName}
    ln -s ${cfg.bazelNixDeps}/libs ${nixDepsDir}/libs

    # Write marker file (must match dev-shell.nix for lockfile consistency)
    echo "${cfg.toolchainName}" > ${nixDepsDir}/${toolchainMarker}
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

  toolchainLines = "build --extra_toolchains=@local_config_cc_${cfg.toolchainName}//:cc_toolchain\n";
  extraDepsSetup = ccDepsSetup;

  nativeBuildInputs = [
    cfg.gcc
    cfg.binutils
  ]
  ++ pkgs.lib.optional (!cfg.static) pkgs.autoPatchelfHook
  ++ extraNativeBuildInputs;

  buildInputs = [
    cfg.libc
    cfg.libcDev
    cfg.gcc.cc
  ]
  ++ (if cfg.static then [ ] else builtins.attrValues cfg.nixpkgsLibs)
  ++ extraBuildInputs;

  runtimeDependencies =
    if cfg.static then [ ] else map (pkg: pkg.out or pkg) (builtins.attrValues cfg.nixpkgsLibs);
}
