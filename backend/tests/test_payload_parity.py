import importlib.util
from pathlib import Path
import re
import unittest

from bc250_control.backend import METRICS_PAYLOAD_FILES


ROOT = Path(__file__).resolve().parents[2]


class MetricsPayloadParityTests(unittest.TestCase):
    def test_decky_bootstrap_installs_every_trusted_metrics_dependency(self):
        spec = importlib.util.spec_from_file_location("parity_bootstrap", ROOT / "decky-plugin/bootstrap.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        payload = dict(module.PAYLOAD_FILES)
        for relative in METRICS_PAYLOAD_FILES:
            with self.subTest(path=relative):
                self.assertIn(relative, payload)
                self.assertTrue((ROOT / relative).is_file())
                expected = 0o755 if relative.name == "activate-8core-metrics.sh" else 0o644
                self.assertEqual(payload[relative], expected)

    def test_shared_service_stages_the_same_fixed_metrics_files(self):
        source = (ROOT / "desktop-control/shared-service-install.sh").read_text()
        block = source.split("SHARED_METRICS_FILES=(", 1)[1].split(")", 1)[0]
        files = set(re.findall(r"[^\s]+", block))
        for relative in METRICS_PAYLOAD_FILES:
            self.assertIn(relative.relative_to("core-unlock/smu-metrics").as_posix(), files)
        self.assertIn('"$SHARED_STAGE/core-unlock/smu-metrics/$metrics_file"', source)
        self.assertIn('"$metrics_file" != activate-8core-metrics.sh', source)


if __name__ == "__main__":
    unittest.main()
