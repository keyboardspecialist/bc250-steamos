import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOPOLOGY = ROOT / "topology.sh"
POWER = ROOT / "bc250-power.sh"


class TopologyTests(unittest.TestCase):
    def test_renders_cpu_core_map_by_ccx(self):
        with tempfile.TemporaryDirectory() as directory:
            bindir = Path(directory)
            lscpu = bindir / "lscpu"
            lscpu.write_text(
                "#!/usr/bin/env bash\n"
                "cat <<'EOF'\n"
                "CPU CORE CACHE\n"
                "  0    0 0:0:0:0\n"
                "  1    1 1:1:1:0\n"
                "  2    2 2:2:2:0\n"
                "  4    4 4:4:4:1\n"
                "  6    6 6:6:6:1\n"
                "EOF\n",
                encoding="utf-8",
            )
            lscpu.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{bindir}:{env['PATH']}"
            env["REAL_HOME"] = directory
            env["FIXES_REPO_DIR"] = directory

            direct = subprocess.run(
                ["bash", str(TOPOLOGY)],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            integrated = subprocess.run(
                ["bash", str(POWER), "cpu-unlock", "topology"],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

        expected = (
            "BC250 CCX Core Map\n"
            "CCX 0 : ■ ■ ■ □ \n"
            "CCX 1 : ■ □ ■ □ \n"
        )
        self.assertEqual(direct.stdout, expected)
        self.assertEqual(integrated.stdout, expected)

    def test_power_menu_exposes_topology_action(self):
        source = POWER.read_text(encoding="utf-8")

        self.assertIn('TOPOLOGY_SH="${TOPOLOGY_SH:-$SCRIPT_DIR/topology.sh}"', source)
        self.assertIn('"Show CCX core map|', source)
        self.assertIn("topology)  core_unlock_topology", source)

    def test_scripts_parse(self):
        subprocess.run(["bash", "-n", str(TOPOLOGY)], check=True)
        subprocess.run(["bash", "-n", str(POWER)], check=True)


if __name__ == "__main__":
    unittest.main()
