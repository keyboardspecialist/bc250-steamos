import asyncio
import json
import os
import pwd
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack, asynccontextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import bc250_control.backend as backend_module
from bc250_control.backend import BusyError, CommandError, ToolkitBackend


@asynccontextmanager
async def unlocked_process_lock():
    yield


def prepare_mutation_backend(backend):
    backend._mutation_lock = asyncio.Lock()
    backend._process_lock = unlocked_process_lock


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
        self.assertEqual(ToolkitBackend._bus_value("y 5"), 5)
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
        with patch("bc250_control.backend.os.geteuid", return_value=0):
            command = backend._user_argv(["/usr/bin/true"])
        self.assertIn("-i", command)
        self.assertIn("PATH=/usr/local/bin:/usr/bin", command)
        self.assertIn("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus", command)

    def test_user_command_runs_directly_when_backend_is_target_user(self):
        backend = object.__new__(ToolkitBackend)
        backend.user = "deck"
        backend.user_home = Path("/home/deck")
        backend.user_uid = 1000
        with patch("bc250_control.backend.os.geteuid", return_value=1000):
            command = backend._user_argv(["/usr/bin/true"])
        self.assertEqual(command[0:2], [backend_module.ENV, "-i"])
        self.assertNotIn(backend_module.RUNUSER, command)

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

    def test_cpu_topology_reports_core_thread_and_ccx_groups(self):
        backend = object.__new__(ToolkitBackend)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for cpu in range(12):
                topology = root / f"cpu{cpu}" / "topology"
                cache = root / f"cpu{cpu}" / "cache/index3"
                topology.mkdir(parents=True)
                cache.mkdir(parents=True)
                (topology / "physical_package_id").write_text("0\n", encoding="ascii")
                (topology / "core_id").write_text(str(cpu // 2), encoding="ascii")
                (cache / "id").write_text(str((cpu // 2) // 3), encoding="ascii")
            with patch.object(backend_module, "CPU_SYSFS_PATH", root):
                result = backend._cpu_topology()

        self.assertEqual(result["topologyState"], "locked")
        self.assertEqual(result["physicalCores"], 6)
        self.assertEqual(result["logicalThreads"], 12)
        self.assertEqual(result["cores"][0]["logicalCpus"], [0, 1])
        self.assertEqual([group["ccxId"] for group in result["ccxGroups"]], [0, 1])
        self.assertEqual(result["ccxGroups"][0]["cores"][0]["logicalCpus"], [0, 1])

    def test_cpu_topology_handles_unlocked_unexpected_and_unavailable(self):
        backend = object.__new__(ToolkitBackend)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            topology = root / "cpu0/topology"
            topology.mkdir(parents=True)
            (topology / "physical_package_id").write_text("bad", encoding="ascii")
            (topology / "core_id").write_text("0", encoding="ascii")
            with patch.object(backend_module, "CPU_SYSFS_PATH", root):
                self.assertEqual(backend._cpu_topology()["topologyState"], "unavailable")

            for cores, expected in ((8, "unlocked"), (7, "unexpected")):
                case = root / str(cores)
                for cpu in range(cores):
                    cpu_topology = case / f"cpu{cpu}/topology"
                    cpu_topology.mkdir(parents=True)
                    (cpu_topology / "physical_package_id").write_text("0", encoding="ascii")
                    (cpu_topology / "core_id").write_text(str(cpu), encoding="ascii")
                with patch.object(backend_module, "CPU_SYSFS_PATH", case):
                    result = backend._cpu_topology()
                self.assertEqual(result["topologyState"], expected)
                self.assertFalse(result["ccxAvailable"])
                self.assertEqual(len(result["cores"]), cores)

    def test_cpu_unlock_guard_rejects_malformed_oversized_and_symlink_state(self):
        backend = object.__new__(ToolkitBackend)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "reboot-pending"
            boot_id = root / "boot-id"
            boot_id.write_text("01234567-89ab-cdef-0123-456789abcdef\n", encoding="ascii")
            with patch.object(backend_module, "CPU_UNLOCK_STATE_PATH", marker), patch.object(
                backend_module, "BOOT_ID_PATH", boot_id
            ), patch.object(ToolkitBackend, "_trusted_root_file", return_value=True):
                marker.write_text("malformed", encoding="ascii")
                self.assertEqual(backend._cpu_unlock_guard()["state"], "unavailable")
                marker.write_text("x" * 129, encoding="ascii")
                self.assertEqual(backend._cpu_unlock_guard()["state"], "unavailable")
                marker.unlink()
                marker.symlink_to(boot_id)
                self.assertEqual(backend._cpu_unlock_guard()["state"], "unavailable")

            marker.unlink()
            marker.write_text(
                "01234567-89ab-cdef-0123-456789abcdef manual\n", encoding="ascii"
            )
            marker.chmod(0o666)
            with patch.object(backend_module, "CPU_UNLOCK_STATE_PATH", marker), patch.object(
                ToolkitBackend, "_trusted_root_file", return_value=False
            ):
                self.assertEqual(backend._cpu_unlock_guard()["state"], "unavailable")

    def test_cpu_unlock_guard_reports_manual_and_automatic_current_boot(self):
        backend = object.__new__(ToolkitBackend)
        boot = "01234567-89ab-cdef-0123-456789abcdef"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "reboot-pending"
            boot_id = root / "boot-id"
            boot_id.write_text(boot + "\n", encoding="ascii")
            with patch.object(backend_module, "CPU_UNLOCK_STATE_PATH", marker), patch.object(
                backend_module, "BOOT_ID_PATH", boot_id
            ), patch.object(ToolkitBackend, "_trusted_root_file", return_value=True):
                for kind in ("manual", "automatic"):
                    marker.write_text(f"{boot} {kind}\n", encoding="ascii")
                    guard = backend._cpu_unlock_guard()
                    self.assertEqual(guard["state"], kind)
                    self.assertTrue(guard["currentBoot"])

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
            with ExitStack() as stack:
                stack.enter_context(patch.object(backend_module, "CU_CONFIG_PATH", config))
                stack.enter_context(patch.object(
                    ToolkitBackend,
                    "_trusted_root_file",
                    side_effect=lambda path: path == umr,
                ))
                self.assertEqual(backend._trusted_umr(), umr)

    def test_umr_database_skips_incomplete_canonical_copy(self):
        backend = object.__new__(ToolkitBackend)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            canonical = root / "canonical"
            legacy = root / "legacy"
            config = root / "manager.conf"
            config.write_text(
                f"UMR_DATABASE_PATH={canonical}\n", encoding="utf-8"
            )
            for database, complete in ((canonical, False), (legacy, True)):
                (database / "ip").mkdir(parents=True)
                for relative in (
                    "cyan_skillfish.asic",
                    "cyan_skillfish.soc15",
                    "ip/gc_10_1_0.reg",
                ):
                    (database / relative).write_text(
                        "data" if complete else "", encoding="utf-8"
                    )
            with ExitStack() as stack:
                stack.enter_context(patch.object(backend_module, "CU_CONFIG_PATH", config))
                stack.enter_context(patch.object(backend_module, "ROOT_UMR_DATABASE_PATH", canonical))
                stack.enter_context(patch.object(backend_module, "MIGRATED_UMR_DATABASE_PATH", legacy))
                stack.enter_context(patch.object(backend_module, "LEGACY_UMR_DATABASE_PATH", legacy))
                stack.enter_context(patch.object(ToolkitBackend, "_trusted_root_directory", return_value=True))
                stack.enter_context(patch.object(ToolkitBackend, "_trusted_root_file", return_value=True))
                self.assertEqual(
                    backend._umr_database_args(root / "bin/umr"),
                    ["--database-path", str(legacy)],
                )


class BackendMutationTests(unittest.IsolatedAsyncioTestCase):
    async def test_exec_strips_decky_library_path(self):
        backend = object.__new__(ToolkitBackend)
        process = MagicMock()
        process.communicate = AsyncMock(return_value=(b"", b""))
        process.returncode = 0
        with ExitStack() as stack:
            stack.enter_context(patch.object(backend_module, "CLEAN_ENV", {"PATH": "/usr/bin"}))
            create_process = stack.enter_context(patch(
                "bc250_control.backend.asyncio.create_subprocess_exec",
                AsyncMock(return_value=process),
            ))
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
        backend._umr_lock = asyncio.Lock()
        backend._exec = AsyncMock(return_value=(0, "value 0x1f", ""))
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "manager.conf"
            config.write_text("UMR_INSTANCE=3\n", encoding="utf-8")
            with ExitStack() as stack:
                stack.enter_context(patch.object(backend_module, "CU_CONFIG_PATH", config))
                stack.enter_context(patch.object(backend, "_trusted_umr", return_value=Path("/umr")))
                stack.enter_context(patch("bc250_control.backend.os.geteuid", return_value=0))
                value = await backend._umr_register("register", 0, 1)

        self.assertEqual(value, 0x1F)
        argv = backend._exec.await_args.args[0]
        instance_index = argv.index("-i")
        self.assertEqual(argv[instance_index : instance_index + 2], ["-i", "3"])

    async def test_umr_register_parses_stderr(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/toolkit")
        backend._umr_lock = asyncio.Lock()
        backend._exec = AsyncMock(return_value=(0, "", "value 0x1f"))
        with ExitStack() as stack:
            stack.enter_context(patch.object(backend, "_trusted_umr", return_value=Path("/umr")))
            stack.enter_context(patch.object(backend, "_umr_instance", return_value=None))
            stack.enter_context(patch.object(backend, "_umr_database_args", return_value=[]))
            stack.enter_context(patch("bc250_control.backend.os.geteuid", return_value=0))
            value = await backend._umr_register("register", 1, 0)

        self.assertEqual(value, 0x1F)
        self.assertEqual(backend._exec.await_count, 1)
        self.assertEqual(
            backend._exec.await_args.args[0][-4:], ["-b", "1", "0", "0xffffffff"]
        )

    async def test_umr_register_accepts_value_with_nonzero_status(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/toolkit")
        backend._umr_lock = asyncio.Lock()
        backend._exec = AsyncMock(return_value=(1, "value 0x1f", ""))
        with ExitStack() as stack:
            stack.enter_context(patch.object(backend, "_trusted_umr", return_value=Path("/umr")))
            stack.enter_context(patch.object(backend, "_umr_instance", return_value=None))
            stack.enter_context(patch.object(backend, "_umr_database_args", return_value=[]))
            stack.enter_context(patch("bc250_control.backend.os.geteuid", return_value=0))
            value = await backend._umr_register("register", 0, 0)

        self.assertEqual(value, 0x1F)
        self.assertEqual(backend._exec.await_count, 1)

    async def test_umr_register_retries_legacy_bank_syntax(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/toolkit")
        backend._umr_lock = asyncio.Lock()
        backend._exec = AsyncMock(
            side_effect=[
                (1, "", "unsupported bank mask"),
                (0, "", "value 0x1f"),
            ]
        )
        with ExitStack() as stack:
            stack.enter_context(patch.object(backend, "_trusted_umr", return_value=Path("/umr")))
            stack.enter_context(patch.object(backend, "_umr_instance", return_value=None))
            stack.enter_context(patch.object(backend, "_umr_database_args", return_value=[]))
            stack.enter_context(patch("bc250_control.backend.os.geteuid", return_value=0))
            value = await backend._umr_register("register", 1, 0)

        self.assertEqual(value, 0x1F)
        self.assertEqual(backend._exec.await_count, 2)
        self.assertEqual(backend._exec.await_args.args[0][-3:], ["-b", "1", "0"])

    async def test_eager_load_target_uses_more_aggressive_thresholds(self):
        backend = object.__new__(ToolkitBackend)
        prepare_mutation_backend(backend)
        backend._update_gpu_config = AsyncMock()
        backend._gpu_call = AsyncMock()

        await backend.set_load_target("eager")

        self.assertEqual(
            backend._update_gpu_config.await_args.args[0],
            {"load-target": {"upper": "0.40", "lower": "0.10"}},
        )

    async def test_umr_register_serializes_concurrent_reads(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/toolkit")
        backend._umr_lock = asyncio.Lock()
        active = 0
        maximum = 0

        async def execute(*_args, **_kwargs):
            nonlocal active, maximum
            active += 1
            maximum = max(maximum, active)
            await asyncio.sleep(0.01)
            active -= 1
            return 0, "value 0x1f", ""

        backend._exec = AsyncMock(side_effect=execute)
        with ExitStack() as stack:
            stack.enter_context(patch.object(backend, "_trusted_umr", return_value=Path("/umr")))
            stack.enter_context(patch.object(backend, "_umr_instance", return_value=0))
            stack.enter_context(patch.object(backend, "_umr_database_args", return_value=[]))
            stack.enter_context(patch("bc250_control.backend.os.geteuid", return_value=0))
            await asyncio.gather(
                *(backend._umr_register("register", se, sh) for se in range(2) for sh in range(2))
            )

        self.assertEqual(maximum, 1)

    async def test_factory_cu_masks_parse_cu_map_output(self):
        backend = object.__new__(ToolkitBackend)
        backend._exec = AsyncMock(
            return_value=(
                0,
                "0 0 0x03f\n0 1 0x03f\n1 0 0x03f\n1 1 0x03f",
                "",
            )
        )

        self.assertEqual(await backend._factory_cu_masks(), [0x3F] * 4)

    async def test_factory_cu_masks_reject_non_stock_total(self):
        backend = object.__new__(ToolkitBackend)
        backend._exec = AsyncMock(
            return_value=(
                0,
                "0 0 0x3ff\n0 1 0x3ff\n1 0 0x3ff\n1 1 0x3ff",
                "",
            )
        )

        self.assertIsNone(await backend._factory_cu_masks())

    async def test_cu_status_rejects_partially_malformed_saved_table(self):
        backend = object.__new__(ToolkitBackend)
        backend.toolkit = Path("/toolkit")
        backend._service = AsyncMock(
            return_value={"enabled": "enabled", "active": "active"}
        )
        backend._factory_cu_masks = AsyncMock(return_value=None)
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
        backend._cec_properties = AsyncMock(
            side_effect=[
                ["BC-250", True, False, False, True],
                [False, 1000, 5],
            ]
        )
        backend._service = AsyncMock(
            return_value={"enabled": "static", "active": "inactive"}
        )

        status = await backend.get_cec_status()

        self.assertEqual(status["service"]["active"], "active")
        backend._service.assert_awaited_once_with("cecd.service", user=True)

    async def test_cec_property_batch_rejects_incomplete_response(self):
        backend = object.__new__(ToolkitBackend)
        backend._user_exec = AsyncMock(return_value=(0, 's "BC-250"\nb true', ""))

        values = await backend._cec_properties(
            "/daemon", "com.example.Config", ("Name", "Wake", "Suspend")
        )

        self.assertEqual(values, [None, None, None])

    async def test_rpc_rejects_boolean_frequency(self):
        backend = object.__new__(ToolkitBackend)
        with self.assertRaises(CommandError):
            await backend.set_gpu_frequency("pin", 0, True)

    async def test_rpc_rejects_non_boolean_toggle(self):
        backend = object.__new__(ToolkitBackend)
        with self.assertRaises(CommandError):
            await backend.set_cec_toggle("wake-tv", "true")

    async def test_cec_name_uses_existing_tool_command(self):
        backend = object.__new__(ToolkitBackend)
        prepare_mutation_backend(backend)
        backend._user_tool = AsyncMock(return_value="")

        await backend.set_cec_name("Living Room")

        backend._user_tool.assert_awaited_once_with(
            "bc250-cec.sh", "osd-name", "Living Room", timeout=20
        )

    async def test_cec_name_rejects_invalid_config_text(self):
        backend = object.__new__(ToolkitBackend)

        for name in ("", "123456789012345", 'bad"name', "bad\\name", "bad\nname"):
            with self.subTest(name=name), self.assertRaises(CommandError):
                await backend.set_cec_name(name)

    async def test_mesh_status_returns_unavailable_without_toolkit_script(self):
        backend = object.__new__(ToolkitBackend)
        backend.user_home = Path("/home/deck")
        backend._user_script_available = MagicMock(return_value=False)

        status = await backend.get_mesh_status()

        self.assertFalse(status["scriptAvailable"])
        self.assertEqual(status["runtimeState"], "not-installed")
        self.assertEqual(
            status["icdPath"], "/home/deck/radeon_driconf_icd.x86_64.json"
        )

    async def test_mesh_status_validates_and_normalizes_tool_output(self):
        backend = object.__new__(ToolkitBackend)
        prepare_mutation_backend(backend)
        backend._user_script_available = MagicMock(return_value=True)
        backend._user_tool = AsyncMock(
            return_value=json.dumps(
                {
                    "scriptAvailable": True,
                    "runtimeState": "ready",
                    "mesaVersion": "mesa-26.1.4",
                    "icdPath": "/home/deck/radeon_driconf_icd.x86_64.json",
                    "configValid": True,
                    "error": None,
                    "games": [
                        {
                            "executable": "bc250-steam-1462040",
                            "name": "Final Fantasy VII Rebirth",
                        }
                    ],
                }
            )
        )

        status = await backend.get_mesh_status()

        self.assertEqual(status["runtimeState"], "ready")
        self.assertEqual(status["games"][0]["executable"], "bc250-steam-1462040")
        backend._user_tool.assert_awaited_once_with(
            "bc250-mesh-shader.sh", "status-json", timeout=30
        )

    async def test_mesh_status_rejects_invalid_tool_output(self):
        backend = object.__new__(ToolkitBackend)
        prepare_mutation_backend(backend)
        backend._user_script_available = MagicMock(return_value=True)
        backend._user_tool = AsyncMock(return_value="not-json")

        with self.assertRaisesRegex(CommandError, "invalid JSON"):
            await backend.get_mesh_status()

    async def test_mesh_game_toggle_uses_appid_alias(self):
        backend = object.__new__(ToolkitBackend)
        prepare_mutation_backend(backend)
        backend._user_tool = AsyncMock(return_value="")

        await backend.set_mesh_game_enabled(1462040, "Final Fantasy VII Rebirth", True)
        backend._user_tool.assert_awaited_once_with(
            "bc250-mesh-shader.sh",
            "game",
            "enable",
            "bc250-steam-1462040",
            "Final Fantasy VII Rebirth",
            timeout=30,
        )

        backend._user_tool.reset_mock()
        await backend.set_mesh_game_enabled(1462040, "Final Fantasy VII Rebirth", False)
        backend._user_tool.assert_awaited_once_with(
            "bc250-mesh-shader.sh",
            "game",
            "disable",
            "bc250-steam-1462040",
            timeout=30,
        )

    async def test_mesh_game_toggle_rejects_invalid_input(self):
        backend = object.__new__(ToolkitBackend)
        prepare_mutation_backend(backend)
        backend._user_tool = AsyncMock(return_value="")
        for app_id in (True, 0, -1, 0x100000000):
            with self.subTest(app_id=app_id), self.assertRaises(CommandError):
                await backend.set_mesh_game_enabled(app_id, "Game", True)
        for name in ("", "bad\nname", "x" * 257):
            with self.subTest(name=name), self.assertRaises(CommandError):
                await backend.set_mesh_game_enabled(1, name, True)
        await backend.set_mesh_game_enabled(1, "", False)
        with self.assertRaises(CommandError):
            await backend.set_mesh_game_enabled(1, "Game", "true")

    async def test_custom_load_target_rejects_inverted_range(self):
        backend = object.__new__(ToolkitBackend)
        with self.assertRaisesRegex(CommandError, "below maximum"):
            await backend.set_custom_load_target(80, 60)

    async def test_custom_load_target_updates_percentages(self):
        backend = object.__new__(ToolkitBackend)
        prepare_mutation_backend(backend)
        backend._update_gpu_config = AsyncMock()
        backend._gpu_call = AsyncMock()

        await backend.set_custom_load_target(35, 70)

        backend._update_gpu_config.assert_awaited_once()
        self.assertEqual(
            backend._update_gpu_config.await_args.args[0],
            {"load-target": {"upper": "0.70", "lower": "0.35"}},
        )
        callback = backend._update_gpu_config.await_args.kwargs["live_callback"]
        await callback()
        backend._gpu_call.assert_awaited_once_with(
            "SetLoadTarget", "dd", "0.35", "0.70"
        )

    async def test_cu_rpc_rejects_boolean_coordinate(self):
        backend = object.__new__(ToolkitBackend)
        with self.assertRaisesRegex(CommandError, "whole numbers"):
            await backend.set_cu_wgp(True, 0, 0, True)

    async def test_cu_rpc_uses_trusted_manager(self):
        backend = object.__new__(ToolkitBackend)
        prepare_mutation_backend(backend)
        backend._bc250_present = MagicMock(return_value=True)
        backend._trusted_umr = MagicMock(return_value=Path("/trusted/umr"))
        backend._trusted_cu_manager = MagicMock(
            return_value=Path("/trusted/cu-manager")
        )
        backend._umr_register = AsyncMock(return_value=0x07)
        backend._factory_cu_masks = AsyncMock(return_value=[0x3F] * 4)
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
        prepare_mutation_backend(backend)
        backend._bc250_present = MagicMock(return_value=True)
        backend._trusted_umr = MagicMock(return_value=Path("/trusted/umr"))
        backend._trusted_cu_manager = MagicMock(
            return_value=Path("/trusted/cu-manager")
        )
        backend._umr_register = AsyncMock(return_value=0x07)
        backend._factory_cu_masks = AsyncMock(return_value=[0x3F] * 4)
        backend._umr_instance = MagicMock(return_value=None)
        backend._exec = AsyncMock(return_value=(0, "", ""))

        with patch.object(backend_module, "CLEAN_ENV", {"UMR_INSTANCE": "99"}):
            await backend.set_cu_wgp(0, 0, 4, False)

        self.assertNotIn("UMR_INSTANCE", backend._exec.await_args.kwargs["env"])

    async def test_cu_rpc_rejects_factory_wgp(self):
        backend = object.__new__(ToolkitBackend)
        prepare_mutation_backend(backend)
        backend._bc250_present = MagicMock(return_value=True)
        backend._trusted_umr = MagicMock(return_value=Path("/trusted/umr"))
        backend._trusted_cu_manager = MagicMock(return_value=Path("/trusted/cu-manager"))
        backend._umr_register = AsyncMock(return_value=0x1F)
        backend._factory_cu_masks = AsyncMock(return_value=[0x3F] * 4)
        backend._exec = AsyncMock(return_value=(0, "", ""))

        with self.assertRaisesRegex(CommandError, "Factory-enabled"):
            await backend.set_cu_wgp(1, 1, 2, False)

        backend._exec.assert_not_awaited()

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
        prepare_mutation_backend(backend)
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
        prepare_mutation_backend(backend)
        backend._cpu_tool = AsyncMock(return_value="")

        await backend.cpu_oc_action("off", None, None, None)

        backend._cpu_tool.assert_awaited_once_with(
            "cpu-oc", "off", timeout=180
        )

    async def test_cpu_unlock_rejects_unknown_action_before_lock_or_execution(self):
        backend = object.__new__(ToolkitBackend)
        backend._mutate = AsyncMock()

        with self.assertRaisesRegex(CommandError, "Unknown CPU core-unlock"):
            await backend.cpu_unlock_action("enable; reboot")

        backend._mutate.assert_not_awaited()

    async def test_cpu_unlock_uses_exact_trusted_bundle_command_and_environment(self):
        backend = object.__new__(ToolkitBackend)
        prepare_mutation_backend(backend)
        backend._cpu_unlock_payload_available = MagicMock(return_value=True)
        backend._cpu_topology = MagicMock(return_value={"physicalCores": 6})
        backend._exec = AsyncMock(return_value=(0, "ignored human output", ""))
        bundle = Path("/trusted/helper-bundle")

        with patch.object(backend_module, "CPU_UNLOCK_PAYLOAD_PATH", bundle):
            result = await backend.cpu_unlock_action("test")

        self.assertEqual(result, {"action": "test", "nextStep": "warm-reboot"})
        self.assertEqual(
            backend._exec.await_args.args[0],
            [
                backend_module.BASH,
                "/trusted/helper-bundle/bc250-power.sh",
                "cpu-unlock",
                "test",
            ],
        )
        self.assertEqual(
            backend._exec.await_args.kwargs["env"],
            {
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": "/root",
                "USER": "root",
                "LOGNAME": "root",
            },
        )

    async def test_cpu_unlock_next_steps_do_not_parse_command_output(self):
        cases = (
            ("test", 8, "none"),
            ("enable", 8, "none"),
            ("off", 8, "full-power-off"),
            ("off", 6, "none"),
        )
        for action, cores, expected in cases:
            backend = object.__new__(ToolkitBackend)
            prepare_mutation_backend(backend)
            backend._cpu_unlock_payload_available = MagicMock(return_value=True)
            backend._cpu_topology = MagicMock(return_value={"physicalCores": cores})
            backend._exec = AsyncMock(return_value=(0, "anything", ""))
            result = await backend.cpu_unlock_action(action)
            self.assertEqual(result["nextStep"], expected)

    async def test_cpu_unlock_bundle_requires_all_five_trusted_files(self):
        backend = object.__new__(ToolkitBackend)
        bundle = Path("/trusted/helper-bundle")
        trusted = MagicMock(side_effect=lambda path: path != bundle / "core-unlock/LICENSE")
        with patch.object(backend_module, "CPU_UNLOCK_PAYLOAD_PATH", bundle), patch.object(
            ToolkitBackend, "_trusted_root_directory", return_value=True
        ), patch.object(ToolkitBackend, "_trusted_root_file", trusted):
            self.assertFalse(backend._cpu_unlock_payload_available())
        self.assertIn(bundle / "core-unlock/LICENSE", [call.args[0] for call in trusted.call_args_list])

    async def test_cpu_unlock_status_has_installation_state_and_advisory_blockers(self):
        backend = object.__new__(ToolkitBackend)
        backend._service = AsyncMock(
            return_value={"enabled": "disabled", "active": "inactive"}
        )
        backend._cpu_topology = MagicMock(
            return_value={
                "physicalCores": 8,
                "logicalThreads": 16,
                "topologyState": "unlocked",
                "cores": [],
                "ccxGroups": [],
                "ccxAvailable": False,
            }
        )
        backend._cpu_unlock_guard = MagicMock(
            return_value={"state": "clear", "active": False, "currentBoot": False}
        )
        backend._bc250_present_secure = MagicMock(return_value=True)
        backend._cpu_unlock_payload_available = MagicMock(return_value=True)
        backend._cpu_unlock_persistent = MagicMock(return_value=False)

        with patch.object(ToolkitBackend, "_trusted_root_file", return_value=True):
            status = await backend.get_cpu_unlock_status()

        self.assertEqual(status["schemaVersion"], 1)
        self.assertTrue(status["helperInstalled"])
        self.assertTrue(status["unitInstalled"])
        self.assertTrue(status["actions"]["enable"]["available"])
        self.assertEqual(
            status["actions"]["off"]["blockers"], ["persistent-replay-disabled"]
        )

    async def test_cpu_unlock_automatic_guard_blocks_every_action(self):
        guard = {"state": "automatic", "active": True, "currentBoot": True}
        for action in ("test", "enable", "off"):
            result = ToolkitBackend._cpu_unlock_action_status(
                action,
                device_present=True,
                topology_state="unlocked",
                payload_available=True,
                service_enabled=True,
                guard=guard,
            )
            self.assertIn("automatic-reboot-pending", result["blockers"])
            self.assertFalse(result["available"])

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
        prepare_mutation_backend(backend)
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


class BackendLockTests(unittest.IsolatedAsyncioTestCase):
    def make_backend(self, lock_path):
        account = pwd.getpwuid(os.getuid())
        return ToolkitBackend(account.pw_name, account.pw_dir, lock_path=lock_path)

    async def test_mutations_serialize_between_backend_instances(self):
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "backend.lock"
            first = self.make_backend(lock_path)
            second = self.make_backend(lock_path)
            entered = asyncio.Event()
            release = asyncio.Event()
            second_entered = asyncio.Event()

            async def first_action():
                entered.set()
                await release.wait()

            async def second_action():
                second_entered.set()

            first_task = asyncio.create_task(first._mutate(first_action))
            await entered.wait()
            second_task = asyncio.create_task(second._mutate(second_action))
            await asyncio.sleep(backend_module.BACKEND_LOCK_POLL_INTERVAL * 2)
            self.assertFalse(second_entered.is_set())
            release.set()
            await asyncio.gather(first_task, second_task)
            self.assertTrue(second_entered.is_set())

    async def test_snapshot_waits_for_cross_process_mutation_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "backend.lock"
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import fcntl, os, sys; "
                    "fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o600); "
                    "fcntl.flock(fd, fcntl.LOCK_EX); print('locked', flush=True); "
                    "sys.stdin.readline()",
                    str(lock_path),
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            try:
                self.assertEqual(process.stdout.readline().strip(), "locked")
                backend = self.make_backend(lock_path)
                backend._get_snapshot = AsyncMock(return_value={"complete": True})
                snapshot = asyncio.create_task(backend.get_snapshot())
                await asyncio.sleep(backend_module.BACKEND_LOCK_POLL_INTERVAL * 2)
                self.assertFalse(snapshot.done())
                process.stdin.write("\n")
                process.stdin.flush()
                self.assertEqual(await snapshot, {"complete": True})
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=2)
                process.stdin.close()
                process.stdout.close()

    async def test_busy_lock_raises_exported_busy_error(self):
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "backend.lock"
            descriptor = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600)
            fcntl = backend_module.fcntl
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            backend = self.make_backend(lock_path)
            try:
                with ExitStack() as stack:
                    stack.enter_context(patch.object(backend_module, "BACKEND_LOCK_TIMEOUT", 0.01))
                    stack.enter_context(patch.object(backend_module, "BACKEND_LOCK_POLL_INTERVAL", 0.001))
                    stack.enter_context(self.assertRaises(BusyError))
                    await backend._mutate(AsyncMock())
            finally:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                os.close(descriptor)

    async def test_lock_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text("", encoding="utf-8")
            lock_path = root / "backend.lock"
            lock_path.symlink_to(target)
            backend = self.make_backend(lock_path)

            with self.assertRaisesRegex(CommandError, "backend lock"):
                await backend._mutate(AsyncMock())

    async def test_telemetry_does_not_wait_for_backend_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "backend.lock"
            descriptor = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600)
            backend_module.fcntl.flock(descriptor, backend_module.fcntl.LOCK_EX)
            backend = self.make_backend(lock_path)
            backend._temperatures = MagicMock(return_value=[])
            backend._cpu_current_mhz = MagicMock(return_value=1000)
            backend._active_gpu_mhz = MagicMock(return_value=500)
            try:
                telemetry = await asyncio.wait_for(backend.get_telemetry(), 0.1)
            finally:
                backend_module.fcntl.flock(descriptor, backend_module.fcntl.LOCK_UN)
                os.close(descriptor)
            self.assertEqual(telemetry["cpuClock"], 1000)


class DeckyRuntimeTests(unittest.TestCase):
    def test_staged_runtime_imports_in_isolation_and_is_reproducible(self):
        repository = Path(__file__).resolve().parents[2]
        stage_script = repository / "scripts/stage-decky-runtime.py"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first"
            second = root / "second"
            first_archive = root / "first.zip"
            second_archive = root / "second.zip"
            environment = {**os.environ, "SOURCE_DATE_EPOCH": "315532800"}
            subprocess.run(
                [
                    sys.executable,
                    str(stage_script),
                    "--output",
                    str(first),
                    "--archive",
                    str(first_archive),
                ],
                check=True,
                env=environment,
            )
            subprocess.run(
                [
                    sys.executable,
                    str(stage_script),
                    "--output",
                    str(second),
                    "--archive",
                    str(second_archive),
                ],
                check=True,
                env=environment,
            )

            code = (
                "import pathlib, sys; sys.path.insert(0, sys.argv[1]); "
                "import bc250_control, bc250_control.backend, tomli; "
                "root=pathlib.Path(sys.argv[1]).resolve(); "
                "files=(bc250_control.__file__, bc250_control.backend.__file__, tomli.__file__); "
                "assert all(root in pathlib.Path(item).resolve().parents for item in files); "
                "assert all(not pathlib.Path(item).is_symlink() for item in files)"
            )
            subprocess.run(
                [sys.executable, "-I", "-c", code, str(first / "py_modules")],
                check=True,
                cwd=str(root),
            )
            self.assertEqual(first_archive.read_bytes(), second_archive.read_bytes())


if __name__ == "__main__":
    unittest.main()
