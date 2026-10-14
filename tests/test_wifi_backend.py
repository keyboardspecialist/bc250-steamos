import configparser
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("wifi_backend", ROOT / "scripts/wifi-backend.py")
wifi = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wifi)


class WifiBackendTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config_dir = self.root / "NetworkManager/conf.d"
        self.config_dir.mkdir(parents=True)
        self.valve = self.config_dir / "99-valve-wifi-backend.conf"
        self.lock = self.config_dir / "zz-bc250-wifi-backend.conf"
        self.service = self.root / "systemd/NetworkManager.service.d/90-bc250-wifi-backend.conf"
        self.keep = self.root / "keep/bc250-wifi.conf"
        self.switch = self.root / "switch-helper"
        self.switch.write_text("helper", encoding="utf-8")
        self.original = "# User Wi-Fi settings\n[connection]\nwifi.powersave=3\n[device]\nwifi.backend=iwd\n"
        self.valve.write_text(self.original, encoding="utf-8")
        self.active = "iwd"
        self.calls = []
        for name, value in (
            ("VALVE_CONFIG", self.valve),
            ("LOCK_CONFIG", self.lock),
            ("SERVICE_CONFIG", self.service),
            ("KEEP_FILE", self.keep),
            ("SWITCH_HELPER", self.switch),
        ):
            patch = mock.patch.object(wifi, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(wifi.os, "geteuid", return_value=0)
        patch.start()
        self.addCleanup(patch.stop)
        patch = mock.patch.object(wifi, "run", side_effect=self.fake_run)
        self.runner = patch.start()
        self.addCleanup(patch.stop)
        patch = mock.patch.object(wifi, "persist", side_effect=self.persist)
        self.persistence = patch.start()
        self.addCleanup(patch.stop)

    def fake_run(self, *args, check=True):
        self.calls.append(args)
        output = ""
        code = 0
        if args == ("NetworkManager", "--print-config"):
            config = configparser.ConfigParser(interpolation=None)
            config.read(sorted(self.config_dir.glob("*.conf")))
            stream = io.StringIO()
            config.write(stream)
            output = stream.getvalue()
        elif args[:2] == ("systemctl", "show"):
            output = "loaded\n"
        elif args[:2] == ("systemctl", "is-active"):
            code = 0 if args[-1] == f"{self.active}.service" else 3
        elif args[:2] == ("bash", str(self.switch)):
            self.active = "wpa_supplicant" if args[-1] == "iwd" else "iwd"
        return subprocess.CompletedProcess(args, code, stdout=output, stderr="")

    def persist(self, action):
        if action == "install":
            self.keep.parent.mkdir(exist_ok=True)
            self.keep.write_text(
                wifi.KEEP_HEADER + str(self.lock) + "\n" + str(self.service) + "\n",
                encoding="utf-8",
            )
        elif action == "remove":
            self.keep.unlink(missing_ok=True)

    def configure(self, action, backend=None):
        with contextlib.redirect_stdout(io.StringIO()):
            wifi.configure(action, backend)

    def test_lock_survives_steam_backend_rewrite_without_restarting_working_wifi(self):
        self.configure("lock", "iwd")
        self.assertTrue(self.lock.exists())
        self.assertTrue(self.keep.exists())
        self.assertIn("Wants=iwd.service\nAfter=iwd.service\n", self.service.read_text(encoding="utf-8"))
        self.assertIn(("systemctl", "daemon-reload"), self.calls)
        self.assertEqual(self.valve.read_text(encoding="utf-8"), self.original)
        self.assertFalse(any(args[0] == "bash" for args in self.calls))

        # Steam's Game Mode preference rewrites Valve's file after the lock is set.
        self.valve.write_text("[device]\nwifi.backend=wpa_supplicant\n", encoding="utf-8")
        self.assertEqual(wifi.effective_backend(), "iwd")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            wifi.show_status(as_json=True)
        status = json.loads(output.getvalue())
        self.assertTrue(status["lock_effective"])
        self.assertTrue(status["update_protected"])
        self.assertEqual(status["service_binding"], "iwd")
        self.assertEqual(status["active_services"], ["iwd"])

    def test_switch_preserves_power_settings_and_stops_the_previous_backend(self):
        self.configure("lock", "wpa_supplicant")
        text = self.valve.read_text(encoding="utf-8")
        self.assertIn("# User Wi-Fi settings\n", text)
        self.assertIn("[connection]\nwifi.powersave=3\n", text)
        self.assertEqual(wifi.effective_backend(), "wpa_supplicant")
        self.assertEqual(self.active, "wpa_supplicant")
        self.assertIn(("bash", str(self.switch), "restart_units", "iwd"), self.calls)

    def test_unlocked_selection_has_no_override_or_keep_list(self):
        self.configure("set", "wpa_supplicant")
        self.assertEqual(wifi.effective_backend(), "wpa_supplicant")
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.keep.exists())
        self.assertFalse(self.service.exists())
        self.persistence.assert_not_called()

    def test_set_updates_an_existing_lock(self):
        self.configure("lock", "iwd")
        self.configure("set", "wpa_supplicant")
        self.assertEqual(wifi.locked_backend(), "wpa_supplicant")
        self.assertEqual(wifi.service_binding(), "wpa_supplicant")
        self.assertTrue(self.keep.exists())

    def test_unlock_retains_selected_backend_after_steam_changed_underlying_config(self):
        self.configure("lock", "iwd")
        self.valve.write_text("[connection]\nwifi.powersave=2\n[device]\nwifi.backend=wpa_supplicant\n", encoding="utf-8")
        self.calls.clear()
        self.configure("unlock")
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.keep.exists())
        self.assertFalse(self.service.exists())
        self.assertEqual(wifi.effective_backend(), "iwd")
        self.assertIn("wifi.powersave=2", self.valve.read_text(encoding="utf-8"))
        self.assertFalse(any(args[0] == "bash" for args in self.calls))

    def test_foreign_lock_and_symlink_are_rejected_before_modification(self):
        for content in ("[device]\nwifi.backend=iwd\n", "symlink"):
            with self.subTest(content=content):
                self.lock.unlink(missing_ok=True)
                if content == "symlink":
                    self.lock.symlink_to(self.valve)
                else:
                    self.lock.write_text(content, encoding="utf-8")
                with self.assertRaises(wifi.WifiError):
                    self.configure("lock", "wpa_supplicant")
                self.assertEqual(self.valve.read_text(encoding="utf-8"), self.original)
        self.persistence.assert_not_called()

    def test_conflicting_override_rolls_back_all_changed_files(self):
        # This per-file precedence conflict must be detected before a network restart.
        foreign = self.config_dir / "zzz-operator.conf"
        foreign.write_text("[device]\nwifi.backend=wpa_supplicant\n", encoding="utf-8")
        with self.assertRaisesRegex(wifi.WifiError, "overrides"):
            self.configure("lock", "iwd")
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.keep.exists())
        self.assertFalse(self.service.exists())
        self.assertEqual(self.valve.read_text(encoding="utf-8"), self.original)
        self.assertFalse(any(args[0] == "bash" for args in self.calls))

    def test_failed_persistence_restores_config_and_existing_file_mode(self):
        self.valve.chmod(0o600)
        self.persistence.side_effect = RuntimeError("persistence failed")
        with self.assertRaisesRegex(RuntimeError, "persistence failed"):
            self.configure("lock", "wpa_supplicant")
        self.assertEqual(self.valve.read_text(encoding="utf-8"), self.original)
        self.assertEqual(self.valve.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.lock.exists())

    def test_missing_backend_service_leaves_configuration_untouched(self):
        real_runner = self.fake_run

        def missing(*args, **kwargs):
            if args[:2] == ("systemctl", "show"):
                return subprocess.CompletedProcess(args, 0, stdout="not-found\n", stderr="")
            return real_runner(*args, **kwargs)

        self.runner.side_effect = missing
        with self.assertRaisesRegex(wifi.WifiError, "not available"):
            self.configure("lock", "wpa_supplicant")
        self.assertEqual(self.valve.read_text(encoding="utf-8"), self.original)
        self.assertFalse(self.lock.exists())

    def test_foreign_service_binding_is_rejected_before_modification(self):
        self.service.parent.mkdir(parents=True)
        self.service.write_text("[Unit]\nRequires=custom.service\n", encoding="utf-8")
        with self.assertRaisesRegex(wifi.WifiError, "Unrecognized Wi-Fi service binding"):
            self.configure("lock", "iwd")
        self.assertEqual(self.valve.read_text(encoding="utf-8"), self.original)
        self.assertFalse(self.lock.exists())

    @unittest.skipUnless(shutil.which("NetworkManager"), "NetworkManager is not installed")
    def test_real_networkmanager_keeps_lock_when_steam_rewrites_its_configuration(self):
        main_config = self.root / "NetworkManager.conf"
        main_config.write_text("[main]\nplugins=keyfile\n", encoding="utf-8")
        system_config = self.root / "system-config"
        system_config.mkdir()
        for backend, other in (("iwd", "wpa_supplicant"), ("wpa_supplicant", "iwd")):
            with self.subTest(backend=backend):
                self.lock.write_text(wifi.lock_text(backend), encoding="utf-8")
                self.valve.write_text(f"[device]\nwifi.backend={other}\n", encoding="utf-8")
                result = subprocess.run(
                    [
                        "NetworkManager", "--print-config",
                        f"--config={main_config}",
                        f"--config-dir={self.config_dir}",
                        f"--system-config-dir={system_config}",
                        f"--intern-config={self.root / 'intern.conf'}",
                    ],
                    check=True, capture_output=True, text=True, timeout=10,
                )
                parser = configparser.ConfigParser(interpolation=None)
                parser.read_string(result.stdout)
                self.assertEqual(parser.get("device", "wifi.backend"), backend)

    def test_invalid_backend_cannot_reach_privileged_operations(self):
        with self.assertRaises(wifi.WifiError):
            self.configure("lock", "invalid")
        self.assertEqual(self.calls, [])
        result = subprocess.run(
            ["bash", str(ROOT / "bc250-wifi-backend.sh"), "lock", "invalid"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Usage:", result.stderr)

    def test_backend_insert_into_absent_or_existing_device_section(self):
        for original in (
            "",
            "# Comment\n[connection]\nwifi.powersave=3",
            "[device]\nmanaged=true\n[connection]\nwifi.powersave=2\n",
        ):
            with self.subTest(original=original):
                updated = wifi.update_backend(original, "iwd")
                parser = configparser.ConfigParser(interpolation=None)
                parser.read_string(updated)
                self.assertEqual(parser.get("device", "wifi.backend"), "iwd")
                if "wifi.powersave" in original:
                    self.assertIn(original.split("wifi.powersave=")[1].strip(), updated)


class WifiPersistenceTests(unittest.TestCase):
    def test_wifi_keep_list_protects_only_owned_override_and_shared_infrastructure(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [
                    "bash", "-c",
                    'script=$1; keep=$2; set -- help; source "$script" >/dev/null; '
                    'KEEP_DIR=$keep; write_keep_file wifi',
                    "_", str(ROOT / "bc250-update-persistence.sh"), directory,
                ],
                check=True, capture_output=True, text=True,
            )
            keep = (Path(directory) / "bc250-wifi.conf").read_text(encoding="utf-8")
        self.assertIn("/etc/NetworkManager/conf.d/zz-bc250-wifi-backend.conf\n", keep)
        self.assertIn("/etc/systemd/system/NetworkManager.service.d/90-bc250-wifi-backend.conf\n", keep)
        self.assertNotIn("99-valve-wifi-backend.conf", keep)
        self.assertNotIn("system-connections", keep)
        self.assertIn("bc250-persistence-recovery.service", keep)
        self.assertIn("wifi", result.stdout)

    def test_protect_all_does_not_recreate_an_unlocked_wifi_keep_list(self):
        with tempfile.TemporaryDirectory() as directory:
            keeper = Path(directory) / "bc250-wifi.conf"
            keeper.write_text(wifi.KEEP_HEADER + "/etc/obsolete-wifi-lock\n", encoding="utf-8")
            subprocess.run(
                [
                    "bash", "-c",
                    'script=$1; keep=$2; set -- help; source "$script" >/dev/null; '
                    'require_root() { :; }; install_storage() { :; }; '
                    'component_has_state() { return 1; }; COMPONENTS=(wifi); KEEP_DIR=$keep; '
                    'LEGACY_KEEP_FILE="$keep/legacy.conf"; install_keep_list all',
                    "_", str(ROOT / "bc250-update-persistence.sh"), directory,
                ],
                check=True, capture_output=True, text=True,
            )
            self.assertFalse(keeper.exists())


if __name__ == "__main__":
    unittest.main()
