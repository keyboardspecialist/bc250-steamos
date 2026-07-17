import asyncio
import stat
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import bc250_control.backend as backend_module
from bc250_control.backend import CommandError, ToolkitBackend


class BackendParsingTests(unittest.TestCase):
    def test_key_value_reader_ignores_shell_syntax(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state"
            path.write_text(
                "MODE=range\nA=0\nB=2000\nBAD-KEY=value\nCOMMAND=$(id)\n",
                encoding="utf-8",
            )
            self.assertEqual(
                ToolkitBackend._read_key_values(path),
                {
                    "MODE": "range",
                    "A": "0",
                    "B": "2000",
                    "COMMAND": "$(id)",
                },
            )

    def test_safe_int_degrades_malformed_state(self):
        self.assertEqual(ToolkitBackend._safe_int("oops"), 0)
        self.assertEqual(ToolkitBackend._safe_int("1800"), 1800)

    def test_bus_values(self):
        self.assertTrue(ToolkitBackend._bus_value("b true"))
        self.assertEqual(ToolkitBackend._bus_value('s "BC-250"'), "BC-250")
        self.assertEqual(ToolkitBackend._bus_value("u 1200"), 1200)

    def test_toml_updates_preserve_other_sections(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_text(
                "[load-target]\nupper = 0.80\nlower = 0.65\n\n"
                "[frequency-range]\nmax = 1500\n",
                encoding="utf-8",
            )
            ToolkitBackend._update_toml_values(
                path,
                {
                    "load-target": {"upper": "0.60", "lower": "0.45"},
                    "timing": {"down-events": "5"},
                },
            )
            content = path.read_text(encoding="utf-8")
            self.assertIn("upper = 0.60", content)
            self.assertIn("lower = 0.45", content)
            self.assertIn("max = 1500", content)
            self.assertIn("[timing]\ndown-events = 5", content)

    def test_toml_update_rejects_duplicate_section(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            original = "[load-target] # existing\nupper = 0.80\nlower = 0.65\n"
            path.write_text(original, encoding="utf-8")
            with self.assertRaises(CommandError):
                ToolkitBackend._update_toml_values(
                    path, {"load-target": {"upper": "0.60"}}
                )
            self.assertEqual(path.read_text(encoding="utf-8"), original)

    def test_atomic_write_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text("original", encoding="utf-8")
            link = root / "link"
            link.symlink_to(target)
            with self.assertRaises(CommandError):
                ToolkitBackend._atomic_write(link, "replacement")

    def test_atomic_write_preserves_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config"
            path.write_text("old", encoding="utf-8")
            path.chmod(0o640)
            ToolkitBackend._atomic_write(path, "new")
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)

    def test_user_command_has_clean_environment(self):
        backend = object.__new__(ToolkitBackend)
        backend.user = "deck"
        backend.user_home = Path("/home/deck")
        backend.user_uid = 1000
        command = backend._user_argv(["/usr/bin/true"])
        self.assertIn("-i", command)
        self.assertIn("PATH=/usr/local/bin:/usr/bin", command)
        self.assertIn("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus", command)

    def test_root_helper_rejects_writable_files(self):
        path = MagicMock()
        parent = MagicMock()
        root = MagicMock()
        path.parent = parent
        parent.parent = root
        root.parent = root
        path.is_absolute.return_value = True
        path.lstat.return_value = SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o755)
        parent.lstat.return_value = SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755)
        root.lstat.return_value = SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755)
        self.assertTrue(ToolkitBackend._trusted_root_file(path))

        path.lstat.return_value = SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o777)
        self.assertFalse(ToolkitBackend._trusted_root_file(path))

    def test_root_helper_rejects_user_owned_ancestor(self):
        path = MagicMock()
        parent = MagicMock()
        ancestor = MagicMock()
        root = MagicMock()
        path.parent = parent
        parent.parent = ancestor
        ancestor.parent = root
        root.parent = root
        path.is_absolute.return_value = True
        path.lstat.return_value = SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o755)
        parent.lstat.return_value = SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755)
        ancestor.lstat.return_value = SimpleNamespace(st_uid=1000, st_mode=stat.S_IFDIR | 0o755)
        root.lstat.return_value = SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755)

        self.assertFalse(ToolkitBackend._trusted_root_file(path))

    def test_umr_uses_configured_root_owned_path(self):
        backend = object.__new__(ToolkitBackend)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            umr = root / "umr"
            umr.write_text("", encoding="utf-8")
            umr.chmod(0o755)
            config = root / "manager.conf"
            config.write_text(f"UMR={umr}\n", encoding="utf-8")
            backend.toolkit = root / "toolkit"
            with (
                patch.object(backend_module, "CU_CONFIG_PATH", config),
                patch.object(
                    ToolkitBackend,
                    "_trusted_root_file",
                    side_effect=lambda path: path == umr,
                ),
            ):
                self.assertEqual(backend._trusted_umr(), umr)


