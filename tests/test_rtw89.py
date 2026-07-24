import hashlib
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RTW89 = ROOT / "rtw89"
COMMIT = "08b8d326937a200a706ec9c501374eec15835b5a"


class Rtw89Tests(unittest.TestCase):
    def test_vendored_source_is_pinned_and_has_no_nested_repository(self):
        self.assertEqual((RTW89 / "UPSTREAM_COMMIT").read_text().strip(), COMMIT)
        self.assertFalse(any(path.name == ".git" for path in RTW89.rglob(".git")))
        self.assertFalse(any(path.is_symlink() for path in RTW89.rglob("*")))
        makefile = (RTW89 / "Makefile").read_text(encoding="utf-8")
        self.assertIn(f"-DGIT_COMMIT={COMMIT}", makefile)
        self.assertNotIn("git --git-dir", makefile)

    def test_source_manifest_matches_every_pinned_file(self):
        manifest = RTW89 / "SOURCE_MANIFEST.sha256"
        entries = manifest.read_text(encoding="ascii").splitlines()
        self.assertGreater(len(entries), 100)
        manifested = set()
        for entry in entries:
            digest, relative = entry.split("  ", 1)
            manifested.add(relative)
            payload = RTW89 / relative
            self.assertTrue(payload.is_file(), relative)
            self.assertEqual(hashlib.sha256(payload.read_bytes()).hexdigest(), digest)
        lifecycle = {
            "SOURCE_MANIFEST.sha256",
            "STEAMOS.md",
            "steamdeck-setup.sh",
            "rtw89-ensure-modules.sh",
            "rtw89-modules.service",
        }
        vendored = {
            path.relative_to(RTW89).as_posix()
            for path in RTW89.rglob("*")
            if path.is_file() and path.relative_to(RTW89).as_posix() not in lifecycle
        }
        self.assertEqual(manifested, vendored)

    def test_lifecycle_contract_and_supported_families(self):
        installer = RTW89 / "steamdeck-setup.sh"
        for command in ("help", "status"):
            result = subprocess.run(
                ["bash", str(installer), command],
                capture_output=True,
                text=True,
            )
            if command == "help":
                self.assertEqual(result.returncode, 0)
                self.assertIn("uninstall", result.stdout)
            else:
                self.assertIn(result.returncode, (0, 1))
                self.assertIn("[rtw89] state:", result.stdout)
        readme = (RTW89 / "STEAMOS.md").read_text(encoding="utf-8")
        for family in ("RTL8851", "RTL8852", "RTL8922", "PCIe", "USB"):
            self.assertIn(family, readme)
        self.assertIn("Bluetooth is a separate", readme)

    def test_lifecycle_caches_firmware_and_recovers_module_transactions(self):
        installer = (RTW89 / "steamdeck-setup.sh").read_text(encoding="utf-8")
        repair = (RTW89 / "rtw89-ensure-modules.sh").read_text(encoding="utf-8")
        for source in (installer, repair):
            self.assertIn("bc250-rtw89-firmware-v2", source)
            self.assertIn("manifest.pending", source)
            self.assertIn("recover_module_transaction", source)
            self.assertIn("install-transaction", source)
            self.assertIn(".zst", source)
        self.assertIn('cat "$SCRIPT_DIR/usb_storage.conf"', installer)
        self.assertIn("0bda", installer)
        self.assertIn("RTL8922DE", installer)
        self.assertIn("find_matching_endpoints", repair)

    def test_toolkit_release_and_persistence_include_rtw89(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="utf-8"
        )
        persistence = (ROOT / "bc250-update-persistence.sh").read_text(
            encoding="utf-8"
        )
        storage = (ROOT / "bc250-storage.sh").read_text(encoding="utf-8")
        self.assertIn("desktop-control backend scripts rtw89", workflow)
        self.assertIn("bc250-rtw89.conf", persistence)
        self.assertIn("rtw89-modules.service", persistence)
        self.assertIn("rtw89-modules.service", storage)


if __name__ == "__main__":
    unittest.main()
