import json
import re
import unittest
from pathlib import Path

from scripts.menu_graph import parse

ROOT = Path(__file__).resolve().parents[1]


class InstallVersionTests(unittest.TestCase):
    def test_menu_versions_match_installer_pins(self):
        toolkit = parse(ROOT / "menus/toolkit.mmd")
        mesh = parse(ROOT / "menus/mesh-shader.mmd")
        cases = (
            (toolkit, "action__graphics_setup", "bc250-mesh-shader.sh", "DEFAULT_MESA_TAG", "mesa-"),
            (toolkit, "action__graphics_setup", "bc250-mesh-shader.sh", "DIRECTMESH_RELEASE", "directmesh-v"),
            (mesh, "action__setup", "bc250-mesh-shader.sh", "DEFAULT_MESA_TAG", "mesa-"),
            (mesh, "action__setup", "bc250-mesh-shader.sh", "DIRECTMESH_RELEASE", "directmesh-v"),
            (mesh, "action__fsr4_dll", "bc250-fsr4.sh", "RELEASE", ""),
            (mesh, "action__helixsr_prepare", "bc250-helixsr.sh", "RELEASE", ""),
            (toolkit, "action__coolercontrol", "coolercontrol/install.sh", "VERSION", ""),
            (toolkit, "action__video_codec_install", "video-codec/bc250-video-codec.sh", "RELEASE", ""),
        )
        for graph, node, filename, key, prefix in cases:
            with self.subTest(node=node, key=key):
                line = re.search(r"^" + key + r"=(.*)$", (ROOT / filename).read_text(), re.M).group(1)
                value = re.search(r"(?:mesa-|directmesh-v|v)?[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-rc[0-9]+)?", line).group(0)
                self.assertIn(value[len(prefix):] if prefix else value, graph.nodes[node].title)
        plugin = json.loads((ROOT / "decky-plugin/package.json").read_text())["version"]
        plasma = json.loads((ROOT / "desktop-control/plasmoid/metadata.json").read_text())["KPlugin"]["Version"]
        self.assertIn(plugin, toolkit.nodes["action__decky"].title)
        self.assertIn(plasma, toolkit.nodes["action__desktop"].title)

    def test_dynamic_installers_do_not_claim_a_fixed_version(self):
        graph = parse(ROOT / "menus/toolkit.mmd")
        for node in ("action__trainer", "action__proton_install", "action__proton_update"):
            self.assertIn("latest", graph.nodes[node].title)
