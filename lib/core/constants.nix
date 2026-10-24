# Filesystem-layout constants for the Nix side of flazel.
#
# Each constant is a literal in bazel/*.bzl, where Bazel needs it at load time;
# Nix extracts it from there, so there is one definition per name.
let
  # Fails if the constant is missing or not on one line.
  extract =
    file: name:
    let
      m = builtins.match ".*\n${name} = \"([^\"]*)\".*" (builtins.readFile (../../bazel + "/${file}"));
    in
    if m == null then
      throw "constants.nix: could not extract ${name} from bazel/${file}"
    else
      builtins.head m;
in
{
  # Directory (relative to the workspace root) where flazel materializes Bazel's
  # Nix-provided toolchains, libs, caches, and generated .bazelrc.nix.
  nixDepsDir = extract "nix_common.bzl" "NIX_DEPS_DIR";

  # File in nixDepsDir recording the CC toolchain decisions (lib/cc/bazelrc.nix).
  ccToolchainsFile = extract "nix_cc.bzl" "CC_TOOLCHAINS_FILE";
}
