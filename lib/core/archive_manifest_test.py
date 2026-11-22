"""Unit tests of archive_manifest.py over recorded `bazel mod show_repo` dumps.

Usage: python3 -I archive_manifest_test.py ARCHIVE_MANIFEST_PY TESTDATA_DIR

testdata/show_repo/bazel<N>-<case>.txt is `bazel mod show_repo flazel@_
platforms@_` from tests/archive-override, flazel being a local_path_override
and platforms overridden as <case> says, recorded unedited but for scrubbed
local paths. The remote_patches case names an unresolvable patch URL, which
show_repo prints without fetching. Bazel 7's archive_override has no
remote_patches, so that case exists for 8 and 9 only.

testdata/show_repo/bazel<N>-registry.txt is `bazel mod show_repo` of the
registry modules REGISTRY_KEYS from tests/fetched-modules, scrubbed alike.
"""
import importlib.util
import os
import stat
import sys
import tempfile
import unittest

MODULE_PY, TESTDATA = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("archive_manifest", MODULE_PY)
am = importlib.util.module_from_spec(spec)
spec.loader.exec_module(am)

VERSIONS = (7, 8, 9)
KEYS = ["flazel@_", "platforms@_"]
URL = ("https://github.com/bazelbuild/platforms/releases/download/1.0.0/"
       "platforms-1.0.0.tar.gz")
SHA = "3384eb1c30762704fbe38e440204e114154086c8fc8a8c2e3e28441028c019a8"
ARCHIVE = ((URL,), SHA, "")

REGISTRY_KEYS = ["libpfm@4.11.0.bcr.1", "lz4@1.10.0.bcr.2", "rules_cc@0.2.27"]
BCR = "https://bcr.bazel.build/modules/"
LIBPFM = {
    "5da5f8872bde14b3634c9688d980f68bda28b510268723cc12973eedbab9fecc":
    "https://netcologne.dl.sourceforge.net/project/perfmon2/libpfm4/"
    "libpfm-4.11.0.tar.gz",
    "0fb056ad8d168a2842abd5d289589f6562b7b0c2db2367210ac81d74a277f243":
    BCR + "libpfm/4.11.0.bcr.1/patches/module_dot_bazel.patch",
    "89ba4b3f25f6bff7db0f2b54b8ae0f29e665feadf4ddb5ad4914d4f798398f3d":
    BCR + "libpfm/4.11.0.bcr.1/patches/add_build_file.patch",
}
LZ4 = {
    "537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b":
    "https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz",
    "f8f677c31c4440a37a42528a7b2c46ec1862a26a463e5d7f492819ee16b3e3fb":
    BCR + "lz4/1.10.0.bcr.2/overlay/BUILD.bazel",
    "bf2d9ac92dd3b792e514ca412965d78863ba3a05344c77f4109b4daa8dd81dab":
    BCR + "lz4/1.10.0.bcr.2/overlay/MODULE.bazel",
    "4f7bd0a687fb3642eb2189ffcae94f397e7a98d3e6b06b92a2c2a8c4c109a32e":
    BCR + "lz4/1.10.0.bcr.2/overlay/programs/BUILD.bazel",
}
RULES_CC = {
    "6bcf1b46d9e629cbe4c96d7bfc56f61034c2193b7b16001201282ea50bef5d91":
    "https://github.com/bazelbuild/rules_cc/releases/download/0.2.27/"
    "rules_cc-0.2.27.tar.gz",
    "2c0d01afd9f01da60c6e155106b306b43dfeca22bbb0b6360b3fa3e77c855685":
    BCR + "rules_cc/0.2.27/patches/module_dot_bazel_version.patch",
}


def dump(version, case):
    path = os.path.join(TESTDATA, "show_repo", f"bazel{version}-{case}.txt")
    with open(path) as f:
        return f.read()


def entries(downloads):
    """Manifest entries of sha256 -> url, one url each and no canonical id."""
    return [{"urls": [u], "sha256": h, "canonical_id": ""}
            for h, u in downloads.items()]


def answering(text):
    """A stand-in for archive_manifest.bazel that prints text."""
    return lambda *args: text


