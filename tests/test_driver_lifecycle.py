import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AIC_INSTALLER = ROOT / "aic8800/steamdeck-setup.sh"
AUDIO_INSTALLER = ROOT / "bc250-audio-fix/patch-driver.sh"
AUDIO_ROLLBACK = ROOT / "bc250-audio-fix/rollback.sh"
AUDIO_PREREQS = ROOT / "bc250-audio-fix/ensure-build-prereqs.sh"


class DriverLifecycleTests(unittest.TestCase):
    def test_status_entrypoints_are_read_only_and_do_not_require_sudo(self):
        for script, prefix in (
            (AIC_INSTALLER, "[aic8800]"),
            (AUDIO_INSTALLER, "[bc250-audio]"),
        ):
            result = subprocess.run(
                ["bash", str(script), "status"],
                capture_output=True,
                text=True,
            )
            self.assertIn(prefix, result.stdout)
            self.assertIn("state:", result.stdout)
            self.assertIn(result.returncode, (0, 1))

    def test_audio_uninstall_routes_noninteractive_slot_rollbacks(self):
        with tempfile.TemporaryDirectory() as directory:
            bindir = Path(directory)
            call_log = bindir / "sudo-call"
            (bindir / "id").write_text(
                "#!/bin/sh\n[ \"$1\" = -u ] && { echo 1000; exit 0; }\n"
                "exec /usr/bin/id \"$@\"\n",
                encoding="utf-8",
            )
            (bindir / "sudo").write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$SUDO_CALL_LOG\"\n",
                encoding="utf-8",
            )
            (bindir / "flock").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            os.chmod(bindir / "id", 0o755)
            os.chmod(bindir / "sudo", 0o755)
            os.chmod(bindir / "flock", 0o755)
            env = os.environ.copy()
            env["PATH"] = f"{bindir}:{env['PATH']}"
            env["SUDO_CALL_LOG"] = str(call_log)

            result = subprocess.run(
                ["bash", str(AUDIO_INSTALLER), "uninstall"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(
                call_log.read_text(encoding="utf-8").splitlines(),
                [
                    str(AUDIO_ROLLBACK),
                    "--all",
                    str(ROOT / "bc250-audio-fix/cleanup-other-slot.sh"),
                    "--skip-current",
                ],
            )
            self.assertIn("build output were preserved", result.stdout)

    def test_aic_uninstall_disables_repair_before_removing_artifacts(self):
        script = AIC_INSTALLER.read_text(encoding="utf-8")
        disable = script.index(
            "systemctl disable --now aic8800-modules.service"
        )
        remove_modules = script.index(
            "for path in /usr/lib/modules/*/updates/aic8800/aic_load_fw.ko"
        )
        self.assertLess(disable, remove_modules)
        self.assertIn(
            'rm -rf "$AIC_DATA_DIR/firmware" "$AIC_DATA_DIR/modules"',
            script,
        )
        self.assertNotIn('rm -rf "$ROOT_SOURCE"', script)
        self.assertIn("persistent source preserved", script)

    def test_lifecycle_scripts_parse(self):
        subprocess.run(
            [
                "bash",
                "-n",
                str(AIC_INSTALLER),
                str(AUDIO_INSTALLER),
                str(ROOT / "bc250-audio-fix/install.sh"),
                str(AUDIO_ROLLBACK),
                str(AUDIO_PREREQS),
            ],
            check=True,
        )

    def test_audio_build_restores_and_validates_prerequisites(self):
        installer = AUDIO_INSTALLER.read_text(encoding="utf-8")
        builder = (ROOT / "bc250-audio-fix/build.sh").read_text(encoding="utf-8")
        fetcher = (ROOT / "bc250-audio-fix/fetch-sources.sh").read_text(
            encoding="utf-8"
        )
        preparer = (ROOT / "bc250-audio-fix/prepare-kernel.sh").read_text(
            encoding="utf-8"
        )
        environment = (ROOT / "bc250-audio-fix/build-env.sh").read_text(
            encoding="utf-8"
        )
        prerequisites = AUDIO_PREREQS.read_text(encoding="utf-8")

        for entrypoint in (installer, builder, fetcher, preparer):
            self.assertIn('"$HERE/ensure-build-prereqs.sh"', entrypoint)
        self.assertIn("base-devel", prerequisites)
        for tool in ("make", "gcc", "ld", "patch", "pahole", "bc", "zstd"):
            self.assertIn(tool, environment)


if __name__ == "__main__":
    unittest.main()
