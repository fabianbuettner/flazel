# Filesystem-layout constants shared across the Nix side of flazel.
#
# The Starlark side mirrors nixDepsDir as NIX_DEPS_DIR (and the marker suffix)
# in bazel/nix_common.bzl. The two halves are cross-language, so they must be
# kept in agreement by hand; this file is the single source of truth for the
# Nix half.
{
  # Directory (relative to the workspace root) where flazel materializes Bazel's
  # Nix-provided toolchains, libs, caches, and generated .bazelrc.nix.
  nixDepsDir = ".nix-bazel-deps";

  # Marker file inside nixDepsDir whose contents list the active toolchains. The
  # nix_cc / nix_rust repository rules read it to force re-evaluation when the
  # toolchain set changes.
  toolchainMarker = ".toolchain-marker";
}
