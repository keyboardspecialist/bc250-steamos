import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "coolercontrol/install.sh"
SERVICE = ROOT / "coolercontrol/bc250-coolercontrold.service"


class CoolerControlTests(unittest.TestCase):
    def test_installer_is_pinned_and_verifies_the_official_appimage(self):
        source = INSTALLER.read_text(encoding="utf-8")

        self.assertIn("VERSION=5.0.0", source)
        self.assertIn(
            "APPIMAGE_SHA256="
            "15c17f7a3990c21f2cc8cbbda5cde8ea6c8ecb63a79f982aa9fbedc308d3440b",
            source,
        )
        self.assertIn("gitlab.com/coolercontrol/coolercontrol/-/releases/$VERSION", source)
        self.assertIn('[[ "$version" == "coolercontrold $VERSION" ]]', source)
        self.assertIn("Root-staged AppImage failed integrity", source)
        self.assertIn("payload_integrity_valid", source)
        self.assertIn('systemctl restart "$SERVICE_NAME"', source)
        self.assertNotIn("curl |", source)

    def test_service_uses_persistent_configuration_and_web_ui_daemon(self):
        service = SERVICE.read_text(encoding="utf-8")

        self.assertIn("CC_CONFIG_DIR=/var/lib/bc250-control/coolercontrol/config", service)
        self.assertIn("CC_DATA_DIR=/var/lib/bc250-control/coolercontrol/data", service)
        self.assertIn("CoolerControlD-x86_64.AppImage", service)
        self.assertIn("Type=notify", service)

    def test_status_reports_absent_state_without_root(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'installer=$1; root=$2; set -- help; source "$installer" >/dev/null; '
                    'ROOT_DIR=$root/root; RUNTIME_DIR=$ROOT_DIR/runtime; '
                    'APPIMAGE=$RUNTIME_DIR/$APPIMAGE_NAME; MARKER=$RUNTIME_DIR/.bc250-managed; '
                    'SERVICE_UNIT=$root/service; SERVICE_WANTS=$root/wants; '
                    'SERVICE_DROPIN=$root/dropin; KEEP_FILE=$root/keep; '
                    'DESKTOP_FILE=$root/launcher; show_status',
                    "_",
                    str(INSTALLER),
                    directory,
                ],
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("state: not-installed", result.stdout)

    def test_desktop_launcher_is_owned_and_opens_local_web_ui(self):
        with tempfile.TemporaryDirectory() as directory:
            launcher = Path(directory) / "applications/coolercontrol.desktop"
            subprocess.run(
                [
                    "bash",
                    "-c",
                    'installer=$1; launcher=$2; set -- help; '
                    'source "$installer" >/dev/null; DESKTOP_FILE=$launcher; '
                    'install_desktop_launcher; desktop_owned',
                    "_",
                    str(INSTALLER),
                    str(launcher),
                ],
                check=True,
            )
            content = launcher.read_text(encoding="utf-8")
            self.assertIn("http://localhost:11987", content)
            self.assertIn("BC-250 toolkit managed CoolerControl launcher", content)

    def test_uninstall_stops_daemon_before_restoring_automatic_fan_control(self):
        source = INSTALLER.read_text(encoding="utf-8")
        uninstall = source[source.index("uninstall_root() {") : source.index("install_all() {")]

        self.assertLess(
            uninstall.index('systemctl disable --now "$SERVICE_NAME"'),
            uninstall.index("restore_automatic_fan_control"),
        )
        self.assertIn("printf '2\\n'", source)
        self.assertIn('bash "$PERSISTENCE_SH" remove coolercontrol', uninstall)

    def test_scripts_parse(self):
        subprocess.run(
            ["bash", "-n", str(INSTALLER)],
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
