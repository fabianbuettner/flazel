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
  # Path to flazel source (auto-injected, used for --override_module in .bazelrc.nix)
  flazelPath ? null,
  # Language-specific toolchain registration lines for .bazelrc.nix
  toolchainLines ? "",
  # Optional: extra setup script (for language-specific toolchain/libs)
  extraDepsSetup ? "",
  packages ? [ ],
  shellHook ? "",
}:
let
  inherit (import ./derivation.nix) mkFlazelDepsSetup;
  inherit (import ./constants.nix) nixDepsDir;
in
pkgs.mkShell {
  packages = [
    bazel
    # Regenerates flazel-archives.json (downloads hidden from the lockfile by
    # reproducible module extensions); see lib/core/archive-manifest.nix.
    (import ./archive-manifest.nix { inherit pkgs; })
  ]
  ++ packages;

  shellHook = ''
    echo "=== Flazel Development Environment ==="
    ${mkFlazelDepsSetup {
      inherit
        pkgs
        caches
        flazelPath
        toolchainLines
        ;
      extraSetup = extraDepsSetup;
    }}
    echo "Created ${nixDepsDir}"
    echo ""
    echo "Ready! Run: bazel build //..."
    ${shellHook}
  '';
}
