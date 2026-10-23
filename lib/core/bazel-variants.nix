# One entry per Bazel version a project is built with: the default pkgs.bazel
# with the project's own MODULE.bazel.lock, and every version of
# bazel-versions.nix with its lockfile under locks/ (see update-locks.nix).
{ pkgs, root }:
{
  default = {
    bazel = pkgs.bazel;
    suffix = "";
    lockFile = root + "/MODULE.bazel.lock";
    archives = root + "/flazel-archives.json";
    # mkDerivation's lockFile: null keeps the project's own.
    lockOverride = null;
    # mkDevShell's lockfileMode: Bazel may maintain MODULE.bazel.lock.
    lockfileMode = null;
  };
}
// builtins.mapAttrs (id: bazel: {
  inherit bazel;
  suffix = "-${id}";
  lockFile = root + "/locks/${id}.lock";
  archives = root + "/locks/${id}.archives.json";
  lockOverride = root + "/locks/${id}.lock";
  # Bazel would rewrite MODULE.bazel.lock in its own format; update-locks.nix
  # writes locks/ explicitly instead.
  lockfileMode = "off";
}) (import ./bazel-versions.nix pkgs)