class BackendMutationTests(unittest.IsolatedAsyncioTestCase):
    async def test_exec_strips_decky_library_path(self):
        backend = object.__new__(ToolkitBackend)
        process = MagicMock()
        process.communicate = AsyncMock(return_value=(b"", b""))
        process.returncode = 0
        with (
            patch.object(backend_module, "CLEAN_ENV", {"PATH": "/usr/bin"}),
            patch(
                "bc250_control.backend.asyncio.create_subprocess_exec",
                AsyncMock(return_value=process),
            ) as create_process,
        ):
            await backend._exec(["/usr/bin/true"])

        self.assertEqual(create_process.await_args.kwargs["env"], {"PATH": "/usr/bin"})
        self.assertNotIn("LD_LIBRARY_PATH", create_process.await_args.kwargs["env"])

    async def test_performance_mode_uses_enabled_property(self):
        backend = object.__new__(ToolkitBackend)
        backend._exec = AsyncMock(return_value=(0, "", ""))

        await backend._set_gpu_enabled(True)

        argv = backend._exec.await_args.args[0]
        self.assertIn("set-property", argv)
        self.assertEqual(argv[-3:], ["Enabled", "b", "true"])

    async def test_umr_register_uses_configured_instance(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/toolkit")
        backend._exec = AsyncMock(return_value=(0, "value 0x1f", ""))
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "manager.conf"
            config.write_text("UMR_INSTANCE=3\n", encoding="utf-8")
            with (
                patch.object(backend_module, "CU_CONFIG_PATH", config),
                patch.object(backend, "_trusted_umr", return_value=Path("/umr")),
            ):
                value = await backend._umr_register("register", 0, 1)

        self.assertEqual(value, 0x1F)
        self.assertEqual(backend._exec.await_args.args[0][1:3], ["-i", "3"])

    async def test_umr_register_retries_legacy_bank_syntax_and_parses_stderr(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/toolkit")
        backend._exec = AsyncMock(
            side_effect=[
                (1, "", "unsupported bank mask"),
                (0, "", "value 0x1f"),
            ]
        )
        with (
            patch.object(backend, "_trusted_umr", return_value=Path("/umr")),
            patch.object(backend, "_umr_instance", return_value=None),
            patch.object(backend, "_umr_database_args", return_value=[]),
        ):
            value = await backend._umr_register("register", 1, 0)

        self.assertEqual(value, 0x1F)
        self.assertEqual(backend._exec.await_count, 2)
        self.assertEqual(backend._exec.await_args.args[0][-3:], ["-b", "1", "0"])

    async def test_cu_status_rejects_partially_malformed_saved_table(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/toolkit")
        backend._service = AsyncMock(
            return_value={"enabled": "enabled", "active": "active"}
        )
        backend._umr_register = AsyncMock(return_value=None)
        backend._trusted_umr = MagicMock(return_value=None)
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "manager.conf"
            config.write_text(
                "BC250_WGP_MASKS=0x1f,bad,0x1f,0x1f,0x1f\n",
                encoding="utf-8",
            )
            with patch.object(backend_module, "CU_CONFIG_PATH", config):
                status = await backend.get_cu_status()

        self.assertEqual(status["savedMasks"], [])

    async def test_cec_dbus_response_marks_daemon_active(self):
        backend = object.__new__(ToolkitBackend)
        backend._cec_property = AsyncMock(
            side_effect=["BC-250", True, False, False, True, False, 1000, 5]
        )
        backend._service = AsyncMock(
            return_value={"enabled": "static", "active": "inactive"}
        )

        status = await backend.get_cec_status()

        self.assertEqual(status["service"]["active"], "active")
        backend._service.assert_awaited_once_with("cecd.service", user=True)

    async def test_rpc_rejects_boolean_frequency(self):
        backend = object.__new__(ToolkitBackend)
        with self.assertRaises(CommandError):
            await backend.set_gpu_frequency("pin", 0, True)

    async def test_rpc_rejects_non_boolean_toggle(self):
        backend = object.__new__(ToolkitBackend)
        with self.assertRaises(CommandError):
            await backend.set_cec_toggle("wake-tv", "true")

    async def test_cu_rpc_rejects_boolean_coordinate(self):
        backend = object.__new__(ToolkitBackend)
        with self.assertRaisesRegex(CommandError, "whole numbers"):
            await backend.set_cu_wgp(True, 0, 0, True)

    async def test_cu_rpc_uses_trusted_manager(self):
        backend = object.__new__(ToolkitBackend)
        backend._mutation_lock = asyncio.Lock()
        backend._bc250_present = MagicMock(return_value=True)
        backend._trusted_umr = MagicMock(return_value=Path("/trusted/umr"))
        backend._trusted_cu_manager = MagicMock(
            return_value=Path("/trusted/cu-manager")
        )
        backend._umr_register = AsyncMock(return_value=0x07)
        backend._umr_instance = MagicMock(return_value=2)
        backend._exec = AsyncMock(return_value=(0, "", ""))

        with patch.object(
            backend_module,
            "CLEAN_ENV",
            {"PATH": "/wrong", "UMR_INSTANCE": "99"},
        ):
            await backend.set_cu_wgp(1, 0, 4, True)

        self.assertEqual(
            backend._exec.await_args.args[0],
            ["/trusted/cu-manager", "--yes", "enable-wgp", "1.0.4"],
        )
        self.assertEqual(backend._exec.await_args.kwargs["env"]["UMR_INSTANCE"], "2")
        self.assertNotEqual(backend._exec.await_args.kwargs["env"]["PATH"], "/wrong")

    async def test_cu_rpc_drops_inherited_instance_when_detection_fails(self):
        backend = object.__new__(ToolkitBackend)
        backend._mutation_lock = asyncio.Lock()
        backend._bc250_present = MagicMock(return_value=True)
        backend._trusted_umr = MagicMock(return_value=Path("/trusted/umr"))
        backend._trusted_cu_manager = MagicMock(
            return_value=Path("/trusted/cu-manager")
        )
        backend._umr_register = AsyncMock(return_value=0x07)
        backend._umr_instance = MagicMock(return_value=None)
        backend._exec = AsyncMock(return_value=(0, "", ""))

        with patch.object(backend_module, "CLEAN_ENV", {"UMR_INSTANCE": "99"}):
            await backend.set_cu_wgp(0, 0, 0, False)

        self.assertNotIn("UMR_INSTANCE", backend._exec.await_args.kwargs["env"])

    async def test_cpu_oc_rejects_unsafe_values(self):
        backend = object.__new__(ToolkitBackend)
        with self.assertRaisesRegex(CommandError, "Unknown"):
            await backend.cpu_oc_action("detect; reboot", 4000, 1275, 90)
        with self.assertRaisesRegex(CommandError, "1325"):
            await backend.cpu_oc_action("detect", 4000, 1350, 90)
        with self.assertRaisesRegex(CommandError, "whole numbers"):
            await backend.cpu_oc_action("detect", True, 1275, 90)

    async def test_cpu_oc_uses_allowlisted_tool_arguments(self):
        backend = object.__new__(ToolkitBackend)
        backend._mutation_lock = asyncio.Lock()
        backend._cpu_tool = AsyncMock(return_value="")

        await backend.cpu_oc_action("detect", 4000, 1275, 90)

        backend._cpu_tool.assert_awaited_once_with(
            "cpu-oc",
            "detect",
            "4000",
            "1275",
            "90",
            timeout=1800,
        )

    async def test_cpu_stock_restore_ignores_detection_values(self):
        backend = object.__new__(ToolkitBackend)
        backend._mutation_lock = asyncio.Lock()
        backend._cpu_tool = AsyncMock(return_value="")

        await backend.cpu_oc_action("off", None, None, None)

        backend._cpu_tool.assert_awaited_once_with(
            "cpu-oc", "off", timeout=180
        )

    async def test_inactive_governor_config_update_does_not_start_service(self):
        backend = object.__new__(ToolkitBackend)
        backend._service = AsyncMock(
            return_value={"enabled": "disabled", "active": "inactive"}
        )
        backend._restart_governor_and_reapply = AsyncMock()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_text(
                "[load-target]\nupper = 0.80\nlower = 0.65\n",
                encoding="utf-8",
            )
            with patch.object(backend_module, "GPU_CONFIG_PATH", path):
                await backend._update_gpu_config(
                    {"load-target": {"upper": "0.60", "lower": "0.45"}},
                    restart=True,
                )
            self.assertIn("upper = 0.60", path.read_text(encoding="utf-8"))
            backend._restart_governor_and_reapply.assert_not_awaited()

    async def test_config_update_rolls_back_after_restart_failure(self):
        backend = object.__new__(ToolkitBackend)
        backend._service = AsyncMock(
            return_value={"enabled": "enabled", "active": "active"}
        )
        backend._restart_governor_and_reapply = AsyncMock(
            side_effect=[CommandError("restart failed"), None]
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            original = "[load-target]\nupper = 0.80\nlower = 0.65\n"
            path.write_text(original, encoding="utf-8")
            with patch.object(backend_module, "GPU_CONFIG_PATH", path):
                with self.assertRaisesRegex(CommandError, "restart failed"):
                    await backend._update_gpu_config(
                        {"load-target": {"upper": "0.60", "lower": "0.45"}},
                        restart=True,
                    )
            self.assertEqual(path.read_text(encoding="utf-8"), original)
            self.assertEqual(backend._restart_governor_and_reapply.await_count, 2)

    async def test_cancelled_config_update_rolls_back(self):
        backend = object.__new__(ToolkitBackend)
        backend._service = AsyncMock(
            return_value={"enabled": "enabled", "active": "active"}
        )
        backend._restart_governor_and_reapply = AsyncMock()
        live_callback = AsyncMock(side_effect=asyncio.CancelledError)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            original = "[load-target]\nupper = 0.80\nlower = 0.65\n"
            path.write_text(original, encoding="utf-8")
            with patch.object(backend_module, "GPU_CONFIG_PATH", path):
                with self.assertRaises(asyncio.CancelledError):
                    await backend._update_gpu_config(
                        {"load-target": {"upper": "0.60", "lower": "0.45"}},
                        live_callback=live_callback,
                    )
            self.assertEqual(path.read_text(encoding="utf-8"), original)
            backend._restart_governor_and_reapply.assert_awaited_once()

    async def test_frequency_state_rolls_back_after_live_failure(self):
        backend = object.__new__(ToolkitBackend)
        backend._mutation_lock = asyncio.Lock()
        backend._apply_frequency = AsyncMock(
            side_effect=[CommandError("D-Bus failed"), None]
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "freq-state"
            original = "MODE=range\nA=500\nB=1500\n"
            path.write_text(original, encoding="utf-8")
            with patch.object(backend_module, "GPU_STATE_PATH", path):
                with self.assertRaisesRegex(CommandError, "D-Bus failed"):
                    await backend.set_gpu_frequency("max", 0, 0)
            self.assertEqual(path.read_text(encoding="utf-8"), original)
            self.assertEqual(backend._apply_frequency.await_count, 2)
            self.assertEqual(
                backend._apply_frequency.await_args_list[1].args,
                ("range", 500, 1500),
            )


if __name__ == "__main__":
    unittest.main()
