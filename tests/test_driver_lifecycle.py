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
METRICS_PATCH = ROOT / "bc250-audio-fix/bc250-cyan-skillfish-gpu-telemetry.patch"
GFXCLK_PATCH = ROOT / "bc250-audio-fix/bc250-cyan-skillfish-gfxclk.patch"
CORE_METRICS_PATCH = (
    ROOT / "bc250-audio-fix/bc250-cyan-skillfish-8core-metrics.patch"
)


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
                str(ROOT / "bc250-audio-fix/build.sh"),
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

    def test_amdgpu_build_integrates_cyan_skillfish_metrics_patches(self):
        builder = (ROOT / "bc250-audio-fix/build.sh").read_text(encoding="utf-8")
        installer = (ROOT / "bc250-audio-fix/install.sh").read_text(encoding="utf-8")
        rollback = AUDIO_ROLLBACK.read_text(encoding="utf-8")
        patch = METRICS_PATCH.read_text(encoding="utf-8")
        gfxclk_patch = GFXCLK_PATCH.read_text(encoding="utf-8")
        core_metrics_patch = CORE_METRICS_PATCH.read_text(encoding="utf-8")
        self.assertIn("bc250-cyan-skillfish-gpu-telemetry.patch", builder)
        self.assertIn("bc250-cyan-skillfish-gfxclk.patch", builder)
        self.assertIn("bc250-cyan-skillfish-8core-metrics.patch", builder)
        self.assertLess(
            builder.index(str(METRICS_PATCH.name)),
            builder.index(str(GFXCLK_PATCH.name)),
        )
        self.assertLess(
            builder.index(str(GFXCLK_PATCH.name)),
            builder.index(str(CORE_METRICS_PATCH.name)),
        )
        self.assertNotIn("LEGACY_", builder)
        self.assertIn("unknown Cyan Skillfish metrics patch found", builder)
        self.assertIn("METRICS_SOURCE_SHA", builder)
        self.assertIn("METRICS_HEADER_SHA", builder)
        self.assertIn('git --git-dir="$GITDIR" --work-tree="$TREE"', builder)
        self.assertIn("GRBM_STATUS__GUI_ACTIVE_MASK", patch)
        self.assertIn("AMDGPU_PP_SENSOR_GPU_LOAD", patch)
        self.assertIn("average_gfx_activity", patch)
        self.assertIn("PPSMC_MSG_GetGfxFrequency", gfxclk_patch)
        self.assertIn("SMU_MSG_GetGfxclkFrequency", gfxclk_patch)
        self.assertIn("cyan_skillfish_get_gfxclk_frequency", gfxclk_patch)
        self.assertIn("return -ERANGE", gfxclk_patch)
        self.assertIn("gpu_metrics->current_gfxclk = gfxclk", gfxclk_patch)
        self.assertIn("CYAN_SKILLFISH_ROBIN3_SMU_VERSION", core_metrics_patch)
        self.assertIn("0x00580600", core_metrics_patch)
        self.assertIn("0x0115a870", core_metrics_patch)
        self.assertIn("RREG32_PCIE", core_metrics_patch)
        self.assertNotIn("cpufreq_quick_get", core_metrics_patch)
        self.assertIn("CYAN_SKILLFISH_ROBIN3_TABLE_SIZE", core_metrics_patch)
        self.assertIn("0x344", core_metrics_patch)
        self.assertIn("SMU_TABLE_PMSTATUSLOG", core_metrics_patch)
        self.assertIn("CYAN_SKILLFISH_ROBIN3_CORE_POWER", core_metrics_patch)
        self.assertIn("0x118", core_metrics_patch)
        self.assertIn("CYAN_SKILLFISH_ROBIN3_CORE_TEMP", core_metrics_patch)
        self.assertIn("0x158", core_metrics_patch)
        self.assertIn("CYAN_SKILLFISH_ROBIN3_CORE_FREQ", core_metrics_patch)
        self.assertIn("0x198", core_metrics_patch)
        self.assertIn("CYAN_SKILLFISH_ROBIN3_SET_ADDR_HIGH", core_metrics_patch)
        self.assertIn("CYAN_SKILLFISH_ROBIN3_SET_ADDR_LOW", core_metrics_patch)
        self.assertIn("CYAN_SKILLFISH_ROBIN3_TRANSFER_TABLE", core_metrics_patch)
        self.assertIn("mutex_lock(&smu->message_lock)", core_metrics_patch)
        self.assertIn("amdgpu_asic_invalidate_hdp", core_metrics_patch)
        self.assertIn("get_unaligned_le32", core_metrics_patch)
        self.assertIn("PPSMC_Result_CmdRejectedBusy", core_metrics_patch)
        self.assertIn("core_ret == -ENODEV", core_metrics_patch)
        self.assertNotIn("CYAN_SKILLFISH_CORE_POWER_BASE", core_metrics_patch)
        self.assertNotIn("SmuMetricsTable8_t", core_metrics_patch)
        self.assertIn("OLD_CORE_METRICS_SOURCE_SHA", builder)
        self.assertIn("OLD_C0_SCALE_SOURCE_SHA", builder)
        self.assertIn("OLD_CPUFREQ_SOURCE_SHA", builder)
        self.assertIn("CORE_METRICS_SOURCE_SHA", builder)
        self.assertIn("d7191ecdd18a34478d7f58de79a149935e2deef73444e996cde6cf5cb596e35c", builder)
        self.assertIn("c73a50285bc70e3be3199e70c8717dd0fdf77208cff178bdd75a623ed4d08ceb", builder)
        self.assertIn("ac197ddf75abfd4aa491b016a6e4c592333a83f120d14ae1d23a95f33731472f", builder)
        self.assertIn("13c0587e7c7020567fb5028e8bf21c295445cb0aaf97180f556bbc2b5940b961", builder)
        self.assertIn(".bc250-metrics-fix", installer)
        self.assertIn(".bc250-metrics-fix", rollback)


if __name__ == "__main__":
    unittest.main()
