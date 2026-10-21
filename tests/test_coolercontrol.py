import hashlib
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

        self.assertIn("VERSION=5.1.1", source)
        self.assertIn(
            "APPIMAGE_SHA256="
            "89d35570b098c885673afda56d3f38f830286b42f61051e0194e864d21495130",
            source,
        )
        self.assertIn("gitlab.com/coolercontrol/coolercontrol/-/releases/$VERSION", source)
        self.assertIn('[[ "$version" == "coolercontrold $VERSION" ]]', source)
        self.assertIn("Root-staged AppImage failed integrity", source)
        self.assertIn("payload_integrity_valid", source)
        self.assertIn('systemctl restart "$SERVICE_NAME"', source)
        self.assertNotIn("curl |", source)
        self.assertIn("curl --proto '=https' --tlsv1.2", source)
        self.assertIn("LEGACY_VERSION=5.0.0", source)
        self.assertIn(
            "LEGACY_APPIMAGE_SHA256="
            "15c17f7a3990c21f2cc8cbbda5cde8ea6c8ecb63a79f982aa9fbedc308d3440b",
            source,
        )

    def test_known_payloads_require_matching_version_hash_and_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "daemon"
            marker = root / "marker"
            current = b"current verified fixture"
            legacy = b"legacy verified fixture"
            current_hash = hashlib.sha256(current).hexdigest()
            legacy_hash = hashlib.sha256(legacy).hexdigest()
            cases = (
                (current, "5.1.1", current_hash, "", 0, 0),
                (legacy, "5.0.0", legacy_hash, "", 0, 1),
                (legacy, "5.1.1", current_hash, "", 1, 1),
                (current, "5.0.0", legacy_hash, "", 1, 1),
                (legacy, "4.0.0", legacy_hash, "", 1, 1),
                (current, "5.1.1", current_hash, "version=5.0.0\n", 1, 1),
            )
            for content, version, digest, extra, known, installed in cases:
                with self.subTest(version=version, digest=digest, extra=extra):
                    payload.write_bytes(content)
                    marker.write_text(
                        "# BC-250 toolkit managed CoolerControl daemon.\n"
                        f"version={version}\nsha256={digest}\n{extra}"
                    )
                    result = subprocess.run(
                        ["bash", "-c",
                         'installer=$1; payload=$2; marker=$3; current=$4; legacy=$5; '
                         'set -- help; source "$installer" >/dev/null; '
                         'APPIMAGE=$payload; MARKER=$marker; APPIMAGE_SHA256=$current; '
                         'LEGACY_APPIMAGE_SHA256=$legacy; '
                         'protected_root_file() { [[ -f "$1" && ! -L "$1" ]]; }; '
                         'if known_payload_integrity_valid; then echo known=0; else echo known=1; fi; '
                         'if payload_integrity_valid; then echo installed=0; else echo installed=1; fi',
                         "_", str(INSTALLER), str(payload), str(marker),
                         current_hash, legacy_hash],
                        check=True, capture_output=True, text=True,
                    )
                    self.assertEqual(result.stdout, f"known={known}\ninstalled={installed}\n")

    def test_upgrade_snapshots_preserve_custom_settings_without_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config"
            data = root / "data/plugins/custom"
            config.mkdir()
            data.mkdir(parents=True)
            settings = b'[[custom_sensors]]\nid = "custom-one"\nmetric = "RPM"\n'
            (config / "config.toml").write_bytes(settings)
            (config / "config-ui.json").write_text('{"label":"My fan"}\n')
            (data / "settings.json").write_text('{"custom":true}\n')
            result = subprocess.run(
                ["bash", "-c",
                 'installer=$1; root=$2; set -- help; source "$installer" >/dev/null; '
                 'ROOT_DIR=$root; '
                 'protected_root_directory() { [[ -d "$1" && ! -L "$1" ]]; }; '
                 'install() { local -a args=(); while (($#)); do '
                 'case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; '
                 'done; command install "${args[@]}"; }; '
                 'backup_configuration_before_upgrade; backup_configuration_before_upgrade',
                 "_", str(INSTALLER), str(root)],
                check=True, capture_output=True, text=True,
            )
            snapshots = sorted((root / "backups").glob("pre-5.1.1.*"))
            self.assertEqual(len(snapshots), 2, result.stdout)
            self.assertEqual((root / "backups").stat().st_mode & 0o777, 0o700)
            for snapshot in snapshots:
                self.assertEqual(snapshot.stat().st_mode & 0o777, 0o700)
                self.assertTrue((snapshot / ".complete").is_file())
                self.assertEqual((snapshot / "config/config.toml").read_bytes(), settings)
                self.assertEqual(
                    (snapshot / "data/plugins/custom/settings.json").read_text(),
                    '{"custom":true}\n',
                )
                self.assertEqual(
                    (snapshot / "config/config-ui.json").read_bytes(),
                    (config / "config-ui.json").read_bytes(),
                )
            self.assertEqual((config / "config.toml").read_bytes(), settings)

    def test_legacy_uninstall_preserves_configuration_and_stops_before_fan_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime"
            runtime.mkdir()
            config = root / "config"
            config.mkdir()
            (config / "config.toml").write_text('custom = "preserved"\n')
            payload = b"legacy fixture"
            digest = hashlib.sha256(payload).hexdigest()
            (runtime / "daemon").write_bytes(payload)
            (runtime / "marker").write_text(
                "# BC-250 toolkit managed CoolerControl daemon.\n"
                f"version=5.0.0\nsha256={digest}\n"
            )
            (root / "service").write_text("# BC-250 toolkit managed CoolerControl service.\n")
            (root / "persistence.sh").write_text("exit 0\n")
            result = subprocess.run(
                ["bash", "-c",
                 'installer=$1; root=$2; digest=$3; set -- help; source "$installer" >/dev/null; '
                 'ROOT_DIR=$root; RUNTIME_DIR=$root/runtime; APPIMAGE=$RUNTIME_DIR/daemon; '
                 'MARKER=$RUNTIME_DIR/marker; SERVICE_UNIT=$root/service; '
                 'SERVICE_WANTS=$root/wants; SERVICE_DROPIN=$root/dropin; '
                 'PERSISTENCE_SH=$root/persistence.sh; LEGACY_APPIMAGE_SHA256=$digest; '
                 'require_root() { :; }; '
                 'protected_root_file() { [[ -f "$1" && ! -L "$1" ]]; }; '
                 'systemctl() { printf "%s\\n" "$*" >> "$root/actions"; '
                 'case "$1" in is-active|is-enabled) return 1 ;; esac; }; '
                 'restore_automatic_fan_control() { echo restore-fans >> "$root/actions"; }; '
                 'uninstall_root', "_", str(INSTALLER), str(root), digest],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(runtime.exists())
            self.assertFalse((root / "service").exists())
            self.assertEqual((config / "config.toml").read_text(), 'custom = "preserved"\n')
            actions = (root / "actions").read_text()
            self.assertLess(actions.index("disable --now"), actions.index("restore-fans"))

    def test_backup_refuses_symlink_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "outside").mkdir()
            (root / "backups").symlink_to(root / "outside")
            result = subprocess.run(
                ["bash", "-c",
                 'installer=$1; root=$2; set -- help; source "$installer" >/dev/null; '
                 'ROOT_DIR=$root; backup_configuration_before_upgrade',
                 "_", str(INSTALLER), str(root)], capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing unsafe configuration backup directory", result.stderr)
            self.assertEqual(list((root / "outside").iterdir()), [])

    def test_upgrade_stops_and_backs_up_before_payload_swap(self):
        source = INSTALLER.read_text(encoding="utf-8")
        install = source[source.index("install_root() {\n    require_root") : source.index("safe_dropin() {")]
        self.assertIn("known_payload_integrity_valid", install)
        self.assertLess(install.index('systemctl stop "$SERVICE_NAME"'),
                        install.index("backup_configuration_before_upgrade"))
        self.assertLess(install.index("backup_configuration_before_upgrade"),
                        install.index('mv -f "$app_tmp" "$APPIMAGE"'))
        uninstall = source[source.index("uninstall_root() {") : source.index("install_all() {")]
        self.assertIn("known_payload_integrity_valid", uninstall)
        self.assertNotIn('rm -rf "$ROOT_DIR/config"', uninstall)
        self.assertNotIn('rm -rf "$ROOT_DIR/data"', uninstall)

    def test_documentation_explains_authenticated_shared_port_and_migration(self):
        readme = (ROOT / "coolercontrol/README.md").read_text()
        self.assertIn("11987", readme)
        self.assertIn("11988 is removed", readme)
        self.assertIn("authentication", readme)
        self.assertIn("pre-5.1.1", readme)
        self.assertIn("custom settings", readme)

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