class OverrideEntries(unittest.TestCase):
    def entries(self, text):
        am.bazel = answering(text)
        return am.module_entries(KEYS)

    def refused(self, text):
        am.bazel = answering(text)
        with self.assertRaises(SystemExit) as cm:
            am.module_entries(KEYS)
        self.assertIn("platforms@_", str(cm.exception.code))
        self.assertIn("not supported offline", str(cm.exception.code))

    def test_archive_kept_with_hex_sha_and_local_skipped(self):
        for v in VERSIONS:
            with self.subTest(bazel=v):
                self.assertEqual(
                    self.entries(dump(v, "archive")), {ARCHIVE}
                )

    def test_parse_blocks_reads_the_rule(self):
        for v in VERSIONS:
            with self.subTest(bazel=v):
                blocks = am.parse_blocks(dump(v, "archive"))
                self.assertEqual(
                    [b["rule"] for b in blocks],
                    ["local_repository", "http_archive"],
                )

    def test_git_override_refused(self):
        for v in VERSIONS:
            with self.subTest(bazel=v):
                self.refused(dump(v, "git"))

    def test_missing_integrity_refused(self):
        for v in VERSIONS:
            with self.subTest(bazel=v):
                self.refused(dump(v, "nointegrity"))

    def test_remote_patches_kept_also_with_the_archive_bytes(self):
        # The recorded patch names the archive's own integrity.
        patch = "https://example.invalid/fix.patch"
        for v in (8, 9):
            with self.subTest(bazel=v):
                self.assertEqual(
                    self.entries(dump(v, "remote_patches")),
                    {ARCHIVE, ((patch,), SHA, "")},
                )

    def test_remote_file_without_integrity_refused(self):
        text = dump(9, "archive").replace(
            '  integrity = "',
            '  remote_file_urls = {"BUILD.bazel": ["https://x.invalid/B"]},\n'
            '  integrity = "',
        )
        self.assertIn("remote_file_urls", text)
        self.refused(text)

    def test_remote_patch_with_another_algorithm_refused(self):
        text = dump(9, "remote_patches").replace(
            '"https://example.invalid/fix.patch": "sha256-',
            '"https://example.invalid/fix.patch": "sha384-',
        )
        self.assertIn("sha384-", text)
        self.refused(text)

    def test_empty_download_attributes_accepted(self):
        # How Bazel 7 prints a registry module's spec.
        text = dump(7, "archive").replace(
            '  strip_prefix = "",\n',
            '  strip_prefix = "",\n  remote_file_urls = {},\n'
            "  remote_patches = {},\n",
        )
        self.assertIn("remote_patches = {}", text)
        self.assertEqual(self.entries(text), {ARCHIVE})


class Downloads(unittest.TestCase):
    """What parse_blocks reads of a spec's urls and canonical id."""

    def archive(self, attrs):
        text = dump(9, "archive").replace(
            '  urls = ["' + URL + '"],\n', attrs
        )
        self.assertIn(attrs, text)
        return am.parse_blocks(text)[1]["archive"]

    def test_every_url_in_order_url_first(self):
        self.assertEqual(
            self.archive('  url = "https://a/x",\n'
                         '  urls = ["https://b/x", "https://c/x"],\n'),
            (("https://a/x", "https://b/x", "https://c/x"), SHA, ""),
        )

    def test_the_canonical_id_reaches_every_download(self):
        text = dump(9, "remote_patches").replace(
            '  integrity = "', '  canonical_id = "cid",\n  integrity = "'
        )
        self.assertIn("canonical_id", text)
        block = am.parse_blocks(text)[1]
        self.assertEqual(block["archive"], ((URL,), SHA, "cid"))
        self.assertEqual(
            block["extra"],
            [(("https://example.invalid/fix.patch",), SHA, "cid")],
        )


class RegistryModules(unittest.TestCase):
    def entries(self, version):
        am.bazel = answering(dump(version, "registry"))
        return am.module_entries(REGISTRY_KEYS)

    def test_archive_patches_and_overlay_files_declared(self):
        for v in VERSIONS:
            with self.subTest(bazel=v):
                self.assertEqual(
                    self.entries(v),
                    {((u,), h, "")
                     for h, u in {**LIBPFM, **LZ4, **RULES_CC}.items()},
                )

    def test_a_short_answer_is_refused(self):
        am.bazel = answering(dump(9, "registry"))
        with self.assertRaises(SystemExit) as cm:
            am.module_entries(REGISTRY_KEYS + ["zlib@1.3.1.bcr.3"])
        self.assertIn("show_repo returned 3 blocks", str(cm.exception.code))


