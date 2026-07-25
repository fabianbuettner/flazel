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
    # Run all deps-dir setup from the Bazel workspace root (nearest ancestor with
    # a MODULE.bazel / WORKSPACE marker), then restore the caller's directory.
    # mkFlazelDepsSetup, the language extraSetup it runs, and the consumer
    # shellHook below all write ${nixDepsDir} with cwd-relative paths; without
    # this, entering the devshell from a subdirectory scatters ${nixDepsDir}
    # there, and its half-materialized offline registry then breaks
    # `bazel build //...` package loading. Only the dev shell needs this: the
    # build derivation runs mkFlazelDepsSetup with its sandbox cwd already at the
    # workspace root. Falls back to a no-op if no marker is found, and the
    # restore makes the deps-dir location the only observable effect.
    _flazel_prev="$PWD"
    _flazel_root="$PWD"
    while [ "$_flazel_root" != / ] \
      && [ ! -e "$_flazel_root/MODULE.bazel" ] \
      && [ ! -e "$_flazel_root/WORKSPACE" ] \
      && [ ! -e "$_flazel_root/WORKSPACE.bazel" ]; do
      _flazel_root="$(dirname "$_flazel_root")"
    done
    case "$_flazel_root" in
      /) ;; # no workspace marker found: leave cwd as-is (previous behavior)
      *) cd "$_flazel_root" ;;
    esac
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
    cd "$_flazel_prev"
  '';
}
