# Build cargo-bazel from source for crate_universe support on NixOS
#
# On NixOS, the cargo-bazel binary downloaded by rules_rust won't run
# (no /lib64/ld-linux-x86-64.so.2). This builds it from the rules_rust
# source tree so crate_universe can resolve Cargo dependencies.
#
# The rules_rust version and source archive are derived from the consumer's
# MODULE.bazel.lock (the MVS-resolved version's BCR source.json, same
# machinery as mkBcrCaches), so the generator can never skew from the
# bazel_dep the build actually uses. The only flazel-maintained datum is
# cargoHashes: one vendored-deps hash per supported rules_rust version,
# which doubles as the registry of versions the release-parse patch has
# been verified against. An unknown version fails loudly with TOFU
# instructions instead of building a mismatched generator.
#
# Usage:
#   cargoBazel = flazel.lib.rust.mkCargoBazel {
#     inherit pkgs;
#     lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
#   };
{
  pkgs,
  lockFile,
  # rules_rust version -> cargoHash of crate_universe's vendored deps.
  # Extend (or override) when adopting a new rules_rust version: build once
  # with the new version mapped to "" and copy the hash from the mismatch
  # error.
  cargoHashes ? {
    "0.70.0" = "sha256-MPaL3S2xxtzk+7JbAk5xskeKvQ7d3w353HTWrG4XHio=";
  },
}:
let
  sourceJsonUrls = builtins.filter (
    url: builtins.match "https://bcr.bazel.build/modules/rules_rust/[^/]+/source.json" url != null
  ) (builtins.attrNames (lockFile.registryFileHashes or { }));

  sourceJsonUrl =
    if builtins.length sourceJsonUrls == 1 then
      builtins.head sourceJsonUrls
    else
      throw (
        "mkCargoBazel: expected exactly one resolved rules_rust version in "
        + "MODULE.bazel.lock, found ${toString (builtins.length sourceJsonUrls)}. "
        + "Is rules_rust a bazel_dep of this workspace (and the lockfile current)?"
      );

  version = builtins.head (
    builtins.match "https://bcr.bazel.build/modules/rules_rust/([^/]+)/source.json" sourceJsonUrl
  );

  sourceJson = builtins.fromJSON (
    builtins.readFile (
      builtins.fetchurl {
        url = sourceJsonUrl;
        sha256 = lockFile.registryFileHashes.${sourceJsonUrl};
      }
    )
  );

  cargoHash =
    cargoHashes.${version} or (throw (
      "mkCargoBazel: no cargoHash for rules_rust ${version}. Add it to the "
      + "cargoHashes map in flazel's lib/rust/cargo-bazel.nix (or pass "
      + "cargoHashes with an entry): map the version to \"\" once, build, and "
      + "copy the hash from the mismatch error. Also verify "
      + "cargo-bazel-release-parse.patch still applies to this version."
    ));

  stripPrefix = sourceJson.strip_prefix or "";
in
assert pkgs.lib.assertMsg (
  sourceJson ? url && sourceJson ? integrity
) "mkCargoBazel: rules_rust source.json lacks url/integrity";
assert pkgs.lib.assertMsg (
  (sourceJson.patches or { }) == { }
) "mkCargoBazel: rules_rust ${version} carries BCR patches; teach mkCargoBazel to apply them first";
pkgs.rustPlatform.buildRustPackage {
  pname = "cargo-bazel";
  inherit version cargoHash;
  # The BCR archive (not a parallel GitHub tag fetch): the same bytes bazel
  # builds the module from, with the integrity recorded in the lockfile.
  src = pkgs.fetchurl {
    url = sourceJson.url;
    hash = sourceJson.integrity;
    name = "rules_rust-${version}.tar.gz";
  };
  sourceRoot = "${if stripPrefix == "" then "." else stripPrefix}/crate_universe";
  # vendor mode parses `bazel info release` assuming the official "release
  # X.Y.Z" format; nix-built bazel reports "7.6.0- (@non-git)" (bazel's own
  # non-git stamping, pinned by nixpkgs for determinism) and the parse panics
  # the whole vendor run. Lenient-parse patch; drop once upstream accepts an
  # equivalent fix.
  patches = [ ./cargo-bazel-release-parse.patch ];
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];
  doCheck = false;
}
