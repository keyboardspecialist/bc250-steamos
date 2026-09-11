import hashlib
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Dict, Tuple


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "bc250-optiscaler.sh"
PROXY = "winmm.dll"

ARCHIVE_FILES = (
    "!! README_EXTRACT ALL FILES TO GAME FOLDER !!.txt",
    "D3D12_Optiscaler/D3D12Core.dll",
    "Licenses/DirectX_LICENSE.txt",
    "Licenses/FidelityFX_v1_LICENSE.md",
    "Licenses/FidelityFX_v2_LICENSE.md",
    "Licenses/XeSS_LICENSE.txt",
    "OptiScaler.dll",
    "OptiScaler.ini",
    "amd_fidelityfx_dx12.dll",
    "amd_fidelityfx_framegeneration_dx12.dll",
    "amd_fidelityfx_upscaler_dx12.dll",
    "amd_fidelityfx_vk.dll",
    "dlssg_to_fsr3_amd_is_better.dll",
    "fakenvapi.dll",
    "fakenvapi.ini",
    "libxell.dll",
    "libxess.dll",
    "libxess_dx11.dll",
    "libxess_fg.dll",
    "setup_linux.sh",
    "setup_windows.bat",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_archive(root: Path, marker: bytes = b"fixture") -> Tuple[Path, Dict[str, bytes]]:
    payload = root / "payload"
    payload.mkdir(parents=True)
    contents = {}
    for name in ARCHIVE_FILES:
        path = payload / name
        path.parent.mkdir(parents=True, exist_ok=True)
        value = marker + b":" + name.encode("ascii") + b"\n"
        path.write_bytes(value)
        contents[name] = value
    archive = root / "Optiscaler_0.9.4-final.20260718._MM.7z"
    subprocess.run(
        ["7z", "a", "-t7z", str(archive), "."],
        cwd=payload,
        check=True,
        capture_output=True,
    )
    return archive, contents


class OptiScalerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive, self.payload = make_archive(self.root)
        self.game = self.root / "game with spaces"
        self.game.mkdir()
        self.env = {
            **os.environ,
            "HOME": str(self.root / "home"),
            "BC250_OPTISCALER_STATE_DIR": str(self.root / "state"),
            "BC250_FSR4_STATE_DIR": str(self.root / "fsr4"),
            "BC250_OPTISCALER_ARCHIVE": str(self.archive),
            "BC250_OPTISCALER_ARCHIVE_SHA256": sha256(self.archive),
        }

    def tearDown(self):
        self.temporary.cleanup()

    def run_helper(self, *args, env=None, check=True):
        return subprocess.run(
            ["bash", str(HELPER), *map(str, args)],
            env=env or self.env,
            check=check,
            capture_output=True,
            text=True,
        )

    @staticmethod
    def candidate_id(path):
        return hashlib.sha256(str(path.resolve()).encode()).hexdigest()

    def install(self, path=None, proxy=PROXY, env=None, check=True):
        target = path or self.game
        return self.run_helper(
            "install", target, proxy, self.candidate_id(target), env=env, check=check
        )

    def uninstall(self, path=None, env=None, check=True):
        target = path or self.game
        return self.run_helper(
            "uninstall", target, self.candidate_id(target), env=env, check=check
        )

    def records(self):
        return json.loads(self.run_helper("records-json").stdout)

    def test_script_parses(self):
        subprocess.run(["bash", "-n", str(HELPER)], check=True)

    def test_install_status_idempotence_and_uninstall_restore_exactly(self):
        collision = self.game / "amd_fidelityfx_dx12.dll"
        collision.write_bytes(b"original collision\n")
        collision.chmod(0o751)
        existing_ini = self.game / "fakenvapi.ini"
        existing_ini.write_bytes(b"user ini\n")
        existing_ini.chmod(0o640)

        first = self.install()
        self.assertIn('WINEDLLOVERRIDES="winmm=n,b" %command%', first.stdout)
        self.assertEqual((self.game / PROXY).read_bytes(), self.payload["OptiScaler.dll"])
        self.assertEqual(collision.read_bytes(), self.payload["amd_fidelityfx_dx12.dll"])
        self.assertEqual(existing_ini.read_bytes(), b"user ini\n")
        self.assertFalse((self.game / "setup_linux.sh").exists())
        self.assertFalse((self.game / "setup_windows.bat").exists())

        status = self.records()
        self.assertEqual(status["schemaVersion"], 1)
        self.assertEqual(status["currentRelease"], "v0.9.4")
        self.assertEqual(status["state"], "ready")
        self.assertEqual(status["invalidRecordCount"], 0)
        self.assertEqual(len(status["records"]), 1)
        record = status["records"][0]
        self.assertEqual(record["candidateId"], hashlib.sha256(str(self.game.resolve()).encode()).hexdigest())
        self.assertEqual(record["installPath"], str(self.game.resolve()))
        self.assertEqual(record["proxy"], PROXY)
        self.assertEqual(record["state"], "ready")
        self.assertTrue(record["currentRelease"])

        second = self.install()
        self.assertIn("already installed", second.stdout)
        self.uninstall()
        self.assertEqual(collision.read_bytes(), b"original collision\n")
        self.assertEqual(stat.S_IMODE(collision.stat().st_mode), 0o751)
        self.assertEqual(existing_ini.read_bytes(), b"user ini\n")
        self.assertEqual(stat.S_IMODE(existing_ini.stat().st_mode), 0o640)
        self.assertFalse((self.game / PROXY).exists())
        self.assertFalse((self.game / "OptiScaler.ini").exists())
        self.assertEqual(self.records()["state"], "not-installed")

    def test_modified_dll_refuses_uninstall(self):
        self.install()
        proxy = self.game / PROXY
        proxy.write_bytes(b"external modification\n")
        status = self.records()
        self.assertEqual(status["state"], "invalid")
        self.assertEqual(status["records"][0]["state"], "modified")
        refused = self.uninstall(check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("changed outside the toolkit", refused.stderr)
        self.assertEqual(proxy.read_bytes(), b"external modification\n")

    def test_modified_ini_is_preserved_on_update_and_uninstall(self):
        collision = self.game / "libxell.dll"
        collision.write_bytes(b"preexisting xell\n")
        collision.chmod(0o744)
        self.install()
        config = self.game / "OptiScaler.ini"
        config.write_bytes(b"user changed config\n")
        archive, _ = make_archive(self.root / "update", marker=b"new release")
        update_env = {
            **self.env,
            "BC250_OPTISCALER_RELEASE": "v0.9.5-test",
            "BC250_OPTISCALER_ARCHIVE": str(archive),
            "BC250_OPTISCALER_ARCHIVE_SHA256": sha256(archive),
        }
        pending = json.loads(
            self.run_helper("records-json", env=update_env).stdout
        )
        self.assertEqual(pending["state"], "upgrade-required")
        self.assertEqual(pending["records"][0]["state"], "upgrade-required")
        self.install(env=update_env)
        self.assertEqual(config.read_bytes(), b"user changed config\n")
        status = json.loads(self.run_helper("records-json", env=update_env).stdout)
        self.assertEqual(status["state"], "ready")
        self.uninstall(env=update_env)
        self.assertEqual(config.read_bytes(), b"user changed config\n")
        self.assertEqual(collision.read_bytes(), b"preexisting xell\n")
        self.assertEqual(stat.S_IMODE(collision.stat().st_mode), 0o744)

    def test_missing_toolkit_ini_is_reported_and_repaired(self):
        self.install()
        config = self.game / "OptiScaler.ini"
        config.unlink()

        status = self.records()
        self.assertEqual(status["state"], "repair-required")
        self.assertEqual(status["records"][0]["state"], "repair-required")
        self.install()
        self.assertEqual(config.read_bytes(), self.payload["OptiScaler.ini"])
        self.assertEqual(self.records()["state"], "ready")

    def test_edited_ini_is_preserved_by_direct_uninstall(self):
        self.install()
        config = self.game / "OptiScaler.ini"
        config.write_bytes(b"user settings\n")

        self.uninstall()

        self.assertEqual(config.read_bytes(), b"user settings\n")
        self.assertFalse((self.game / PROXY).exists())

    def test_interrupted_quarantine_is_recovered(self):
        self.install()
        proxy = self.game / PROXY
        suffix = hashlib.sha256(PROXY.encode()).hexdigest()[:24]
        quarantine = self.game / f".bc250-optiscaler-{suffix}.rollback"
        proxy.rename(quarantine)

        self.assertEqual(self.records()["state"], "restorable")
        self.uninstall()
        self.assertFalse(proxy.exists())
        self.assertFalse(quarantine.exists())

    def test_idempotent_install_cleans_post_publication_quarantine(self):
        collision = self.game / "libxell.dll"
        collision.write_bytes(b"original\n")
        self.install()
        identifier = self.candidate_id(self.game)
        record_dir = self.root / "state/installs" / identifier
        record = json.loads((record_dir / "record.json").read_text())
        entry = next(
            item for item in record["files"] if item["path"] == collision.name
        )
        backup = record_dir / "backups" / entry["original"]["backup"]
        suffix = hashlib.sha256(collision.name.encode()).hexdigest()[:24]
        quarantine = self.game / f".bc250-optiscaler-{suffix}.rollback"
        quarantine.write_bytes(backup.read_bytes())
        quarantine.chmod(entry["original"]["mode"])

        result = self.install()

        self.assertIn("already installed", result.stdout)
        self.assertFalse(quarantine.exists())
        self.assertEqual(collision.read_bytes(), self.payload[collision.name])

    def test_post_publication_quarantines_are_reconciled(self):
        collisions = [
            self.game / "amd_fidelityfx_dx12.dll",
            self.game / "libxell.dll",
        ]
        for index, collision in enumerate(collisions):
            collision.write_bytes(f"original {index}\n".encode())
            collision.chmod(0o740 + index)
        self.install()
        identifier = self.candidate_id(self.game)
        record_dir = self.root / "state/installs" / identifier
        record = json.loads((record_dir / "record.json").read_text())

        first_entry = next(
            entry for entry in record["files"] if entry["path"] == collisions[0].name
        )
        first_backup = record_dir / "backups" / first_entry["original"]["backup"]
        first_suffix = hashlib.sha256(collisions[0].name.encode()).hexdigest()[:24]
        first_quarantine = self.game / f".bc250-optiscaler-{first_suffix}.rollback"
        first_quarantine.write_bytes(first_backup.read_bytes())
        first_quarantine.chmod(first_entry["original"]["mode"])

        second_entry = next(
            entry for entry in record["files"] if entry["path"] == collisions[1].name
        )
        second_backup = record_dir / "backups" / second_entry["original"]["backup"]
        second_suffix = hashlib.sha256(collisions[1].name.encode()).hexdigest()[:24]
        second_quarantine = self.game / f".bc250-optiscaler-{second_suffix}.rollback"
        second_quarantine.write_bytes(collisions[1].read_bytes())
        second_quarantine.chmod(second_entry["installedMode"])
        collisions[1].write_bytes(second_backup.read_bytes())
        collisions[1].chmod(second_entry["original"]["mode"])

        self.uninstall()

        for index, collision in enumerate(collisions):
            self.assertEqual(collision.read_bytes(), f"original {index}\n".encode())
        self.assertFalse(first_quarantine.exists())
        self.assertFalse(second_quarantine.exists())

    def test_stale_removed_record_tombstone_is_cleaned_before_install(self):
        identifier = self.candidate_id(self.game)
        tombstone = self.root / "state" / f".removed-{identifier}"
        tombstone.mkdir(parents=True)
        (tombstone / "partial-record").write_bytes(b"stale\n")

        self.install()

        self.assertFalse(tombstone.exists())
        self.assertEqual(self.records()["state"], "ready")

    def test_nested_symlink_swap_is_rejected_without_touching_outside(self):
        self.install()
        nested = self.game / "D3D12_Optiscaler"
        moved = self.game / "D3D12_Optiscaler.original"
        outside = self.root / "outside"
        outside.mkdir()
        sentinel = outside / "D3D12Core.dll"
        sentinel.write_bytes(b"outside\n")
        nested.rename(moved)
        nested.symlink_to(outside, target_is_directory=True)

        refused = self.uninstall(check=False)

        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("subdirectory became unsafe", refused.stderr)
        self.assertEqual(sentinel.read_bytes(), b"outside\n")

    def test_rejects_symlink_install_and_payload_collision(self):
        linked_game = self.root / "linked-game"
        linked_game.symlink_to(self.game, target_is_directory=True)
        refused = self.install(path=linked_game, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("non-symlinked directory", refused.stderr)

        target = self.root / "outside.dll"
        target.write_bytes(b"outside\n")
        (self.game / PROXY).symlink_to(target)
        refused = self.install(check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("symlinked collision", refused.stderr)
        self.assertEqual(target.read_bytes(), b"outside\n")
        self.assertFalse((self.game / "D3D12_Optiscaler").exists())
        self.assertFalse((self.game / "Licenses").exists())

    def test_rejects_archive_checksum_mismatch(self):
        env = {**self.env, "BC250_OPTISCALER_ARCHIVE_SHA256": "0" * 64}
        refused = self.install(env=env, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("checksum mismatch", refused.stderr)
        self.assertEqual(list(self.game.iterdir()), [])

    def test_candidate_id_must_match_canonical_directory(self):
        refused = self.run_helper(
            "install", self.game, PROXY, "0" * 64, check=False
        )
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("Candidate ID does not match", refused.stderr)
        self.assertEqual(list(self.game.iterdir()), [])

    def test_fresh_install_is_blocked_by_fsr4_record(self):
        target = self.game / "amd_fidelityfx_upscaler_dx12.dll"
        fsr_record = self.root / "fsr4/installs" / hashlib.sha256(
            str(target).encode()
        ).hexdigest()
        fsr_record.mkdir(parents=True)
        (fsr_record / "target").write_text(str(target) + "\n", encoding="utf-8")

        refused = self.install(check=False)

        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("FSR4 rollback record", refused.stderr)
        self.assertEqual(list(self.game.iterdir()), [])
        self.assertEqual(self.records()["state"], "not-installed")

    def test_interrupted_fresh_install_remains_uninstallable(self):
        collision = self.game / "amd_fidelityfx_dx12.dll"
        collision.write_bytes(b"original collision\n")
        self.install()
        identifier = self.candidate_id(self.game)
        record_dir = self.root / "state/installs" / identifier
        record = json.loads((record_dir / "record.json").read_text())
        collision_entry = next(
            entry for entry in record["files"]
            if entry["path"] == collision.name
        )
        backup = record_dir / "backups" / collision_entry["original"]["backup"]
        collision.write_bytes(backup.read_bytes())
        collision.chmod(collision_entry["original"]["mode"])
        (self.game / PROXY).unlink()

        status = self.records()
        self.assertEqual(status["state"], "restorable")
        self.assertEqual(status["records"][0]["state"], "restorable")
        self.uninstall()
        self.assertEqual(collision.read_bytes(), b"original collision\n")
        self.assertEqual(self.records()["state"], "not-installed")

    def test_interrupted_update_can_resume_from_durable_journal(self):
        self.install()
        archive, updated_payload = make_archive(
            self.root / "update-journal", marker=b"new release"
        )
        update_env = {
            **self.env,
            "BC250_OPTISCALER_RELEASE": "v0.9.5-test",
            "BC250_OPTISCALER_ARCHIVE": str(archive),
            "BC250_OPTISCALER_ARCHIVE_SHA256": sha256(archive),
        }
        identifier = self.candidate_id(self.game)
        record_path = self.root / "state/installs" / identifier / "record.json"
        record = json.loads(record_path.read_text())
        record["release"] = "v0.9.5-test"
        for entry in record["files"]:
            if entry["kind"] != "runtime":
                continue
            source = "OptiScaler.dll" if entry["path"] == PROXY else entry["path"]
            entry["previousInstalledSha256"] = entry["installedSha256"]
            entry["previousInstalledMode"] = entry["installedMode"]
            entry["installedSha256"] = hashlib.sha256(updated_payload[source]).hexdigest()
        record_path.write_text(json.dumps(record, separators=(",", ":")) + "\n")

        status = json.loads(self.run_helper("records-json", env=update_env).stdout)
        self.assertEqual(status["state"], "restorable")
        self.install(env=update_env)
        self.assertEqual((self.game / PROXY).read_bytes(), updated_payload["OptiScaler.dll"])
        self.assertEqual(
            json.loads(self.run_helper("records-json", env=update_env).stdout)["state"],
            "ready",
        )

    def test_fsr4_record_blocks_update_and_uninstall(self):
        self.install()
        target = self.game / "amd_fidelityfx_upscaler_dx12.dll"
        fsr_record = self.root / "fsr4/installs" / hashlib.sha256(
            str(target).encode()
        ).hexdigest()
        fsr_record.mkdir(parents=True)
        (fsr_record / "target").write_text(
            str(target) + "\n",
            encoding="utf-8",
        )
        update_env = {**self.env, "BC250_OPTISCALER_RELEASE": "v0.9.5-test"}
        update = self.install(env=update_env, check=False)
        self.assertNotEqual(update.returncode, 0)
        self.assertIn("FSR4 rollback record", update.stderr)
        uninstall = self.uninstall(check=False)
        self.assertNotEqual(uninstall.returncode, 0)
        self.assertIn("FSR4 rollback record", uninstall.stderr)
        self.assertTrue((self.game / PROXY).exists())


if __name__ == "__main__":
    unittest.main()
