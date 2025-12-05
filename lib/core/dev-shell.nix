# Generic Flazel development shell (language-agnostic)
#
# Provides a minimal Bazel development shell without any language-specific
# assumptions. Language-specific modules (cc, rust, etc.) can wrap this
# and add their own packages and configuration.
#
# Usage:
#   shell = flazel.lib.mkFlazelDevShell {
#     inherit pkgs;
#     caches = flazel.lib.mkBcrCaches { ... };
#   };
#
{
  pkgs,
  caches,
  # Bazel package to use (defaults to latest stable)
  bazel ? pkgs.bazel,
  # Path to flazel source (for bzlmod local_path_override)
  flazelPath ? null,
  # Optional: extra setup script (for language-specific toolchain/libs)
  extraDepsSetup ? "",
  packages ? [ ],
  shellHook ? "",
}:
let
  inherit (import ./derivation.nix) mkFlazelDepsSetup;
in
pkgs.mkShell {
  packages = [
    bazel
  ]
  ++ packages;

  shellHook = ''
    echo "=== Flazel Development Environment ==="
    ${mkFlazelDepsSetup {
      inherit caches flazelPath;
      extraSetup = extraDepsSetup;
    }}
    echo "Created .nix-bazel-deps"
    echo ""
    echo "Ready! Run: bazel build //..."
    ${shellHook}
  '';
}
