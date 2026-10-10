#!/usr/bin/env python3
"""Unit tests for scripts/fetch_prebuilt.py.

`fetch_prebuilt.py` is the consumer half of the two-repo scheme: a user with
the `lib/` submodule checked out runs it to download the pre-built dependency
archives published for the exact commit they have, verify them against the
release's `.sha256` sibling, and extract them into `prebuilt/`.

The cases here pin the properties that are easy to break and expensive to
notice:

- **Determinism of the release contract.** The tag (`lib-<sha12>`) and the
  archive names are computed, never queried, so drifting from the producer
  CI's `lib-<sha12>` / `windows-x64.zip` / `macos-arm64.tar.gz` names would
  make every fetch 404. They are pinned here.
- **Fail closed on corruption.** `verify_sha256` raises on a mismatch, and
  the archive is verified *before* anything is extracted.
- **Replace, not merge.** `install` clears only the target platform's tree
  before extracting, so a file absent from a newer archive cannot survive in
  `prebuilt/`, and another platform's tree is never touched.
- **Idempotence.** A `.version` stamp naming the resolved tag short-circuits
  the download unless `--force` is given.

No network access and no third-party dependencies: only the pure helpers plus
`install()` / `verify_sha256()` run, against local temp files. The macOS
extraction branch is exercised with a locally built `.tar.gz` because that
leg cannot run on a Windows machine.

Run directly (`python scripts/test_fetch_prebuilt.py`) or via unittest
discovery.
"""

import hashlib
import io
import os
import platform
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fetch_prebuilt as fp  # noqa: E402


