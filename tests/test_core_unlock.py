import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "core-unlock" / "bc250-unlock-cores.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("bc250_core_unlock", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CoreUnlockTests(unittest.TestCase):
    def test_boot_clears_guard_when_eight_cores_are_present(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            helper.PENDING.write_text("prior-boot\n", encoding="ascii")
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(8, 16)
            ), mock.patch.object(
                helper, "read_or_apply_mask"
            ) as apply_mask, mock.patch.object(helper.subprocess, "run") as reboot:
                self.assertEqual(helper.boot(), 0)
            self.assertFalse(helper.PENDING.exists())
            apply_mask.assert_not_called()
            reboot.assert_not_called()

    def test_boot_guard_prevents_a_second_automatic_reboot(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            helper.PENDING.write_text("prior-boot\n", encoding="ascii")
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(6, 12)
            ), mock.patch.object(
                helper, "read_or_apply_mask"
            ) as apply_mask, mock.patch.object(helper.subprocess, "run") as reboot:
                with self.assertRaisesRegex(RuntimeError, "reboot-loop guard"):
                    helper.boot()
            apply_mask.assert_not_called()
            reboot.assert_not_called()

    def test_boot_applies_then_requests_one_warm_reboot(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(6, 12)
            ), mock.patch.object(
                helper, "read_or_apply_mask"
            ) as apply_mask, mock.patch.object(helper, "write_pending") as pending, mock.patch.object(
                helper.subprocess, "run"
            ) as reboot:
                self.assertEqual(helper.boot(), 0)
            apply_mask.assert_called_once_with()
            pending.assert_called_once_with("automatic")
            reboot.assert_called_once_with(
                ["/usr/bin/systemctl", "--no-block", "reboot"], check=True
            )

    def test_boot_refuses_non_bc250_hardware_before_smu_access(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            with mock.patch.object(helper, "is_bc250", return_value=False), mock.patch.object(
                helper, "read_or_apply_mask"
            ) as apply_mask:
                with self.assertRaisesRegex(RuntimeError, "1002:13fe"):
                    helper.boot()
            apply_mask.assert_not_called()

    def test_boot_failure_leaves_guard_and_blocks_same_boot_retry(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(6, 12)
            ), mock.patch.object(
                helper, "current_boot_id", return_value="current-boot"
            ), mock.patch.object(
                helper, "read_or_apply_mask", side_effect=RuntimeError("mailbox timeout")
            ):
                with self.assertRaisesRegex(RuntimeError, "mailbox timeout"):
                    helper.boot()
                self.assertTrue(helper.PENDING.exists())
                with self.assertRaisesRegex(RuntimeError, "already attempted this boot"):
                    helper.apply()

    def test_manual_failure_also_blocks_same_boot_retry(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(6, 12)
            ), mock.patch.object(
                helper, "current_boot_id", return_value="current-boot"
            ), mock.patch.object(
                helper, "read_or_apply_mask", side_effect=RuntimeError("mailbox timeout")
            ):
                with self.assertRaisesRegex(RuntimeError, "mailbox timeout"):
                    helper.apply()
                self.assertEqual(helper.pending_kind(), "manual")
                with self.assertRaisesRegex(RuntimeError, "already attempted this boot"):
                    helper.apply()

    def test_persistence_gate_requires_eight_active_cores(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            helper.STATE_DIR = Path(directory)
            helper.PENDING = helper.STATE_DIR / "reboot-pending"
            helper.LOCK_PATH = helper.STATE_DIR / "operation.lock"
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(6, 12)
            ):
                with self.assertRaisesRegex(RuntimeError, "validate before enabling"):
                    helper.verify_unlocked()

            helper.PENDING.write_text("prior-boot manual\n", encoding="ascii")
            with mock.patch.object(helper, "is_bc250", return_value=True), mock.patch.object(
                helper, "topology", return_value=(8, 16)
            ):
                self.assertEqual(helper.verify_unlocked(), 0)
            self.assertFalse(helper.PENDING.exists())


if __name__ == "__main__":
    unittest.main()
