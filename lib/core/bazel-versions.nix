# Bazel versions flazel supports besides pkgs.bazel. The resolved module graph
# depends on the Bazel version, so a project tested against several keeps one
# lockfile per version (see update-locks.nix).
pkgs: {
  bazel8 = pkgs.bazel_8;
  bazel9 = pkgs.bazel_9;
}
