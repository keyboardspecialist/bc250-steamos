#!/usr/bin/env python3
"""Tests for the BC250 Trainer release bootstrap installer."""

import importlib.util
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "trainer/install-release.py"
SPEC = importlib.util.spec_from_file_location("trainer_release_installer", INSTALLER)
BOOTSTRAP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOOTSTRAP)


def release(tag, draft=False):
    archive_name = "bc250-{}.zip".format(tag)
    assets = []
    for name, size in ((archive_name, 1234), (archive_name + ".sha256", 85)):
        assets.append(
            {
                "name": name,
                "size": size,
                "state": "uploaded",
                "digest": "sha256:" + "a" * 64,
                "browser_download_url": BOOTSTRAP.expected_asset_url(tag, name),
            }
        )
    return {"tag_name": tag, "draft": draft, "prerelease": True, "assets": assets}


def add_zip_member(archive, name, content=b"", mode=stat.S_IFREG | 0o644):
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = mode << 16
    archive.writestr(info, content)


class TrainerBootstrapTests(unittest.TestCase):
    def test_selects_highest_semantic_trainer_release(self):
        selected = BOOTSTRAP.select_release(
            [
                release("trainer-v1.9.0"),
                release("v99.0.0"),
                release("trainer-v2.0.0", draft=True),
                release("trainer-v1.10.0"),
                release("trainer-v1.10.0-rc1"),
            ]
        )
        self.assertEqual(selected["tag_name"], "trainer-v1.10.0")

    def test_requires_exact_native_archive_and_checksum_assets(self):
        selected = release("trainer-v2.3.4")
        archive, checksum = BOOTSTRAP.select_release_assets(selected)
        self.assertEqual(archive["name"], "bc250-trainer-v2.3.4.zip")
        self.assertEqual(checksum["name"], "bc250-trainer-v2.3.4.zip.sha256")

        selected["assets"].append(dict(selected["assets"][0]))
        with self.assertRaisesRegex(BOOTSTRAP.InstallError, "exactly one"):
            BOOTSTRAP.select_release_assets(selected)

    def test_checksum_parser_requires_expected_filename(self):
        with tempfile.TemporaryDirectory() as directory:
            checksum = Path(directory) / "archive.sha256"
            checksum.write_text("{}  expected.zip\n".format("1" * 64), encoding="ascii")
            self.assertEqual(
                BOOTSTRAP.parse_checksum(checksum, "expected.zip"), "1" * 64
            )
            with self.assertRaises(BOOTSTRAP.InstallError):
                BOOTSTRAP.parse_checksum(checksum, "different.zip")

    def test_safe_extract_accepts_release_layout_and_sets_executables(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "trainer.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                add_zip_member(archive, "bc250-trainer/", mode=stat.S_IFDIR | 0o755)
                add_zip_member(
                    archive,
                    "bc250-trainer/trainer/",
                    mode=stat.S_IFDIR | 0o755,
                )
                add_zip_member(
                    archive,
                    "bc250-trainer/trainer/install.sh",
                    b"#!/bin/sh\n",
                    stat.S_IFREG | 0o755,
                )
                add_zip_member(
                    archive,
                    "bc250-trainer/trainer/bc250-trainer",
                    b"binary",
                    stat.S_IFREG | 0o755,
                )
            extracted = BOOTSTRAP.safe_extract(archive_path, root / "extracted")
            for relative in ("trainer/install.sh", "trainer/bc250-trainer"):
                path = extracted / relative
                self.assertTrue(path.is_file())
                self.assertTrue(path.stat().st_mode & stat.S_IXUSR)

    def test_safe_extract_rejects_traversal_and_links(self):
        cases = (
            ("bc250-trainer/../escape", stat.S_IFREG | 0o644),
            ("bc250-trainer/trainer/install.sh", stat.S_IFLNK | 0o777),
        )
        for unsafe_name, mode in cases:
            with self.subTest(name=unsafe_name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive_path = root / "unsafe.zip"
                with zipfile.ZipFile(archive_path, "w") as archive:
                    add_zip_member(archive, unsafe_name, b"unsafe", mode)
                with self.assertRaises(BOOTSTRAP.InstallError):
                    BOOTSTRAP.safe_extract(archive_path, root / "extracted")


if __name__ == "__main__":
    unittest.main()