class Derive(unittest.TestCase):
    """derive() feeds the override pass into the manifest."""

    def test_override_archive_reaches_the_manifest(self):
        graph = (
            '{"key": "<root>", "dependencies": ['
            '{"key": "flazel@_"}, {"key": "platforms@_"}]}'
        )

        def fake_bazel(*args):
            if args[:2] == ("mod", "graph"):
                return graph
            return dump(9, "archive")

        am.bazel = fake_bazel
        am.observe = lambda build_args: {SHA}
        self.assertEqual(
            am.derive([["//..."]]),
            [{"urls": [URL], "sha256": SHA, "canonical_id": ""}],
        )

    def registry_graph(self, observed_per_group):
        """derive() over the registry dump, each group observing its set."""
        graph = '{"key": "<root>", "dependencies": [%s]}' % ", ".join(
            '{"key": "%s"}' % k for k in REGISTRY_KEYS
        )

        def fake_bazel(*args):
            return graph if args[:2] == ("mod", "graph") else dump(
                9, "registry"
            )

        am.bazel = fake_bazel
        am.observe = lambda build_args: observed_per_group[build_args[0]]

    def test_a_module_no_build_fetches_stays_out(self):
        self.registry_graph({"//...": set(RULES_CC)})
        manifest = am.derive([["//..."]])
        self.assertEqual(
            {e["sha256"] for e in manifest}, set(RULES_CC)
        )
        for url in LIBPFM.values():
            self.assertNotIn([url], [e["urls"] for e in manifest])

    def test_the_groups_observed_are_unioned(self):
        self.registry_graph({"a": set(RULES_CC), "b": set(LZ4)})
        both = am.derive([["a"], ["b"]])
        self.assertEqual(
            {e["sha256"] for e in both}, set(RULES_CC) | set(LZ4)
        )
        self.assertEqual(
            {e["sha256"] for e in am.derive([["a"]])}, set(RULES_CC)
        )


class Check(unittest.TestCase):
    def setUp(self):
        fd, self.path = tempfile.mkstemp()
        os.close(fd)

    def tearDown(self):
        os.unlink(self.path)

    def committed(self, manifest):
        with open(self.path, "w") as f:
            am.json.dump(manifest, f)

    def test_a_missing_module_entry_is_stale(self):
        derived = entries(RULES_CC)
        self.committed(derived[1:])
        self.assertEqual(am.check(derived, self.path), 1)

    def test_an_extra_module_entry_is_stale(self):
        derived = entries(RULES_CC)
        self.committed(derived + entries(LIBPFM))
        self.assertEqual(am.check(derived, self.path), 1)

    def test_another_canonical_id_is_stale(self):
        derived = entries(RULES_CC)
        self.committed([dict(e, canonical_id="x") for e in derived])
        self.assertEqual(am.check(derived, self.path), 1)

    def test_a_manifest_without_urls_is_refused(self):
        self.committed([{"url": URL, "sha256": SHA}])
        self.assertEqual(am.check(entries({SHA: URL}), self.path), 1)

    def test_the_same_set_is_current(self):
        derived = entries(RULES_CC)
        self.committed(list(reversed(derived)))
        self.assertEqual(am.check(derived, self.path), 0)


