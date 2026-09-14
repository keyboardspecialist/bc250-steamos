import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLKIT = ROOT / "bc250-toolkit.sh"


class ToolkitTests(unittest.TestCase):
    def test_help_lists_components_and_user_privilege_model(self):
        result = subprocess.run(
            ["bash", str(TOOLKIT), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        for command in (
            "setup",
            "auto-base-installation",
            "graphics-setup",
            "status",
            "drivers",
            "unlocks",
            "storage-updates",
            "interfaces",
            "power",
            "ram",
            "swap",
            "compute",
            "cpu-unlock",
            "cec",
            "audio-output",
            "hdmi-ac3-enable",
            "hdmi-ac3-revert",
            "storage",
            "persistence",
            "wifi",
            "fan-driver",
            "amdgpu",
            "amdgpu-clean",
            "scheduler-policy",
            "kfd-runlist",
            "radv",
            "proton",
            "proton-install",
            "proton-update",
            "proton-status",
            "proton-uninstall",
            "audio",
            "mesh",
            "decky",
            "coolercontrol",
            "manage",
            "inventory-json",
            "action OPERATION_ID",
        ):
            self.assertIn(command, result.stdout)
        self.assertIn("logged-in Deck user, not with sudo", result.stdout)
        self.assertIn("Compatibility aliases: audio (amdgpu), mesh (radv)", result.stdout)

    def test_main_menu_groups_related_workflows(self):
        source = TOOLKIT.read_text(encoding="utf-8")
        main_menu = source[source.index("cmd_menu() {") : source.index("cmd_help() {")]
        drivers_menu = source[
            source.index("cmd_drivers_menu() {") : source.index("cmd_unlocks_menu() {")
        ]
        unlocks_menu = source[
            source.index("cmd_unlocks_menu() {") : source.index("cmd_storage_updates_menu() {")
        ]
        interfaces_menu = source[
            source.index("cmd_interfaces_menu() {") : source.index("cmd_core_system_menu() {")
        ]
        devices_menu = source[
            source.index("cmd_devices_menu() {") : source.index("cmd_audio_menu() {")
        ]
        guided_overview = source[
            source.index("show_guided_setup_overview() {") : source.index("cmd_guided_setup_menu() {")
        ]
        performance_menu = source[
            source.index("cmd_performance_menu() {") : source.index("cmd_devices_menu() {")
        ]

        for label in (
            "Auto Base Toolkit Installation",
            "Manual guided setup",
            "System health",
            "Core system",
            "Performance tuning",
            "Hardware unlocks",
            "Device drivers & connectivity",
            "Control interfaces",
            "Maintenance & recovery",
        ):
            self.assertIn(f'"{label}|', main_menu)
        self.assertRegex(
            (ROOT / "VERSION").read_text(encoding="utf-8").strip(),
            r"^v\d+\.\d+\.\d+$",
        )
        self.assertIn(
            'menu_select "BC-250 SteamOS toolkit ${CD}[${TOOLKIT_VERSION}]${C0}"',
            main_menu,
        )
        self.assertGreater(
            main_menu.index('"System health|'),
            main_menu.index('"Maintenance & recovery|'),
        )
        self.assertIn("0) run_menu_action auto-base-installation", main_menu)
        self.assertIn("8) run_menu_action status", main_menu)
        self.assertNotIn("Mesh shaders (per game)", source)
        self.assertNotIn("[optional]", drivers_menu)
        self.assertIn("Install / resume async-compute stack", drivers_menu)
        self.assertIn("AMDGPU scheduler policy (advanced)", drivers_menu)
        self.assertIn("KFD HWS runlist TLB flush (experimental)", drivers_menu)
        self.assertIn("Clean AMDGPU build tree", drivers_menu)
        self.assertLess(
            drivers_menu.index("AMDGPU kernel fixes"),
            drivers_menu.index("Clean AMDGPU build tree"),
        )
        self.assertLess(
            drivers_menu.index("Clean AMDGPU build tree"),
            drivers_menu.index("AMDGPU scheduler policy (advanced)"),
        )
        self.assertLess(
            drivers_menu.index("AMDGPU scheduler policy (advanced)"),
            drivers_menu.index("KFD HWS runlist TLB flush (experimental)"),
        )
        self.assertLess(
            drivers_menu.index("KFD HWS runlist TLB flush (experimental)"),
            drivers_menu.index("Install / resume async-compute stack"),
        )
        self.assertLess(
            drivers_menu.index("Install / resume async-compute stack"),
            drivers_menu.index("NCT6687 fan-control driver"),
        )
        self.assertLess(
            drivers_menu.index("NCT6687 fan-control driver"),
            drivers_menu.index("AIC8800 WiFi / Bluetooth"),
        )
        self.assertIn("0) run_menu_action amdgpu", drivers_menu)
        self.assertIn("1) run_menu_action amdgpu-clean", drivers_menu)
        self.assertIn("2) run_menu_action scheduler-policy", drivers_menu)
        self.assertIn("3) run_menu_action kfd-runlist", drivers_menu)
        self.assertIn("4) run_menu_action graphics-setup", drivers_menu)
        self.assertIn("GE-Proton with FSR4", performance_menu)
        self.assertIn("portable FSR4 RC9 game DLLs", performance_menu)
        self.assertIn("2) cmd_proton_menu", performance_menu)
        self.assertIn("bc250-proton.sh", source)
        self.assertIn("GPU compute-unit unlock", unlocks_menu)
        self.assertIn("CPU core unlock", unlocks_menu)
        self.assertIn(
            "Test GPU compute units or CPU cores with explicit stability and recovery steps.",
            main_menu,
        )
        self.assertNotIn("without confusing the two workflows", source)
        self.assertIn("0) run_menu_child compute", unlocks_menu)
        self.assertIn("1) run_menu_child cpu-unlock", unlocks_menu)
        self.assertIn('"HDMI audio|', source)
        self.assertNotIn('"HDMI-CEC"', guided_overview)
        self.assertIn('"HDMI-CEC|${CG}[menu]${C0}|', devices_menu)
        self.assertIn('"Enable HDMI AC-3 5.1|', source)
        self.assertIn('"Revert HDMI AC-3 to stereo|', source)
        self.assertIn("0) run_menu_action hdmi-ac3-enable", source)
        self.assertIn("1) run_menu_action hdmi-ac3-revert", source)
        self.assertIn("amdgpu|audio)", source)
        self.assertIn("radv|mesh)", source)
        self.assertIn('python3 "$TRAINER_RELEASE_INSTALLER"', source)
        self.assertNotIn('bash "$TRAINER_INSTALL_SH" install', source)
        self.assertIn('"CoolerControl|', interfaces_menu)
        self.assertIn("2) run_menu_action coolercontrol", interfaces_menu)
        self.assertIn("3) run_menu_action trainer", interfaces_menu)

        power = (ROOT / "bc250-power.sh").read_text(encoding="utf-8")
        power_menu = power[power.index("cmd_menu() {") : power.index("cmd_help() {")]
        self.assertNotIn('"CPU core unlock|', power_menu)
        self.assertIn("menu)      menu_cpu_unlock", power)

        guided_menu = source[
            source.index("cmd_guided_setup_menu() {") : source.index("cmd_drivers_menu() {")
        ]
        for label in (
            "Setup overview",
            "GPU compute-unit unlock",
            "CPU core unlock",
            "AMDGPU kernel fixes",
            "Power foundation",
            "RAM / VRAM split",
            "Performance tuning",
        ):
            self.assertIn(label, guided_menu)
        self.assertIn("load-test", guided_menu.lower())
        self.assertIn("reboot", guided_menu.lower())
        self.assertIn("choose by goal", guided_menu)
        self.assertNotIn("Step 1", guided_menu)
        self.assertNotIn("Step 2", guided_menu)
        self.assertNotIn("Step 3", guided_menu)
        self.assertNotIn("Persistent foundation", guided_menu)
        self.assertNotIn("run_menu_child storage", guided_menu)
        self.assertLess(
            guided_menu.index("GPU compute-unit unlock"),
            guided_menu.index("Performance tuning"),
        )
        self.assertLess(
            guided_menu.index("CPU core unlock"),
            guided_menu.index("Performance tuning"),
        )
        self.assertNotIn("auto-base-installation", guided_menu)
        self.assertIn("1) run_menu_child compute", guided_menu)
        self.assertIn("2) run_menu_child cpu-unlock", guided_menu)
        self.assertIn("3) run_menu_action amdgpu", guided_menu)
        self.assertIn("4) run_menu_child power", guided_menu)
        self.assertIn("5) run_menu_child ram", guided_menu)
        self.assertIn("6) cmd_performance_menu", guided_menu)
        self.assertNotIn("Finish - Verify system", guided_menu)
        self.assertIn("cmd_guided_setup_menu", main_menu)

    def test_dense_component_menus_are_grouped_by_intent(self):
        power = (ROOT / "bc250-power.sh").read_text(encoding="utf-8")
        power_menu = power[power.index("cmd_menu() {") : power.index("cmd_help() {")]
        self.assertIn("Power foundation", power_menu)
        self.assertIn("GPU performance tuning", power_menu)
        self.assertIn("CPU performance & security", power_menu)
        self.assertNotIn('"Step 1 - ACPI fix:', power_menu)
        self.assertIn("menu_power_setup()", power)
        self.assertIn("menu_gpu_tuning()", power)
        self.assertIn("menu_cpu_tuning()", power)

        cec = (ROOT / "bc250-cec.sh").read_text(encoding="utf-8")
        cec_menu = cec[cec.index("cmd_menu() {") : cec.index("tv_badge_menu() {")]
        self.assertIn("Setup & automation", cec_menu)
        self.assertIn("Everyday controls", cec_menu)
        self.assertIn("Diagnostics & recovery", cec_menu)
        self.assertNotIn('"Scan CEC bus|', cec_menu)
        self.assertIn("menu_setup()", cec)
        self.assertIn("menu_controls()", cec)
        self.assertIn("menu_diagnostics()", cec)
        self.assertIn('echo "  boot wake mode: $mode"', cec)
        controls = cec[cec.index("menu_controls() {") : cec.index("menu_diagnostics() {")]
        self.assertIn("Take the input", controls)
        self.assertIn("4) run_action cmd_switch", controls)

        toolkit = TOOLKIT.read_text(encoding="utf-8")
        guided = toolkit[
            toolkit.index("cmd_guided_setup_menu() {") : toolkit.index("cmd_drivers_menu() {")
        ]
        self.assertNotIn("start_sudo_session", guided)

    def test_trainer_toolkit_uses_semantic_setup_groups(self):
        page = (ROOT / "trainer/qml/pages/ToolkitPage.qml").read_text(
            encoding="utf-8"
        )
        controller = (ROOT / "trainer/src/ToolkitController.cpp").read_text(
            encoding="utf-8"
        )
        self.assertIn('property string category: "FOUNDATION"', page)
        self.assertIn(
            '["FOUNDATION", "PERFORMANCE", "DEVICES", "INTERFACES", "ALL"]',
            page,
        )
        self.assertIn('title: "POWER FOUNDATION"', page)
        self.assertIn('title: "GPU CU PREREQUISITES"', page)
        self.assertIn("Automatic infrastructure", page)
        self.assertNotIn("Start here: home-backed storage", page)
        self.assertIn("test-starts the GPU governor", page)
        self.assertIn("Build UMR only", page)
        self.assertIn("./bc250-toolkit.sh power", controller)
        self.assertIn("Live routing, stability testing", controller)

    def test_shell_menus_are_anchored_and_status_aligned(self):
        menu_scripts = (
            "bc250-toolkit.sh",
            "bc250-power.sh",
            "bc250-cec.sh",
            "bc250-40cu.sh",
            "bc250-ram-split.sh",
            "bc250-swap.sh",
            "bc250-storage.sh",
            "bc250-update-persistence.sh",
            "bc250-mesh-shader.sh",
            "bc250-maintenance.sh",
        )
        for relative in menu_scripts:
            with self.subTest(script=relative):
                source = (ROOT / relative).read_text(encoding="utf-8")
                menu = source[source.index("menu_select() {") :]
                self.assertIn("label_width=0", menu)
                self.assertIn("${#label} > label_width", menu)
                self.assertIn("\\033[H\\033[2J", menu)
                self.assertIn("%-*s", menu)
                self.assertIn("CONTROLS  [Up/Down or J/K] Move", menu)
                self.assertIn("[Enter] Select", menu)
                self.assertIn("[Q/Esc]", menu)
                self.assertIn("${CB}${CC}", menu)
                self.assertNotIn("drawn=", menu)
                self.assertNotIn("\\033[%dA", menu)

        toolkit = TOOLKIT.read_text(encoding="utf-8")
        menu = toolkit[toolkit.index("menu_select() {") : toolkit.index("pause_key() {")]
        self.assertIn("exit_label=back", menu)
        self.assertIn("exit_label=quit", menu)
        self.assertIn("${exit_label^}", menu)

    def test_main_menu_keeps_sudo_alive_and_revokes_it_on_exit(self):
        source = TOOLKIT.read_text(encoding="utf-8")
        sudo_session = source[
            source.index("toolkit_cleanup() {") : source.index("require_script() {")
        ]
        main_menu = source[source.index("cmd_menu() {") : source.index("cmd_help() {")]

        self.assertIn("trap toolkit_cleanup EXIT", sudo_session)
        self.assertIn("sudo -v", sudo_session)
        self.assertIn("sudo -n -v", sudo_session)
        self.assertIn("sudo -n -k", sudo_session)
        self.assertIn('kill "$SUDO_KEEPALIVE_PID"', sudo_session)
        self.assertIn('wait "$SUDO_KEEPALIVE_PID"', sudo_session)
        self.assertIn("start_sudo_session", main_menu)

    def test_scheduler_policy_toggle_uses_guarded_boot_config_lifecycle(self):
        source = TOOLKIT.read_text(encoding="utf-8")
        toggle = source[
            source.index("scheduler_policy_badge() {") : source.index("install_decky() {")
        ]

        self.assertIn('bash "$AMDGPU_BOOT_CONFIG_SH" configured', toggle)
        self.assertIn('bash "$AMDGPU_BOOT_CONFIG_SH" active', toggle)
        self.assertIn('bash "$AMDGPU_BOOT_CONFIG_SH" present', toggle)
        self.assertIn('sudo bash "$AMDGPU_BOOT_CONFIG_SH" install', toggle)
        self.assertIn('sudo bash "$AMDGPU_BOOT_CONFIG_SH" policy-remove', toggle)
        self.assertIn('sudo bash "$AMDGPU_BOOT_CONFIG_SH" runlist-install', toggle)
        self.assertIn('sudo bash "$AMDGPU_BOOT_CONFIG_SH" runlist-remove', toggle)
        self.assertIn("kfd_runlist_supported", toggle)
        self.assertIn('bash "$MESH_SHADER_SH" status-json', toggle)
        self.assertIn('json_field "$radv_json" kernelReady', toggle)
        self.assertIn("before enabling amdgpu.sched_policy=2", toggle)
        self.assertIn("Scheduler policy state is incomplete", toggle)
        self.assertIn("cannot coexist with sched_policy=2", source)

    def test_decky_install_bootstraps_loader_before_plugin_dependencies(self):
        installer = (ROOT / "decky-plugin/install.sh").read_text(encoding="utf-8")
        install_plugin = installer[installer.index("install_plugin() {") :]

        self.assertIn(
            "https://github.com/SteamDeckHomebrew/decky-installer/"
            "releases/latest/download/install_release.sh",
            installer,
        )
        self.assertIn("systemctl cat plugin_loader.service", installer)
        self.assertIn(
            "curl -L https://github.com/SteamDeckHomebrew/decky-installer/"
            "releases/latest/download/install_release.sh | sh",
            installer,
        )
        self.assertLess(
            install_plugin.index("ensure_decky_loader"),
            install_plugin.index("command -v pnpm"),
        )

    def test_decky_root_helper_uses_explicit_smu_patch_allowlist(self):
        installer = (ROOT / "decky-plugin/install.sh").read_text(encoding="utf-8")

        for expected in (
            "0001-transaction-level-flock.patch",
            "0002-steamos-stress-fallback.patch",
            "0003-atomic-config-write.patch",
            "README.md",
            "bc250_detect.py",
            "stress_helper.py",
            "transport.py",
        ):
            self.assertIn(f'"$SRC_DIR/../smu-oc-patches/{expected}"', installer)
        self.assertIn(
            'sudo install -m 0644 "${SMU_PATCH_SOURCES[@]}"', installer
        )
        self.assertNotIn('smu-oc-patches/*', installer)

    def make_action_environment(self, root):
        toolkit = root / TOOLKIT.name
        shutil.copy2(TOOLKIT, toolkit)
        call_log = root / "calls"
        bindir = root / "bin"
        bindir.mkdir()
        (bindir / "sudo").write_text(
            "#!/usr/bin/env bash\n"
            "printf 'sudo' >> \"$CALL_LOG\"\n"
            "for argument; do printf '|%s' \"$argument\" >> \"$CALL_LOG\"; done\n"
            "printf '|machine=%s\\n' \"${BC250_TOOLKIT_MACHINE:-}\" >> \"$CALL_LOG\"\n",
            encoding="utf-8",
        )
        (bindir / "sudo").chmod(0o755)

        scripts = (
            "bc250-storage.sh",
            "bc250-power.sh",
            "bc250-ram-split.sh",
            "bc250-swap.sh",
            "bc250-40cu.sh",
            "bc250-cec.sh",
            "bc250-update-persistence.sh",
            "bc250-mesh-shader.sh",
            "bc250-maintenance.sh",
            "aic8800/steamdeck-setup.sh",
            "nct6687d/steamdeck-setup.sh",
            "bc250-audio-fix/patch-driver.sh",
            "bc250-audio-fix/clean.sh",
            "hdmi-ac3/hdmi-ac3.sh",
            "bc250-proton.sh",
            "decky-plugin/install.sh",
            "desktop-control/install.sh",
            "coolercontrol/install.sh",
        )
        for relative in scripts:
            script = root / relative
            script.parent.mkdir(parents=True, exist_ok=True)
            script.write_text(
                "#!/usr/bin/env bash\n"
                f"printf '{relative}' >> \"$CALL_LOG\"\n"
                "for argument; do printf '|%s' \"$argument\" >> \"$CALL_LOG\"; done\n"
                "printf '|machine=%s\\n' \"${BC250_TOOLKIT_MACHINE:-}\" >> \"$CALL_LOG\"\n",
                encoding="utf-8",
            )

        env = os.environ.copy()
        env["PATH"] = f"{bindir}:{env['PATH']}"
        env["CALL_LOG"] = str(call_log)
        return toolkit, call_log, env

    def make_inventory_environment(self, root):
        toolkit = root / TOOLKIT.name
        maintenance = root / "bc250-maintenance.sh"
        shutil.copy2(TOOLKIT, toolkit)
        shutil.copy2(ROOT / "bc250-maintenance.sh", maintenance)

        probes = {
            "bc250-power.sh": ("installed", 0),
            "bc250-ram-split.sh": ("installed", 0),
            "bc250-swap.sh": ("installed", 0),
            "bc250-40cu.sh": ("installed", 0),
            "bc250-cec.sh": ("installed", 1),
            "bc250-storage.sh": ("installed", 0),
            "bc250-mesh-shader.sh": ("status", 0),
            "bc250-proton.sh": ("status", 0),
            "aic8800/steamdeck-setup.sh": ("status", 0),
            "nct6687d/steamdeck-setup.sh": ("status", 0),
            "bc250-audio-fix/patch-driver.sh": ("status", 0),
            "hdmi-ac3/hdmi-ac3.sh": ("status", 0),
            "decky-plugin/install.sh": ("status", 1),
            "desktop-control/install.sh": ("status", 0),
            "coolercontrol/install.sh": ("status", 0),
            "trainer/install.sh": ("status", 0),
            "trainer/install-flatpak.sh": ("status", 1),
        }
        for relative, (probe, result) in probes.items():
            script = root / relative
            script.parent.mkdir(parents=True, exist_ok=True)
            script.write_text(
                "#!/usr/bin/env bash\n"
                f"[[ \"${{1:-}}\" == {probe} ]] || exit 2\n"
                f"exit {result}\n",
                encoding="utf-8",
            )

        home = root / "home"
        cec_artifact = home / ".config/systemd/user/bc250-cec-boot-wake.service"
        cec_artifact.parent.mkdir(parents=True)
        cec_artifact.touch()
        env = os.environ.copy()
        env["HOME"] = str(home)
        return toolkit, env

    def make_status_environment(self, root, amdgpu_state):
        toolkit = root / TOOLKIT.name
        shutil.copy2(TOOLKIT, toolkit)
        bindir = root / "bin"
        bindir.mkdir()
        sudo = bindir / "sudo"
        sudo.write_text(
            "#!/usr/bin/env bash\n"
            "[[ \"${1:-}\" == -v ]] && exit 0\n"
            "export BC250_TEST_ELEVATED=1\n"
            "exec \"$@\"\n",
            encoding="utf-8",
        )
        sudo.chmod(0o755)
        scripts = (
            "bc250-storage.sh",
            "bc250-power.sh",
            "bc250-ram-split.sh",
            "bc250-swap.sh",
            "bc250-cec.sh",
            "bc250-update-persistence.sh",
        )
        for relative in scripts:
            script = root / relative
            if relative == "bc250-power.sh":
                content = (
                    "#!/usr/bin/env bash\n"
                    "if [[ \"$*\" == \"cpu-unlock status\" ]]; then\n"
                    "  printf '%s\\n' '  automatic unlock: disabled'\n"
                    "  printf '%s\\n' 'CPU topology: 6 cores / 12 threads (locked)'\n"
                    "  printf '%s\\n' 'unlock attempt/reboot guard: clear'\n"
                    "else\n"
                    "  printf '%s\\n' '  saved freq setting (reapplied at boot): MODE=range A=1000 B=1850 '\n"
                    "  printf '%s\\n' '  max MHz: config=1500 initial=1500 current=1500'\n"
                    "  printf '%s\\n' '  governor: schedutil'\n"
                    "fi\n"
                )
            elif relative == "bc250-cec.sh":
                content = (
                    "#!/usr/bin/env bash\n"
                    "case \"${1:-}\" in\n"
                    "  status)\n"
                    "    printf '%s\\n' '/dev/cec0: present'\n"
                    "    printf '%s\\n' 'cecd.service: active'\n"
                    "    printf '%s\\n' 'aggregate integration: installed'\n"
                    "    printf '%s\\n' 'poweroff standby unit: enabled'\n"
                    "    printf '%s\\n' 'boot wake unit (user): enabled'\n"
                    "    printf '%s\\n' 'boot wake mode: polite'\n"
                    "    ;;\n"
                    "  scan)\n"
                    "    printf '%s\\n' 'physical      LA  role                 OSD name         vendor     power'\n"
                    "    printf '%s\\n' '0.0.0.0       0   TV                   Living Room TV   0x123456   on'\n"
                    "    printf '%s\\n' '  1.0.0.0     4   Playback Device      BC-250           -          (this device)'\n"
                    "    ;;\n"
                    "  *) exit 2 ;;\n"
                    "esac\n"
                )
            else:
                content = "#!/usr/bin/env bash\nexit 0\n"
            script.write_text(content, encoding="utf-8")
        audio = root / "bc250-audio-fix/patch-driver.sh"
        audio.parent.mkdir(parents=True)
        audio.write_text(
            "#!/usr/bin/env bash\n"
            "[[ \"${1:-}\" == status-json ]] || exit 2\n"
            f"printf '%s\\n' {json.dumps(json.dumps({'scriptAvailable': True, 'runningKernel': 'test-kernel', 'state': amdgpu_state, 'overrideInstalled': amdgpu_state != 'not-installed', 'overrideSelected': amdgpu_state in ('reboot-required', 'ready'), 'activeReady': amdgpu_state == 'ready', 'rebootRequired': amdgpu_state == 'reboot-required'}, separators=(',', ':')))}\n",
            encoding="utf-8",
        )
        mesh = root / "bc250-mesh-shader.sh"
        mesh.write_text(
            "#!/usr/bin/env bash\n"
            "[[ \"${1:-}\" == status-json ]] || exit 2\n"
            "printf '%s\\n' '{\"runtimeState\":\"not-installed\",\"kernelReady\":false,\"schedulerConfigured\":false,\"schedulerActive\":false,\"globalEnabled\":false}'\n",
            encoding="utf-8",
        )
        proton = root / "bc250-proton.sh"
        proton.write_text(
            "#!/usr/bin/env bash\nprintf '%s\\n' '[bc250-proton] state: not-installed'\nexit 1\n",
            encoding="utf-8",
        )
        fan = root / "nct6687d/steamdeck-setup.sh"
        fan.parent.mkdir(parents=True, exist_ok=True)
        fan.write_text(
            "#!/usr/bin/env bash\nprintf '%s\\n' '[nct6687] state: not-installed'\nexit 1\n",
            encoding="utf-8",
        )
        cu_status = root / "bc250-cu-status.sh"
        cu_status.write_text(
            "#!/usr/bin/env bash\n"
            "[[ ${BC250_TEST_ELEVATED:-0} == 1 ]] || exit 2\n"
            "printf '%s\\n' '38/40'\n",
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["PATH"] = f"{bindir}:{env['PATH']}"
        return toolkit, env

    def test_without_terminal_prints_help(self):
        result = subprocess.run(
            ["bash", str(TOOLKIT)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Usage:", result.stderr)

    def test_status_accepts_missing_amdgpu_but_rejects_incomplete_integration(self):
        cases = (("not-installed", 0, False), ("invalid", 1, True))
        for state, expected, incomplete in cases:
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                toolkit, env = self.make_status_environment(Path(directory), state)
                result = subprocess.run(
                    ["bash", str(toolkit), "status"],
                    capture_output=True,
                    text=True,
                    env=env,
                )
                self.assertEqual(result.returncode, expected)
                self.assertIn("BC-250 system health", result.stdout)
                self.assertIn("1000-1850 MHz saved range", result.stdout)
                self.assertNotIn("config=1500", result.stdout)
                self.assertIn("CPU core unlock", result.stdout)
                self.assertIn("6 cores / 12 threads (locked)", result.stdout)
                self.assertIn("GPU compute-unit unlock", result.stdout)
                self.assertIn("BC-250 GE-Proton", result.stdout)
                self.assertIn("[38/40]", result.stdout)
                self.assertIn("CEC setup & automation", result.stdout)
                self.assertIn("[configured]", result.stdout)
                self.assertIn("Poweroff standby", result.stdout)
                self.assertIn("Boot wake", result.stdout)
                self.assertIn("Boot wake mode", result.stdout)
                self.assertIn("\x1b[32m[polite]", result.stdout)
                self.assertLess(
                    result.stdout.index("CEC setup & automation"),
                    result.stdout.index("Poweroff standby"),
                )
                self.assertLess(
                    result.stdout.index("Poweroff standby"),
                    result.stdout.index("Boot wake"),
                )
                self.assertLess(
                    result.stdout.index("Boot wake"),
                    result.stdout.index("Boot wake mode"),
                )
                self.assertIn("CEC BUS MAP", result.stdout)
                self.assertIn("Living Room TV", result.stdout)
                self.assertIn("BC-250", result.stdout)
                expected_badge = "[invalid]" if incomplete else "[not installed]"
                self.assertIn(expected_badge, result.stdout)
                self.assertEqual("OVERALL  [attention required]" in result.stdout, incomplete)
                if incomplete:
                    self.assertIn("AMDGPU kernel fixes", result.stdout)
                else:
                    self.assertIn("OVERALL  [healthy]", result.stdout)

                plain = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
                rows = [
                    line
                    for line in plain.splitlines()
                    if re.match(r"^  .{30} \[", line)
                ]
                self.assertGreaterEqual(len(rows), 10)

    def test_status_reports_unlocked_cpu_topology_and_efi_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            toolkit, env = self.make_status_environment(root, "not-installed")
            power = root / "bc250-power.sh"
            content = power.read_text(encoding="utf-8")
            content = content.replace(
                "automatic unlock: disabled", "automatic unlock: EFI pre-boot method"
            ).replace(
                "6 cores / 12 threads (locked)",
                "8 cores / 16 threads (unlocked)",
            )
            power.write_text(content, encoding="utf-8")

            result = subprocess.run(
                ["bash", str(toolkit), "status"],
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("CPU core unlock", result.stdout)
            self.assertIn("[unlocked]", result.stdout)
            self.assertIn("8 cores / 16 threads (unlocked)", result.stdout)
            self.assertIn("EFI pre-boot method", result.stdout)

    def test_interactive_status_reports_health_instead_of_action_failure(self):
        source = TOOLKIT.read_text(encoding="utf-8")
        status = source[source.index("show_status() {") : source.index("menu_select() {")]
        runner = source[
            source.index("run_menu_action() {") : source.index("cmd_drivers_menu() {")
        ]

        self.assertIn("sudo -v", status)
        self.assertIn(
            'status_script_capture cu_output cu_rc root "$CU_STATUS_SH" -q', status
        )
        self.assertIn(
            'status_script_capture cpu_output cpu_rc root "$POWER_SH" cpu-unlock status',
            status,
        )
        self.assertIn("system status is incomplete", runner)
        self.assertIn("if [[ ${1:-} == status ]]", runner)

    def test_component_dispatch_opens_menu_and_rejects_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            toolkit = root / TOOLKIT.name
            power = root / "bc250-power.sh"
            bindir = root / "bin"
            bindir.mkdir()
            shutil.copy2(TOOLKIT, toolkit)
            power.write_text(
                "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\"\n",
                encoding="utf-8",
            )
            sudo = bindir / "sudo"
            sudo.write_text("#!/usr/bin/env bash\nexec \"$@\"\n", encoding="utf-8")
            sudo.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{bindir}:{env['PATH']}"

            default = subprocess.run(
                ["bash", str(toolkit), "power"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            rejected = subprocess.run(
                ["bash", str(toolkit), "power", "freq", "status"],
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(default.stdout.strip(), "menu")
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("Usage:", rejected.stderr)

    def test_new_component_names_and_compatibility_aliases_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            toolkit, call_log, env = self.make_action_environment(root)
            mappings = {
                "radv": ("bc250-mesh-shader.sh", "menu"),
                "mesh": ("bc250-mesh-shader.sh", "menu"),
                "power": ("sudo", "bash", str(root / "bc250-power.sh"), "menu"),
                "compute": ("sudo", "bash", str(root / "bc250-40cu.sh"), "menu"),
                "cpu-unlock": (
                    "sudo",
                    "bash",
                    str(root / "bc250-power.sh"),
                    "cpu-unlock",
                    "menu",
                ),
                "swap": ("sudo", "bash", str(root / "bc250-swap.sh"), "menu"),
            }
            for command, expected in mappings.items():
                with self.subTest(command=command):
                    call_log.unlink(missing_ok=True)
                    subprocess.run(
                        ["bash", str(toolkit), command],
                        check=True,
                        capture_output=True,
                        text=True,
                        env=env,
                    )
                    self.assertEqual(
                        call_log.read_text(encoding="utf-8").strip(),
                        "|".join(expected) + "|machine=",
                    )

    def test_action_dispatch_is_a_fixed_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            toolkit, call_log, env = self.make_action_environment(root)
            mappings = {
                "storage-install": ("sudo", "bc250-storage.sh", "install"),
                "storage-repair": ("sudo", "bc250-storage.sh", "repair-infrastructure"),
                "power-install": ("sudo", "bc250-power.sh", "all"),
                "ram-install": ("sudo", "bc250-ram-split.sh", "install"),
                "swap-zram-install": ("sudo", "bc250-swap.sh", "install", "zram"),
                "swap-zswap-install": ("sudo", "bc250-swap.sh", "install", "zswap"),
                "compute-build": ("sudo", "bc250-40cu.sh", "prep"),
                "ac3-install": ("direct", "hdmi-ac3/hdmi-ac3.sh", "install"),
                "proton-install": ("direct", "bc250-proton.sh", "install"),
                "proton-update": ("direct", "bc250-proton.sh", "update"),
                "cec-setup": ("direct", "bc250-cec.sh", "setup"),
                "cec-repair": ("direct", "bc250-cec.sh", "repair"),
                "persistence-install": (
                    "sudo",
                    "bc250-update-persistence.sh",
                    "install",
                    "all",
                ),
                "aic-install": ("sudo", "aic8800/steamdeck-setup.sh", "install"),
                "fan-install": ("sudo", "nct6687d/steamdeck-setup.sh", "install"),
                "audio-build": ("direct", "bc250-audio-fix/patch-driver.sh"),
                "mesh-setup": ("direct", "bc250-mesh-shader.sh", "setup"),
                "decky-install": ("direct", "decky-plugin/install.sh", "install"),
                "desktop-install": ("direct", "desktop-control/install.sh", "install"),
                "coolercontrol-install": ("direct", "coolercontrol/install.sh", "install"),
                "persistence-remove": (
                    "sudo",
                    "bc250-update-persistence.sh",
                    "remove",
                    "all",
                ),
            }
            for component in (
                "storage",
                "power",
                "ram",
                "swap",
                "compute",
                "cec",
                "ac3",
                "proton",
                "aic",
                "fan",
                "audio",
                "mesh",
                "decky",
                "desktop",
                "coolercontrol",
            ):
                mappings[f"{component}-remove"] = (
                    "direct",
                    "bc250-maintenance.sh",
                    "uninstall",
                    component,
                    "--yes",
                )

            for operation, (mode, relative, *arguments) in mappings.items():
                with self.subTest(operation=operation):
                    call_log.unlink(missing_ok=True)
                    subprocess.run(
                        ["bash", str(toolkit), "action", operation],
                        check=True,
                        capture_output=True,
                        text=True,
                        env=env,
                    )
                    if mode == "sudo":
                        expected = ["sudo", "bash", str(root / relative), *arguments]
                    else:
                        expected = [relative, *arguments]
                    self.assertEqual(
                        call_log.read_text(encoding="utf-8").strip(),
                        "|".join(expected) + "|machine=1",
                    )

    def test_action_rejects_unknown_ids_and_wrong_argument_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            toolkit, call_log, env = self.make_action_environment(Path(directory))
            for arguments in (
                ("action",),
                ("action", "power-install", "unexpected"),
                ("action", "bc250-power.sh"),
            ):
                with self.subTest(arguments=arguments):
                    result = subprocess.run(
                        ["bash", str(toolkit), *arguments],
                        capture_output=True,
                        text=True,
                        env=env,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(call_log.exists())

    def make_auto_base_installation_environment(
        self, root, audio_state="not-installed", radv_state="not-installed"
    ):
        toolkit = root / TOOLKIT.name
        shutil.copy2(TOOLKIT, toolkit)
        bindir = root / "bin"
        bindir.mkdir()
        call_log = root / "calls"
        audio_state_file = root / "audio-state"
        radv_state_file = root / "radv-state"
        ram_state_file = root / "ram-state"
        power_state_file = root / "power-state"
        audio_state_file.write_text(audio_state, encoding="ascii")
        radv_state_file.write_text(radv_state, encoding="ascii")

        sudo = bindir / "sudo"
        sudo.write_text("#!/usr/bin/env bash\nexec \"$@\"\n", encoding="utf-8")
        sudo.chmod(0o755)

        power = root / "bc250-power.sh"
        power.write_text(
            "#!/usr/bin/env bash\n"
            "case \"${1:-}\" in\n"
            "  foundation-ready) [[ -e \"$POWER_STATE_FILE\" ]] ;;\n"
            "  all) printf 'power|all\\n' >> \"$CALL_LOG\"; touch \"$POWER_STATE_FILE\" ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        ram = root / "bc250-ram-split.sh"
        ram.write_text(
            "#!/usr/bin/env bash\n"
            "case \"${1:-}\" in\n"
            "  status-json) if [[ -e \"$RAM_STATE_FILE\" ]]; then state=$(< \"$RAM_STATE_FILE\"); else state=not-installed; fi; printf '{\"toolState\":\"%s\"}\\n' \"$state\" ;;\n"
            "  install) printf 'ram|install\\n' >> \"$CALL_LOG\"; printf 'verified\\n' > \"$RAM_STATE_FILE\" ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        audio = root / "bc250-audio-fix/patch-driver.sh"
        audio.parent.mkdir(parents=True)
        audio.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ \"${1:-}\" == status-json ]]; then\n"
            "  state=$(< \"$AUDIO_STATE_FILE\")\n"
            "  [[ $state == ready ]] && active=true || active=false\n"
            "  [[ $state == reboot-required ]] && reboot=true || reboot=false\n"
            "  printf '{\"state\":\"%s\",\"activeReady\":%s,\"rebootRequired\":%s}\\n' \"$state\" \"$active\" \"$reboot\"\n"
            "else\n"
            "  printf 'audio|install\\n' >> \"$CALL_LOG\"\n"
            "  printf 'reboot-required\\n' > \"$AUDIO_STATE_FILE\"\n"
            "fi\n",
            encoding="utf-8",
        )
        mesh = root / "bc250-mesh-shader.sh"
        mesh.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ \"${1:-}\" == status-json ]]; then\n"
            "  state=$(< \"$RADV_STATE_FILE\")\n"
            "  case $state in\n"
            "    active) printf '%s\\n' '{\"runtimeState\":\"ready\",\"kernelReady\":true,\"schedulerConfigured\":true,\"schedulerActive\":true,\"globalEnabled\":true}' ;;\n"
            "    reboot-required) printf '%s\\n' '{\"runtimeState\":\"ready\",\"kernelReady\":true,\"schedulerConfigured\":true,\"schedulerActive\":false,\"globalEnabled\":false}' ;;\n"
            "    *) printf '%s\\n' '{\"runtimeState\":\"not-installed\",\"kernelReady\":false,\"schedulerConfigured\":false,\"schedulerActive\":false,\"globalEnabled\":false}' ;;\n"
            "  esac\n"
            "elif [[ \"${1:-}\" == setup ]]; then\n"
            "  printf 'mesh|setup\\n' >> \"$CALL_LOG\"\n"
            "  printf 'reboot-required\\n' > \"$RADV_STATE_FILE\"\n"
            "else exit 2\n"
            "fi\n",
            encoding="utf-8",
        )

        env = {
            **os.environ,
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "CALL_LOG": str(call_log),
            "AUDIO_STATE_FILE": str(audio_state_file),
            "RADV_STATE_FILE": str(radv_state_file),
            "RAM_STATE_FILE": str(ram_state_file),
            "POWER_STATE_FILE": str(power_state_file),
        }
        return toolkit, call_log, ram_state_file, env

    def test_auto_base_installation_installs_foundation_then_pauses_for_amdgpu_reboot(self):
        with tempfile.TemporaryDirectory() as directory:
            toolkit, call_log, _, env = self.make_auto_base_installation_environment(
                Path(directory)
            )
            result = subprocess.run(
                ["bash", str(toolkit), "action", "auto-base-installation"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(
                call_log.read_text(encoding="utf-8").splitlines(),
                ["power|all", "ram|install", "audio|install"],
            )
            self.assertIn("Reboot to activate the AMDGPU kernel fixes", result.stdout)
            self.assertNotIn("mesh|setup", call_log.read_text(encoding="utf-8"))

    def test_auto_base_installation_resumes_with_radv_after_amdgpu_reboot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            toolkit, call_log, ram_state_file, env = self.make_auto_base_installation_environment(
                root, audio_state="ready"
            )
            Path(env["POWER_STATE_FILE"]).touch()
            ram_state_file.write_text("verified\n", encoding="ascii")

            result = subprocess.run(
                ["bash", str(toolkit), "action", "auto-base-installation"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(call_log.read_text(encoding="utf-8").strip(), "mesh|setup")
            self.assertIn("Reboot to activate the scheduler policy", result.stdout)

    def test_auto_base_installation_rejects_invalid_state_before_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            toolkit, call_log, ram_state_file, env = self.make_auto_base_installation_environment(
                Path(directory)
            )
            ram_state_file.write_text("invalid\n", encoding="ascii")
            result = subprocess.run(
                ["bash", str(toolkit), "action", "auto-base-installation"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("RAM / VRAM helper is incomplete", result.stderr)
            self.assertFalse(call_log.exists())

    def test_inventory_json_uses_maintenance_states_without_terminal_output(self):
        with tempfile.TemporaryDirectory() as directory:
            toolkit, env = self.make_inventory_environment(Path(directory))
            result = subprocess.run(
                ["bash", str(toolkit), "inventory-json"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            inventory = json.loads(result.stdout)
            self.assertEqual(inventory["schemaVersion"], 1)
            self.assertEqual(
                [component["id"] for component in inventory["components"]],
                [
                    "trainer",
                    "desktop",
                    "decky",
                    "coolercontrol",
                    "cec",
                    "ac3",
                    "power",
                    "ram",
                    "swap",
                    "compute",
                    "proton",
                    "mesh",
                    "audio",
                    "fan",
                    "aic",
                    "storage",
                ],
            )
            states = {
                component["id"]: component["state"]
                for component in inventory["components"]
            }
            self.assertEqual(states["power"], "installed")
            self.assertEqual(states["cec"], "partial")
            self.assertEqual(states["decky"], "not-installed")
            self.assertTrue(
                set(states.values())
                <= {"installed", "partial", "data-preserved", "not-installed"}
            )
            self.assertNotIn("\x1b", result.stdout)
            self.assertEqual(result.stderr, "")

    def test_inventory_json_rejects_extra_arguments(self):
        result = subprocess.run(
            ["bash", str(TOOLKIT), "inventory-json", "unexpected"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stderr)

    def test_script_parses(self):
        subprocess.run(
            ["bash", "-n", str(TOOLKIT), str(ROOT / "bc250-maintenance.sh")],
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