class TempDirTestCase(unittest.TestCase):
    """Base class giving every test an isolated temporary directory."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.tmp_path = Path(self._dir.name)


class NamingTest(unittest.TestCase):
    """Pins the exact tag/archive names the producer CI publishes."""

    def test_release_tag_for(self):
        self.assertEqual(
            fp.release_tag_for("f837ed6ff0c252b4f89ad6d480cdfd5ad25487a1"),
            "lib-f837ed6ff0c2",
        )

    def test_archive_names(self):
        self.assertEqual(fp.archive_name("windows"), "windows-x64.zip")
        self.assertEqual(fp.archive_name("macos"), "macos-arm64.tar.gz")
        self.assertEqual(fp.archive_name("linux"), "linux-x64.tar.gz")

    def test_archive_name_rejects_unknown_platform(self):
        with self.assertRaises(ValueError):
            fp.archive_name("haiku")


class PlatformDetectionTest(unittest.TestCase):
    def test_detect_platform_matches_os(self):
        expected = {
            "Windows": "windows",
            "Darwin": "macos",
            "Linux": "linux",
        }.get(platform.system())
        if expected is None:
            self.skipTest(f"unsupported test host: {platform.system()}")
        self.assertEqual(fp.detect_platform(), expected)

    def test_detect_platform_rejects_unknown_os(self):
        with mock.patch.object(platform, "system", return_value="BeOS"):
            with self.assertRaises(RuntimeError):
                fp.detect_platform()


class LayoutTest(unittest.TestCase):
    def test_repo_root_from(self):
        self.assertEqual(
            fp.repo_root_from(Path("/a/b/scripts/fetch_prebuilt.py")),
            Path("/a/b"),
        )

    def test_prebuilt_and_stamp_paths(self):
        root = Path("/a/b")
        self.assertEqual(fp.prebuilt_dir(root), Path("/a/b/prebuilt"))
        self.assertEqual(
            fp.version_stamp_path(root), Path("/a/b/prebuilt") / fp.VERSION_STAMP
        )


class VerifySha256Test(TempDirTestCase):
    def test_verify_sha256_ok(self):
        payload = b"neurus prebuilt payload\n"
        path = self.tmp_path / "blob.bin"
        path.write_bytes(payload)

        fp.verify_sha256(path, hashlib.sha256(payload).hexdigest())  # no raise

    def test_verify_sha256_mismatch_raises(self):
        path = self.tmp_path / "blob.bin"
        path.write_bytes(b"corrupted")

        with self.assertRaises(RuntimeError):
            fp.verify_sha256(path, "0" * 64)

    def test_verify_sha256_accepts_uppercase_expected(self):
        # `Get-FileHash` (the Windows sibling of `sha256sum`) emits uppercase.
        payload = b"case matters"
        path = self.tmp_path / "blob.bin"
        path.write_bytes(payload)

        fp.verify_sha256(path, hashlib.sha256(payload).hexdigest().upper())

    def test_sha256_file_parsing_handles_both_sibling_formats(self):
        # `sha256sum`: "<digest>  <filename>"; `Get-FileHash` text: bare digest.
        checksum = self.tmp_path / "windows-x64.zip.sha256"
        checksum.write_text("AB12cd  windows-x64.zip\n", encoding="utf-8")
        self.assertEqual(fp._read_expected_sha256(checksum), "AB12cd")

        checksum.write_text("AB12cd\n", encoding="utf-8")
        self.assertEqual(fp._read_expected_sha256(checksum), "AB12cd")


class InstallTest(TempDirTestCase):
    def test_install_extracts_and_replaces(self):
        root = self.tmp_path / "root"
        platform_dir = root / "prebuilt" / "windows"
        (platform_dir / "stale").mkdir(parents=True)
        (platform_dir / "stale" / "old.txt").write_text("old", encoding="utf-8")

        archive = self.tmp_path / "windows-x64.zip"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("windows/shaderc/lib/shaderc_shared.dll", b"dll")
            zf.writestr("windows/qtadvanceddocking/build_info.txt", b"stamp")

        fp.install(archive, root, "windows")

        self.assertEqual(
            (platform_dir / "shaderc" / "lib" / "shaderc_shared.dll").read_bytes(),
            b"dll",
        )
        self.assertEqual(
            (platform_dir / "qtadvanceddocking" / "build_info.txt").read_bytes(),
            b"stamp",
        )
        self.assertFalse((platform_dir / "stale").exists(),
                         "the old tree must be replaced, not merged into")

    def test_install_extracts_tar_gz(self):
        root = self.tmp_path / "root"
        archive = self.tmp_path / "macos-arm64.tar.gz"
        with tarfile.open(archive, "w:gz") as tf:
            data = b"qt_version=6.11.1\ncxx_standard=20\n"
            info = tarfile.TarInfo("macos/qtadvanceddocking/build_info.txt")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))

        fp.install(archive, root, "macos")

        self.assertEqual(
            (root / "prebuilt" / "macos" / "qtadvanceddocking"
             / "build_info.txt").read_bytes(),
            data,
        )

    def test_install_leaves_other_platforms_alone(self):
        root = self.tmp_path / "root"
        other = root / "prebuilt" / "macos" / "keep.txt"
        other.parent.mkdir(parents=True)
        other.write_text("keep", encoding="utf-8")

        archive = self.tmp_path / "windows-x64.zip"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("windows/x.txt", b"x")

        fp.install(archive, root, "windows")

        self.assertEqual(other.read_text(encoding="utf-8"), "keep")
        self.assertEqual((root / "prebuilt" / "windows" / "x.txt").read_bytes(),
                         b"x")


class VersionStampTest(TempDirTestCase):
    def test_should_skip_roundtrip(self):
        root = self.tmp_path / "root"
        self.assertFalse(fp.should_skip(root, "lib-f837ed6ff0c2"),
                         "no stamp -> must not skip")

        stamp = fp.version_stamp_path(root)
        stamp.parent.mkdir(parents=True)
        stamp.write_text("lib-f837ed6ff0c2\n"
                         "f837ed6ff0c252b4f89ad6d480cdfd5ad25487a1\n",
                         encoding="utf-8")

        self.assertTrue(fp.should_skip(root, "lib-f837ed6ff0c2"))
        self.assertFalse(fp.should_skip(root, "lib-000000000000"),
                         "a stamp for another tag must not skip")


class ManifestTest(unittest.TestCase):
    SHA = "f837ed6ff0c252b4f89ad6d480cdfd5ad25487a1"

    def test_validate_manifest_commit_mismatch(self):
        with self.assertRaises(RuntimeError):
            fp.validate_manifest({"built_from_commit": "0" * 40}, self.SHA)

    def test_validate_manifest_missing_commit_raises(self):
        with self.assertRaises(RuntimeError):
            fp.validate_manifest({}, self.SHA)

    def test_validate_manifest_matching_commit_passes(self):
        fp.validate_manifest(
            {"tag": "lib-f837ed6ff0c2", "built_from_commit": self.SHA},
            self.SHA,
        )  # no raise


if __name__ == "__main__":
    unittest.main(verbosity=2)
