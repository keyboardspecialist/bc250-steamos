import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOPOLOGY = ROOT / "topology.sh"
COMPUTE = ROOT / "bc250-40cu.sh"


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

            result = subprocess.run(
                ["bash", str(TOPOLOGY)],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

        self.assertEqual(
            result.stdout,
            "BC250 CCX Core Map\n"
            "CCX 0 : ■ ■ ■ □ \n"
            "CCX 1 : ■ □ ■ □ \n",
        )

    def test_compute_menu_dispatches_to_topology_helper(self):
        source = COMPUTE.read_text(encoding="utf-8")

        self.assertIn('TOPOLOGY_SH="${TOPOLOGY_SH:-$SCRIPT_DIR/topology.sh}"', source)
        self.assertIn('"CPU core topology|', source)
        self.assertIn("topology) (($# == 1))", source)

    def test_scripts_parse(self):
        subprocess.run(["bash", "-n", str(TOPOLOGY)], check=True)
        subprocess.run(["bash", "-n", str(COMPUTE)], check=True)


if __name__ == "__main__":
    unittest.main()
