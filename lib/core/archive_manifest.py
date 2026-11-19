"""flazel-lock-archives: writes flazel-archives.json, the (url, sha256)
archives a build downloads that MODULE.bazel.lock does not record, for
mkBcrCaches' extraArchives. See the README for usage.

The lockfile omits reproducible extensions, the root module's use_repo_rule
repos and archive_override archives, so the tool asks Bazel instead of
scraping ruleset sources:

1. `bazel mod graph --extension_info=all` lists every extension usage, with
   its imported and unimported repos; use_repo_rule repos appear as usages of
   a pseudo-extension. Imported repos are dumped per host module with
   `show_repo --base_module`; each spec's canonical name reveals its
   extension's canonical prefix.
2. Unimported repos (hub-and-spoke spokes) are dumped by constructed
   canonical name: prefix + internal name.
3. Non-registry overrides (graph key `<name>@_`) are dumped by module key. An
   archive with an integrity is kept, a local repository skipped, anything
   else refused.

All of it comes from the current resolution, in O(modules + chunks) bazel
calls. The declared set is cut down to what an analysis of the build in a
probe output base downloads into an empty repository cache; the probe's
directories and server are removed on every exit. Every bazel call reads
MODULE.bazel.lock and none writes it.
"""
import argparse
import base64
import json
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

# The resolution the offline build uses is the locked one: read the lock,
# never write it, and fail when it is stale.
LOCKFILE = "--lockfile_mode=error"

# While a probe exists, a signal is recorded instead of raised (see
# on_signal), so that nothing can interrupt the probe's cleanup.
deferred = {"active": False, "signum": None, "child": None}


def run_bazel(*args):
    return subprocess.run(
        ["bazel", *args], capture_output=True, text=True, check=False
    )


def bazel(*args):
    res = run_bazel(*args)
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        sys.exit(f"bazel {' '.join(args[:2])}... failed")
    return res.stdout


def show_repo(*args):
    return run_bazel("mod", "show_repo", LOCKFILE, *args)


def show_visible_repos(base, chunk):
    """show_repo for the (ext, name) pairs a module can see: those pairs,
    their blocks and the extensions of the pairs it cannot see.

    The graph also lists the repos of a non-root module's dev-dependency
    extension usages, which Bazel ignores; those repos are not visible from
    the module, are never created and have nothing to fetch.
    """
    hidden = set()
    while chunk:
        res = show_repo(*base, *["@" + name for _, name in chunk])
        if res.returncode == 0:
            return chunk, parse_blocks(res.stdout), hidden
        invisible = set(
            re.findall(r"No repo visible as (\S+) from", res.stderr)
        )
        if not invisible:
            sys.stderr.write(res.stderr)
            sys.exit("bazel mod show_repo... failed")
        hidden |= {ext for ext, name in chunk if name in invisible}
        chunk = [(ext, name) for ext, name in chunk if name not in invisible]
    return [], [], hidden


def parse_blocks(dump):
    """Split a show_repo dump into blocks, in argument order."""
    blocks = []
    for block in re.split(r"^## ", dump, flags=re.M)[1:]:
        rule = re.search(r"^(\w+)\($", block, re.M)
        name = re.search(r'^  name = "([^"]+)"', block, re.M)
        url = re.search(r'^  urls? = \[?"([^"]+)"', block, re.M)
        sha = re.search(r'^  sha256 = "([^"]+)"', block, re.M)
        sri = re.search(r'^  integrity = "sha256-([^"]+)"', block, re.M)
        # Integrity SRI is converted to hex, the format bazel keys its
        # repo cache by.
        digest = sha.group(1) if sha else (
            base64.b64decode(sri.group(1)).hex() if sri else None
        )
        # Attributes naming downloads besides the archive itself.
        more = re.findall(
            r"^  (remote_patches|remote_file_urls) = \{[^}]", block, re.M
        )
        blocks.append({
            "rule": rule.group(1) if rule else None,
            "canonical": name.group(1) if name else None,
            "url": url.group(1) if url else None,
            "sha256": digest,
            "more_downloads": more,
        })
    return blocks


