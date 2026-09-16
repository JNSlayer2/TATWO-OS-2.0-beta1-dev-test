import copy
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "release_cache", Path(__file__).parents[1] / "scripts/published-release-cache.py")
CACHE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CACHE)


class PublishedCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source, self.out = self.root / "source", self.root / "out"
        self.source.mkdir()
        self.out.mkdir(mode=0o700)
        self.data = b"synthetic release fixture"
        (self.source / "TATWO-OS.zip").write_bytes(self.data)
        self.meta = {"tag_name": "v9.1.2.003", "draft": False, "prerelease": False,
                     "assets": [{"name": "TATWO-OS.zip", "state": "uploaded",
                                 "size": len(self.data),
                                 "digest": "sha256:" + hashlib.sha256(self.data).hexdigest()}]}

    def run_copy(self, names=None):
        return CACHE.materialize(self.meta, "v9.1.2.003", self.source, self.out, names)

    def test_published_bytes_and_receipt(self):
        result = self.run_copy()
        self.assertEqual((self.out / "TATWO-OS.zip").read_bytes(), self.data)
        self.assertEqual(result["assets"][0]["digest"], self.meta["assets"][0]["digest"])

    def test_unpublished_or_wrong_tag(self):
        for field, value in [("draft", True), ("prerelease", True),
                             ("tag_name", "v9.1.2.004"), ("draft", None)]:
            with self.subTest(field=field, value=value):
                original = self.meta[field]
                self.meta[field] = value
                with self.assertRaises(ValueError):
                    self.run_copy()
                self.meta[field] = original

    def test_missing_digest_size_or_uploaded_state(self):
        for field, value in [("digest", None), ("digest", ""),
                             ("size", 0), ("size", True), ("state", "new")]:
            with self.subTest(field=field, value=value):
                original = self.meta["assets"][0][field]
                self.meta["assets"][0][field] = value
                with self.assertRaises(ValueError):
                    self.run_copy()
                self.meta["assets"][0][field] = original

    def test_missing_asset(self):
        with self.assertRaises(ValueError):
            self.run_copy(["missing.zip"])

    def test_missing_file(self):
        (self.source / "TATWO-OS.zip").rename(self.source / "kept.zip")
        with self.assertRaises(FileNotFoundError):
            self.run_copy()

    def test_corrupt_bytes(self):
        (self.source / "TATWO-OS.zip").write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            self.run_copy()

    def test_wrong_size(self):
        self.meta["assets"][0]["size"] += 1
        with self.assertRaises(ValueError):
            self.run_copy()

    def test_unsafe_or_duplicate_names(self):
        for name in ["../escape", "/absolute", "a/b", "a\\b", ""]:
            with self.subTest(name=name):
                self.meta["assets"][0]["name"] = name
                with self.assertRaises(ValueError):
                    self.run_copy()
        self.meta["assets"][0]["name"] = "TATWO-OS.zip"
        self.meta["assets"].append(copy.deepcopy(self.meta["assets"][0]))
        with self.assertRaises(ValueError):
            self.run_copy()

    def test_symlink_rejected(self):
        asset = self.source / "TATWO-OS.zip"
        asset.rename(self.source / "real.zip")
        asset.symlink_to(self.source / "real.zip")
        with self.assertRaises(OSError):
            self.run_copy()

    def test_fifo_rejected_without_blocking(self):
        asset = self.source / "TATWO-OS.zip"
        asset.rename(self.source / "real.zip")
        os.mkfifo(asset)
        with self.assertRaises(ValueError):
            self.run_copy()

    def test_existing_output_preserved(self):
        (self.out / "keep").write_text("keep")
        with self.assertRaises(ValueError):
            self.run_copy()
        self.assertEqual((self.out / "keep").read_text(), "keep")

    def test_unprotected_directory_rejected(self):
        self.source.chmod(0o777)
        with self.assertRaises(ValueError):
            self.run_copy()
        self.source.chmod(0o755)
        self.out.chmod(0o755)
        with self.assertRaises(ValueError):
            self.run_copy()

    def test_symlinked_directory_rejected(self):
        link = self.root / "linked"
        link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            CACHE.materialize(self.meta, "v9.1.2.003", link, self.out)

    def test_baseline_explicit_subset(self):
        self.meta["assets"].append({"name": "not-requested.zip"})
        self.assertEqual(len(self.run_copy(["TATWO-OS.zip"])["assets"]), 1)

    def test_empty_assets_and_duplicate_selection(self):
        with self.assertRaises(ValueError):
            self.run_copy(["TATWO-OS.zip", "TATWO-OS.zip"])
        self.meta["assets"] = []
        with self.assertRaises(ValueError):
            self.run_copy()


if __name__ == "__main__":
    unittest.main()
