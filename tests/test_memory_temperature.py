import importlib.util
import json
import os
from pathlib import Path

from scripts.menu_graph import parse
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bc250-memory-temperature.sh"
HELPER = ROOT / "memory-temperature/bc250-memory-temperature.py"
UPSTREAM_COMMIT = "b7e6bffcb5d592fc03edde375b7598ddc79aa846"


def load_helper():
    spec = importlib.util.spec_from_file_location("bc250_memory_temperature", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeSmu:
    def __init__(self, helper, handler, payload, fail_write_number=None):
        self.helper = helper
        self.handler = handler
        self.payload = bytearray(payload)
        self.fail_write_number = fail_write_number
        self.write_count = 0
        self.closed = False

    def smu_read(self, address, count=1):
        size = count * 4
        if address == self.helper.HANDLER_REGISTER:
            return self.handler.to_bytes(4, "little") + bytes(max(0, size - 4))
        offset = address - self.helper.PAYLOAD_START
        return bytes(self.payload[offset : offset + size]).ljust(size, b"\0")

    def smu_write32(self, address, value):
        self.write_count += 1
        if self.fail_write_number == self.write_count:
            self.fail_write_number = None
            raise OSError("synthetic write failure")
        if address == self.helper.HANDLER_REGISTER:
            self.handler = value
            return
        offset = address - self.helper.PAYLOAD_START
        self.payload[offset : offset + 4] = value.to_bytes(4, "little")

    def close(self):
        self.closed = True


class MemoryTemperatureTests(unittest.TestCase):
    def test_shell_and_python_sources_parse(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
        compile(HELPER.read_text(encoding="utf-8"), str(HELPER), "exec")

    def test_upstream_inputs_are_commit_and_checksum_pinned(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(f'UPSTREAM_COMMIT="{UPSTREAM_COMMIT}"', source)
        self.assertIn(
            "SMUPayload.bin b31908460e932a615d9eafb6b3112e6448994f9f6fa656d1d80a8616ac1df4df",
            source,
        )
        self.assertIn(
            "LICENSE 2c077d99237afe7b5a57ad02c515d2eee309e1149f5f0af7d346b793d43bd753",
            source,
        )
        self.assertIn('curl --retry 3 --retry-all-errors -fsSL "$RAW_BASE/$relative"', source)
        self.assertIn('"$(sha256_file "$SOURCE_DIR/$relative")" == "$expected"', source)
        self.assertNotIn("releases/latest", source)

    def test_live_writes_require_exact_acknowledgement(self):
        for action in ("patch", "restore"):
            result = subprocess.run(
                ["bash", str(SCRIPT), action],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f"Usage: {SCRIPT} {action} --acknowledge-smu-risk", result.stderr)

    def test_status_does_not_create_or_touch_state(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            result = subprocess.run(
                ["bash", str(SCRIPT), "status"],
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "BC250_MEMORY_TEMP_STATE_DIR": str(state),
                    "BC250_MEMORY_TEMP_ALLOW_UNPRIVILEGED_TEST": "1",
                },
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("source:   not prepared", result.stdout)
            self.assertFalse(state.exists())

    def test_hardware_guard_requires_both_exact_pci_devices(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            pci = Path(directory)
            root = pci / helper.ROOT_BDF
            gpu = pci / helper.GPU_BDF
            root.mkdir()
            gpu.mkdir()
            (root / "vendor").write_text("0x1022\n", encoding="ascii")
            (root / "device").write_text("0x13e0\n", encoding="ascii")
            (gpu / "vendor").write_text("0x1002\n", encoding="ascii")
            (gpu / "device").write_text("0x13fe\n", encoding="ascii")
            previous = os.environ.get("BC250_MEMORY_TEMP_PCI_ROOT")
            os.environ["BC250_MEMORY_TEMP_PCI_ROOT"] = str(pci)
            try:
                helper.require_hardware()
                (gpu / "device").write_text("0xffff\n", encoding="ascii")
                with self.assertRaisesRegex(RuntimeError, "not the BC-250 GFX1013 GPU"):
                    helper.require_hardware()
            finally:
                if previous is None:
                    os.environ.pop("BC250_MEMORY_TEMP_PCI_ROOT", None)
                else:
                    os.environ["BC250_MEMORY_TEMP_PCI_ROOT"] = previous

    def test_original_smu_backup_is_atomic_and_self_validating(self):
        helper = load_helper()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "original-smu.json"
            payload = bytes(range(176))
            helper.write_backup(path, 0x12345678, payload)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(helper.read_backup(path, len(payload)), (0x12345678, payload))
            record = json.loads(path.read_text(encoding="ascii"))
            record["payloadSha256"] = "0" * 64
            path.write_text(json.dumps(record), encoding="ascii")
            with self.assertRaisesRegex(RuntimeError, "invalid original-firmware backup"):
                helper.read_backup(path, len(payload))

    def test_partial_patch_write_rolls_back_to_recorded_original(self):
        helper = load_helper()
        payload = bytes((index * 3) & 0xFF for index in range(176))
        original = bytes((255 - index) & 0xFF for index in range(176))
        smu = FakeSmu(helper, 0x00001234, original, fail_write_number=3)
        original_loader = helper.load_payload
        original_upstream = helper.load_upstream
        helper.load_payload = lambda _source: payload
        helper.load_upstream = lambda _source: (lambda: smu, lambda _smu: True)
        try:
            with tempfile.TemporaryDirectory() as directory:
                backup = Path(directory) / "original-smu.json"
                with self.assertRaisesRegex(OSError, "synthetic write failure"):
                    helper.patch_payload(Path(directory), backup, True)
                self.assertEqual(smu.handler, 0x00001234)
                self.assertEqual(bytes(smu.payload), original)
                self.assertTrue(backup.exists())
                self.assertTrue(smu.closed)
        finally:
            helper.load_payload = original_loader
            helper.load_upstream = original_upstream

    def test_cold_cycle_original_state_clears_stale_backup(self):
        helper = load_helper()
        payload = bytes((index * 5) & 0xFF for index in range(176))
        original = bytes((index * 7) & 0xFF for index in range(176))
        original_handler = 0x00004567
        smu = FakeSmu(helper, original_handler, original)
        original_loader = helper.load_payload
        original_upstream = helper.load_upstream
        helper.load_payload = lambda _source: payload
        helper.load_upstream = lambda _source: (lambda: smu, lambda _smu: True)
        try:
            with tempfile.TemporaryDirectory() as directory:
                backup = Path(directory) / "original-smu.json"
                helper.write_backup(backup, original_handler, original)
                helper.restore_payload(Path(directory), backup, True)
                self.assertFalse(backup.exists())
                self.assertEqual(bytes(smu.payload), original)
        finally:
            helper.load_payload = original_loader
            helper.load_upstream = original_upstream

    def test_active_payload_without_backup_is_refused(self):
        helper = load_helper()
        payload = bytes((index * 11) & 0xFF for index in range(176))
        smu = FakeSmu(helper, helper.PAYLOAD_HANDLER, payload)
        original_loader = helper.load_payload
        original_upstream = helper.load_upstream
        helper.load_payload = lambda _source: payload
        helper.load_upstream = lambda _source: (lambda: smu, lambda _smu: True)
        try:
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(RuntimeError, "no recorded original-SMU backup"):
                    helper.patch_payload(
                        Path(directory), Path(directory) / "missing.json", True
                    )
        finally:
            helper.load_payload = original_loader
            helper.load_upstream = original_upstream

    def test_toolkit_release_and_references_include_component(self):
        toolkit = (ROOT / "bc250-toolkit.sh").read_text(encoding="utf-8")
        workflow = (ROOT / ".github/workflows/release-artifacts.yml").read_text(
            encoding="utf-8"
        )
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn('MEMORY_TEMP_SH="$SCRIPT_DIR/bc250-memory-temperature.sh"', toolkit)
        self.assertIn("memory-temperature-patch", toolkit)
        graph = parse(ROOT / "menus/toolkit.mmd")
        power_ids = {node.id for node in graph.choices("menu__cmd_power_menu")}
        device_ids = {node.id for node in graph.choices("menu__cmd_devices_menu")}
        self.assertIn("menu__cmd_memory_temperature_menu", power_ids)
        self.assertNotIn("menu__cmd_memory_temperature_menu", device_ids)
        self.assertNotIn("memory temperature (research)", toolkit)
        self.assertNotIn("memory-temperature research", toolkit)
        self.assertIn("bc250-mesa-patches memory-temperature", workflow)
        self.assertIn("| BC-250 GDDR6 Memory Temperature |", readme)
        self.assertIn(UPSTREAM_COMMIT, readme)

    def test_no_boot_service_or_automatic_patch_is_added(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("systemctl enable", source)
        self.assertNotIn("WantedBy=", source)
        self.assertIn('systemctl stop "$GOVERNOR_SERVICE"', source)
        helper = HELPER.read_text(encoding="utf-8")
        self.assertIn("fcntl.LOCK_EX | fcntl.LOCK_NB", helper)
        self.assertLess(
            helper.index("write_bytes(smu, PAYLOAD_START, payload)"),
            helper.index("smu.smu_write32(HANDLER_REGISTER, PAYLOAD_HANDLER)"),
        )


if __name__ == "__main__":
    unittest.main()
