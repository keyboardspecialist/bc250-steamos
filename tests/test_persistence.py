import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORAGE = ROOT / "bc250-storage.sh"


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
            self.assertEqual(link.readlink(), Path("../test.service"))

    def test_all_shell_entrypoints_parse(self):
        scripts = [
            "bc250-storage.sh",
            "bc250-update-persistence.sh",
            "bc250-power.sh",
            "bc250-40cu.sh",
            "bc250-cec.sh",
            "aic8800/steamdeck-setup.sh",
            "decky-plugin/install.sh",
        ]
        subprocess.run(
            ["bash", "-n", *(str(ROOT / script) for script in scripts)],
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