def chunked(seq, n=200):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def walk_graph(graph):
    """The extension usages per module key, deduplicated (the graph repeats
    a module wherever it appears in the dependency tree), and the keys of
    the non-registry overrides, which the graph versions as "_"."""
    modules = {}
    overrides = set()

    def walk(node):
        key = node.get("key")
        if key and key.endswith("@_"):
            overrides.add(key)
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
    return modules, sorted(overrides)


def extension_entries(modules):
    """sha256 -> url of every archive the extension repos declare."""
    entries = {}
    prefixes = {}  # extension key -> canonical prefix
    dev_usages = set()  # (module key, extension key) Bazel ignores

    # Pass 1: imported repos, per host module; blocks come back in argument
    # order, which associates each canonical name with its extension.
    for mod_key, usages in modules.items():
        order = [(u["ext"], name) for u in usages for name in u["used"]]
        if not order:
            continue
        base = [] if mod_key == "<root>" else [f"--base_module={mod_key}"]
        for chunk_start in range(0, len(order), 200):
            chunk, blocks, hidden = show_visible_repos(
                base, order[chunk_start:chunk_start + 200]
            )
            dev_usages |= {(mod_key, ext) for ext in hidden}
            if len(blocks) != len(chunk):
                sys.exit(
                    f"show_repo returned {len(blocks)} blocks "
                    f"for {len(chunk)} repos (module {mod_key})"
                )
            for (ext, _), block in zip(chunk, blocks):
                if block["canonical"]:
                    # "rules_rust~~i2~rrc__x" -> "rules_rust~~i2~"; Bazel 8
                    # separates with "+" instead of "~".
                    canonical = block["canonical"]
                    cut = max(canonical.rfind("~"), canonical.rfind("+"))
                    prefixes[ext] = canonical[:cut + 1]
                if block["url"] and block["sha256"]:
                    entries[block["sha256"]] = block["url"]

    # Pass 2: unimported repos (spokes) by constructed canonical name.
    spokes = []
    for mod_key, usages in modules.items():
        for u in usages:
            if not u["unused"] or (mod_key, u["ext"]) in dev_usages:
                continue
            prefix = prefixes.get(u["ext"])
            if prefix is None:
                sys.exit(
                    f"extension {u['ext']} has unimported repos but no "
                    "imported one to derive its canonical prefix from "
                    "(use_repo rename?)"
                )
            spokes += [prefix + name for name in u["unused"]]

    for chunk in chunked(sorted(set(spokes))):
        for block in parse_blocks(
            bazel("mod", "show_repo", LOCKFILE, *["@@" + c for c in chunk])
        ):
            if block["url"] and block["sha256"]:
                entries[block["sha256"]] = block["url"]
    return entries


def override_entries(keys):
    """sha256 -> url of every archive the module overrides declare.

    A local override has nothing to fetch. Anything else must be a single
    archive with a checksum, or the manifest cannot make it offline.
    """
    entries = {}
    if not keys:
        return entries
    blocks = parse_blocks(bazel("mod", "show_repo", LOCKFILE, *keys))
    if len(blocks) != len(keys):
        sys.exit(
            f"show_repo returned {len(blocks)} blocks "
            f"for {len(keys)} module overrides"
        )
    for key, block in zip(keys, blocks):
        if block["rule"] == "local_repository":
            continue
        archive = block["rule"] in ("http_archive", "http_file")
        if not (archive and block["url"] and block["sha256"]):
            sys.exit(
                f"module override {key} ({block['rule']}) is not supported "
                "offline: only an archive_override with an integrity is"
            )
        if block["more_downloads"]:
            sys.exit(
                f"module override {key} sets "
                f"{', '.join(block['more_downloads'])}, which is not "
                "supported offline"
            )
        entries[block["sha256"]] = block["url"]
    return entries


