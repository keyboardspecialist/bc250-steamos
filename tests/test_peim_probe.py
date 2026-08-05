import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PEIM = ROOT / "bc250-pmfw-pei"
BUILD_CHECK = ROOT / "scripts/check-peim-probe-build.sh"


class PeimProbeTests(unittest.TestCase):
    def test_native_mailbox_state_machine(self):
        subprocess.run([str(BUILD_CHECK), "--host-only"], check=True)

    def test_probe_is_read_only_and_runs_from_synchronous_notify(self):
        source = (PEIM / "Bc250EarlyProbePeim.c").read_text(encoding="ascii")
        mailbox = (PEIM / "Bc250Mailbox.c").read_text(encoding="ascii")
        header = (PEIM / "Include/Bc250Mailbox.h").read_text(encoding="ascii")
        result = (PEIM / "Include/Bc250PeiResult.h").read_text(encoding="ascii")
        metadata = (PEIM / "Bc250EarlyProbePeim.inf").read_text(encoding="ascii")

        self.assertIn("EFI_PEI_PPI_DESCRIPTOR_NOTIFY_CALLBACK", source)
        self.assertIn("PeiServicesNotifyPpi", source)
        self.assertIn("Bc250ProbeDispatchGate", source)
        self.assertIn("#define BC250_LOCAL_READ_MESSAGE       0x27U", header)
        self.assertIn("BC250_LOCAL_READ_MESSAGE", mailbox)
        self.assertNotIn("0x28", source + mailbox + header)
        self.assertNotIn("0x29", source + mailbox + header)
        self.assertIn("BC250_GPU_PCI_ID     0x13fe1002U", source)
        self.assertIn("BC250_ROOT_PCI_ID    0x13e01022U", source)
        self.assertIn("STATIC_ASSERT (sizeof (BC250_PEI_RESULT) == 56", source)
        self.assertIn("Bc250PeiStageGateOpen = 13", result)
        self.assertIn("[Depex]\n  TRUE", metadata)
        self.assertNotIn("BEFORE", metadata)

    def test_package_targets_ia32_peim_and_pins_edk2(self):
        platform = (PEIM / "Bc250Pkg.dsc").read_text(encoding="ascii")
        metadata = (PEIM / "Bc250EarlyProbePeim.inf").read_text(encoding="ascii")
        build = BUILD_CHECK.read_text(encoding="ascii")

        self.assertIn("SUPPORTED_ARCHITECTURES        = IA32", platform)
        self.assertIn("MODULE_TYPE                    = PEIM", metadata)
        self.assertIn("6951dfe7d59d144a3a980bd7eda699db2d8554ac", build)
        self.assertNotIn("GenFv", build)
        self.assertNotIn("flash", build.lower())


if __name__ == "__main__":
    unittest.main()
