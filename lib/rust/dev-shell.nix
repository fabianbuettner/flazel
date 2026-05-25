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
  extraPackages ? [ ],
  shellHook ? "",
}:
let
  coreDevShell = import ../core/dev-shell.nix;
  inherit (import ../core/derivation.nix) mkBazelrcFooter;

  toolchainList = pkgs.lib.attrValues toolchains;
  toolchainNames = pkgs.lib.attrNames toolchains;
  ccToolchainNames = pkgs.lib.attrNames ccToolchains;

  primaryCfg = builtins.head toolchainList;

  rustDepsSetup = ''
        mkdir -p .nix-bazel-deps/toolchains .nix-bazel-deps/libs

        # Symlink each Rust toolchain (creates toolchains/<name>/rust/)
        ${pkgs.lib.concatStringsSep "\n" (
          pkgs.lib.mapAttrsToList (name: cfg: ''
            mkdir -p .nix-bazel-deps/toolchains/${name}
            ln -sfn ${cfg.bazelNixDeps}/toolchains/${name}/rust .nix-bazel-deps/toolchains/${name}/rust
          '') toolchains
        )}

        # Symlink each CC toolchain (creates toolchains/<name>/cc/ and deps/)
        ${pkgs.lib.concatStringsSep "\n" (
          pkgs.lib.mapAttrsToList (name: cfg: ''
            mkdir -p .nix-bazel-deps/toolchains/${name}
            ln -sfn ${cfg.bazelNixDeps}/toolchains/${name}/cc .nix-bazel-deps/toolchains/${name}/cc
            ln -sfn ${cfg.bazelNixDeps}/toolchains/${name}/deps .nix-bazel-deps/toolchains/${name}/deps
          '') ccToolchains
        )}

        # Generate .bazelrc.nix with toolchain registrations
        cat >> .nix-bazel-deps/.bazelrc.nix << 'EOF'
    ${
      pkgs.lib.concatMapStrings (name: ''
        build --extra_toolchains=@local_config_cc_${name}//:cc_toolchain
      '') ccToolchainNames
    }${
      pkgs.lib.concatMapStrings (
        name:
        let
          cfg = toolchains.${name};
        in
        pkgs.lib.concatMapStrings (target: ''
          build --extra_toolchains=@local_config_rust_${name}//:rust_toolchain_${
            builtins.replaceStrings [ "-" ] [ "_" ] target
          }
        '') cfg.targets
      ) toolchainNames
    }${mkBazelrcFooter { inherit flazelPath caches; }}EOF

        echo "${
          pkgs.lib.concatStringsSep "," (builtins.sort builtins.lessThan (toolchainNames ++ ccToolchainNames))
        }" >> .nix-bazel-deps/.toolchain-marker
  '';

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
  ++ extraPackages;

  shellHook = ''
    echo "(Rust toolchains: ${toolchainInfo})"
    ${shellHook}
  '';
}
