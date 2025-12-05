# Utility function to recursively collect all transitive dependencies
# from a package's propagatedBuildInputs.
#
# Usage:
#   flazel.lib.getTransitiveDeps pkgs pkgs.openssl
#   # Returns a list of all transitive dependencies
#
pkgs: pkg:
let
  getTransitiveDeps =
    p:
    let
      direct = p.propagatedBuildInputs or [ ];
      # Filter out null and packages without pname
      validDeps = builtins.filter (d: d != null && (d.pname or d.name or "") != "") direct;
      # Recursively get deps of deps
      recurse = dep: [ dep ] ++ (getTransitiveDeps dep);
      allDeps = pkgs.lib.flatten (map recurse validDeps);
    in
    pkgs.lib.unique allDeps;
in
getTransitiveDeps pkg
