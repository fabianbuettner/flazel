# Rust-specific Flazel development shell
#
# Wraps the core mkFlazelDevShell with Rust toolchain packages.
#
# Usage:
#   cfg = flazel.lib.rust.mkConfig { inherit pkgs; };
#   shell = flazel.lib.rust.mkDevShell {
#     inherit pkgs caches;
#     toolchains = { default = cfg; };
#   };
#
{
  pkgs,
  toolchains,
  caches,
  # CC toolchains for linking (Rust needs a linker; on NixOS this must come from Nix)
  ccToolchains ? { },
  bazel ? pkgs.bazel,
  flazelPath ? null,
  cargoBazel ? null,
  extraPackages ? [ ],
  shellHook ? "",
}:
let
  coreDevShell = import ../core/dev-shell.nix;
  inherit (import ../core/constants.nix) nixDepsDir toolchainMarker;

  toolchainList = pkgs.lib.attrValues toolchains;
  toolchainNames = pkgs.lib.attrNames toolchains;
  ccToolchainNames = pkgs.lib.attrNames ccToolchains;

  primaryCfg = builtins.head toolchainList;

  rustDepsSetup = ''
    mkdir -p ${nixDepsDir}/toolchains ${nixDepsDir}/libs

    # Symlink each Rust toolchain (creates toolchains/<name>/rust/)
    ${pkgs.lib.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (name: cfg: ''
        mkdir -p ${nixDepsDir}/toolchains/${name}
        ln -sfn ${cfg.bazelNixDeps}/toolchains/${name}/rust ${nixDepsDir}/toolchains/${name}/rust
      '') toolchains
    )}

    # Symlink each CC toolchain (creates toolchains/<name>/cc/ and deps/)
    ${pkgs.lib.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (name: cfg: ''
        mkdir -p ${nixDepsDir}/toolchains/${name}
        ln -sfn ${cfg.bazelNixDeps}/toolchains/${name}/cc ${nixDepsDir}/toolchains/${name}/cc
        ln -sfn ${cfg.bazelNixDeps}/toolchains/${name}/deps ${nixDepsDir}/toolchains/${name}/deps
      '') ccToolchains
    )}

    echo "${
      pkgs.lib.concatStringsSep "," (builtins.sort builtins.lessThan (toolchainNames ++ ccToolchainNames))
    }" >> ${nixDepsDir}/${toolchainMarker}

    ${pkgs.lib.optionalString (cargoBazel != null) ''
      export CARGO_BAZEL_GENERATOR_URL="file://${cargoBazel}/bin/cargo-bazel"
    ''}
  '';

  # Register every CC toolchain (the linker) and every Rust target toolchain.
  rustToolchainLines =
    pkgs.lib.concatMapStrings (
      name: "build --extra_toolchains=@local_config_cc_${name}//:cc_toolchain\n"
    ) ccToolchainNames
    + pkgs.lib.concatMapStrings (
      name:
      pkgs.lib.concatMapStrings (
        target:
        "build --extra_toolchains=@local_config_rust_${name}//:rust_toolchain_${
          builtins.replaceStrings [ "-" ] [ "_" ] target
        }\n"
      ) toolchains.${name}.targets
    ) toolchainNames
    # Match the derivation: bootstrap process_wrapper via the hermetic sh_toolchain
    # rather than #!/usr/bin/env bash, so builds work without /usr/bin/env.
    + "build --@rules_rust//rust/settings:experimental_use_sh_toolchain_for_bootstrap_process_wrapper=True\n";

  toolchainInfo = pkgs.lib.concatStringsSep ", " (
    pkgs.lib.mapAttrsToList (name: cfg: "${name} (rust ${cfg.rustVersion})") toolchains
  );
in
coreDevShell {
  inherit
    pkgs
    caches
    bazel
    flazelPath
    ;

  toolchainLines = rustToolchainLines;
  extraDepsSetup = rustDepsSetup;

  packages = [
    primaryCfg.rustToolchain
  ]
  ++ (with pkgs; [
    cargo-nextest
    cargo-llvm-cov
    cargo-deny
    bacon
  ])
  ++ pkgs.lib.optional (cargoBazel != null) cargoBazel
  ++ extraPackages;

  shellHook = ''
    echo "(Rust toolchains: ${toolchainInfo})"
    ${shellHook}
  '';
}
