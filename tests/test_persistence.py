import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORAGE = ROOT / "bc250-storage.sh"
DESKTOP_INSTALL = ROOT / "desktop-control" / "install.sh"
DESKTOP_REPAIR = ROOT / "desktop-control" / "bc250-desktop-control-repair"
DESKTOP_TEMPLATES = ROOT / "desktop-control" / "templates"


def render(name: str) -> str:
    return subprocess.run(
        ["bash", str(STORAGE), "render", name],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


class PersistenceUnitTests(unittest.TestCase):
    def test_recovery_bootstraps_from_home_before_local_filesystems(self):
        unit = render("recovery")
        self.assertIn("DefaultDependencies=no", unit)
        self.assertIn("RequiresMountsFor=/home", unit)
        self.assertIn("After=home.mount", unit)
        self.assertIn(
            "Before=var-lib-bc250\\x2dcontrol.mount local-fs.target", unit
        )
        self.assertIn(
            "ExecStart=/home/.steamos/offload/var/lib/bc250-control/helper/"
            "bc250-storage.sh repair-infrastructure",
            unit,
        )
        self.assertNotIn("/etc/previous", unit)
        self.assertNotIn("recover all", unit)
        self.assertNotIn("PrivateMounts=", unit)
        self.assertNotIn("PrivateTmp=", unit)
        self.assertNotIn("ProtectHome=", unit)
        self.assertNotIn("ProtectKernel", unit)
        self.assertNotIn("ProtectControlGroups=", unit)

    def test_mount_waits_for_recovery(self):
        unit = render("mount")
        self.assertIn("Requires=bc250-persistence-recovery.service", unit)
        self.assertIn(
            "After=home.mount bc250-persistence-recovery.service", unit
        )
        self.assertIn("What=/home/.steamos/offload/var/lib/bc250-control", unit)
        self.assertIn("Where=/var/lib/bc250-control", unit)
        self.assertIn("Options=bind", unit)

    def test_keep_list_retains_complete_bootstrap(self):
        keep = render("keep")
        for path in (
            "/etc/systemd/system/bc250-persistence-recovery.service",
            "/etc/systemd/system/local-fs.target.wants/"
            "bc250-persistence-recovery.service",
            "/etc/systemd/system/var-lib-bc250\\x2dcontrol.mount",
            "/etc/systemd/system/local-fs.target.wants/"
            "var-lib-bc250\\x2dcontrol.mount",
        ):
            self.assertIn(path, keep)

    def test_generated_services_do_not_order_after_their_target(self):
        for relative in ("bc250-power.sh", "bc250-cec.sh"):
            source = (ROOT / relative).read_text(encoding="utf-8")
            self.assertNotIn("After=multi-user.target", source)

    def test_governor_and_restore_require_bootstrap(self):
        source = (ROOT / "bc250-power.sh").read_text(encoding="utf-8")
        self.assertIn("Requires=$RECOVERY_SVC", source)
        self.assertIn("Requires=$RECOVERY_SVC $GOV_SVC", source)
        self.assertIn(
            "After=$RECOVERY_SVC bc250-cu-live-manager.service", source
        )
        self.assertIn(
            "Conflicts=cyan-skillfish-governor.service "
            "cyan-skillfish-governor-tt.service oberon-governor.service",
            source,
        )

    def test_acpi_persistence_targets_active_steamos_grub_config(self):
        source = (ROOT / "bc250-power.sh").read_text(encoding="utf-8")
        persistence = (ROOT / "bc250-update-persistence.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('GRUB_CFG="/efi/EFI/steamos/grub.cfg"', source)
        self.assertIn(
            'GRUB_ACPI_DEFAULT="/etc/default/grub.d/bc250-acpi.cfg"', source
        )
        self.assertNotIn("/boot/grub/grub.cfg", source)
        self.assertIn("/etc/default/grub.d/bc250-acpi.cfg", persistence)
        self.assertIn("current_os_build > \"\\$READY_MARKER\"", source)
        self.assertIn("installed - boot repair needed", source)
        self.assertIn(
            "After=$RECOVERY_SVC local-fs.target steamos-post-update.service", source
        )

    def test_storage_help_documents_menu_and_sudo_prompt(self):
        result = subprocess.run(
            ["bash", str(STORAGE), "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("interactive menu", result.stdout)
        self.assertIn("confirmation before invoking sudo", result.stdout)
        source = STORAGE.read_text(encoding="utf-8")
        self.assertIn("Continue with sudo? [y/N]", source)
        self.assertIn('sudo bash "$SELF" "$@"', source)
        self.assertIn(
            'Repair boot infrastructure|$(infrastructure_badge)|', source
        )
        self.assertIn('log "Boot infrastructure is healthy."', source)

    def test_desktop_service_is_isolated_root_dbus_service(self):
        unit = (DESKTOP_TEMPLATES / "bc250-control.service").read_text(
            encoding="utf-8"
        )
        self.assertIn("Type=dbus", unit)
        self.assertIn("BusName=io.github.keyboardspecialist.BC250Control1", unit)
        self.assertIn(
            "ExecStart=/usr/bin/python3 -I /var/lib/bc250-control/desktop/"
            "bc250-control-service",
            unit,
        )
        self.assertIn("User=root", unit)
        self.assertIn("Requires=bc250-desktop-control-repair.service", unit)

    def test_desktop_dbus_policy_defers_client_authorization_to_service(self):
        policy = (
            DESKTOP_TEMPLATES
            / "io.github.keyboardspecialist.BC250Control1.conf"
        ).read_text(encoding="utf-8")
        self.assertIn('<policy user="root">', policy)
        self.assertIn(
            '<allow own="io.github.keyboardspecialist.BC250Control1"/>',
            policy,
        )
        self.assertIn(
            '<allow send_destination="io.github.keyboardspecialist.BC250Control1"/>',
            policy,
        )
        self.assertNotIn("send_interface", policy)

    def test_governor_dbus_policy_is_root_only(self):
        power = (ROOT / "bc250-power.sh").read_text(encoding="utf-8")
        self.assertIn('<policy user="root">', power)
        self.assertEqual(power.count('<policy context="default">'), 1)
        self.assertNotIn('<allow send_interface=', power)
        self.assertIn(
            "grep -q '<policy context=\"default\">' \"$DBUS_POLICY\"",
            power,
        )

    def test_desktop_payload_and_readonly_handling_are_persistent(self):
        installer = DESKTOP_INSTALL.read_text(encoding="utf-8")
        repair = DESKTOP_REPAIR.read_text(encoding="utf-8")
        self.assertIn("/var/lib/bc250-control/.desktop-stage.", installer)
        self.assertIn("$STAGE/py_modules/bc250_control_service", installer)
        self.assertIn("$STAGE/py_modules/bc250_control", installer)
        self.assertIn("$STAGE/py_modules/tomli", installer)
        self.assertIn("$STAGE/py_modules/dbus_next", installer)
        self.assertIn("kpackagetool6 --type Plasma/Applet --upgrade", installer)
        self.assertNotIn("--show-info", installer)
        self.assertIn('plugin.get("Id") != sys.argv[2]', installer)
        self.assertIn(
            'metadata.get("X-Plasma-API-Minimum-Version") != "6.0"',
            installer,
        )
        self.assertIn("PAYLOAD_SWAPPED=1", installer)
        self.assertIn("trap restore_uninstall_readonly EXIT", installer)
        self.assertIn("READONLY_CHANGED=1", repair)
        self.assertIn("trap restore_readonly EXIT", repair)
        self.assertIn(
            "if [[ $READONLY_CHANGED -eq 1 ]]; then\n"
            "        /usr/bin/steamos-readonly enable",
            repair,
        )

    def test_isolated_entrypoint_imports_staged_service_and_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory) / "desktop"
            modules = payload / "py_modules"
            modules.mkdir(parents=True)
            shutil.copy2(
                ROOT / "desktop-control" / "service" / "bc250-control-service",
                payload / "bc250-control-service",
            )
            for source, name in (
                (
                    ROOT / "desktop-control" / "service" / "bc250_control_service",
                    "bc250_control_service",
                ),
                (ROOT / "backend" / "bc250_control", "bc250_control"),
                (ROOT / "backend" / "vendor" / "tomli", "tomli"),
                (ROOT / "desktop-control" / "vendor" / "dbus_next", "dbus_next"),
            ):
                shutil.copytree(source, modules / name)
            subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-c",
                    "import runpy; runpy.run_path("
                    + repr(str(payload / "bc250-control-service"))
                    + ", run_name='bc250_install_check')",
                ],
                check=True,
            )

    def test_desktop_component_is_kept_and_root_backed(self):
        persistence = (ROOT / "bc250-update-persistence.sh").read_text(
            encoding="utf-8"
        )
        storage = STORAGE.read_text(encoding="utf-8")
        for expected in (
            "COMPONENTS=(compute power cec aic desktop)",
            "/etc/systemd/system/bc250-control.service",
            "/etc/systemd/system/bc250-desktop-control-repair.service",
            "/etc/dbus-1/system.d/io.github.keyboardspecialist.BC250Control1.conf",
        ):
            self.assertIn(expected, persistence)
        self.assertNotIn("/usr/share/polkit-1/actions/", persistence)
        repair = DESKTOP_REPAIR.read_text(encoding="utf-8")
        self.assertIn(
            "/usr/share/polkit-1/actions/"
            "io.github.keyboardspecialist.bc250-control.policy",
            repair,
        )
        self.assertIn("bc250-control.service", storage)
        self.assertIn("bc250-desktop-control-repair.service", storage)

    def test_storage_without_terminal_prints_help(self):
        result = subprocess.run(
            ["bash", str(STORAGE)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Usage:", result.stderr)

    def test_storage_enablement_is_safe_with_nounset(self):
        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory) / "test.service"
            subprocess.run(
                [
                    "bash",
                    "-c",
                    'storage=$1; link=$2; set -- help; source "$storage" >/dev/null; '
                    'install() { :; }; install_enablement "$link" test.service',
                    "_",
                    str(STORAGE),
                    str(link),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(Path(os.readlink(str(link))), Path("../test.service"))

    def test_all_shell_entrypoints_parse(self):
        scripts = [
            "bc250-toolkit.sh",
            "bc250-storage.sh",
            "bc250-update-persistence.sh",
            "bc250-power.sh",
            "bc250-40cu.sh",
            "bc250-cec.sh",
            "aic8800/steamdeck-setup.sh",
            "aic8800/aic8800-ensure-modules.sh",
            "fetch-steamos-package.sh",
            "bc250-audio-fix/fetch-sources.sh",
            "bc250-audio-fix/build.sh",
            "bc250-audio-fix/prepare-kernel.sh",
            "bc250-audio-fix/patch-driver.sh",
            "decky-plugin/install.sh",
            "desktop-control/install.sh",
            "desktop-control/bc250-desktop-control-repair",
        ]
        subprocess.run(
            ["bash", "-n", *(str(ROOT / script) for script in scripts)],
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
