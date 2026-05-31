# Filesystem-layout constants for the Nix side of flazel.
#
# The canonical definitions live in bazel/nix_common.bzl as Starlark literals:
# Bazel needs them at load time (default args, attr defaults), where it cannot
# read an external data file, so the .bzl must hold the literal. Nix, which can
# read any file at eval time, derives its copy from that .bzl here. One literal
# per name, no cross-language drift.
let
  bzl = builtins.readFile ../../bazel/nix_common.bzl;

  # Extract `NAME = "value"` from the .bzl. Fails loudly if the constant is
  # missing or reformatted off a single line, so drift can never pass silently.
  extract =
    name:
    let
      m = builtins.match ".*\n${name} = \"([^\"]*)\".*" bzl;
    in
    if m == null then
      throw "constants.nix: could not extract ${name} from bazel/nix_common.bzl"
    else
      builtins.head m;
in
{
  # Directory (relative to the workspace root) where flazel materializes Bazel's
  # Nix-provided toolchains, libs, caches, and generated .bazelrc.nix.
  nixDepsDir = extract "NIX_DEPS_DIR";

  # Marker file inside nixDepsDir whose contents list the active toolchains. The
  # nix_cc / nix_rust repository rules read it to force re-evaluation when the
  # toolchain set changes.
  toolchainMarker = extract "TOOLCHAIN_MARKER";
}
