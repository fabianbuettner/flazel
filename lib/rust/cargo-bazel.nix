# Provides a Nix-built cargo-bazel binary for crate_universe
#
# On NixOS, the cargo-bazel binary downloaded by rules_rust won't run
# (no /lib64/ld-linux-x86-64.so.2). This module builds it from source
# via Nix so crate_universe can resolve Cargo dependencies.
#
# Usage:
#   cargoBazel = flazel.lib.rust.mkCargoBazel { inherit pkgs cfg; };
#
{
  pkgs,
  cfg,
}:
# Phase 0 stub — crate_universe integration follows in Step 5.
# The consuming project will configure crate_universe to use cargo
# from the Nix-provided Rust toolchain.
{
  cargo = "${cfg.rustToolchain}/bin/cargo";
}