def probe_args(build_args, repository_cache):
    """build_args with the probe's own options last among the options, so a
    --config the caller passes cannot override them.

    The probe analyzes only, on the premise that analysis fetches what the
    build reads. Where a full build observes more (compare both with
    --output), pass --build. The verb is `build`: options under `test:` and
    downloads only `bazel test` makes are not observed unless passed here.
    """
    own = [
        "--repository_cache=" + repository_cache,
        # The workspace's bazel-* links would point into the deleted probe.
        "--symlink_prefix=/",
        LOCKFILE,
    ]
    cut = build_args.index("--") if "--" in build_args else len(build_args)
    return ["--nobuild"] + build_args[:cut] + own + build_args[cut:]


def on_signal(signum, _frame):
    """Exit with 128 + signum; while a probe exists, record the signal, kill
    the probe build, and leave the exit to observe()."""
    if deferred["active"]:
        deferred["signum"] = deferred["signum"] or signum
        if deferred["child"] is not None:
            deferred["child"].kill()
        return
    exit_for(signum)


def exit_for(signum):
    for s in SIGNALS:
        signal.signal(s, signal.SIG_IGN)
    sys.exit(128 + signum)


def handle_signals():
    for s in SIGNALS:
        signal.signal(s, on_signal)


def remove_tree(root):
    """Delete root, including what Bazel made read-only. Returns None, or
    the reason root could not be deleted."""
    root = os.path.abspath(root)

    def make_parent_writable(func, failed, exc):
        parent = os.path.dirname(os.path.abspath(failed))
        inside = parent == root or parent.startswith(root + os.sep)
        # PermissionError is EACCES or EPERM.
        if not (func in (os.unlink, os.rmdir) and inside
                and isinstance(exc, PermissionError)):
            raise exc
        os.chmod(parent, stat.S_IRWXU)
        func(failed)

    try:
        shutil.rmtree(root, onexc=make_parent_writable)
    except OSError as e:
        return f"could not delete {root}: {e}"
    if os.path.lexists(root):
        return f"could not delete {root}"
    return None


def probe_path(prefix):
    """A fresh path, named before its directory exists, so that a signal
    cannot leave a directory behind that the cleanup does not know."""
    return os.path.join(tempfile.gettempdir(), prefix + secrets.token_hex(8))


