# BCR (Bazel Central Registry) caching and non-BCR dependency management
#
# Provides functions to:
# - Cache the registry files MODULE.bazel.lock records, by the lock's hashes
# - Seed the offline repo cache with the archives a build downloads
#   (archives), keyed by sha256
# - Override non-BCR Bazel *modules* (bazel_dep with no registry entry) via
#   --override_module in .bazelrc.nix
#
# Usage:
#   caches = flazel.lib.mkBcrCaches {
#     inherit pkgs;
#     lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
#     # Bazel *modules* with no BCR registry entry (bazel_dep name has no version):
#     nonBcrDeps = [
#       { name = "foo"; url = "..."; hash = "..."; stripPrefix = "..."; }
#     ];
#     # The manifest flazel-lock-archives writes (module archives, patches and
#     # overlay files, extension and use_repo_rule repos; see
#     # archive_manifest.py), plus by hand only what no Bazel resolution names.
#     archives = flazel.lib.parseArchiveManifest ./flazel-archives.json;
#   };
#   # caches.bazelRepoCache - content-addressable cache of the registry files
#   #   and archives
#   # caches.nonBcrOverrideFlags - .bazelrc.nix --override_module lines
#
{
  # Parse a MODULE.bazel.lock file safely
  parseLockFile =
    path:
    let
      content = if builtins.pathExists path then builtins.readFile path else "";
      # Check if content starts with '{' (valid JSON object)
      isValidJson = builtins.stringLength content > 0 && builtins.substring 0 1 content == "{";
    in
    if isValidJson then builtins.fromJSON content else { registryFileHashes = { }; };

  # Parse a flazel-archives.json manifest (written by flazel-lock-archives in
  # the dev shell) into the archives list. A missing file is an
  # evaluation error: an untracked manifest must not empty the cache.
  parseArchiveManifest =
    path:
    let
      entries = builtins.fromJSON (builtins.readFile path);
      fields = [
        "urls"
        "sha256"
        "canonical_id"
      ];
      # A flake's files are read from its store copy; name them from its root.
      inStore = builtins.match "${builtins.storeDir}/[^/]+/(.*)" (toString path);
      shown = if inStore == null then toString path else builtins.head inStore;
    in
    if builtins.all (e: builtins.all (f: e ? ${f}) fields) entries then
      entries
    else
      throw "${shown}: an entry lacks urls, sha256 or canonical_id. Replace it with [] and regenerate it with flazel-lock-archives; in a project with Bazel variants, replace every locks/*.archives.json too, since update-locks enters each variant's dev shell, which reads its own.";

  # Generate BCR caches from lock file
  mkBcrCaches =
    {
      pkgs,
      lockFile,
      nonBcrDeps ? [ ],
      archives,
    }:
    let
      # The lock names every module the version resolution visited, also
      # those no build fetches, whose archive URLs may be long dead; so the
      # archives come from an observed build instead (the manifest), and the
      # lock contributes only the registry files resolution reads.

      # The urls are mirrors of one another, tried in order.
      fetchArchive =
        a:
        pkgs.fetchurl {
          inherit (a) urls sha256;
        };

      # Extract a non-BCR module archive into a ready-to-use directory. These are
      # Bazel modules (they carry their own MODULE.bazel + BUILD files), so no
      # BUILD injection is needed. Non-module repos (use_repo_rule http_archive)
      # are handled by archives, not here: see the module header.
      mkExtractedDep =
        dep:
        pkgs.stdenv.mkDerivation {
          name = "bazel-dep-${dep.name}";
          src = pkgs.fetchurl {
            url = dep.url;
            hash = dep.hash;
          };
          sourceRoot = dep.stripPrefix;
          phases = [
            "unpackPhase"
            "installPhase"
          ];
          installPhase = "cp -r . $out";
        };

      # Generate .bazelrc.nix --override_module lines for non-BCR modules.
      nonBcrOverrideFlags = builtins.concatStringsSep "\n" (
        # common, not build: see mkBazelrcFooter (bazel mod must see overrides too).
        map (dep: "common --override_module=${dep.name}=${mkExtractedDep dep}") nonBcrDeps
      );

      # Bazel keys its content-addressable cache by the hex sha256 of the
      # file's bytes and an id marker by the hex sha256 of the download's
      # canonical id: the one its spec sets, else its urls joined by spaces.
      # Both are known at eval time, so convert them here instead of
      # re-reading every archive at build time.
      toHex =
        h:
        if builtins.substring 0 7 h == "sha256-" then
          builtins.convertHash {
            hash = h;
            toHashFormat = "base16";
          }
        else
          h;
      idHash = id: builtins.hashString "sha256" id;
      canonicalId =
        a: if a.canonical_id != "" then a.canonical_id else builtins.concatStringsSep " " a.urls;

      registryFiles = builtins.filter (url: builtins.match "https://bcr.bazel.build/.*" url != null) (
        builtins.attrNames (lockFile.registryFileHashes or { })
      );

      # Registry files are verified against the lockfile's hashes and looked up
      # in this cache by them, so Bazel resolves modules without reading the
      # registry at all.
      bazelRepoCache = pkgs.runCommand "bazel-repo-cache" { } ''
        mkdir -p $out/content_addressable/sha256

        add_to_cache() {
          local file=$1 hash=$2 id_hash=$3
          mkdir -p $out/content_addressable/sha256/$hash
          ln -sf "$file" $out/content_addressable/sha256/$hash/file
          touch $out/content_addressable/sha256/$hash/id-$id_hash
        }

        # BCR registry files: bazel_registry.json, MODULE.bazel, source.json.
        ${builtins.concatStringsSep "\n" (
          map (
            url:
            let
              hash = lockFile.registryFileHashes.${url};
            in
            ''add_to_cache "${
              builtins.fetchurl {
                inherit url;
                sha256 = hash;
              }
            }" "${hash}" "${idHash url}"''
          ) registryFiles
        )}

        ${builtins.concatStringsSep "\n" (
          map (
            a: ''add_to_cache "${fetchArchive a}" "${toHex a.sha256}" "${idHash (canonicalId a)}"''
          ) archives
        )}
      '';

    in
    {
      inherit bazelRepoCache nonBcrOverrideFlags;
    };
}
