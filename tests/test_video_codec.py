import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "video-codec/bc250-video-codec.sh"
MANIFEST = ROOT / "video-codec/v0.5.1.sha256"


class VideoCodecTests(unittest.TestCase):
    def run_script(self, *arguments, data_dir, env_file):
        environment = os.environ.copy()
        environment.update(
            {
                "BC250_VIDEO_DATA_DIR": str(data_dir),
                "BC250_VIDEO_ENV_FILE": str(env_file),
                "BC250_VIDEO_LOCK_FILE": str(data_dir.parent / "codec.lock"),
            }
        )
        return subprocess.run(
            ["bash", str(SCRIPT), *arguments],
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_status_distinguishes_absent_and_partial_installations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data"
            environment = root / "environment.d/90-bc250-video-codec.conf"

            absent = self.run_script(
                "status", data_dir=data, env_file=environment
            )
            self.assertEqual(absent.returncode, 1)
            self.assertIn("state: not-installed", absent.stdout)
            self.assertIn("release: v0.5.1", absent.stdout)

            environment.parent.mkdir()
            environment.write_text(
                "# BC-250 toolkit managed VA-API video codec\n",
                encoding="utf-8",
            )
            partial = self.run_script(
                "status", data_dir=data, env_file=environment
            )
            self.assertEqual(partial.returncode, 2)
            self.assertIn("state: incomplete", partial.stdout)
            self.assertIn("driver: missing-or-invalid", partial.stdout)

    def test_release_and_payload_digests_are_pinned(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("RELEASE=v0.5.1", source)
        self.assertIn(
            "SOURCE_COMMIT=180aab87fa84b68f8d4a9d6bf8d4c1fb0cac940e",
            source,
        )
        self.assertIn(
            "ARCHIVE_SHA256=b38347ffa7bbc2d9365edcf83ac5b161516eb3625946abeaa1cb600aef2d2b05",
            source,
        )
        self.assertIn("releases/download/$RELEASE/$ARCHIVE_NAME", source)

        entries = MANIFEST.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(entries), 14)
        self.assertTrue(
            all(re.fullmatch(r"[0-9a-f]{64}  [^/].+", entry) for entry in entries)
        )
        self.assertEqual(
            sum(entry.endswith(".spv") for entry in entries),
            11,
        )
        self.assertTrue(any(entry.endswith("dri/bc250_drv_video.so") for entry in entries))
        self.assertTrue(any(entry.endswith("LICENSE.upstream") for entry in entries))

    def test_installer_uses_safe_verified_persistent_layout(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for required in (
            "curl --proto '=https' --tlsv1.2 --fail --location",
            '[[ "$actual" == "$ARCHIVE_SHA256" ]]',
            "unsafe archive path",
            "unsafe archive entry type",
            "duplicate archive entry",
            "sha256sum -c --quiet manifest.sha256",
            "validate_elf64",
            "runtime_dependencies_valid",
            "unavailable runtime dependencies",
            "/var/lib/bc250-control/video-codec",
            "/etc/environment.d/90-bc250-video-codec.conf",
            "Refusing to replace an unrecognized runtime",
            "Refusing to remove an unrecognized runtime",
        ):
            self.assertIn(required, source)
        self.assertNotIn("steamos-readonly disable", source)
        self.assertNotIn("radeonsi_drv_video.so", source)
        self.assertNotIn("/usr/lib", source)

    def test_toolkit_release_and_maintenance_include_component(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="utf-8"
        )
        maintenance = (ROOT / "bc250-maintenance.sh").read_text(encoding="utf-8")
        self.assertIn("nct6687d video-codec", workflow)
        self.assertIn("video-codec) echo \"VA-API video codec\"", maintenance)
        self.assertIn("sudo bash \"$script\" uninstall", maintenance)

    def test_help_is_non_privileged(self):
        result = subprocess.run(
            ["bash", str(SCRIPT), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("install", result.stdout)
        self.assertIn("status", result.stdout)
        self.assertIn("uninstall", result.stdout)


if __name__ == "__main__":
    unittest.main()
