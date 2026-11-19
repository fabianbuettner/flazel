"""Unit tests of archive_manifest.py over recorded `bazel mod show_repo` dumps.

Usage: python3 -I archive_manifest_test.py ARCHIVE_MANIFEST_PY TESTDATA_DIR

testdata/show_repo/bazel<N>-<case>.txt is `bazel mod show_repo flazel@_
platforms@_` from tests/archive-override, flazel being a local_path_override
and platforms overridden as <case> says, recorded unedited but for scrubbed
local paths. The remote_patches case names an unresolvable patch URL, which
show_repo prints without fetching. Bazel 7's archive_override has no
remote_patches, so that case exists for 8 and 9 only.
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


def dump(version, case):
    path = os.path.join(TESTDATA, "show_repo", f"bazel{version}-{case}.txt")
    with open(path) as f:
        return f.read()


def answering(text):
    """A stand-in for archive_manifest.bazel that prints text."""
    return lambda *args: text


class OverrideEntries(unittest.TestCase):
    def entries(self, text):
        am.bazel = answering(text)
        return am.override_entries(KEYS)

    def refused(self, text):
        am.bazel = answering(text)
        with self.assertRaises(SystemExit) as cm:
            am.override_entries(KEYS)
        self.assertIn("platforms@_", str(cm.exception.code))
        self.assertIn("not supported offline", str(cm.exception.code))

    def test_archive_kept_with_hex_sha_and_local_skipped(self):
        for v in VERSIONS:
            with self.subTest(bazel=v):
                self.assertEqual(self.entries(dump(v, "archive")), {SHA: URL})

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

    def test_remote_patches_refused(self):
        for v in (8, 9):
            with self.subTest(bazel=v):
                self.refused(dump(v, "remote_patches"))

    def test_remote_file_urls_refused(self):
        # No override sets it; the registry's own specs print it, as below.
        text = dump(9, "remote_patches").replace(
            "remote_patches", "remote_file_urls"
        )
        self.refused(text)

    def test_empty_download_attributes_accepted(self):
        # How Bazel 7 prints a registry module's spec.
        text = dump(7, "archive").replace(
            '  strip_prefix = "",\n',
            '  strip_prefix = "",\n  remote_file_urls = {},\n'
            "  remote_patches = {},\n",
        )
        self.assertIn("remote_patches = {}", text)
        self.assertEqual(self.entries(text), {SHA: URL})


class Derive(unittest.TestCase):
    """derive() feeds the override pass into the manifest."""

    def test_override_archive_reaches_the_manifest(self):
        graph = (
            '{"key": "<root>", "dependencies": ['
            '{"key": "flazel@_"}, {"key": "platforms@_"}]}'
        )

        def fake_bazel(*args):
            return graph if args[:2] == ("mod", "graph") else dump(9, "archive")

        am.bazel = fake_bazel
        am.observe = lambda build_args: {SHA}
        self.assertEqual(am.derive(["//..."]), [{"url": URL, "sha256": SHA}])


class ManifestOf(unittest.TestCase):
    def test_nothing_declared_gives_an_empty_manifest(self):
        self.assertEqual(am.manifest_of({}, {SHA}), [])

    def test_nothing_observed_of_a_declared_set_is_refused(self):
        with self.assertRaises(SystemExit) as cm:
            am.manifest_of({SHA: URL}, {"00" * 32})
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
