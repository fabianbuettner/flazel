# BCR (Bazel Central Registry) caching for hermetic builds
#
# Provides functions to prefetch and cache BCR module dependencies
# based on MODULE.bazel.lock file content.
#
# Usage:
#   caches = flazel.lib.mkBcrCaches {
#     inherit pkgs;
#     lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
#     nonBcrDeps = [ { name = "foo"; url = "..."; hash = "..."; } ];
#   };
#   # caches.bazelRepoCache - content-addressable archive cache
#   # caches.bazelRegistryCache - BCR registry metadata cache
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

  # Generate BCR caches from lock file
  mkBcrCaches =
    {
      pkgs,
      lockFile,
      nonBcrDeps ? [ ],
    }:
    let
      parseSourceUrl =
        url:
        let
          parts = builtins.match "https://bcr.bazel.build/modules/([^/]+)/([^/]+)/source.json" url;
        in
        if parts != null then
          {
            name = builtins.elemAt parts 0;
            version = builtins.elemAt parts 1;
            sourceJsonUrl = url;
            sourceJsonHash = lockFile.registryFileHashes.${url};
            baseUrl = "https://bcr.bazel.build/modules/${builtins.elemAt parts 0}/${builtins.elemAt parts 1}";
          }
        else
          null;

      sourceJsonUrls = builtins.filter (url: builtins.match ".*source\\.json$" url != null) (
        builtins.attrNames (lockFile.registryFileHashes or { })
      );

      modules = builtins.filter (x: x != null) (map parseSourceUrl sourceJsonUrls);

      fetchSourceJson =
        module:
        let
          sourceJson = builtins.fetchurl {
            url = module.sourceJsonUrl;
            sha256 = module.sourceJsonHash;
          };
          sourceInfo = builtins.fromJSON (builtins.readFile sourceJson);
        in
        module
        // {
          archiveUrl = sourceInfo.url;
          archiveIntegrity = sourceInfo.integrity;
          patches = sourceInfo.patches or { };
        };

      modulesWithSources = map fetchSourceJson modules;

      fetchModuleArchive =
        mod:
        pkgs.fetchurl {
          url = mod.archiveUrl;
          name = "${mod.name}-${mod.version}.tar.gz";
          hash = mod.archiveIntegrity;
        };

      fetchModulePatches =
        mod:
        builtins.mapAttrs (
          name: hash:
          pkgs.fetchurl {
            url = "${mod.baseUrl}/patches/${name}";
            inherit hash name;
          }
        ) mod.patches;

      fetchNonBcrDep =
        dep:
        pkgs.fetchurl {
          url = dep.url;
          hash = dep.hash;
          name = "${dep.name}.tar.gz";
        };

      bazelRepoCache = pkgs.runCommand "bazel-repo-cache" { } ''
        mkdir -p $out/content_addressable/sha256

        add_to_cache() {
          local file=$1 url=$2
          local HASH=$(${pkgs.coreutils}/bin/sha256sum "$file" | cut -d' ' -f1)
          local URL_HASH=$(echo -n "$url" | ${pkgs.coreutils}/bin/sha256sum | cut -d' ' -f1)
          mkdir -p $out/content_addressable/sha256/$HASH
          ln -sf "$file" $out/content_addressable/sha256/$HASH/file
          touch $out/content_addressable/sha256/$HASH/id-$URL_HASH
        }

        ${builtins.concatStringsSep "\n" (
          map (dep: ''
            add_to_cache "${fetchNonBcrDep dep}" "${dep.url}"
          '') nonBcrDeps
        )}

        ${builtins.concatStringsSep "\n" (
          map (
            mod:
            let
              archive = fetchModuleArchive mod;
              patches = fetchModulePatches mod;
            in
            ''
              add_to_cache "${archive}" "${mod.archiveUrl}"
              ${builtins.concatStringsSep "\n" (
                builtins.attrValues (
                  builtins.mapAttrs (
                    name: patch: ''add_to_cache "${patch}" "${mod.baseUrl}/patches/${name}"''
                  ) patches
                )
              )}
            ''
          ) modulesWithSources
        )}
      '';

      registryFiles = builtins.filter (url: builtins.match "https://bcr.bazel.build/.*" url != null) (
        builtins.attrNames (lockFile.registryFileHashes or { })
      );

      bazelRegistryCache = pkgs.runCommand "bazel-registry-cache" { } ''
        mkdir -p $out
        ${builtins.concatStringsSep "\n" (
          map (
            url:
            let
              urlPath = builtins.replaceStrings [ "https://bcr.bazel.build/" ] [ "" ] url;
              file = builtins.fetchurl {
                inherit url;
                sha256 = lockFile.registryFileHashes.${url};
              };
            in
            ''
              mkdir -p $out/$(dirname "${urlPath}")
              cp ${file} $out/${urlPath}
              chmod 644 $out/${urlPath}
            ''
          ) registryFiles
        )}
        find $out -type d -exec chmod 755 {} \;
      '';
    in
    {
      inherit bazelRepoCache bazelRegistryCache;
    };
}
