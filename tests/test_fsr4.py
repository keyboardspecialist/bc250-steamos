import hashlib
import io
import json
import os
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "bc250-fsr4.sh"
DLL_NAME = "amd_fidelityfx_upscaler_dx12.dll"
RC11 = "v4.0.0-rc11"
ARCHIVE_SHA256 = "95ef0c6ea887e0506a3a92f7e4648e7ab7e1100e99f5eff2f70dd33b8dff2a72"
DLL_SHA256 = "8192ea97620f8e6407bff346bf905f0d555ff73d89fe14616eb1fa5e41ab3175"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class FSR4PortableDllTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "fsr4"
        self.target = self.root / "game with spaces/OptiScaler" / DLL_NAME
        self.target.parent.mkdir(parents=True)
        self.original = b"MZ original game DLL\n"
        self.payload = b"MZ synthetic rc11 DLL\n"
        self.target.write_bytes(self.original)
        self.target.chmod(0o751)
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("BC250_FSR4_", "BC250_HELIXSR_"))
        }
        self.env.update({
            "HOME": str(self.root / "home"),
            "BC250_FSR4_STATE_DIR": str(self.state),
            "BC250_FSR4_LOCK_FILE": str(self.root / "fsr4.lock"),
            "BC250_HELIXSR_STATE_DIR": str(self.root / "helixsr"),
            "BC250_HELIXSR_LOCK_FILE": str(self.root / "helixsr.lock"),
            "BC250_FSR4_DLL_SHA256": hashlib.sha256(self.payload).hexdigest(),
        })
        self.archive = self.root / "fixture.zip"

    @property
    def record(self):
        identifier = hashlib.sha256(str(self.target.resolve()).encode()).hexdigest()
        return self.state / "installs" / identifier

    def run_helper(self, *arguments, env=None, success=True):
        result = subprocess.run(
            ["bash", str(HELPER), *map(str, arguments)],
            env=self.env if env is None else env,
            capture_output=True, text=True, check=False,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def files(self):
        return [
            (DLL_NAME, self.payload),
            ("README.md", b"experimental prerelease\n"),
            ("SHA256SUMS", b"fixture checksums\n"),
            ("notices/PROVENANCE.md", b"fixture provenance\n"),
            ("notices/AMD-SDK-LICENSE.md", b"fixture SDK license\n"),
            ("notices/LICENSE-LLVM.txt", b"fixture LLVM license\n"),
            ("notices/LICENSE-MS.txt", b"fixture MS license\n"),
            ("notices/LICENSE.new-code", b"fixture code license\n"),
            ("notices/V4-THIRD-PARTY.md", b"fixture third party notices\n"),
            ("linux/shared-cache.sh", b"#!/bin/sh\nexit 99\n"),
        ]

    def make_zip(self, entries=None, compression=zipfile.ZIP_DEFLATED):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "w", compression=compression) as output:
                for name, data in self.files() if entries is None else entries:
                    output.writestr(name, data)
        self.pin_archive()

    def pin_archive(self):
        self.env["BC250_FSR4_ARCHIVE"] = str(self.archive)
        self.env["BC250_FSR4_ARCHIVE_SHA256"] = digest(self.archive)

    def assert_rejected(self, message=None):
        result = self.run_helper("install", self.target, success=False)
        if message:
            self.assertIn(message, result.stderr)
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o751)
        self.assertFalse(self.record.exists())
        self.assertFalse((self.state / "cache" / RC11).exists())
        self.assertEqual(list((self.state / "cache").glob(".release.*")), [])

    def install_rc9(self):
        old_payload = b"MZ synthetic rc9 DLL\n"
        archive = self.root / "rc9-docs2.tar.xz"
        with tarfile.open(archive, "w:xz") as output:
            for name, data in self.files():
                data = old_payload if name == DLL_NAME else data
                member = tarfile.TarInfo(name)
                member.size = len(data)
                output.addfile(member, io.BytesIO(data))
        old_env = {
            **self.env,
            "BC250_FSR4_RELEASE": "v4.0.0-rc9",
            "BC250_FSR4_ARCHIVE_NAME": archive.name,
            "BC250_FSR4_ARCHIVE": str(archive),
            "BC250_FSR4_ARCHIVE_SHA256": digest(archive),
            "BC250_FSR4_DLL_SHA256": hashlib.sha256(old_payload).hexdigest(),
        }
        self.run_helper("install", self.target, env=old_env)
        self.assertEqual(self.target.read_bytes(), old_payload)
        self.assertTrue((self.record / "install.conf").read_text().startswith("v4.0.0-rc9 "))
        return old_payload

    def test_official_rc11_pins_and_default_download_url(self):
        source = HELPER.read_text()
        self.assertIn(f'RELEASE="${{BC250_FSR4_RELEASE:-{RC11}}}"', source)
        self.assertIn(ARCHIVE_SHA256, source)
        self.assertIn(DLL_SHA256, source)
        self.make_zip()
        binary = self.root / "bin"
        binary.mkdir()
        curl = binary / "curl"
        curl.write_text(
            '#!/bin/bash\n'
            'printf "%s\\n" "$@" > "$DOWNLOAD_LOG"\n'
            'while (($#)); do\n'
            '  if [[ "$1" == -o ]]; then cp "$FIXTURE_ARCHIVE" "$2"; exit; fi\n'
            '  shift\n'
            'done\nexit 1\n'
        )
        curl.chmod(0o755)
        env = {
            **self.env,
            "PATH": f"{binary}:{self.env['PATH']}",
            "DOWNLOAD_LOG": str(self.root / "download.log"),
            "FIXTURE_ARCHIVE": str(self.archive),
        }
        del env["BC250_FSR4_ARCHIVE"]
        self.run_helper("install", self.target, env=env)
        arguments = (self.root / "download.log").read_text().splitlines()
        self.assertIn(
            "https://github.com/daniel-h-0/bc250-fsr4-fork/releases/download/"
            "v4.0.0-rc11/bc250-fsr4-dll-4.0.0-rc11.zip", arguments,
        )
        self.assertEqual(self.target.read_bytes(), self.payload)

    def test_zip_install_is_idempotent_and_preserves_notices_mode_and_rollback(self):
        self.make_zip()
        self.run_helper("install", self.target)
        self.assertEqual(self.target.read_bytes(), self.payload)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o751)
        self.assertEqual((self.record / "original.dll").read_bytes(), self.original)
        release = self.state / "cache" / RC11
        for name, data in self.files():
            self.assertEqual((release / name).read_bytes(), data)
            self.assertFalse((release / name).stat().st_mode & 0o022)
        self.assertFalse((release / "linux/shared-cache.sh").stat().st_mode & 0o111)
        before = (self.record / "install.conf").read_bytes()
        self.run_helper("install", self.target)
        self.assertEqual((self.record / "install.conf").read_bytes(), before)
        self.assertEqual((self.record / "original.dll").read_bytes(), self.original)
        self.run_helper("probe")
        report = json.loads(self.run_helper("records-json").stdout)
        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(report["currentRelease"], RC11)
        self.assertEqual(report["state"], "ready")
        self.assertTrue(report["records"][0]["currentRelease"])
        self.run_helper("uninstall", self.target)
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o751)
        self.assertFalse(self.record.exists())

    def test_legacy_rc9_tar_upgrade_keeps_original_not_old_dll(self):
        self.install_rc9()
        self.make_zip()
        result = self.run_helper("status", success=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("upgrade-required (v4.0.0-rc9)", result.stdout)
        self.assertEqual(self.run_helper("probe", success=False).returncode, 2)
        report = json.loads(self.run_helper("records-json").stdout)
        self.assertEqual(report["records"][0]["state"], "upgrade-required")
        self.assertFalse(report["records"][0]["currentRelease"])
        self.run_helper("install", self.target)
        self.assertEqual(self.target.read_bytes(), self.payload)
        self.assertEqual((self.record / "original.dll").read_bytes(), self.original)
        self.assertTrue((self.record / "install.conf").read_text().startswith(RC11 + " "))
        self.run_helper("uninstall", "--all")
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o751)

    def test_rc9_removal_needs_no_old_release_cache_archive_or_current_hash(self):
        self.install_rc9()
        shutil.rmtree(self.state / "cache")
        (self.root / "rc9-docs2.tar.xz").unlink()
        env = {**self.env, "BC250_FSR4_DLL_SHA256": "0" * 64}
        self.run_helper("uninstall", "--all", env=env)
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o751)
        self.assertFalse(self.record.exists())

    def test_failed_rc11_upgrade_preserves_rc9_and_its_record(self):
        old_payload = self.install_rc9()
        before = (self.record / "install.conf").read_bytes()
        self.make_zip(self.files() + [("../escape", b"unsafe")])
        self.run_helper("install", self.target, success=False)
        self.assertEqual(self.target.read_bytes(), old_payload)
        self.assertEqual((self.record / "install.conf").read_bytes(), before)
        self.assertEqual((self.record / "original.dll").read_bytes(), self.original)
        self.run_helper("uninstall", self.target)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_modified_rc9_target_is_never_overwritten_by_upgrade_or_removal(self):
        self.install_rc9()
        self.make_zip()
        changed = b"external game update\n"
        self.target.write_bytes(changed)
        for action in ("install", "uninstall"):
            with self.subTest(action=action):
                result = self.run_helper(action, self.target, success=False)
                self.assertIn("changed outside the toolkit", result.stderr)
                self.assertEqual(self.target.read_bytes(), changed)
                self.assertEqual((self.record / "original.dll").read_bytes(), self.original)

    def test_missing_rc9_target_can_be_restored(self):
        self.install_rc9()
        self.target.unlink()
        self.run_helper("uninstall", self.target)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_archive_and_dll_checksum_mismatches_do_not_replace_original(self):
        self.make_zip()
        self.env["BC250_FSR4_ARCHIVE_SHA256"] = "0" * 64
        self.assert_rejected("checksum mismatch")
        self.pin_archive()
        self.env["BC250_FSR4_DLL_SHA256"] = "0" * 64
        self.assert_rejected("payload failed validation")

    def test_missing_required_payload_files_fail_before_record_creation(self):
        for missing in (DLL_NAME, "README.md", "notices/PROVENANCE.md"):
            with self.subTest(missing=missing):
                self.make_zip([(name, data) for name, data in self.files() if name != missing])
                self.assert_rejected("payload failed validation")

    def test_zip_rejects_unsafe_member_paths(self):
        for name in ("../escape", "/absolute", "a/../../escape", "a//b", "./extra",
                     "a/./b", "a\\b", "C:/escape", "C:escape", "line\nbreak", "a/../b"):
            with self.subTest(name=name):
                self.make_zip(self.files() + [(name, b"unsafe")])
                self.assert_rejected("Unsafe archive member path")
        self.assertFalse((self.state / "cache/escape").exists())

    def test_zip_rejects_nul_in_member_name(self):
        self.make_zip(self.files() + [("nul-marker.txt", b"unsafe")])
        self.archive.write_bytes(self.archive.read_bytes().replace(b"nul-marker.txt", b"nul\x00marker.txt"))
        self.pin_archive()
        self.assert_rejected("Unsafe archive member path")

    def test_zip_rejects_duplicates_and_file_directory_collisions(self):
        cases = [
            [("README.md", b"duplicate")],
            [("readme.MD", b"case duplicate")],
            [("extra", b"file"), ("extra/child", b"child")],
            [("EXTRA/child", b"child"), ("extra", b"file")],
            [("extra/", b""), ("extra", b"file")],
        ]
        for extra in cases:
            with self.subTest(extra=extra):
                self.make_zip(self.files() + extra)
                self.assert_rejected()

    def test_zip_rejects_links_devices_fifos_sockets_and_mistyped_directories(self):
        for mode in (stat.S_IFLNK, stat.S_IFCHR, stat.S_IFBLK, stat.S_IFIFO, stat.S_IFSOCK,
                     stat.S_IFDIR):
            with self.subTest(mode=mode):
                member = zipfile.ZipInfo("unsafe")
                member.create_system = 3
                member.external_attr = (mode | 0o777) << 16
                self.make_zip(self.files() + [(member, b"../escape")])
                self.assert_rejected("non-regular member")
        member = zipfile.ZipInfo("unsafe/")
        member.external_attr = (stat.S_IFREG | 0o644) << 16
        self.make_zip(self.files() + [(member, b"")])
        self.assert_rejected("non-regular member")

    def test_zip_accepts_explicit_directories_and_windows_regular_files(self):
        directory = zipfile.ZipInfo("notices/")
        directory.external_attr = (stat.S_IFDIR | 0o777) << 16 | 0x10
        windows = zipfile.ZipInfo("windows.txt")
        windows.create_system = 0
        windows.external_attr = 0x20
        self.make_zip([(directory, b"")] + self.files() + [(windows, b"regular file")])
        self.run_helper("install", self.target)
        self.run_helper("uninstall", self.target)

    def test_zip_rejects_directory_data_and_unsupported_compression(self):
        member = zipfile.ZipInfo("extra/")
        member.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
        self.make_zip(self.files() + [(member, b"directory data")])
        self.assert_rejected("size limit")
        self.make_zip(compression=zipfile.ZIP_BZIP2)
        self.assert_rejected("Unsupported ZIP member encoding")

    def test_zip_rejects_encryption_flags(self):
        self.make_zip()
        content = bytearray(self.archive.read_bytes())
        for signature, offset in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
            position = content.index(signature) + offset
            struct.pack_into("<H", content, position, struct.unpack_from("<H", content, position)[0] | 1)
        self.archive.write_bytes(content)
        self.pin_archive()
        self.assert_rejected("Unsupported ZIP member encoding")

    def test_zip_rejects_corrupt_crc_and_nonarchives(self):
        self.make_zip(compression=zipfile.ZIP_STORED)
        self.archive.write_bytes(self.archive.read_bytes().replace(self.payload, b"X" + self.payload[1:], 1))
        self.pin_archive()
        self.assert_rejected("invalid FSR4 archive")
        self.archive.write_bytes(b"not a ZIP or tar.xz")
        self.pin_archive()
        self.assert_rejected("invalid FSR4 archive")

    def test_zip_bombs_are_rejected_by_ratio_and_member_count(self):
        self.make_zip(self.files() + [("bomb", b"0" * 1024 * 1024)])
        self.assert_rejected("compression ratio")
        self.make_zip(self.files() + [(f"extra-{index}", b"") for index in range(129)])
        self.assert_rejected("ZIP directory limit")

    def test_zip_bombs_are_rejected_by_declared_file_and_total_size(self):
        for sizes, message in (([129 * 1024 * 1024], "member size"),
                               ([96 * 1024 * 1024] * 3, "expanded size")):
            with self.subTest(sizes=sizes):
                self.make_zip([(f"entry-{index}", b"tiny") for index in range(len(sizes))])
                content = bytearray(self.archive.read_bytes())
                position = 0
                for size in sizes:
                    position = content.index(b"PK\x01\x02", position)
                    struct.pack_into("<II", content, position + 20, 1024 * 1024, size)
                    position += 4
                self.archive.write_bytes(content)
                self.pin_archive()
                self.assert_rejected(message)

    def test_zip_central_directory_allocation_is_bounded(self):
        self.make_zip()
        content = bytearray(self.archive.read_bytes())
        end = content.rindex(b"PK\x05\x06")
        struct.pack_into("<I", content, end + 12, 1024 * 1024 * 1024)
        self.archive.write_bytes(content)
        self.pin_archive()
        self.assert_rejected("ZIP directory limit")

    def test_zip64_cannot_override_the_bounded_classic_directory(self):
        self.make_zip()
        content = self.archive.read_bytes()
        end = content.rindex(b"PK\x05\x06")
        _, _, _, count, _, _, offset, _ = struct.unpack("<4s4H2LH", content[end:end + 22])
        zip64_end = struct.pack(
            "<4sQ2H2L4Q", b"PK\x06\x06", 44, 45, 45, 0, 0,
            count, count, 1024 * 1024 * 1024, offset,
        )
        locator = struct.pack("<4sLQL", b"PK\x06\x07", 0, end, 1)
        self.archive.write_bytes(content[:end] + zip64_end + locator + content[end:])
        self.pin_archive()
        self.assert_rejected("ZIP directory limit")

    def test_archive_name_cannot_escape_cache(self):
        self.make_zip()
        for name in ("../escape.zip", "/absolute.zip", "a/b.zip", "a\\b.zip", "-option.zip"):
            with self.subTest(name=name):
                env = {**self.env, "BC250_FSR4_ARCHIVE_NAME": name}
                result = self.run_helper("install", self.target, env=env, success=False)
                self.assertIn("Invalid archive name", result.stderr)
                self.assertEqual(self.target.read_bytes(), self.original)

    def test_invalid_checksum_pins_are_rejected(self):
        for variable in ("BC250_FSR4_ARCHIVE_SHA256", "BC250_FSR4_DLL_SHA256"):
            with self.subTest(variable=variable):
                result = self.run_helper("records-json", env={**self.env, variable: "not a hash"}, success=False)
                self.assertIn("Invalid checksum pin", result.stderr)

    def test_legacy_tar_rejects_links_traversal_and_duplicates(self):
        for kind in ("symlink", "hardlink", "fifo", "traversal", "duplicate"):
            with self.subTest(kind=kind):
                with tarfile.open(self.archive, "w:xz") as output:
                    for name, data in self.files():
                        member = tarfile.TarInfo(name)
                        member.size = len(data)
                        output.addfile(member, io.BytesIO(data))
                    member = tarfile.TarInfo("../escape" if kind == "traversal" else "README.md")
                    if kind in ("symlink", "hardlink", "fifo"):
                        member.type = {"symlink": tarfile.SYMTYPE, "hardlink": tarfile.LNKTYPE,
                                       "fifo": tarfile.FIFOTYPE}[kind]
                        member.linkname = "../escape"
                    output.addfile(member)
                self.pin_archive()
                self.assert_rejected()


