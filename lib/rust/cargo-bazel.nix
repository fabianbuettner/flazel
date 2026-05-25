# Build cargo-bazel from source for crate_universe support on NixOS
#
# On NixOS, the cargo-bazel binary downloaded by rules_rust won't run
# (no /lib64/ld-linux-x86-64.so.2). This builds it from the rules_rust
# source tree so crate_universe can resolve Cargo dependencies.
#
# Usage:
#   cargoBazel = flazel.lib.rust.mkCargoBazel { inherit pkgs; };
#
# For a different rules_rust version, override all three:
#   cargoBazel = flazel.lib.rust.mkCargoBazel {
#     inherit pkgs;
#     rulesRustVersion = "0.70.0";
#     rulesRustHash = "sha256-...";
#     cargoHash = "sha256-...";
#   };
#
{
  pkgs,
  rulesRustVersion ? "0.56.0",
  rulesRustHash ? "sha256-AJPxxTF7Kx9sYmiAs5L6Jjo53IegXXma9QdMWzBSpAk=",
  cargoHash ? "sha256-1tuLZVyHBGYAJXrnfgq0ItDz+V0UZ7yFPEWjR7CZqKs=",
}:
let
  rulesRustSrc = pkgs.fetchFromGitHub {
    owner = "bazelbuild";
    repo = "rules_rust";
    rev = rulesRustVersion;
    hash = rulesRustHash;
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "cargo-bazel";
  version = rulesRustVersion;
  src = rulesRustSrc;
  sourceRoot = "source/crate_universe";
  inherit cargoHash;
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];
  doCheck = false;
}
