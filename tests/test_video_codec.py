import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "video-codec/bc250-video-codec.sh"
SOURCE_ROOT = "bc250-encoding-decoding-fix-180aab87fa84b68f8d4a9d6bf8d4c1fb0cac940e"


class VideoCodecTests(unittest.TestCase):
    def run_script(self, *arguments, data_dir, env_file):
        environment = os.environ.copy()
        environment.update(
            {
                "BC250_VIDEO_DATA_DIR": str(data_dir),
                "BC250_VIDEO_ENV_FILE": str(env_file),
                "BC250_VIDEO_PROFILE_FILE": str(
                    env_file.parent.parent / "profile.d/90-bc250-video-codec.sh"
                ),
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

    def test_source_commit_and_archive_digest_are_pinned(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("RELEASE=v0.5.1", source)
        self.assertIn(
            "SOURCE_COMMIT=180aab87fa84b68f8d4a9d6bf8d4c1fb0cac940e",
            source,
        )
        self.assertIn(
            "SOURCE_ARCHIVE_SHA256=c735c3c566882b1e8594eff7e163feb0d62e2ad52d83c104c5178a34f5a2784a",
            source,
        )
        self.assertIn("codeload.github.com/simpmix/bc250-encoding-decoding-fix/tar.gz/$SOURCE_COMMIT", source)
        self.assertIn("-DBC250_WITH_X264=OFF", source)
        self.assertIn('"$output" != *"libx264"*', source)
        self.assertIn("build=local-source", source)
        self.assertIn("write_runtime_manifest", source)
        self.assertEqual(source.count(".comp.spv\n"), 11)

    def test_installer_uses_safe_verified_persistent_layout(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for required in (
            "curl --proto '=https' --tlsv1.2 --fail --location",
            '[[ "$actual" == "$SOURCE_ARCHIVE_SHA256" ]]',
            "unsafe source archive path",
            "unsafe source archive entry type",
            "duplicate source archive entry",
            "sha256sum -c --quiet manifest.sha256",
            "validate_elf64",
            "runtime_dependencies_valid",
            "unavailable runtime dependencies",
            "ldd -r",
            "verify_vaapi_initialization",
            "vainfo --display drm --device",
            "pacman -S --needed --noconfirm",
            "pacman -S --noconfirm",
            "cmake make gcc binutils glibc pkgconf libva libdrm",
            "compiler-link-probe:libva+libdrm+vulkan+openmp",
            "Still missing:",
            "steamos-readonly disable",
            "steamos-readonly enable",
            "/var/lib/bc250-control/video-codec",
            "/etc/environment.d/90-bc250-video-codec.conf",
            "/etc/profile.d/90-bc250-video-codec.sh",
            "Refusing to replace an unrecognized runtime",
            "Refusing to remove an unrecognized runtime",
        ):
            self.assertIn(required, source)
        self.assertNotIn("radeonsi_drv_video.so", source)

    def test_source_extraction_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "source.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                for relative, content in (
                    ("LICENSE", b"license\n"),
                    ("README.md", b"readme\n"),
                    ("approach1-compute-encoder/CMakeLists.txt", b"cmake\n"),
                ):
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(content)
                    bundle.add(path, arcname=f"{SOURCE_ROOT}/{relative}")
                traversal = tarfile.TarInfo(f"{SOURCE_ROOT}/../escape")
                traversal.size = 1
                import io

                bundle.addfile(traversal, io.BytesIO(b"x"))

            destination = root / "extract"
            destination.mkdir()
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'helper=$1; archive=$2; destination=$3; set -- help; '
                    'source "$helper" >/dev/null; extract_source "$archive" "$destination"',
                    "_",
                    str(SCRIPT),
                    str(archive),
                    str(destination),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsafe source archive path", result.stderr)
            self.assertFalse((root / "escape").exists())

    def test_toolkit_release_and_maintenance_include_component(self):
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="utf-8"
        )
        maintenance = (ROOT / "bc250-maintenance.sh").read_text(encoding="utf-8")
        self.assertIn("nct6687d video-codec", workflow)
        self.assertIn("video-codec) echo \"VA-API video codec\"", maintenance)
        self.assertIn("/etc/profile.d/90-bc250-video-codec.sh", maintenance)
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