class FSR4HelixConflictTests(unittest.TestCase):
    def test_install_refuses_helixsr_managed_target_before_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "game/amd_fidelityfx_upscaler_dx12.dll"
            target.parent.mkdir()
            target.write_bytes(b"game dll\n")
            target_path = str(target.resolve())
            identifier = hashlib.sha256(target_path.encode()).hexdigest()
            record = root / "helixsr/installs" / identifier
            record.mkdir(parents=True)
            (record / "record.json").write_text(json.dumps({
                "targetId": identifier,
                "targetPath": target_path,
            }), encoding="utf-8")
            env = {
                **os.environ,
                "HOME": str(root / "home"),
                "BC250_FSR4_STATE_DIR": str(root / "fsr4"),
                "BC250_FSR4_LOCK_FILE": str(root / "fsr4.lock"),
                "BC250_HELIXSR_STATE_DIR": str(root / "helixsr"),
                "BC250_HELIXSR_LOCK_FILE": str(root / "helixsr.lock"),
            }

            result = subprocess.run(
                ["bash", str(HELPER), "install", str(target)], env=env,
                check=False, capture_output=True, text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("managed by HelixSR", result.stderr)
            self.assertEqual(target.read_bytes(), b"game dll\n")


if __name__ == "__main__":
    unittest.main()
