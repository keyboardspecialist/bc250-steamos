import hashlib
import importlib.util
import struct
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
METRICS = ROOT / "core-unlock/smu-metrics"


def load_patcher():
    spec = importlib.util.spec_from_file_location("bc250_metrics_patcher", METRICS / "patcher.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class SmuMetricsTests(unittest.TestCase):
    def test_payload_and_original_manifest_have_the_same_layout(self):
        patcher = load_patcher()
        payload = patcher.read_hex(METRICS / "metrics-8core.hex")
        originals = patcher.read_hex(METRICS / "metrics-8core-original.hex")

        self.assertEqual(
            [(address, len(data)) for address, data in payload],
            [(address, len(data)) for address, data in originals],
        )
        self.assertEqual(sum(len(data) for _, data in payload), 256)
        self.assertTrue(all(new != old for (_, new), (_, old) in zip(payload, originals)))
        self.assertEqual(
            hashlib.sha256((METRICS / "metrics-8core.hex").read_bytes()).hexdigest(),
            "43fd3a07c2066840246c746fa994585af497a2b9caf23b4d0fa4cbcff7c5b3a1",
        )
        self.assertEqual(
            hashlib.sha256(
                (METRICS / "metrics-8core-original.hex").read_bytes()
            ).hexdigest(),
            "80f97648714ebd7d78afbe8be1a713c5090219bf72dfccbe5559ef979200e12c",
        )
        replacements = dict(payload)
        self.assertEqual(replacements[0x17F24], struct.pack("<I", 0x3C000))
        self.assertEqual(replacements[0x17F34], struct.pack("<I", 0x3BF00))
        self.assertNotIn(0x12000, replacements)
        self.assertNotIn(0x1BA6E, replacements)

    def test_activation_is_fail_closed(self):
        activation = (METRICS / "activate-8core-metrics.sh").read_text(encoding="utf-8")
        disable = activation.index("printf 'N\\n' > \"$PARAM\"")
        unlock = activation.index('python3 -I "$HERE/unlock.py"')
        apply_patch = activation.index('python3 -I "$HERE/patcher.py"')
        verify_patch = activation.index('python3 -I "$HERE/patcher.py" --check')
        enable = activation.index("printf 'Y\\n' > \"$PARAM\"")

        self.assertLess(disable, unlock)
        self.assertLess(disable, activation.index("cores=$(awk"))
        self.assertLess(unlock, apply_patch)
        self.assertLess(apply_patch, verify_patch)
        self.assertLess(verify_patch, enable)
        self.assertIn("smu-8core-metrics-r1", activation)
        self.assertNotIn("--firmware", activation)

    def test_mailbox_waits_for_idle_before_writing(self):
        sys.path.insert(0, str(METRICS))
        try:
            from bc250_smu.mailbox import Bc250Mailbox
        finally:
            sys.path.pop(0)

        class Transport:
            def __init__(self):
                self.responses = iter((0, 1, 0, 1))
                self.writes = []

            def read_smu_reg(self, address):
                if address == 0x80:
                    return next(self.responses)
                return 0x1234

            def write_smu_reg(self, address, value):
                self.writes.append((address, value))

        transport = Transport()
        mailbox = Bc250Mailbox(transport, 3, 0x20, 0x80, 0x88, timeout=1)
        status, value = mailbox.send(0x2A, [0x55])

        self.assertEqual((status, value), (1, 0x1234))
        self.assertEqual(transport.writes[0], (0x80, 0))
        self.assertEqual(transport.writes[-1], (0x20, 0x2A))

    def test_patcher_uses_safe_pause_and_original_byte_manifest(self):
        patcher = (METRICS / "patcher.py").read_text(encoding="utf-8")

        self.assertIn("METRICS_TICK_NOOP = 0x1B220", patcher)
        self.assertIn("original_by_address[addr]", patcher)
        self.assertIn("current not in (original, new)", patcher)
        self.assertNotIn("smu.smu_write32(METRICS_TICK_SLOT, 0)", patcher)

    def test_unlock_recovers_an_already_open_gate(self):
        unlock = (METRICS / "unlock.py").read_text(encoding="utf-8")
        already_open = unlock.index("if not rejected_before:")
        recovery = unlock.index("restore_smu_state(smu)", already_open)
        early_return = unlock.index("return True", already_open)

        self.assertLess(recovery, early_return)
        self.assertIn("failed to restore SMU state", unlock)

    def test_transport_holds_the_pci_lock_for_its_lifetime(self):
        transport = (METRICS / "bc250_smu/transport.py").read_text(
            encoding="utf-8"
        )

        self.assertEqual(transport.count("fcntl.LOCK_EX"), 1)
        self.assertEqual(transport.count("fcntl.LOCK_UN"), 1)
        self.assertNotIn("def _lock", transport)

    def test_toolkit_installs_the_production_boot_service(self):
        power = (ROOT / "bc250-power.sh").read_text(encoding="utf-8")
        persistence = (ROOT / "bc250-update-persistence.sh").read_text(encoding="utf-8")

        self.assertIn('SMU_METRICS_SOURCE_DIR="$SCRIPT_DIR/core-unlock/smu-metrics"', power)
        self.assertIn('SMU_METRICS_SVC="bc250-8core-metrics.service"', power)
        self.assertIn("install_smu_metrics_files", power)
        self.assertIn("enable_smu_metrics_service", power)
        self.assertIn("bc250-8core-metrics.service", persistence)
        self.assertNotIn("smu_8core_metrics", power)
        installer = power[
            power.index("install_smu_metrics_files()") : power.index(
                "enable_smu_metrics_service()"
            )
        ]
        self.assertNotIn("cp -a", installer)
        self.assertIn('install -o root -g root -m 0644', installer)


if __name__ == "__main__":
    unittest.main()
