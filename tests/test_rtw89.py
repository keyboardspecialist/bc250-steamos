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
            "prepare-kbuild.sh",
            "fetch-steamos-package.sh",
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
            self.assertIn("rtw89-steamos-firmware-v2", source)
            self.assertIn("manifest.pending", source)
            self.assertIn("recover_module_transaction", source)
            self.assertIn("install-transaction", source)
            self.assertIn(".zst", source)
        self.assertIn('cat "$SCRIPT_DIR/usb_storage.conf"', installer)
        self.assertIn("0bda", installer)
        self.assertIn("RTL8922DE", installer)
        self.assertIn("find_matching_endpoints", repair)

    def test_standalone_release_and_toolkit_launcher_include_rtw89(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="utf-8"
        )
        persistence = (ROOT / "bc250-update-persistence.sh").read_text(
            encoding="utf-8"
        )
        storage = (ROOT / "bc250-storage.sh").read_text(encoding="utf-8")
        self.assertIn("desktop-control backend scripts rtw89", workflow)
        self.assertIn("RTW89_ARTIFACT_BASENAME", workflow)
        self.assertIn("HEAD:rtw89", workflow)
        self.assertNotIn("rtw89", persistence)
        self.assertNotIn("\n    rtw89-modules.service\n", storage)

    def test_lifecycle_has_no_broader_toolkit_runtime_dependency(self):
        lifecycle = [
            RTW89 / "steamdeck-setup.sh",
            RTW89 / "rtw89-ensure-modules.sh",
            RTW89 / "rtw89-modules.service",
            RTW89 / "prepare-kbuild.sh",
            RTW89 / "fetch-steamos-package.sh",
        ]
        forbidden = (
            "bc250-storage.sh",
            "bc250-update-persistence.sh",
            "bc250-audio-fix",
            "decky-plugin",
            "desktop-control",
            "aic8800",
        )
        combined = "\n".join(path.read_text(encoding="utf-8") for path in lifecycle)
        for value in forbidden:
            self.assertNotIn(value, combined)
        self.assertIn("/home/.steamos/offload/var/lib/rtw89-steamos", combined)
        self.assertIn("migrate_legacy_install", combined)
        self.assertIn("LEGACY_DATA=/var/lib/bc250-control/rtw89", combined)
        self.assertIn("vmlinux is absent; optional module BTF will be skipped", combined)
        self.assertNotIn("vmlinux is required", combined)
        self.assertIn('rm -f "$EXTRACTED/vmlinux"', combined)
        self.assertIn('[[ -s $KDIR/Module.symvers ]]', combined)
        self.assertIn("LEGACY_HELPER_SHA=", combined)
        self.assertIn("finalize_legacy_migration", combined)
        install_flow = combined[combined.index("install_rtw89()") :]
        self.assertLess(
            install_flow.index("finalize_legacy_migration"),
            install_flow.index("relock_rootfs"),
        )
        self.assertIn("secure_kbuild_tree", combined)
        self.assertIn('case "$target" in "$path"/*)', combined)


if __name__ == "__main__":
    unittest.main()
