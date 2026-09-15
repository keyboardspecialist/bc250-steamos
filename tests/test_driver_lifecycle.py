import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AIC_INSTALLER = ROOT / "aic8800/steamdeck-setup.sh"
AIC_HELPER = ROOT / "aic8800/aic8800-ensure-modules.sh"
AIC_SERVICE = ROOT / "aic8800/aic8800-modules.service"
AIC_DRIVER = ROOT / "aic8800/src/USB/driver_fw/drivers/aic8800"
FAN_INSTALLER = ROOT / "nct6687d/steamdeck-setup.sh"
FAN_FETCHER = ROOT / "nct6687d/fetch-source.sh"
FAN_HELPER = ROOT / "nct6687d/nct6687-ensure-module.sh"
FAN_SERVICE = ROOT / "nct6687d/nct6687-modules.service"
AUDIO_INSTALLER = ROOT / "bc250-audio-fix/patch-driver.sh"
AUDIO_ROLLBACK = ROOT / "bc250-audio-fix/rollback.sh"
AUDIO_BOOT_CONFIG = ROOT / "bc250-audio-fix/boot-config.sh"
AUDIO_CLEAN = ROOT / "bc250-audio-fix/clean.sh"
AUDIO_PREREQS = ROOT / "bc250-audio-fix/ensure-build-prereqs.sh"
AUDIO_MKINITCPIO = ROOT / "bc250-audio-fix/mkinitcpio-compat.sh"
HDMI_AC3 = ROOT / "hdmi-ac3/hdmi-ac3.sh"
SCLK_PATCH = ROOT / "bc250-audio-fix/bc250-cyan-skillfish-sclk-range.patch"
TTM_PATCH = ROOT / "bc250-audio-fix/bc250-amdgpu-ttm-null-page-guard.patch"
KFD_RUNLIST_616_PATCH = (
    ROOT / "bc250-audio-fix/bc250-kfd-flush-by-runlist-6.16.patch"
)
KFD_RUNLIST_618_PATCH = (
    ROOT / "bc250-audio-fix/bc250-kfd-flush-by-runlist-6.18.patch"
)
DP_AUDIO_PATCH = ROOT / "bc250-audio-fix/0002-bc250-audio.patch"
DP_CLOCK_616_PATCH = ROOT / "bc250-audio-fix/bc250-dp-audio-clock-6.16.patch"
GFX1013_ATTESTATION_PATCH = (
    ROOT / "bc250-audio-fix/bc250-gfx1013-attestation.patch"
)
DCN201_PCON_PATCH = ROOT / "bc250-audio-fix/bc250-dcn201-pcon-hdmi21.patch"
DCN201_DSC_PATCH = ROOT / "bc250-audio-fix/bc250-dcn201-dsc-enable.patch"