def probe(base, repository_cache, build_args):
    """Runs the observing build: (observed sha256s, None), or (None, its
    stderr) if it failed or a signal stopped it."""
    os.mkdir(repository_cache, 0o700)
    os.mkdir(base, 0o700)
    if deferred["signum"]:
        return None, ""
    child = subprocess.Popen(
        [
            "bazel",
            "--output_base=" + base,
            # Bounds the probe server's life if this process is killed
            # before it can shut the server down.
            "--max_idle_secs=60",
            "build",
            *probe_args(build_args, repository_cache),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    deferred["child"] = child
    if deferred["signum"]:
        child.kill()
    try:
        _, err = child.communicate()
    finally:
        deferred["child"] = None
    if child.returncode != 0:
        return None, err
    cadir = os.path.join(repository_cache, "content_addressable", "sha256")
    if not os.path.isdir(cadir):
        return set(), None
    return {h.lower() for h in os.listdir(cadir)}, None


def shutdown_probe(base):
    """Stops the probe's server. In a session of its own, so that the Ctrl-C
    the cleanup defers cannot reach this client too."""
    subprocess.run(
        ["bazel", "--output_base=" + base, "shutdown"],
        capture_output=True,
        check=False,
        start_new_session=True,
    )


def observe(build_args):
    """sha256s a build downloads into an empty repository cache.

    A fresh output base is required, not optional: this process has already
    run `bazel mod`, so the warm one holds every external repo and a probe
    against it would observe nothing.
    """
    repository_cache = probe_path("flazel-observe-")
    base = probe_path("flazel-obase-")
    deferred["active"] = True
    try:
        observed, error = probe(base, repository_cache, build_args)
    finally:
        if os.path.isdir(base):
            shutdown_probe(base)
        failures = [
            reason
            for reason in (
                remove_tree(p) for p in (base, repository_cache)
                if os.path.lexists(p)
            )
            if reason
        ]
        deferred["active"] = False
    for reason in failures:
        print(reason, file=sys.stderr)
    if deferred["signum"]:
        exit_for(deferred["signum"])
    if failures:
        sys.exit(1)
    if observed is None:
        sys.stderr.write(error)
        sys.exit("the observing build failed; check its arguments")
    return observed


def manifest_of(entries, observed):
    """The declared archives a build downloads, sorted by url. Empty only
    when nothing is declared: a declared set the probe saw none of means the
    probe observed the wrong build."""
    kept = {s: u for s, u in entries.items() if s.lower() in observed}
    if entries and not kept:
        sys.exit(
            f"observed {len(observed)} archives, none of the {len(entries)} "
            "declared; refusing an empty manifest"
        )
    print(
        f"observed {len(kept)} of {len(entries)} declared archives",
        file=sys.stderr,
    )
    return sorted(
        ({"url": url, "sha256": sha} for sha, url in kept.items()),
        key=lambda e: e["url"],
    )


def derive(build_args):
    """The manifest, from the current resolution and an observing build."""
    graph = json.loads(
        bazel("mod", "graph", LOCKFILE, "--extension_info=all",
              "--output=json")
    )
    modules, overrides = walk_graph(graph)
    entries = extension_entries(modules)
    entries.update(override_entries(overrides))
    # The graph lists every repo a ruleset could create and Bazel fetches
    # them lazily, so crate_universe declares one per Cargo-lockfile crate
    # while a build links a fraction.
    return manifest_of(entries, observe(build_args))


def as_set(manifest):
    return {(e["url"], e["sha256"].lower()) for e in manifest}


def check(manifest, path):
    """Exit status of comparing manifest with the file at path."""
    with open(path) as f:
        committed = as_set(json.load(f))
    derived = as_set(manifest)
    for url, _ in sorted(derived - committed):
        print(f"missing: {url}", file=sys.stderr)
    for url, _ in sorted(committed - derived):
        print(f"extra: {url}", file=sys.stderr)
    if derived != committed:
        print(f"{path} is stale; regenerate it", file=sys.stderr)
        return 1
    print(f"{path} is current ({len(derived)} archives)", file=sys.stderr)
    return 0


def parse_args(argv):
    """Flags before `--`, the observing build's Bazel arguments after."""
    cut = argv.index("--") if "--" in argv else len(argv)
    parser = argparse.ArgumentParser(
        prog="flazel-lock-archives",
        usage="%(prog)s [--check] [--output PATH] [-- BAZEL_BUILD_ARGS...]",
        description="Write the archive manifest of the build that "
        "BAZEL_BUILD_ARGS (default //...) describe.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="derive the manifest and compare it with PATH as a set of "
        "(url, sha256), printing each missing and extra url; exit 1 on any "
        "difference or a missing PATH. Never writes PATH.",
    )
    parser.add_argument(
        "--output",
        metavar="PATH",
        help="the manifest (default: <workspace>/flazel-archives.json)",
    )
    opts = parser.parse_args(argv[:cut])
    opts.build_args = argv[cut + 1:] or ["//..."]
    return opts


def main():
    handle_signals()
    opts = parse_args(sys.argv[1:])
    if opts.output:
        out = os.path.abspath(opts.output)
    else:
        workspace = bazel("info", LOCKFILE, "workspace").strip()
        out = os.path.join(workspace, "flazel-archives.json")
    if opts.check and not os.path.isfile(out):
        sys.exit(f"{out} does not exist; nothing to check")

    manifest = derive(opts.build_args)
    if opts.check:
        sys.exit(check(manifest, out))
    with open(out, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"wrote {out} ({len(manifest)} archives)", file=sys.stderr)


if __name__ == "__main__":
    main()
