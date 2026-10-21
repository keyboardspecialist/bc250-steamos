import asyncio
import fcntl
import hashlib
import json
import os
import pwd
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import bc250_control.backend as module
from bc250_control import ToolkitBackend
from bc250_control.backend import CommandError
from bc250_control.parity import CLI_SECTION_IDS, voltage_arguments


class TelemetryParityTests(unittest.IsolatedAsyncioTestCase):
    async def test_snapshot_advertises_backend_api_separately_from_hardware_readiness(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/user/toolkit")
        backend._user_script_available = MagicMock(return_value=False)
        backend._cpu_helper_available = MagicMock(return_value=False)
        for method in ("get_cu_status", "get_power_status", "get_gpu_status", "get_cpu_status", "get_cec_status"):
            setattr(backend, method, AsyncMock(return_value={}))
        backend.get_ram_status = AsyncMock(return_value={"available": False})
        backend.get_hdmi_audio_status = AsyncMock(return_value={"available": False})
        snapshot = await backend._get_snapshot()
        self.assertEqual(snapshot["toolkit"]["controlApiVersion"], 1)
        self.assertIn("gpu-voltage-curve", snapshot["toolkit"]["controlCapabilities"])
        self.assertIn("cpu-oc-update", snapshot["toolkit"]["controlCapabilities"])
        self.assertFalse(snapshot["toolkit"]["cpuControlAvailable"])
        self.assertFalse(snapshot["toolkit"]["available"])

    async def test_read_only_all_channels_roles_and_lock_free_polling(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hwmons = root / "hwmon"
            hwmons.mkdir()

            def chip(index, name, slot, product, readings):
                device = root / slot
                device.mkdir()
                (device / "vendor").write_text("0x1002")
                (device / "device").write_text(product)
                hwmon = hwmons / f"hwmon{index}"
                hwmon.mkdir()
                (hwmon / "device").symlink_to(device)
                (hwmon / "name").write_text(name)
                for key, value in readings.items():
                    (hwmon / key).write_text(value)

            chip(0, "amdgpu", "0000:01:00.0", "0x9999", {
                "temp1_input": "85000", "temp1_label": "edge",
            })
            chip(1, "amdgpu", "0000:03:00.0", "0x13fe", {
                "temp1_input": "72000", "temp1_label": "junction",
                "temp2_input": "81000", "temp2_label": "mem",
                "temp3_input": "41000", "temp3_label": "edge",
                "in0_input": "950", "in0_label": "vddgfx",
                "power1_average": "125500000", "fan1_input": "0",
                "curr1_input": "1250", "temp4_input": "nan",
                "temp5_input": "999000", "power2_input": "inf",
                "in1_input": "-1", "fan2_input": "broken",
                "power3_input": "0", "temp6_input": "0",
            })
            chip(2, "k10temp", "cpu", "", {
                "temp1_input": "55000", "temp1_label": "Tctl",
            })
            backend = object.__new__(ToolkitBackend)
            backend._mutation_lock = asyncio.Lock()
            backend._cpu_current_mhz = MagicMock(return_value=4000)
            backend._active_gpu_mhz = MagicMock(return_value=1000)
            backend._exec = AsyncMock()
            backend._cpu_tool = AsyncMock()
            async with backend._mutation_lock:
                with patch.object(module, "HWMON_PATH", hwmons):
                    telemetry = await asyncio.wait_for(backend.get_telemetry(), 0.5)
            self.assertEqual(telemetry["cpuTemp"], 55)
            self.assertEqual(telemetry["gpuTemp"], 41)
            self.assertEqual(telemetry["cpuClock"], 4000)
            values = {(sensor["label"], sensor["unit"]): sensor["value"]
                      for sensor in telemetry["sensors"]}
            self.assertEqual(values[("vddgfx", "mV")], 950)
            self.assertEqual(values[("power1 (average)", "W")], 125.5)
            self.assertEqual(values[("fan1", "RPM")], 0)
            self.assertEqual(values[("curr1", "A")], 1.25)
            self.assertEqual(values[("power3", "W")], 0)
            self.assertEqual(len(telemetry["sensors"]), 11)
            self.assertEqual(len({s["key"] for s in telemetry["sensors"]}), 11)
            backend._exec.assert_not_called()
            backend._cpu_tool.assert_not_called()

    async def test_missing_or_zero_primary_readings_are_null(self):
        backend = object.__new__(ToolkitBackend)
        backend._hwmon_sensors = MagicMock(return_value=[
            {"key": "/missing/amdgpu/temp1_input", "device": "amdgpu@gpu",
             "label": "edge", "value": 0, "unit": "°C"},
        ])
        backend._cpu_current_mhz = MagicMock(return_value=0)
        backend._active_gpu_mhz = MagicMock(return_value=None)
        telemetry = await backend.get_telemetry()
        for field in ("cpuClock", "gpuClock", "cpuTemp", "gpuTemp"):
            self.assertIsNone(telemetry[field])

    def test_junction_or_memory_is_never_the_primary_gpu_temperature(self):
        backend = object.__new__(ToolkitBackend)
        backend._is_bc250_device = MagicMock(return_value=True)
        sensors = [{"key": f"/gpu/amdgpu/temp{i}_input", "device": "amdgpu@gpu",
                    "label": label, "value": 70, "unit": "°C"}
                   for i, label in enumerate(("junction", "mem"))]
        self.assertEqual(backend._primary_temperatures(sensors), (None, None))

    async def test_power_snapshot_preserves_legacy_temperatures_and_adds_sensors(self):
        backend = object.__new__(ToolkitBackend)
        sensors = [{"key": "/pci/amdgpu/temp1_input", "device": "amdgpu@pci",
                    "label": "edge", "value": 42, "unit": "°C"}]
        backend._hwmon_sensors = MagicMock(return_value=sensors)
        backend._service = AsyncMock(return_value={"enabled": "disabled", "active": "inactive"})
        backend._cpu_governor = MagicMock(return_value="schedutil")
        backend._cpu_current_mhz = MagicMock(return_value=1000)
        power = await backend.get_power_status()
        self.assertEqual(power["sensors"], sensors)
        self.assertEqual(power["temperatures"], [{"device": "amdgpu", "label": "edge", "celsius": 42}])

    def test_clock_selects_bc250_instead_of_first_other_gpu(self):
        backend = object.__new__(ToolkitBackend)
        paths = ["/test/card0/device/pp_dpm_sclk", "/test/card1/device/pp_dpm_sclk"]
        values = {
            paths[0]: "0: 900Mhz *", paths[1]: "0: 1500Mhz *",
            "/test/card0/device/vendor": "0x1002", "/test/card0/device/device": "0x9999",
            "/test/card1/device/vendor": "0x1002", "/test/card1/device/device": "0x13fe",
        }
        backend._read = MagicMock(side_effect=lambda path, default="": values.get(str(path), default))
        with patch.object(module.glob, "glob", return_value=paths):
            self.assertEqual(backend._active_gpu_mhz(), 1500)
            values["/test/card1/device/device"] = "0x9999"
            self.assertIsNone(backend._active_gpu_mhz())


class MetricsParityTests(unittest.IsolatedAsyncioTestCase):
    async def test_cli_decoder_states_hash_revision_and_module_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            updates = root / "test-kernel/updates"
            updates.mkdir(parents=True)
            binary = updates / "amdgpu.ko.zst"
            marker = updates / ".bc250-metrics-fix"
            backend = object.__new__(ToolkitBackend)
            backend._service = AsyncMock(return_value={"enabled": "not-found", "active": "inactive"})
            backend._exec = AsyncMock(return_value=(0, str(binary), ""))
            with patch.object(module, "AMDGPU_MODULES_ROOT", root), patch.object(
                module.os, "uname", return_value=SimpleNamespace(release="test-kernel")
            ), patch.object(module.asyncio, "to_thread", None, create=True):
                self.assertEqual((await backend._cpu_unlock_metrics_status())["state"], "not-installed")
                binary.write_bytes(b"matching-module")
                self.assertEqual((await backend._cpu_unlock_metrics_status())["state"], "legacy-override")
                digest = hashlib.sha256(binary.read_bytes()).hexdigest()
                marker.write_text(f"{digest} smu-8core-metrics-r1\n")
                status = await backend._cpu_unlock_metrics_status()
                self.assertEqual(status["state"], "compatible")
                self.assertEqual(status["revision"], "smu-8core-metrics-r1")
                self.assertEqual(status["service"]["enabled"], "not-found")
                backend._exec.return_value = (0, "/usr/lib/modules/kernel/amdgpu.ko.zst", "")
                self.assertEqual((await backend._cpu_unlock_metrics_status())["state"], "invalid")
                backend._exec.return_value = (0, str(binary), "")
                marker.write_text(f"{digest} old-revision\n")
                self.assertEqual((await backend._cpu_unlock_metrics_status())["state"], "invalid")
                marker.write_text(f"{'0' * 64} smu-8core-metrics-r1\n")
                self.assertEqual((await backend._cpu_unlock_metrics_status())["state"], "invalid")
                self.assertTrue(all(call.args[0][0] == module.MODINFO for call in backend._exec.call_args_list))

    def test_metrics_action_requires_eight_cores_and_automatic_guard(self):
        for topology in ("locked", "unavailable", "unexpected"):
            status = ToolkitBackend._cpu_unlock_action_status(
                "metrics-enable", device_present=True, topology_state=topology,
                payload_available=True, service_enabled=False, mode="none",
                guard={"state": "none", "currentBoot": False},
            )
            self.assertFalse(status["available"])
            self.assertIn("eight-cores-required", status["blockers"])
        status = ToolkitBackend._cpu_unlock_action_status(
            "uninstall", device_present=False, topology_state="unavailable",
            payload_available=True, service_enabled=False, mode="none",
            guard={"state": "automatic", "currentBoot": True},
        )
        self.assertFalse(status["available"])
        self.assertIn("automatic-reboot-pending", status["blockers"])


class MutationParityTests(unittest.IsolatedAsyncioTestCase):
    async def test_orphaned_metrics_payload_keeps_full_uninstall_available(self):
        backend = object.__new__(ToolkitBackend)
        backend._service = AsyncMock(return_value={"enabled": "disabled", "active": "inactive"})
        backend._cpu_unlock_efi_status = AsyncMock(return_value={"installed": False, "partial": False})
        backend._cpu_unlock_metrics_status = AsyncMock(return_value={"state": "not-installed", "service": {"enabled": "disabled", "active": "inactive"}})
        backend._cpu_topology = MagicMock(return_value={"topologyState": "locked", "physicalCores": 6})
        backend._cpu_unlock_guard = MagicMock(return_value={"state": "clear", "currentBoot": False})
        backend._bc250_present_secure = MagicMock(return_value=True)
        backend._cpu_unlock_payload_available = MagicMock(return_value=True)
        backend._cpu_unlock_off_payload_available = MagicMock(return_value=True)
        backend._trusted_root_file = MagicMock(return_value=False)
        backend._cpu_unlock_persistent = MagicMock(return_value=False)
        backend._cpu_unlock_cleanup_payload_path = MagicMock(return_value=Path("/trusted"))
        backend._cpu_unlock_metrics_payload_path = MagicMock(return_value=Path("/trusted"))
        backend._path_represented = MagicMock(side_effect=lambda path: path == Path("/var/lib/bc250-control/smu-8core-metrics"))
        status = await backend.get_cpu_unlock_status()
        self.assertTrue(status["actions"]["uninstall"]["available"])
        backend._path_represented = MagicMock(return_value=False)
        status = await backend.get_cpu_unlock_status()
        self.assertFalse(status["actions"]["uninstall"]["available"])
        self.assertIn("not-installed", status["actions"]["uninstall"]["blockers"])

    async def test_load_targets_match_cli_five_percent_floor(self):
        backend = object.__new__(ToolkitBackend)
        backend._update_gpu_config = AsyncMock()
        for low, high in ((1, 80), (4, 99), (5, 100), (80, 5), (True, 80)):
            with self.subTest(low=low, high=high), self.assertRaises(CommandError):
                await backend.set_custom_load_target(low, high)
        backend._update_gpu_config.assert_not_called()

    async def test_cli_takes_same_flock_without_nested_deadlock(self):
        with tempfile.TemporaryDirectory() as directory:
            account = pwd.getpwuid(os.getuid())
            backend = ToolkitBackend(account.pw_name, account.pw_dir,
                                     lock_path=Path(directory) / "backend.lock")
            calls = []

            async def cli(*args, **kwargs):
                descriptor = backend._open_backend_lock()
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    calls.append(args)
                finally:
                    os.close(descriptor)

            backend._cpu_tool = cli
            await asyncio.wait_for(backend.gpu_voltage_action("edit", 1000, 850, 1100), 0.5)
            await asyncio.wait_for(backend.reset_gpu_ramp(), 0.5)
            self.assertEqual(calls, [("gpu-volt", "edit", "1000", "1100", "850"), ("ramp", "reset")])

    async def test_cancellation_waits_for_cli_transaction(self):
        backend = object.__new__(ToolkitBackend)
        backend._mutation_lock = asyncio.Lock()
        started, finish = asyncio.Event(), asyncio.Event()

        async def cli(*args, **kwargs):
            started.set()
            await finish.wait()

        backend._cpu_tool = cli
        task = asyncio.create_task(backend.gpu_voltage_action("reset", 0, 0, 0))
        await started.wait()
        task.cancel()
        await asyncio.sleep(0)
        self.assertFalse(task.done())
        self.assertTrue(backend._mutation_lock.locked())
        task.cancel()
        await asyncio.sleep(0)
        self.assertFalse(task.done())
        finish.set()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertFalse(backend._mutation_lock.locked())

    async def test_cpu_update_rejects_untrusted_bundle_without_executing(self):
        with tempfile.TemporaryDirectory() as directory:
            account = pwd.getpwuid(os.getuid())
            backend = ToolkitBackend(account.pw_name, account.pw_dir,
                                     lock_path=Path(directory) / "backend.lock")
            backend._cpu_helper_path = MagicMock(return_value=None)
            backend._exec = AsyncMock()
            with self.assertRaisesRegex(CommandError, "missing or unsafe"):
                await backend.cpu_oc_action("update", 0, 0, 0)
            backend._exec.assert_not_called()

    async def test_new_unlock_actions_recheck_guards_and_metrics_requests_reboot(self):
        with tempfile.TemporaryDirectory() as directory:
            account = pwd.getpwuid(os.getuid())
            backend = ToolkitBackend(account.pw_name, account.pw_dir,
                                     lock_path=Path(directory) / "backend.lock")
            backend._cpu_unlock_metrics_payload_path = MagicMock(return_value=Path("/trusted"))
            backend._cpu_unlock_cleanup_payload_path = MagicMock(return_value=Path("/trusted"))
            backend._cpu_topology = MagicMock(return_value={"physicalCores": 8})
            backend.get_cpu_unlock_status = AsyncMock(return_value={"actions": {
                "metrics-enable": {"available": True, "blockers": []},
                "uninstall": {"available": False, "blockers": ["automatic-reboot-pending"]},
            }})
            backend._exec = AsyncMock(return_value=(0, "", ""))
            result = await backend.cpu_unlock_action("metrics-enable")
            self.assertEqual(result, {"action": "metrics-enable", "nextStep": "warm-reboot"})
            argv = backend._exec.call_args.args[0]
            self.assertEqual(argv, [module.BASH, "/trusted/bc250-power.sh", "cpu-unlock", "metrics-enable"])
            backend._exec.reset_mock()
            with self.assertRaisesRegex(CommandError, "automatic-reboot-pending"):
                await backend.cpu_unlock_action("uninstall")
            backend._exec.assert_not_called()

    async def test_voltage_allowlist_bounds_and_unused_integer_placeholders(self):
        self.assertEqual(voltage_arguments("offset", 0, -25, 0), ["offset", "-25"])
        self.assertEqual(voltage_arguments("reset", 0, 0, 0), ["reset"])
        self.assertEqual(voltage_arguments("remove", 1000, 0, 0), ["remove", "1000"])
        for args in (("floor", 350, 700, 0), ("set; reboot", 350, 700, 0),
                     ("add", 349, 800, 0), ("set", 1000, 1051, 0),
                     ("edit", 1000, 850, 2231), ("offset", 0, -351, 0),
                     ("reset", True, 0, 0), ("set", 1000, "850", 0)):
            with self.subTest(args=args), self.assertRaises(ValueError):
                voltage_arguments(*args)


class HandoffParityTests(unittest.IsolatedAsyncioTestCase):
    async def test_capabilities_gate_routes_without_confusing_source_and_ui_versions(self):
        backend = object.__new__(ToolkitBackend)
        script = Path("/home/user/toolkit/bc250-toolkit.sh")
        backend._cli_handoff_context = AsyncMock(return_value=(script, "/usr/bin/konsole", None))
        backend._user_exec = AsyncMock(return_value=(0, json.dumps({
            "schemaVersion": 1, "toolkitVersion": "v0.35.0",
            "menuSections": ["menu", "status", "graphics", "interfaces", "future-section"],
        }), ""))
        catalog = await backend.get_cli_catalog()
        self.assertTrue(catalog["capabilitiesAvailable"])
        self.assertEqual(catalog["toolkitVersion"], "v0.35.0")
        self.assertEqual({item["id"] for item in catalog["sections"]}, {"menu", "status", "graphics", "interfaces"})
        backend._user_exec.assert_awaited_with(
            [module.BASH, str(script), "frontend-capabilities-json"], check=False, timeout=5
        )
        with self.assertRaisesRegex(CommandError, "does not advertise"):
            await backend.open_cli_section("maintenance")
        self.assertFalse(any(call.args[0][0] == module.SYSTEMD_RUN for call in backend._user_exec.call_args_list))

    async def test_legacy_or_malformed_capabilities_offer_only_root_and_status(self):
        backend = object.__new__(ToolkitBackend)
        backend._cli_handoff_context = AsyncMock(return_value=(Path("/user/toolkit.sh"), "/usr/bin/konsole", None))
        for payload in ("old help output", "[]", '{"schemaVersion":true}',
                        json.dumps({"schemaVersion": 1, "menuSections": ["menu", "$(reboot)"]})):
            with self.subTest(payload=payload):
                backend._user_exec = AsyncMock(return_value=(0, payload, ""))
                catalog = await backend.get_cli_catalog()
                self.assertFalse(catalog["capabilitiesAvailable"])
                self.assertIsNone(catalog["toolkitVersion"])
                self.assertEqual({item["id"] for item in catalog["sections"]}, {"menu", "status"})
                with self.assertRaisesRegex(CommandError, "does not advertise"):
                    await backend.open_cli_section("interfaces")

    async def test_fixed_section_user_argv_only_and_catalog_reason(self):
        backend = object.__new__(ToolkitBackend)
        backend._cli_handoff_context = AsyncMock(return_value=(Path("/home/user/toolkit/bc250-toolkit.sh"), "/usr/bin/konsole", None))
        backend._user_exec = AsyncMock(return_value=(0, "", ""))
        backend._exec = AsyncMock()
        result = await backend.open_cli_section("status")
        self.assertIn("Desktop Mode", result["message"])
        argv = backend._user_exec.call_args.args[0]
        self.assertEqual(argv[-3:], [module.BASH, "/home/user/toolkit/bc250-toolkit.sh", "status"])
        self.assertIn("--user", argv)
        self.assertIn("/usr/bin/konsole", argv)
        backend._exec.assert_not_called()
        for section in ("/tmp/arbitrary.sh", "status; reboot", "$(id)", "--help", True):
            with self.subTest(section=section), self.assertRaises(CommandError):
                await backend.open_cli_section(section)
        backend._cli_handoff_context.return_value = (None, None, "No terminal installed")
        catalog = await backend.get_cli_catalog()
        self.assertFalse(catalog["available"])
        self.assertEqual(catalog["reason"], "No terminal installed")
        self.assertEqual({section["id"] for section in catalog["sections"]}, CLI_SECTION_IDS)
        with self.assertRaisesRegex(CommandError, "No terminal"):
            await backend.open_cli_section("menu")

    async def test_root_account_and_unsafe_checkout_are_rejected(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/tmp/not-executed")
        backend.user_uid = 0
        backend._user_exec = AsyncMock()
        self.assertIn("non-root", (await backend.get_cli_catalog())["reason"])
        backend.user_uid = 1000
        self.assertIn("missing or unsafe", (await backend.get_cli_catalog())["reason"])
        backend._user_exec.assert_not_called()

    async def test_launcher_and_graphical_session_unavailability_have_explicit_reasons(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/home/user/toolkit")
        backend.user_uid = 1000
        backend._toolkit_file = MagicMock(return_value=True)
        backend._trusted_root_file = MagicMock(return_value=True)
        backend._user_exec = AsyncMock(return_value=(0, "WAYLAND_DISPLAY=wayland-0\n", ""))
        with patch.object(module.os, "access", return_value=True):
            self.assertTrue((await backend.get_cli_catalog())["available"])
            backend._user_exec.return_value = (0, "HOME=/home/user\n", "")
            self.assertIn("Desktop Mode", (await backend.get_cli_catalog())["reason"])
            backend._trusted_root_file.return_value = False
            self.assertIn("No supported terminal", (await backend.get_cli_catalog())["reason"])
            backend._trusted_root_file.side_effect = lambda path: str(path) != module.SYSTEMD_RUN
            self.assertIn("systemd-run", (await backend.get_cli_catalog())["reason"])
