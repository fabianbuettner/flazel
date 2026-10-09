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
  inherit (import ../core/constants.nix) nixDepsDir;

  toolchainList = pkgs.lib.attrValues toolchains;
  toolchainNames = pkgs.lib.attrNames toolchains;
  ccToolchainNames = pkgs.lib.attrNames ccToolchains;

  primaryCfg = builtins.head toolchainList;

  # Merged in a derivation for the reason the cc module gives: the tree is a pure
  # function of the two toolchain sets, so it is built once and linked, not assembled
  # per entry. A toolchain directory here is nested rather than flat -- rust/, cc/ and
  # deps/ side by side, contributed by two different attribute sets -- which the
  # derivation expresses directly and a merge in the hook could not.
  mergedToolchains = pkgs.runCommand "flazel-rust-toolchains" { } ''
    mkdir -p $out
    ${pkgs.lib.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (name: cfg: ''
        mkdir -p $out/${name}
        ln -sfn ${cfg.bazelNixDeps}/toolchains/${name}/rust $out/${name}/rust
      '') toolchains
    )}
    ${pkgs.lib.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (name: cfg: ''
        mkdir -p $out/${name}
        ln -sfn ${cfg.bazelNixDeps}/toolchains/${name}/cc $out/${name}/cc
        ln -sfn ${cfg.bazelNixDeps}/toolchains/${name}/deps $out/${name}/deps
      '') ccToolchains
    )}
  '';

  rustDepsSetup = ''
    flazel_link ${mergedToolchains} ${nixDepsDir}/toolchains

    # No rust toolchain contributes libs, but the directory is part of the layout a
    # consumer's bazelrc names, so it exists rather than being conditionally absent.
    mkdir -p ${nixDepsDir}/libs

    ${pkgs.lib.optionalString (cargoBazel != null) ''
      export CARGO_BAZEL_GENERATOR_URL="file://${cargoBazel}/bin/cargo-bazel"
    ''}
  '';

  # Register every CC toolchain (the linker) and every Rust target toolchain.
  rustToolchainLines =
    import ../cc/bazelrc.nix {
      inherit (pkgs) lib;
      names = ccToolchainNames;
    }
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
    + "build --@rules_rust//rust/settings:experimental_use_sh_toolchain_for_bootstrap_process_wrapper=True\n"
    # crates_vendor honors this action env over its in-bazel-built generator,
    # so the (patched) Nix cargo-bazel serves the vendor path too; the URL
    # export in rustDepsSetup covers the from_cargo extension path.
    + pkgs.lib.optionalString (
      cargoBazel != null
    ) "build --action_env=CARGO_BAZEL_GENERATOR_PATH=${cargoBazel}/bin/cargo-bazel\n";

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
