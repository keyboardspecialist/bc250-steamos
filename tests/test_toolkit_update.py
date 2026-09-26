#!/usr/bin/env python3
"""Tests for the Trainer's main toolkit release updater."""

import importlib.util
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UPDATER_PATH = ROOT / "scripts/toolkit-update.py"
SPEC = importlib.util.spec_from_file_location("toolkit_update", UPDATER_PATH)
UPDATER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATER)


def release(tag, draft=False, prerelease=False):
    archive_name = "bc250-steamos-toolkit-{}.zip".format(tag)
    assets = []
    for name, size in ((archive_name, 1234), (archive_name + ".sha256", 85)):
        assets.append(
            {
                "name": name,
                "size": size,
                "state": "uploaded",
                "digest": "sha256:" + "a" * 64,
                "browser_download_url": UPDATER.expected_asset_url(tag, name),
            }
        )
    return {
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "assets": assets,
    }


def add_member(archive, name, content=b"", mode=stat.S_IFREG | 0o644):
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = mode << 16
    archive.writestr(info, content)


def write_install(directory, version):
    directory.mkdir()
    (directory / "VERSION").write_text(version + "\n", encoding="ascii")
    launcher = directory / "bc250-toolkit.sh"
    launcher.write_text("#!/usr/bin/env bash\n", encoding="ascii")
    launcher.chmod(0o755)


class ToolkitUpdateTests(unittest.TestCase):
    def test_selects_latest_stable_main_release(self):
        selected = UPDATER.select_release(
            [
                release("v1.9.0"),
                release("trainer-v99.0.0"),
                release("v2.0.0", draft=True),
                release("v1.10.0"),
                release("v3.0.0", prerelease=True),
            ]
        )
        self.assertEqual(selected["tag_name"], "v1.10.0")

    def test_requires_exact_toolkit_archive_and_checksum(self):
        archive, checksum = UPDATER.select_release_assets(release("v2.3.4"))
        self.assertEqual(archive["name"], "bc250-steamos-toolkit-v2.3.4.zip")
        self.assertEqual(checksum["name"], archive["name"] + ".sha256")

    def test_check_compares_semantic_versions(self):
        with tempfile.TemporaryDirectory() as temporary:
            installation = Path(temporary) / "bc250-steamos"
            write_install(installation, "v1.9.0")
            status = UPDATER.check_for_update(
                installation.resolve(), [release("v1.10.0")]
            )
            self.assertEqual(status["currentVersion"], "v1.9.0")
            self.assertEqual(status["latestVersion"], "v1.10.0")
            self.assertTrue(status["updateAvailable"])

    def test_check_env_format_is_safe_for_cli_parser(self):
        result = {
            "currentVersion": "v1.9.0",
            "latestVersion": "v1.10.0",
            "updateAvailable": True,
        }
        self.assertEqual(
            UPDATER.format_check_env(result).splitlines(),
            ["CURRENT_VERSION=v1.9.0", "LATEST_VERSION=v1.10.0", "UPDATE_AVAILABLE=1"],
        )

    def test_safe_extract_validates_layout_and_release_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "toolkit.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                add_member(archive, "bc250-steamos/", mode=stat.S_IFDIR | 0o755)
                add_member(archive, "bc250-steamos/VERSION", b"v2.0.0\n")
                add_member(
                    archive,
                    "bc250-steamos/bc250-toolkit.sh",
                    b"#!/usr/bin/env bash\n",
                    stat.S_IFREG | 0o755,
                )
            extracted = UPDATER.safe_extract(
                archive_path, root / "extracted", "v2.0.0"
            )
            self.assertEqual(
                (extracted / "VERSION").read_text(encoding="ascii"), "v2.0.0\n"
            )
            self.assertTrue((extracted / "bc250-toolkit.sh").stat().st_mode & stat.S_IXUSR)

    def test_safe_extract_rejects_traversal_and_links(self):
        cases = (
            ("bc250-steamos/../escape", stat.S_IFREG | 0o644),
            ("bc250-steamos/bc250-toolkit.sh", stat.S_IFLNK | 0o777),
        )
        for unsafe_name, mode in cases:
            with self.subTest(name=unsafe_name), tempfile.TemporaryDirectory() as temporary:
                archive_path = Path(temporary) / "unsafe.zip"
                with zipfile.ZipFile(archive_path, "w") as archive:
                    add_member(archive, unsafe_name, b"unsafe", mode)
                with self.assertRaises(UPDATER.UpdateError):
                    UPDATER.safe_extract(
                        archive_path, Path(temporary) / "extracted", "v2.0.0"
                    )

    def test_replacement_is_atomic_and_removes_previous_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "bc250-steamos"
            replacement = root / "staged"
            write_install(target, "v1.0.0")
            (target / "old-file").write_text("old", encoding="ascii")
            write_install(replacement, "v2.0.0")
            UPDATER.replace_installation(target, replacement)
            self.assertEqual((target / "VERSION").read_text(encoding="ascii"), "v2.0.0\n")
            self.assertFalse((target / "old-file").exists())
            self.assertFalse(replacement.exists())
            self.assertEqual(list(root.glob(".bc250-steamos.previous-*")), [])


if __name__ == "__main__":
    unittest.main()