class BuildArgGroups(unittest.TestCase):
    def test_one_group_without_a_separator(self):
        self.assertEqual(
            am.build_arg_groups(["--config=x", "//..."]),
            [["--config=x", "//..."]],
        )

    def test_groups_split_at_the_separator_and_bazel_dashes_kept(self):
        self.assertEqual(
            am.build_arg_groups(
                ["//...", "--and", "-c", "opt", "--", "//a", "-//a:b"]
            ),
            [["//..."], ["-c", "opt", "--", "//a", "-//a:b"]],
        )

    def test_an_empty_group_is_refused(self):
        for args in (["--and", "//..."], ["//...", "--and"]):
            with self.subTest(args=args):
                with self.assertRaises(SystemExit):
                    am.build_arg_groups(args)

    def test_parse_args_defaults_to_one_group_of_everything(self):
        self.assertEqual(am.parse_args([]).build_arg_groups, [["//..."]])
        self.assertEqual(
            am.parse_args(["--check", "--", "//a", "--and", "//b"])
            .build_arg_groups,
            [["//a"], ["//b"]],
        )


class ManifestOf(unittest.TestCase):
    def test_two_urls_sharing_their_bytes_are_both_kept(self):
        other = ((URL + ".mirror",), SHA, "")
        self.assertEqual(
            am.manifest_of({ARCHIVE, other}, {SHA}),
            [am.as_entry(ARCHIVE), am.as_entry(other)],
        )

    def test_nothing_declared_gives_an_empty_manifest(self):
        self.assertEqual(am.manifest_of(set(), {SHA}), [])

    def test_nothing_observed_of_a_declared_set_is_refused(self):
        with self.assertRaises(SystemExit) as cm:
            am.manifest_of({ARCHIVE}, {"00" * 32})
        self.assertIn("refusing an empty manifest", str(cm.exception.code))


class Signals(unittest.TestCase):
    def tearDown(self):
        am.deferred.update(active=False, signum=None, child=None)

    def test_a_signal_while_a_probe_exists_is_recorded_not_raised(self):
        am.deferred["active"] = True
        am.on_signal(15, None)
        am.on_signal(2, None)
        self.assertEqual(am.deferred["signum"], 15)

    def test_the_probe_shutdown_runs_in_a_session_of_its_own(self):
        calls = []
        real = am.subprocess.run
        am.subprocess.run = lambda args, **kw: calls.append((args, kw))
        try:
            am.shutdown_probe("/probe")
        finally:
            am.subprocess.run = real
        [(args, kw)] = calls
        self.assertEqual(args[1:], ["--output_base=/probe", "shutdown"])
        self.assertTrue(kw.get("start_new_session"))

    def test_a_signal_otherwise_exits(self):
        with self.assertRaises(SystemExit) as cm:
            am.on_signal(15, None)
        self.assertEqual(cm.exception.code, 143)


class RemoveTree(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp()

    def tearDown(self):
        for d, dirs, _ in os.walk(self.work):
            for name in dirs:
                p = os.path.join(d, name)
                if not os.path.islink(p):
                    os.chmod(p, stat.S_IRWXU)
        os.chmod(self.work, stat.S_IRWXU)
        am.shutil.rmtree(self.work)

    def test_read_only_tree_removed_and_links_not_followed(self):
        outside = os.path.join(self.work, "outside")
        os.makedirs(outside)
        open(os.path.join(outside, "f"), "w").close()
        os.chmod(outside, 0o555)
        root = os.path.join(self.work, "tree")
        os.makedirs(os.path.join(root, "a", "b"))
        open(os.path.join(root, "a", "b", "f"), "w").close()
        os.symlink(outside, os.path.join(root, "a", "link"))
        os.chmod(os.path.join(root, "a", "b"), 0o555)
        os.chmod(os.path.join(root, "a"), 0o555)
        self.assertIsNone(am.remove_tree(root))
        self.assertFalse(os.path.lexists(root))
        self.assertEqual(os.stat(outside).st_mode & 0o777, 0o555)

    def test_unreadable_directory_is_reported(self):
        root = os.path.join(self.work, "tree")
        os.makedirs(os.path.join(root, "x"))
        os.chmod(os.path.join(root, "x"), 0)
        self.assertIn("could not delete", am.remove_tree(root))

    def test_parent_outside_the_tree_is_left_alone(self):
        parent = os.path.join(self.work, "parent")
        os.makedirs(os.path.join(parent, "tree"))
        os.chmod(parent, 0o555)
        reason = am.remove_tree(os.path.join(parent, "tree"))
        self.assertIn("could not delete", reason)
        self.assertEqual(os.stat(parent).st_mode & 0o777, 0o555)


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1], verbosity=2)
