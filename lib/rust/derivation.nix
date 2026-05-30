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
  extraNativeBuildInputs ? [ ],
  extraBuildInputs ? [ ],
}:
let
  coreDeriv = import ../core/derivation.nix;

  rustDepsSetup = ''
    mkdir -p .nix-bazel-deps/toolchains
    ln -s ${cfg.bazelNixDeps}/toolchains/${cfg.toolchainName} .nix-bazel-deps/toolchains/${cfg.toolchainName}

    echo "${cfg.toolchainName}" >> .nix-bazel-deps/.toolchain-marker

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

  toolchainLines = pkgs.lib.concatMapStrings (
    target:
    "build --extra_toolchains=@local_config_rust_${cfg.toolchainName}//:rust_toolchain_${
      builtins.replaceStrings [ "-" ] [ "_" ] target
    }\n"
  ) cfg.targets;
  extraDepsSetup = rustDepsSetup;

  nativeBuildInputs = [
    cfg.rustToolchain
  ]
  ++ extraNativeBuildInputs;

  buildInputs = extraBuildInputs;
}
