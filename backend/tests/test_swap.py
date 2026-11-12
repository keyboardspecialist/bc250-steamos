import asyncio
import json
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import bc250_control.backend as module
from bc250_control.backend import CommandError, ToolkitBackend
from bc250_control.parity import swap_arguments


class SwapBackendTests(unittest.IsolatedAsyncioTestCase):
    def backend(self):
        backend = object.__new__(ToolkitBackend)
        backend._swap_tool = AsyncMock(return_value="Reboot, then rerun uninstall to remove the active swapfile safely.")
        async def mutate(action):
            return await action()
        backend._mutate = AsyncMock(side_effect=mutate)
        return backend

    async def test_all_profiles_use_exact_canonical_cli_argument_order(self):
        backend = self.backend()
        for mode in ("zram", "zswap"):
            for compressor in ("zstd", "lz4"):
                await backend.configure_swap(mode, compressor, 16)
                expected = ("install", "zram", compressor, "16") if mode == "zram" else ("install", "zswap", "16", compressor)
                backend._swap_tool.assert_awaited_with(*expected, timeout=300)
        self.assertEqual(swap_arguments("zram", "lz4", 0), ["install", "zram", "lz4", "0"])

    async def test_invalid_profile_and_swappiness_fail_before_mutation(self):
        backend = self.backend()
        for args in (("zram", "lz4", True), ("zswap", "lz4", 0), ("zram", "bad", 16),
                     ("zram", "zstd", 1), ("bad", "lz4", 16), ("zswap", "lz4", 65),
                     ("zram", "lz4", "16"), ("zram", "lz4", 16.5)):
            with self.subTest(args=args), self.assertRaises(CommandError):
                await backend.configure_swap(*args)
        for value in (-1, 201, True, "100", 99.5):
            with self.subTest(value=value), self.assertRaises(CommandError):
                await backend.set_swappiness(value)
        backend._swap_tool.assert_not_called()
        backend._mutate.assert_not_called()

    async def test_swappiness_verify_and_removal_keep_helper_messages(self):
        backend = self.backend()
        for value in (0, 150, 200):
            await backend.set_swappiness(value)
            backend._swap_tool.assert_awaited_with("swappiness", str(value))
        await backend.verify_swap()
        backend._swap_tool.assert_awaited_with("verify")
        result = await backend.remove_swap_profile()
        backend._swap_tool.assert_awaited_with("uninstall")
        self.assertIn("rerun uninstall", result["message"])

    async def test_cancellation_does_not_interrupt_swap_transaction(self):
        backend = self.backend()
        started, release, completed = asyncio.Event(), asyncio.Event(), asyncio.Event()
        async def helper(*args, **kwargs):
            started.set()
            await release.wait()
            completed.set()
            return "Configured; reboot required."
        backend._swap_tool.side_effect = helper
        operation = asyncio.create_task(backend.configure_swap("zram", "zstd", 16))
        await started.wait()
        operation.cancel()
        await asyncio.sleep(0)
        self.assertFalse(completed.is_set())
        release.set()
        with self.assertRaises(asyncio.CancelledError):
            await operation
        self.assertTrue(completed.is_set())

    async def test_trusted_helper_only_clean_environment_and_pending_exit(self):
        backend = object.__new__(ToolkitBackend)
        backend._swap_helper_path = MagicMock(return_value=Path("/trusted/bc250-swap.sh"))
        backend._exec = AsyncMock(return_value=(75, "Reboot, then retry", ""))
        self.assertIn("Reboot", await backend._swap_tool("uninstall"))
        call = backend._exec.call_args
        self.assertEqual(call.args[0], [module.BASH, "/trusted/bc250-swap.sh", "uninstall"])
        self.assertNotIn("BC250_SWAPFILE", call.kwargs["env"])
        self.assertNotIn("BASH_ENV", call.kwargs["env"])
        with self.assertRaises(CommandError):
            await backend._swap_tool("verify")
        backend._swap_helper_path.return_value = None
        backend._exec.reset_mock()
        with self.assertRaises(CommandError):
            await backend._swap_tool("uninstall")
        backend._exec.assert_not_called()

    async def test_status_is_read_only_and_invalid_or_old_helpers_fail_closed(self):
        backend = self.backend()
        backend._swap_helper_available = MagicMock(return_value=True)
        status = {"schemaVersion": 1, "configuredProfile": "zram", "runtime": "zram+disk", "diskSizeGiB": 16,
                  "compressor": "zstd", "pending": "reboot", "swappiness": 0, "configuredSwappiness": 0,
                  "healthy": True, "details": "safe fixture"}
        backend._swap_tool.return_value = json.dumps(status)
        result = await backend.get_swap_status()
        self.assertTrue(result["available"])
        self.assertEqual(result["swappiness"], 0)
        backend._mutate.assert_not_called()
        for key, value in (("schemaVersion", 2), ("runtime", "bad"), ("diskSizeGiB", True),
                           ("swappiness", 201), ("configuredSwappiness", "100")):
            backend._swap_tool.return_value = json.dumps(dict(status, **{key: value}))
            self.assertFalse((await backend.get_swap_status())["available"])
        backend._swap_tool.return_value = "legacy text"
        self.assertFalse((await backend.get_swap_status())["available"])

    def test_helper_and_both_dependencies_must_be_trusted(self):
        with patch.object(ToolkitBackend, "_trusted_root_file", return_value=True):
            self.assertEqual(ToolkitBackend._swap_helper_path(), module.SWAP_HELPER_PATH)
        with patch.object(ToolkitBackend, "_trusted_root_file", side_effect=lambda path: path.parent == module.DECKY_SWAP_HELPER_PATH.parent):
            self.assertEqual(ToolkitBackend._swap_helper_path(), module.DECKY_SWAP_HELPER_PATH)
        with patch.object(ToolkitBackend, "_trusted_root_file", side_effect=lambda path: path.name == "bc250-swap.sh"):
            self.assertIsNone(ToolkitBackend._swap_helper_path())
