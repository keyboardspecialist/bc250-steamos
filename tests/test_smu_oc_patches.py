import importlib
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / "smu-oc-patches"


class SmuOcPatchTests(unittest.TestCase):
    def test_public_smu_timeout_default_is_five_seconds(self):
        api = (PATCHES / "api.py").read_text(encoding="utf-8")
        mailbox = (PATCHES / "mailbox.py").read_text(encoding="utf-8")
        self.assertIn("timeout: float = 5.0", api)
        self.assertIn("timeout: float = 5.0", mailbox)

    def test_mailbox_waits_longer_than_the_upstream_attempt_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            package_name = "smu_oc_mailbox_test"
            package = Path(directory) / package_name
            package.mkdir()
            (package / "__init__.py").write_text("", encoding="ascii")
            (package / "transport.py").write_text(
                "class Bc250PciTransport:\n    pass\n", encoding="ascii"
            )
            (package / "mailbox.py").write_bytes((PATCHES / "mailbox.py").read_bytes())
            sys.path.insert(0, directory)
            try:
                mailbox_module = importlib.import_module(f"{package_name}.mailbox")

                class SlowTransport:
                    def __init__(self):
                        self.polls = 0

                    def write_smu_reg(self, _address, _value):
                        pass

                    def read_smu_reg(self, _address):
                        self.polls += 1
                        return 1 if self.polls > 150 else 0

                transport = SlowTransport()
                mailbox = mailbox_module.Bc250Mailbox(
                    transport, 0x20, 0x80, 0x88, timeout=1.0
                )
                self.assertEqual(mailbox.send(0x01, 123), 1)
                self.assertEqual(transport.polls, 151)
            finally:
                sys.path.remove(directory)
                sys.modules.pop(f"{package_name}.mailbox", None)
                sys.modules.pop(f"{package_name}.transport", None)
                sys.modules.pop(package_name, None)


if __name__ == "__main__":
    unittest.main()
