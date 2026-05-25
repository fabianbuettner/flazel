# Utility function to recursively collect all transitive dependencies
# from a package's propagatedBuildInputs.
#
# Uses an attrset as a visited set (keyed by pname) to avoid redundant
# traversal of diamond dependencies.
#
# Usage:
#   flazel.lib.getTransitiveDeps pkgs pkgs.openssl
#
pkgs: pkg:
let
  go =
    { visited, deps }:
    p:
    let
      direct = p.propagatedBuildInputs or [ ];
      key = d: d.pname or d.name or "";
      fresh = builtins.filter (
        d:
        d != null
        && (
          let
            k = key d;
          in
          k != "" && !(visited ? ${k})
        )
      ) direct;
      visited' = builtins.foldl' (acc: d: acc // { ${key d} = true; }) visited fresh;
    in
    builtins.foldl' (state: dep: go state dep) {
      visited = visited';
      deps = deps ++ fresh;
    } fresh;
in
(go {
  visited = { };
  deps = [ ];
} pkg).deps
