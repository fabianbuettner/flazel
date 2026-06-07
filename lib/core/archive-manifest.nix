# Generates flazel-archives.json: the (url, sha256) list of archives that
# module extensions download but MODULE.bazel.lock does not record.
#
# Bazel omits extensions that declare `reproducible = True` from the lockfile
# (e.g. rules_rust's internal crate deps since it adopted the flag), so
# mkBcrCaches cannot derive their archives from the lock alone. This tool asks
# Bazel itself instead of scraping ruleset sources: fetch the workspace so
# every needed extension repo materializes, enumerate the extension-generated
# repos in the output base (their canonical names carry "~~"), and dump each
# repo's resolved spec via `bazel mod show_repo`. Repos without a url+hash
# (local config repos) are skipped.
#
# Run it online from the dev shell after a dependency change, commit the
# manifest, and feed it to mkBcrCaches:
#   extraArchives = flazel.lib.parseArchiveManifest ./flazel-archives.json;
# Staleness fails loudly: the offline build reports the missing archive.
{ pkgs }:
pkgs.writeShellApplication {
  name = "flazel-lock-archives";
  runtimeInputs = [
    pkgs.jq
    pkgs.gawk
    pkgs.coreutils
  ];
  text = ''
    workspace=$(bazel info workspace)
    output_base=$(bazel info output_base)
    manifest="$workspace/flazel-archives.json"

    echo "fetching //... so every needed extension repo materializes" >&2
    bazel fetch //...

    # Extension-generated repos carry '~~' (module~~extension~repo) in their
    # canonical names; plain module repos do not. Stale directories from
    # earlier resolutions may linger in the output base; show_repo failing on
    # one of those is expected, so each repo is queried individually and
    # skipped on error.
    entries=""
    while IFS= read -r repo; do
      spec=$(bazel mod show_repo "@@$repo" 2>/dev/null) || continue
      pair=$(printf '%s\n' "$spec" | awk '
        /^  urls? = / { if (url == "" && match($0, /"[^"]+"/)) url = substr($0, RSTART + 1, RLENGTH - 2) }
        /^  sha256 = "/ { if (match($0, /"[^"]+"/)) hash = substr($0, RSTART + 1, RLENGTH - 2) }
        /^  integrity = "sha256-/ { if (match($0, /"[^"]+"/)) hash = substr($0, RSTART + 1, RLENGTH - 2) }
        END { if (url != "" && hash != "") print url "\t" hash }
      ')
      [ -n "$pair" ] || continue
      url=''${pair%%$'\t'*}
      hash=''${pair#*$'\t'}
      case $hash in
        # SRI -> hex, the format bazel keys its repo cache by.
        sha256-*) hash=$(printf '%s' "''${hash#sha256-}" | basenc --decode --base64 | od -An -v -tx1 | tr -d ' \n') ;;
      esac
      entries+=$(jq -cn --arg url "$url" --arg sha256 "$hash" '{url: $url, sha256: $sha256}')$'\n'
    done < <(find "$output_base/external" -maxdepth 1 -mindepth 1 -name '*~~*' -printf '%f\n' | sort)

    printf '%s' "$entries" | jq -s 'unique_by(.sha256) | sort_by(.url)' > "$manifest"
    echo "wrote $manifest ($(jq length "$manifest") archives)" >&2
  '';
}
