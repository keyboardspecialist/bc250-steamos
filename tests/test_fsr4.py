import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "bc250-fsr4.sh"


class FSR4HelixConflictTests(unittest.TestCase):
    def test_install_refuses_helixsr_managed_target_before_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "game/amd_fidelityfx_upscaler_dx12.dll"
            target.parent.mkdir()
            target.write_bytes(b"game dll\n")
            target_path = str(target.resolve())
            identifier = hashlib.sha256(target_path.encode()).hexdigest()
            record = root / "helixsr/installs" / identifier
            record.mkdir(parents=True)
            (record / "record.json").write_text(json.dumps({
                "targetId": identifier,
                "targetPath": target_path,
            }), encoding="utf-8")
            env = {
                **os.environ,
                "HOME": str(root / "home"),
                "BC250_FSR4_STATE_DIR": str(root / "fsr4"),
                "BC250_FSR4_LOCK_FILE": str(root / "fsr4.lock"),
                "BC250_HELIXSR_STATE_DIR": str(root / "helixsr"),
                "BC250_HELIXSR_LOCK_FILE": str(root / "helixsr.lock"),
            }

            result = subprocess.run(
                ["bash", str(HELPER), "install", str(target)], env=env,
                check=False, capture_output=True, text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("managed by HelixSR", result.stderr)
            self.assertEqual(target.read_bytes(), b"game dll\n")


if __name__ == "__main__":
    unittest.main()