class DriverLifecycleTests(unittest.TestCase):
    def audio_status_environment(self, root):
        bindir = root / "bin"
        bindir.mkdir()
        module_dir = root / "modules"
        module = module_dir / "amdgpu.ko.zst"
        boot_config = root / "boot-config.sh"
        (bindir / "modinfo").write_text(
            '#!/bin/sh\nprintf "%s\\n" "${BC250_TEST_MODINFO_PATH:-$BC250_GFX1013_MODULE}"\n',
            encoding="utf-8",
        )
        (bindir / "modinfo").chmod(0o755)
        boot_config.write_text(
            '#!/bin/sh\n[ "$1" = present ] && [ "${BC250_TEST_BOOT_PRESENT:-0}" = 1 ]\n',
            encoding="utf-8",
        )
        boot_config.chmod(0o755)
        return {
            **os.environ,
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "BC250_GFX1013_MODULE": str(module),
            "BC250_AUDIO_MARKER": str(module_dir / ".bc250-audio-fix"),
            "BC250_METRICS_MARKER": str(module_dir / ".bc250-metrics-fix"),
            "BC250_GFX1013_MARKER": str(module_dir / ".bc250-gfx1013-fix"),
            "BC250_GFX1013_ACTIVE": str(root / "sys" / "bc250_gfx1013_fix"),
            "BC250_AMDGPU_REVISION_ACTIVE": str(
                root / "sys" / "bc250_amdgpu_revision"
            ),
            "BC250_AMDGPU_BOOT_CONFIG": str(boot_config),
        }

    def install_audio_status_fixture(self, env):
        module = Path(env["BC250_GFX1013_MODULE"])
        module.parent.mkdir(parents=True, exist_ok=True)
        module.write_bytes(b"patched amdgpu\n")
        digest = hashlib.sha256(module.read_bytes()).hexdigest() + "\n"
        for key in (
            "BC250_AUDIO_MARKER",
            "BC250_METRICS_MARKER",
            "BC250_GFX1013_MARKER",
        ):
            Path(env[key]).write_text(digest, encoding="ascii")

    def audio_status_json(self, env):
        result = subprocess.run(
            ["bash", str(AUDIO_INSTALLER), "status-json"],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(len(result.stdout.splitlines()), 1)
        return json.loads(result.stdout)

    def test_audio_status_json_reports_current_kernel_lifecycle(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.audio_status_environment(Path(directory))
            status = self.audio_status_json(env)
            self.assertEqual(
                status,
                {
                    "scriptAvailable": True,
                    "runningKernel": os.uname().release,
                    "state": "not-installed",
                    "overrideInstalled": False,
                    "overrideSelected": False,
                    "activeReady": False,
                    "rebootRequired": False,
                },
            )

            self.install_audio_status_fixture(env)
            status = self.audio_status_json(env)
            self.assertEqual(status["state"], "reboot-required")
            self.assertTrue(status["overrideInstalled"])
            self.assertTrue(status["overrideSelected"])
            self.assertFalse(status["activeReady"])
            self.assertTrue(status["rebootRequired"])

            active = Path(env["BC250_GFX1013_ACTIVE"])
            active.parent.mkdir(parents=True)
            active.write_text("wrong-commit\n", encoding="ascii")
            status = self.audio_status_json(env)
            self.assertEqual(status["state"], "reboot-required")
            self.assertFalse(status["activeReady"])

            active.write_text(
                "d3e6dc062c34d2523db0abe5741d1f5b0dea00d9\n",
                encoding="ascii",
            )
            status = self.audio_status_json(env)
            self.assertEqual(status["state"], "reboot-required")
            self.assertFalse(status["activeReady"])

            revision_active = Path(env["BC250_AMDGPU_REVISION_ACTIVE"])
            revision_active.write_text(
                "mastag-8core-622ed9e-r1\n", encoding="ascii"
            )
            status = self.audio_status_json(env)
            self.assertEqual(status["state"], "ready")
            self.assertTrue(status["activeReady"])
            self.assertFalse(status["rebootRequired"])

    def test_audio_status_json_rejects_partial_or_unselected_override(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.audio_status_environment(Path(directory))
            self.install_audio_status_fixture(env)
            Path(env["BC250_METRICS_MARKER"]).write_text("0" * 64 + "\n")
            status = self.audio_status_json(env)
            self.assertEqual(status["state"], "invalid")
            self.assertFalse(status["overrideInstalled"])
            self.assertTrue(status["overrideSelected"])

            metrics_marker = Path(env["BC250_METRICS_MARKER"])
            metrics_marker.unlink()
            metrics_marker.symlink_to(Path(env["BC250_AUDIO_MARKER"]))
            status = self.audio_status_json(env)
            self.assertEqual(status["state"], "invalid")
            self.assertFalse(status["overrideInstalled"])

            metrics_marker.unlink()
            self.install_audio_status_fixture(env)
            env["BC250_TEST_MODINFO_PATH"] = str(Path(directory) / "stock-amdgpu.ko.zst")
            status = self.audio_status_json(env)
            self.assertEqual(status["state"], "invalid")
            self.assertTrue(status["overrideInstalled"])
            self.assertFalse(status["overrideSelected"])

    def test_audio_status_json_rejects_boot_only_state_and_help_lists_command(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.audio_status_environment(Path(directory))
            env["BC250_TEST_BOOT_PRESENT"] = "1"
            self.assertEqual(self.audio_status_json(env)["state"], "invalid")

        help_result = subprocess.run(
            ["bash", str(AUDIO_INSTALLER), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("status-json", help_result.stdout)

    def test_status_entrypoints_are_read_only_and_do_not_require_sudo(self):
        for script, prefix in (
            (AIC_INSTALLER, "[aic8800]"),
            (FAN_INSTALLER, "[nct6687]"),
            (AUDIO_INSTALLER, "[bc250-amdgpu]"),
        ):
            result = subprocess.run(
                ["bash", str(script), "status"],
                capture_output=True,
                text=True,
            )
            self.assertIn(prefix, result.stdout)
            self.assertIn("state:", result.stdout)
            self.assertIn(result.returncode, (0, 1))

    def test_missing_amdgpu_scheduler_policy_prints_install_command(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = os.environ.copy()
            env.update(
                {
                    "SCHED_CONFIG": str(root / "bc250-amdgpu.cfg"),
                    "GRUB_DEFAULT": str(root / "grub"),
                    "GRUB_CFG": str(root / "grub.cfg"),
                    "PROC_CMDLINE": str(root / "cmdline"),
                    "AMDGPU_KEEP_FILE": str(root / "bc250-amdgpu.conf"),
                }
            )

            result = subprocess.run(
                ["bash", str(AUDIO_BOOT_CONFIG), "status"],
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("scheduler policy: not configured", result.stdout)
            self.assertIn(
                f"install with: sudo bash {AUDIO_BOOT_CONFIG} install",
                result.stdout,
            )

    def test_active_scheduler_policy_handles_root_only_generated_grub(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "bc250-amdgpu.cfg"
            keep = root / "bc250-amdgpu.conf"
            cmdline = root / "cmdline"
            policy = root / "sched_policy"
            protected = root / "efi"
            config.write_text(
                "# BC-250 AMDGPU scheduler policy managed by "
                "bc250-audio-fix/boot-config.sh.\n"
                "# Required by the GFX1013 async-compute queue repair.\n"
                'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:-} '
                'amdgpu.sched_policy=2"\n',
                encoding="utf-8",
            )
            keep.write_text(
                "# Toolkit state preserved by SteamOS atomic updates.\n"
                "# Generated by bc250-update-persistence.sh.\n"
                f"{config}\n"
                "/etc/systemd/system/bc250-persistence-recovery.service\n"
                "/etc/systemd/system/local-fs.target.wants/"
                "bc250-persistence-recovery.service\n"
                "/etc/systemd/system/var-lib-bc250\\x2dcontrol.mount\n"
                "/etc/systemd/system/local-fs.target.wants/"
                "var-lib-bc250\\x2dcontrol.mount\n",
                encoding="utf-8",
            )
            cmdline.write_text("quiet amdgpu.sched_policy=2\n", encoding="utf-8")
            policy.write_text("2\n", encoding="utf-8")
            protected.mkdir(mode=0o000)
            bindir = root / "bin"
            bindir.mkdir()
            stat = bindir / "stat"
            stat.write_text(
                '#!/bin/sh\n[ "$2" = %u ] && { echo 0; exit; }; echo 644\n',
                encoding="utf-8",
            )
            stat.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "SCHED_CONFIG": str(config),
                    "GRUB_DEFAULT": str(root / "default-grub"),
                    "GRUB_CFG": str(protected / "grub.cfg"),
                    "PROC_CMDLINE": str(cmdline),
                    "SCHED_POLICY_PARAM": str(policy),
                    "AMDGPU_KEEP_FILE": str(keep),
                    "PATH": f"{bindir}:{env['PATH']}",
                }
            )
            try:
                result = subprocess.run(
                    ["bash", str(AUDIO_BOOT_CONFIG), "status"],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=env,
                )
            finally:
                protected.chmod(0o700)

            self.assertIn("configured and active", result.stdout)

            policy.write_text("0\n", encoding="utf-8")
            pending = subprocess.run(
                ["bash", str(AUDIO_BOOT_CONFIG), "status"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertIn("configured; reboot needed", pending.stdout)

    def test_kfd_runlist_status_requires_exclusive_generated_grub_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "bc250-amdgpu.cfg"
            grub = root / "grub.cfg"
            keep = root / "bc250-amdgpu.conf"
            runlist = root / "bc250_flush_by_runlist"
            config.write_text(
                "# BC-250 KFD HWS runlist TLB-flush workaround managed by "
                "bc250-audio-fix/boot-config.sh.\n"
                "# Opt-in workaround for stale compute translations; incompatible "
                "with amdgpu.sched_policy=2.\n"
                'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:-} '
                'amdgpu.bc250_flush_by_runlist=1"\n',
                encoding="utf-8",
            )
            grub.write_text(
                "steamenv_boot linux /boot/vmlinuz quiet "
                "amdgpu.bc250_flush_by_runlist=1\n",
                encoding="utf-8",
            )
            keep.write_text(
                "# Toolkit state preserved by SteamOS atomic updates.\n"
                "# Generated by bc250-update-persistence.sh.\n"
                f"{config}\n"
                "/etc/systemd/system/bc250-persistence-recovery.service\n"
                "/etc/systemd/system/local-fs.target.wants/"
                "bc250-persistence-recovery.service\n"
                "/etc/systemd/system/var-lib-bc250\\x2dcontrol.mount\n"
                "/etc/systemd/system/local-fs.target.wants/"
                "var-lib-bc250\\x2dcontrol.mount\n",
                encoding="utf-8",
            )
            runlist.write_text("Y\n", encoding="utf-8")
            bindir = root / "bin"
            bindir.mkdir()
            stat = bindir / "stat"
            stat.write_text(
                '#!/bin/sh\n[ "$2" = %u ] && { echo 0; exit; }; echo 644\n',
                encoding="utf-8",
            )
            stat.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "SCHED_CONFIG": str(config),
                    "GRUB_DEFAULT": str(root / "default-grub"),
                    "GRUB_CFG": str(grub),
                    "PROC_CMDLINE": str(root / "cmdline"),
                    "RUNLIST_PARAM": str(runlist),
                    "AMDGPU_KEEP_FILE": str(keep),
                    "PATH": f"{bindir}:{env['PATH']}",
                }
            )

            status = subprocess.run(
                ["bash", str(AUDIO_BOOT_CONFIG), "status"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertIn("hardware scheduling retained", status.stdout)
            self.assertIn("configured and active", status.stdout)
            self.assertEqual(
                subprocess.run(
                    ["bash", str(AUDIO_BOOT_CONFIG), "runlist-configured"],
                    env=env,
                ).returncode,
                0,
            )
            self.assertNotEqual(
                subprocess.run(
                    ["bash", str(AUDIO_BOOT_CONFIG), "configured"], env=env
                ).returncode,
                0,
            )

            grub.write_text(
                "steamenv_boot linux /boot/vmlinuz quiet "
                "amdgpu.bc250_flush_by_runlist=1 amdgpu.sched_policy=2\n",
                encoding="utf-8",
            )
            invalid = subprocess.run(
                ["bash", str(AUDIO_BOOT_CONFIG), "status"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("incomplete", invalid.stdout)

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
                    "env",
                    "BC250_PRESERVE_AMDGPU_BOOT_CONFIG=1",
                    str(AUDIO_ROLLBACK),
                    "--all",
                    str(ROOT / "bc250-audio-fix/cleanup-other-slot.sh"),
                    "--skip-current",
                    "env",
                    "BC250_FORCE_GRUB_REGEN=1",
                    str(AUDIO_BOOT_CONFIG),
                    "remove",
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
        self.assertIn("aic_zlp_quirk aic8800_fdrv aic_load_fw", script)
        self.assertIn("aic_zlp_quirk.ko", script)

    def test_aic_new_driver_ids_and_switch_paths_are_integrated(self):
        installer = AIC_INSTALLER.read_text(encoding="utf-8")
        usb_header = (AIC_DRIVER / "aic8800_fdrv/aicwf_usb.h").read_text(
            encoding="utf-8"
        )
        usb_source = (AIC_DRIVER / "aic8800_fdrv/aicwf_usb.c").read_text(
            encoding="utf-8"
        )

        self.assertIn("USB_PRODUCT_ID_AIC8800D80_UGREEN  0x8D88", usb_header)
        self.assertIn("USB_PRODUCT_ID_AIC8800D80_UGREEN", usb_source)
        self.assertIn('ATTRS{idProduct}=="5724"', installer)
        self.assertIn('eject "$msc_block"', installer)
        self.assertIn(
            "base-devel git util-linux usb_modeswitch",
            installer,
        )
        self.assertNotIn("base-devel git eject usb_modeswitch", installer)
        self.assertIn("MODESWITCH_MESSAGE2", installer)
        self.assertIn('modprobe aic_load_fw', installer)
        first_switch = installer.index('if msc_block=$(find_aic_msc_block_device)')
        self.assertLess(installer.index('modprobe aic_load_fw'), first_switch)
        self.assertLess(installer.index('modprobe aic8800_fdrv'), first_switch)
        self.assertTrue((AIC_DRIVER / "aic_zlp_quirk/aic_zlp_quirk.c").is_file())

    def test_aic_boot_defers_firmware_probe_until_persistent_storage(self):
        installer = AIC_INSTALLER.read_text(encoding="utf-8")
        helper = AIC_HELPER.read_text(encoding="utf-8")
        service = AIC_SERVICE.read_text(encoding="utf-8")

        self.assertIn("blacklist aic_load_fw", installer)
        self.assertIn("RequiresMountsFor=/var/lib/bc250-control", service)
        self.assertIn("After=bc250-persistence-recovery.service", service)
        self.assertNotIn("network-online.target", service)
        self.assertIn("module_supports_usb_device aic_load_fw", helper)
        self.assertIn("module_supports_usb_device aic8800_fdrv", helper)
        self.assertNotIn("usb_device_has_id a69c 8d80", helper)
        self.assertIn("/sys/bus/usb/drivers_probe", helper)
        self.assertIn("wait_for_aic_runtime", helper)
        self.assertIn("did not transition to a runtime device bound to aic8800_fdrv", helper)
        self.assertIn("BUILD_ZLP_KO", helper)
        self.assertIn("zlp_target_present", helper)

    def test_nct6687_source_and_build_are_pinned_and_verified(self):
        fetcher = FAN_FETCHER.read_text(encoding="utf-8")
        installer = FAN_INSTALLER.read_text(encoding="utf-8")
        helper = FAN_HELPER.read_text(encoding="utf-8")

        for source_hash in (
            "ab83ace080e46646a9c807e31177a460902b11661bbbde31ed883261eccf3b45",
            "9bd825e95b6804328efbd6a4b587babdcc7acd289407dac3f353109d16f42def",
            "895b5df0011ffa11bdf8bcfef2f002992aa4949d2703cd4281cecdb44917820a",
            "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643",
        ):
            self.assertIn(source_hash, fetcher)
        self.assertIn("a49a8abdfb6221772ecc836b3109e0cc338203cf", fetcher)
        self.assertIn('modinfo -F vermagic "$1"', installer)
        self.assertIn('modinfo -F license "$BUILT_KO"', installer)
        self.assertIn('[[ "$selected" -ef "$module" ]]', installer)
        self.assertIn('[[ "$selected" -ef "$INSTALLED_KO" ]]', helper)
        self.assertIn('M="$SOURCE_CACHE"', installer)
        self.assertNotIn('make -C "$SOURCE_CACHE" install', installer)
        self.assertIn("sha256sum -c --quiet source.sha256", helper)

    def test_nct6687_lifecycle_is_boot_recoverable_and_force_is_opt_in(self):
        installer = FAN_INSTALLER.read_text(encoding="utf-8")
        helper = FAN_HELPER.read_text(encoding="utf-8")
        service = FAN_SERVICE.read_text(encoding="utf-8")

        self.assertIn("--force-unknown", installer)
        self.assertIn("FORCE_UNKNOWN=0", installer)
        self.assertIn('options nct6687 force=%s', installer)
        self.assertIn("Refusing to remove an unrecognized module", installer)
        self.assertIn("Installed module integrity check failed", installer)
        self.assertIn("Could not unload nct6687", installer)
        self.assertIn("restore_automatic_fan_control", installer)
        self.assertIn("Firmware automatic mode was not confirmed", installer)
        self.assertIn("pwmN_enable=2", installer)
        self.assertIn("installed_module_valid", helper)
        self.assertIn('insmod "$STAGED_KO" "$MODULE_OPTIONS"', helper)
        self.assertNotIn("pacman", helper)
        self.assertNotIn("make -C", helper)
        self.assertNotIn("network-online.target", service)
        self.assertIn("blacklist nct6683", installer)
        self.assertIn("pacman-key --verify", installer)
        self.assertIn("Pinned source changed during the build", installer)
        self.assertIn("regenerate it from the package whose signature just passed", installer)
        self.assertIn(
            'IFS= read -r prepared_release < "$KDIR/include/config/kernel.release"',
            installer,
        )
        self.assertNotIn('$(<"$KDIR/include/config/kernel.release" 2>/dev/null', installer)
        self.assertIn("NEW_STAGE_PROBED", installer)
        self.assertIn("PREVIOUS_NCT6687_KO", installer)
        self.assertIn("/sys/module/nct6687", installer)
        probe_cleanup = installer[
            installer.index('if ! insmod "$STAGED_KO"') :
            installer.index("NEW_STAGE_PROBED=1")
        ]
        self.assertIn("rmmod nct6687", probe_cleanup)
        self.assertNotIn("modprobe -r nct6687", probe_cleanup)
        self.assertIn("rmmod nct6687", helper)
        self.assertIn("NCT6683/6686/6687 hwmon", helper)
        self.assertIn("Requires=bc250-persistence-recovery.service", service)
        self.assertIn("RequiresMountsFor=/var/lib/bc250-control", service)
        self.assertLess(
            installer.index('insmod "$STAGED_KO"'),
            installer.index('mv "$stage_dir_tmp" "$STAGE_DIR"'),
        )
        self.assertLess(
            installer.index("Installed module integrity check failed"),
            installer.index("systemctl disable --now nct6687-modules.service"),
        )
        self.assertLess(
            helper.index("staged_module_valid"),
            helper.index("modprobe -r nct6683"),
        )

    def test_nct6687_status_accepts_root_only_persistent_source(self):
        source = FAN_INSTALLER.read_text(encoding="utf-8")
        functions = source[: source.index("usage() {")]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            persistent_source = root / "source"
            persistent_source.mkdir(mode=0o000)
            bindir = root / "bin"
            bindir.mkdir()
            stat = bindir / "stat"
            stat.write_text("#!/bin/sh\nprintf '0 700\\n'\n", encoding="utf-8")
            stat.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{bindir}:{env['PATH']}"

            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    functions
                    + '\nROOT_SOURCE=$1\npersistent_source_present',
                    "_",
                    str(persistent_source),
                ],
                env=env,
            )

            self.assertEqual(result.returncode, 0)
            stat.write_text("#!/bin/sh\nprintf '0 777\\n'\n", encoding="utf-8")
            invalid = subprocess.run(
                [
                    "bash",
                    "-c",
                    functions
                    + '\nROOT_SOURCE=$1\npersistent_source_present',
                    "_",
                    str(persistent_source),
                ],
                env=env,
            )
            self.assertNotEqual(invalid.returncode, 0)
        status = source[
            source.index("show_status() {") : source.index("usage() {")
        ]
        self.assertIn("persistent_source_present", status)
        self.assertNotIn('$ROOT_SOURCE/Kbuild', status)

    def test_lifecycle_scripts_parse(self):
        subprocess.run(
            [
                "bash",
                "-n",
                str(AIC_INSTALLER),
                str(FAN_INSTALLER),
                str(FAN_FETCHER),
                str(FAN_HELPER),
                str(AUDIO_INSTALLER),
                str(ROOT / "bc250-audio-fix/install.sh"),
                str(AUDIO_BOOT_CONFIG),
                str(ROOT / "bc250-audio-fix/build.sh"),
                str(AUDIO_CLEAN),
                str(AUDIO_ROLLBACK),
                str(AUDIO_PREREQS),
                str(AUDIO_MKINITCPIO),
                str(HDMI_AC3),
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
        self.assertIn("/usr/include/bfd.h", prerequisites)
        self.assertIn("/usr/include/dis-asm.h", prerequisites)
        for tool in ("make", "gcc", "ld", "patch", "pahole", "bc", "zstd"):
            self.assertIn(tool, environment)

    def test_diverged_audio_tree_offers_clean_and_retry(self):
        installer = AUDIO_INSTALLER.read_text(encoding="utf-8")
        builder = (ROOT / "bc250-audio-fix/build.sh").read_text(encoding="utf-8")

        self.assertIn("die_tree_drift", builder)
        self.assertIn("exit 75", builder)
        self.assertIn("Clean the build tree and retry?", installer)
        self.assertIn('"$HERE/clean.sh" "$@"', installer)
        self.assertIn('"$HERE/fetch-sources.sh" "$@"', installer)
        self.assertLess(
            installer.index('"$HERE/clean.sh" "$@"'),
            installer.rindex('"$HERE/fetch-sources.sh" "$@"'),
        )
        self.assertGreaterEqual(builder.count("die_tree_drift \""), 6)

    def test_dp_audio_uses_stable_tagged_upstream_quirk(self):
        builder = (ROOT / "bc250-audio-fix/build.sh").read_text(encoding="utf-8")
        readme = (ROOT / "bc250-audio-fix/README.md").read_text(encoding="utf-8")
        audio_patch = DP_AUDIO_PATCH.read_text(encoding="utf-8")
        clock_patch = DP_CLOCK_616_PATCH.read_text(encoding="utf-8")

        self.assertIn("ff209cd04845", readme)
        self.assertIn("AMD_APU_IS_CYAN_SKILLFISH2", audio_patch)
        self.assertIn("init_data.flags.ignore_dpref_ss = true", audio_patch)
        self.assertNotIn("dprefclk_ss_percentage", audio_patch)
        self.assertNotIn("ss_on_dprefclk", audio_patch)
        self.assertNotIn("dprefclk_ss_percentage", clock_patch)
        self.assertNotIn("ss_on_dprefclk", clock_patch)
        self.assertIn("AUDIO_PATCH=$HERE/0002-bc250-audio.patch", builder)
        self.assertNotIn("bc250-dp-audio-clock-6.18.patch", builder)
        self.assertIn("superseded blanket DPREF", builder)
        kernel_72 = builder[builder.index("    7.2.*)") :]
        kernel_72 = kernel_72[: kernel_72.index("        ;;")]
        self.assertIn("CLOCK_PATCH=", kernel_72)
        self.assertIn("AUDIO_PATCH=", kernel_72)
        self.assertNotIn("0002-bc250-audio.patch", kernel_72)
        self.assertNotIn("bc250-dp-audio-clock", kernel_72)

    def test_dcn201_dsc_and_pcon_require_explicit_risk_acknowledgement(self):
        driver = AUDIO_INSTALLER.read_text(encoding="utf-8")
        builder = (ROOT / "bc250-audio-fix/build.sh").read_text(encoding="utf-8")
        installer = (ROOT / "bc250-audio-fix/install.sh").read_text(encoding="utf-8")
        toolkit = (ROOT / "bc250-toolkit.sh").read_text(encoding="utf-8")

        acknowledgement = "--acknowledge-dcn201-display-risk"
        self.assertTrue(DCN201_PCON_PATCH.is_file())
        self.assertTrue(DCN201_DSC_PATCH.is_file())
        self.assertIn(acknowledgement, driver)
        self.assertIn(acknowledgement, builder)
        self.assertIn(acknowledgement, installer)
        self.assertIn(acknowledgement, toolkit)
        self.assertIn("DISPLAY_COMPOSITION=stable", builder)
        self.assertIn("DISPLAY_COMPOSITION=dcn201-display-unstable", builder)
        self.assertIn("ATTESTED_COMPOSITION", installer)
        self.assertIn("may cause display instability", toolkit)
        self.assertIn("Building without the experimental DSC/PCON patches.", toolkit)
        self.assertIn('bash "$AUDIO_FIX_SH"\n', toolkit)

    def test_amdgpu_build_integrates_cyan_skillfish_metrics_patches(self):
        builder = (ROOT / "bc250-audio-fix/build.sh").read_text(encoding="utf-8")
        installer = (ROOT / "bc250-audio-fix/install.sh").read_text(encoding="utf-8")
        rollback = AUDIO_ROLLBACK.read_text(encoding="utf-8")
        sclk_patch = SCLK_PATCH.read_text(encoding="utf-8")
        ttm_patch = TTM_PATCH.read_text(encoding="utf-8")
        gfx1013_attestation_patch = GFX1013_ATTESTATION_PATCH.read_text(
            encoding="utf-8"
        )
        self.assertIn("0001-bc250-8core-telemetry-gpu-activity.patch", builder)
        self.assertIn("622ed9e56107f8d13a19848ed06b7a7241ff6cd3", builder)
        self.assertIn(
            "c6b930593e35e4d774f7da65fc8d0312d80f7c5c646aab7bee711b0447206f8b",
            builder,
        )
        self.assertIn("bc250-cyan-skillfish-sclk-range.patch", builder)
        self.assertIn("bc250-amdgpu-ttm-null-page-guard.patch", builder)
        self.assertNotIn("bc250-cyan-skillfish-gpu-telemetry", builder)
        self.assertNotIn("bc250-cyan-skillfish-gfxclk", builder)
        self.assertIn("amdgpu_fence_count_emitted", builder)
        self.assertIn("SmuMetrics_8core_t", builder)
        self.assertIn("cs_legacy_8core_metrics", builder)
        self.assertIn("PPSMC_MSG_GetGfxFrequency", builder)
        self.assertIn("CYAN_SKILLFISH_SCLK_MIN\t\t\t350", sclk_patch)
        self.assertIn("CYAN_SKILLFISH_SCLK_MAX\t\t\t2230", sclk_patch)
        self.assertIn("if (ttm->pages[i])", ttm_patch)
        for name in (
            "0001-gfx1013-mmio-pasid-route.patch",
            "0002-gfx1013-compute-gfxoff-guard.patch",
            "0003-gfx1013-scoped-pasid-type0.patch",
        ):
            self.assertIn(name, builder)
        self.assertIn("d3e6dc062c34d2523db0abe5741d1f5b0dea00d9", builder)
        self.assertIn("DryhoppedIPA/bc250-gfx1013-fix", builder)
        self.assertIn("bc250-gfx1013-attestation.patch", builder)
        self.assertIn("bc250_gfx1013_fix", gfx1013_attestation_patch)
        self.assertIn("bc250_amdgpu_revision", gfx1013_attestation_patch)
        self.assertIn("mastag-8core-622ed9e-r1", builder)
        self.assertIn("mastag-8core-622ed9e-r1", installer)
        self.assertIn(
            "BC250_AMDGPU_REVISION_ACTIVE",
            AUDIO_INSTALLER.read_text(encoding="utf-8"),
        )
        self.assertIn(".bc250-metrics-fix", installer)
        self.assertIn(".bc250-metrics-fix", rollback)
        self.assertIn(".bc250-gfx1013-fix", installer)
        self.assertIn(".bc250-gfx1013-fix", rollback)
        self.assertIn("amdgpu.gfx1013.attestation", builder)
        self.assertIn("amdgpu.gfx1013.attestation", installer)

    def test_tracked_amdgpu_patches_are_well_formed(self):
        tracked = subprocess.run(
            ["git", "ls-files", "bc250-audio-fix/*.patch"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()

        tracked = [patch for patch in tracked if (ROOT / patch).is_file()]
        self.assertTrue(tracked)
        for patch in tracked:
            with self.subTest(patch=patch):
                result = subprocess.run(
                    ["git", "apply", "--numstat", patch],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_amdgpu_build_integrates_guarded_kfd_runlist_workaround(self):
        builder = (ROOT / "bc250-audio-fix/build.sh").read_text(encoding="utf-8")
        checker = (ROOT / "bc250-audio-fix/check-module.sh").read_text(
            encoding="utf-8"
        )
        patch_616 = KFD_RUNLIST_616_PATCH.read_text(encoding="utf-8")
        patch_618 = KFD_RUNLIST_618_PATCH.read_text(encoding="utf-8")

        self.assertIn(KFD_RUNLIST_616_PATCH.name, builder)
        self.assertIn(KFD_RUNLIST_618_PATCH.name, builder)
        self.assertIn("patch -p1 --fuzz=0", builder)
        self.assertIn("^bc250_flush_by_runlist:", checker)
        self.assertIn(
            "kfd_flush_tlb(peer_pdd, TLB_FLUSH_HEAVYWEIGHT);", patch_616
        )
        self.assertIn("kfd_flush_tlb(peer_pdd);", patch_618)
        self.assertNotIn("TLB_FLUSH_HEAVYWEIGHT", patch_618)
        for patch in (patch_616, patch_618):
            self.assertIn("module_param(bc250_flush_by_runlist, bool, 0644)", patch)
            self.assertIn("BC250_PCI_DEVICE_ID 0x13FE", patch)
            self.assertIn("IP_VERSION(10, 1, 3)", patch)
            self.assertIn("KFD_SCHED_POLICY_HWS", patch)
            self.assertIn("KFD_SCHED_POLICY_HWS_NO_OVERSUBSCRIPTION", patch)
            self.assertIn("shared_resources.enable_mes", patch)
            self.assertIn("dqm->active_runlist", patch)

    def test_async_compute_scheduler_policy_status_is_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "bc250-amdgpu.cfg"
            grub = root / "grub.cfg"
            keep = root / "bc250-amdgpu.conf"
            cmdline = root / "cmdline"
            config.write_text(
                "# BC-250 AMDGPU scheduler policy managed by "
                "bc250-audio-fix/boot-config.sh.\n"
                "# Required by the GFX1013 async-compute queue repair.\n"
                'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:-} '
                'amdgpu.sched_policy=2"\n',
                encoding="utf-8",
            )
            grub.write_text(
                "steamenv_boot linux /boot/vmlinuz quiet amdgpu.sched_policy=2\n",
                encoding="utf-8",
            )
            keep.write_text(
                "# Toolkit state preserved by SteamOS atomic updates.\n"
                "# Generated by bc250-update-persistence.sh.\n"
                f"{config}\n"
                "/etc/systemd/system/bc250-persistence-recovery.service\n"
                "/etc/systemd/system/local-fs.target.wants/"
                "bc250-persistence-recovery.service\n"
                "/etc/systemd/system/var-lib-bc250\\x2dcontrol.mount\n"
                "/etc/systemd/system/local-fs.target.wants/"
                "var-lib-bc250\\x2dcontrol.mount\n",
                encoding="utf-8",
            )
            cmdline.write_text(
                "quiet amdgpu.sched_policy=2\n", encoding="utf-8"
            )
            bindir = root / "bin"
            bindir.mkdir()
            stat = bindir / "stat"
            stat.write_text(
                '#!/bin/sh\n[ "$2" = %u ] && { echo 0; exit; }; echo 644\n',
                encoding="utf-8",
            )
            stat.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "SCHED_CONFIG": str(config),
                    "GRUB_DEFAULT": str(root / "default-grub"),
                    "GRUB_CFG": str(grub),
                    "PROC_CMDLINE": str(cmdline),
                    "AMDGPU_KEEP_FILE": str(keep),
                    "PATH": f"{bindir}:{env['PATH']}",
                }
            )

            result = subprocess.run(
                ["bash", str(AUDIO_BOOT_CONFIG), "status"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertIn("configured and active", result.stdout)

            grub.write_text(
                "steamenv_boot linux /boot/vmlinuz quiet amdgpu.sched_policy=2\n"
                "steamenv_boot linux /boot/vmlinuz-fallback quiet\n",
                encoding="utf-8",
            )
            invalid = subprocess.run(
                ["bash", str(AUDIO_BOOT_CONFIG), "status"],
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("incomplete", invalid.stdout)

    def test_async_compute_install_and_rollback_manage_boot_policy(self):
        installer = (ROOT / "bc250-audio-fix/install.sh").read_text(
            encoding="utf-8"
        )
        rollback = AUDIO_ROLLBACK.read_text(encoding="utf-8")
        cleanup = (ROOT / "bc250-audio-fix/cleanup-other-slot.sh").read_text(
            encoding="utf-8"
        )

        mesh = (ROOT / "bc250-mesh-shader.sh").read_text(encoding="utf-8")
        direct_installer = (ROOT / "bc250-audio-fix/install.sh").read_text(
            encoding="utf-8"
        )
        self.assertNotIn('"$BOOT_CONFIG" install', installer)
        self.assertIn('BC250_FORCE_GRUB_REGEN=1 "$BOOT_CONFIG" policy-remove', direct_installer)
        self.assertLess(
            direct_installer.index('"$BOOT_CONFIG" policy-remove'),
            direct_installer.index(
                '"$MKINITCPIO" "$REL" -p "$PRESET"',
                direct_installer.index('"$BOOT_CONFIG" policy-remove'),
            ),
        )
        self.assertIn('as_root bash "$BOOT_CONFIG" install', mesh)
        self.assertIn('"$BOOT_CONFIG" remove', rollback)
        self.assertIn("BC250_SKIP_GRUB_REGEN=1", cleanup)
        self.assertIn("amdgpu.sched_policy=2", mesh)

    def test_mkinitcpio_ignores_only_stale_blake2b_module_name(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install_dir = root / "install"
            bindir = root / "bin"
            install_dir.mkdir()
            bindir.mkdir()
            hook = install_dir / "steam-deck"
            hook.write_text(
                "#!/bin/bash\nbuild() {\n    blake2b_generic\n}\n",
                encoding="utf-8",
            )
            hook.chmod(0o755)
            (bindir / "modinfo").write_text(
                "#!/bin/bash\n"
                '[ "${@: -1}" = blake2b ] && { echo "(builtin)"; exit 0; }\n'
                "exit 1\n",
                encoding="utf-8",
            )
            (bindir / "mkinitcpio").write_text(
                "#!/bin/bash\n"
                'resolved=$(PATH="$MKINITCPIO_INSTALL" command -v steam-deck)\n'
                'grep -Fq "blake2b_generic?" "$resolved"\n'
                'printf "%s\\n" "$resolved" > "$CALL_LOG"\n',
                encoding="utf-8",
            )
            (bindir / "modinfo").chmod(0o755)
            (bindir / "mkinitcpio").chmod(0o755)
            call_log = root / "call-log"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bindir}:{env['PATH']}",
                    "MKINITCPIO_INSTALL": str(install_dir),
                    "CALL_LOG": str(call_log),
                }
            )

            result = subprocess.run(
                ["bash", str(AUDIO_MKINITCPIO), "7.2-test", "-p", "test"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertIn("stale SteamOS blake2b_generic request", result.stdout)
            self.assertNotEqual(Path(call_log.read_text().strip()), hook)
            self.assertIn("blake2b_generic\n", hook.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
