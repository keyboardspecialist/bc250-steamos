"""Public, fixed CLI menu routes used by native frontend handoffs."""

from pathlib import Path
import json
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOOLKIT = ROOT / "bc250-toolkit.sh"


class CliFrontendRouteTests(unittest.TestCase):
    def test_capability_probe_is_structured_and_matches_the_checkout_version(self):
        result = subprocess.run(
            ["bash", str(TOOLKIT), "frontend-capabilities-json"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["toolkitVersion"], (ROOT / "VERSION").read_text().strip())
        self.assertEqual(len(payload["menuSections"]), len(set(payload["menuSections"])))
        for route in ("core", "graphics", "devices", "maintenance", "amdgpu-boot", "interfaces", "toolkit-update"):
            self.assertIn(route, payload["menuSections"])
        self.assertIn("global-directmesh", payload["features"])
        self.assertIn("cpu-unlock-metrics", payload["features"])
        self.assertEqual(result.stderr, "")

    def run_route(self, root, route, extra=False):
        dispatch = root / "dispatch.sh"
        source = TOOLKIT.read_text()
        dispatch.write_text(source[source.index('case "$command_name" in'):])
        return subprocess.run(
            ["bash", "-c", 'script=$1; route=$2; dispatch=$3; extra=$4; '
             'set -- help; source "$script" >/dev/null; '
             'require_terminal() { :; }; require_normal_user() { :; }; '
             'menu_graph_open() { printf "%s\\n" "$1"; }; '
             'command_name=$route; set --; if [[ "$extra" == yes ]]; then set -- unexpected; fi; '
             'source "$dispatch"',
             "test", str(TOOLKIT), route, str(dispatch), "yes" if extra else "no"],
            capture_output=True, text=True,
        )

    def test_public_domain_routes_open_the_exact_canonical_graph_entry(self):
        for route in ("core", "graphics", "devices", "maintenance", "amdgpu-boot"):
            with self.subTest(route=route), tempfile.TemporaryDirectory() as temporary:
                result = self.run_route(Path(temporary), route)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), route)

    def test_public_routes_reject_additional_arguments_before_opening(self):
        for route in ("core", "graphics", "devices", "maintenance", "amdgpu-boot"):
            with self.subTest(route=route), tempfile.TemporaryDirectory() as temporary:
                result = self.run_route(Path(temporary), route, extra=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Usage:", result.stderr)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
