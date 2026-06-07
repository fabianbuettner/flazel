# Generates flazel-archives.json: the (url, sha256) list of archives that
# module extensions download but MODULE.bazel.lock does not record.
#
# Bazel omits extensions that declare `reproducible = True` from the lockfile
# (e.g. rules_rust's internal crate deps since it adopted the flag), so
# mkBcrCaches cannot derive their archives from the lock alone. This tool asks
# Bazel itself instead of scraping ruleset sources, in two passes:
#
#   1. `bazel mod graph --extension_info=all` lists every extension usage with
#      its imported (use_repo'd) and unimported repos. The imported ones are
#      dumped per host module via `show_repo --base_module=<m> @name...`; each
#      dumped spec's `name` attribute is the repo's canonical name, which also
#      reveals the extension's canonical prefix (e.g. "rules_rust~~i2~").
#   2. Unimported repos (hub-and-spoke extensions generate spokes that are
#      never use_repo'd, e.g. rules_rust's rrc__* crates) are dumped by
#      constructed canonical name: prefix + internal name.
#
# Everything comes from the current resolution (no output-base scanning, so no
# stale repos), and the call count is O(modules + chunks), not O(repos), which
# matters under `startup --batch` where every bazel invocation is a server
# start. Repos without a url+hash (local config repos) are skipped.
#
# Run it online from the dev shell after a dependency change, commit the
# manifest, and feed it to mkBcrCaches:
#   extraArchives = flazel.lib.parseArchiveManifest ./flazel-archives.json;
# Staleness fails loudly: the offline build reports the missing archive.
{ pkgs }:
pkgs.writers.writePython3Bin "flazel-lock-archives" { } ''
  import base64
  import json
  import re
  import subprocess
  import sys


  def bazel(*args):
      res = subprocess.run(
          ["bazel", *args], capture_output=True, text=True, check=False
      )
      if res.returncode != 0:
          sys.stderr.write(res.stderr)
          sys.exit(f"bazel {' '.join(args[:2])}... failed")
      return res.stdout


  def parse_blocks(dump):
      """Split a show_repo dump into blocks, in argument order."""
      blocks = []
      for block in re.split(r"^## ", dump, flags=re.M)[1:]:
          name = re.search(r'^  name = "([^"]+)"', block, re.M)
          url = re.search(r'^  urls? = \[?"([^"]+)"', block, re.M)
          sha = re.search(r'^  sha256 = "([^"]+)"', block, re.M)
          sri = re.search(r'^  integrity = "sha256-([^"]+)"', block, re.M)
          # Integrity SRI is converted to hex, the format bazel keys its
          # repo cache by.
          digest = sha.group(1) if sha else (
              base64.b64decode(sri.group(1)).hex() if sri else None
          )
          blocks.append({
              "canonical": name.group(1) if name else None,
              "url": url.group(1) if url else None,
              "sha256": digest,
          })
      return blocks


  def chunked(seq, n=200):
      for i in range(0, len(seq), n):
          yield seq[i:i + n]


  workspace = bazel("info", "workspace").strip()
  graph = json.loads(
      bazel("mod", "graph", "--extension_info=all", "--output=json")
  )

  # module key -> [{ext, used, unused}], deduplicated (the graph repeats a
  # module wherever it appears in the dependency tree).
  modules = {}


  def walk(node):
      key = node.get("key")
      usages = node.get("extensionUsages")
      if key and usages and key not in modules:
          modules[key] = [
              {
                  "ext": u["key"],
                  "used": u.get("used_repos", []),
                  "unused": u.get("unused_repos", []),
              }
              for u in usages
          ]
      for dep in node.get("dependencies", []):
          walk(dep)


  walk(graph)

  entries = {}
  prefixes = {}  # extension key -> canonical prefix

  # Pass 1: imported repos, per host module; blocks come back in argument
  # order, which associates each canonical name with its extension.
  for mod_key, usages in modules.items():
      order = [(u["ext"], name) for u in usages for name in u["used"]]
      if not order:
          continue
      base = [] if mod_key == "<root>" else [f"--base_module={mod_key}"]
      for chunk_start in range(0, len(order), 200):
          chunk = order[chunk_start:chunk_start + 200]
          dump = bazel(
              "mod", "show_repo", *base, *["@" + name for _, name in chunk]
          )
          blocks = parse_blocks(dump)
          if len(blocks) != len(chunk):
              sys.exit(
                  f"show_repo returned {len(blocks)} blocks "
                  f"for {len(chunk)} repos (module {mod_key})"
              )
          for (ext, _), block in zip(chunk, blocks):
              if block["canonical"]:
                  # "rules_rust~~i2~rrc__x" -> "rules_rust~~i2~"
                  prefixes[ext] = block["canonical"].rsplit("~", 1)[0] + "~"
              if block["url"] and block["sha256"]:
                  entries[block["sha256"]] = block["url"]

  # Pass 2: unimported repos (spokes) by constructed canonical name.
  spokes = []
  for usages in modules.values():
      for u in usages:
          if not u["unused"]:
              continue
          prefix = prefixes.get(u["ext"])
          if prefix is None:
              sys.exit(
                  f"extension {u['ext']} has unimported repos but no imported "
                  "one to derive its canonical prefix from (use_repo rename?)"
              )
          spokes += [prefix + name for name in u["unused"]]

  for chunk in chunked(sorted(set(spokes))):
      for block in parse_blocks(
          bazel("mod", "show_repo", *["@@" + c for c in chunk])
      ):
          if block["url"] and block["sha256"]:
              entries[block["sha256"]] = block["url"]

  manifest = sorted(
      ({"url": url, "sha256": sha} for sha, url in entries.items()),
      key=lambda e: e["url"],
  )
  out = f"{workspace}/flazel-archives.json"
  with open(out, "w") as f:
      json.dump(manifest, f, indent=2)
      f.write("\n")
  print(f"wrote {out} ({len(manifest)} archives)", file=sys.stderr)
''
