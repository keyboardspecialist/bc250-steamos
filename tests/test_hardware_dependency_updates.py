"""Offline regression checks; these never build/load a kernel module or touch hardware."""

import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AIC = ROOT / "aic8800/src/USB/driver_fw/drivers/aic8800"
FDRV = AIC / "aic8800_fdrv"
NCT = ROOT / "nct6687d"
AIC_PIN = "5327c777d00a94ee3bea09525b3acc8e1b031993"
NCT_PIN = "ec1030ba7acc32b36723af0c7c9c9aead5e57b54"
NCT_OLD = "a49a8abdfb6221772ecc836b3109e0cc338203cf"
NCT_HASHES = {
    "Kbuild": "ab83ace080e46646a9c807e31177a460902b11661bbbde31ed883261eccf3b45",
    "Makefile": "ed093eb8f14598a0030382d649c8f5917af303b3cf6a6f88a295c686f34c88e2",
    "nct6687.c": "23449e0ecb0af2145c4253c6f1b1a126eaf2c04e96b3c5757f3f31399b91940e",
    "LICENSE": "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643",
    "README.md": "9cc499871c1bff5ee55942bf7addfc07ae2aad9410728ca5b22c08c0c90c981e",
}


class HardwareDependencyUpdateTests(unittest.TestCase):
    def compile_run(self, source):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "abi-test"
            subprocess.run(
                ["cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                 "-Wno-unused-parameter", "-x", "c", "-o", str(executable), "-"],
                input=source, text=True, check=True, capture_output=True,
            )
            subprocess.run([str(executable)], check=True)

    def test_reviewed_pins_and_complete_nct_manifest(self):
        self.assertIn(f"Commit: {AIC_PIN}", (AIC / "UPSTREAM").read_text())
        fetcher = (NCT / "fetch-source.sh").read_text()
        entries = dict((name, digest) for digest, name in
                       re.findall(r"^([a-f0-9]{64})  (.+)$", fetcher, re.M))
        self.assertEqual(entries, NCT_HASHES)
        for name in ("fetch-source.sh", "steamdeck-setup.sh", "nct6687-ensure-module.sh"):
            self.assertIn(NCT_PIN, (NCT / name).read_text())

    def test_nct_upgrade_accepts_only_recognized_intact_source(self):
        installer = (NCT / "steamdeck-setup.sh").read_text()
        block = installer[installer.index('if [[ -e "$ROOT_SOURCE" || -L "$ROOT_SOURCE" ]]; then'):
                          installer.index('source_stage=$(mktemp')]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "nct6687.c").write_text("fixture\n")
            digest = hashlib.sha256((source / "nct6687.c").read_bytes()).hexdigest()
            (source / "source.sha256").write_text(f"{digest}  nct6687.c\n")
            marker = source / ".bc250-source"
            command = 'die() { echo "$*" >&2; exit 1; }; ROOT_SOURCE=$1\n' + block
            for pin, expected in ((NCT_PIN, 0), (NCT_OLD, 0), ("unknown", 1)):
                with self.subTest(pin=pin):
                    marker.write_text(pin + "\n")
                    result = subprocess.run(["bash", "-c", command, "_", str(source)],
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stderr)
            marker.write_text(NCT_OLD + "\n")
            (source / "nct6687.c").write_text("tampered\n")
            result = subprocess.run(["bash", "-c", command, "_", str(source)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("integrity check failed", result.stderr)

    @unittest.skipUnless(os.environ.get("BC250_TEST_NCT_SOURCE"),
                         "set BC250_TEST_NCT_SOURCE to an independently fetched pinned tree")
    def test_nct_reviewed_source_hashes_and_safety_semantics(self):
        source_dir = Path(os.environ["BC250_TEST_NCT_SOURCE"])
        for name, digest in NCT_HASHES.items():
            self.assertEqual(hashlib.sha256((source_dir / name).read_bytes()).hexdigest(), digest)
        source = (source_dir / "nct6687.c").read_text()
        constants = {name: int(value, 0) for name, value in re.findall(
            r"^#define (IOREGION_OFFSET|IOREGION_LENGTH|EC_SPACE_\w+_OFFSET) (0x[0-9a-fA-F]+|\d+)",
            source, re.M)}
        self.assertEqual(constants, {
            "IOREGION_OFFSET": 4, "IOREGION_LENGTH": 4,
            "EC_SPACE_PAGE_REGISTER_OFFSET": 0,
            "EC_SPACE_INDEX_REGISTER_OFFSET": 1,
            "EC_SPACE_DATA_REGISTER_OFFSET": 2,
        })
        self.assertEqual(source.count("value = (s8)nct6687_read("), 2)
        self.assertNotIn("EC_io_lock", source)
        self.assertNotRegex(source, r"HWMON_[IFT]_(?:MIN|MAX)\b")
        for name in ("nct6687_update_device", "nct6687_write_pwm",
                     "nct6687_write_pwm_enable", "nct6687_fan_watchdog_work",
                     "nct6687_suspend", "nct6687_resume",
                     "nct6687_restore_firmware_state"):
            function = re.search(r"\b" + name + r"\([^;]*?\)\n\{([\s\S]*?)\n\}", source)
            self.assertIsNotNone(function, name)
            self.assertIn("mutex_lock(&data->update_lock)", function.group(1), name)
        probe = source[source.index("static int nct6687_probe("):
                       source.index("static int nct6687_suspend(")]
        self.assertLess(probe.index("devm_add_action_or_reset("),
                        probe.index("devm_hwmon_device_register_with_info("))
        self.assertLess(probe.index("nct6687_setup_fans(data)"),
                        probe.index("devm_hwmon_device_register_with_info("))

    @unittest.skipIf(os.geteuid() == 0, "fetcher intentionally refuses root")
    def test_nct_fetcher_cache_and_failure_paths_without_network(self):
        # Exercise the real fetch flow with synthetic payloads and matching fixture hashes.
        script = (NCT / "fetch-source.sh").read_text()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "payload"
            payload.mkdir()
            for name, digest in NCT_HASHES.items():
                data = (name + " fixture\n").encode()
                (payload / name).write_bytes(data)
                script = script.replace(digest, hashlib.sha256(data).hexdigest())
            fetcher = root / "fetch-source.sh"
            fetcher.write_text(script)
            bindir = root / "bin"
            bindir.mkdir()
            curl = bindir / "curl"
            curl.write_text(
                '#!/bin/bash\nset -eu\n'
                'while [[ $# -gt 0 ]]; do\n'
                ' case "$1" in https:*) url=$1;; -o) shift; dest=$1;; esac\n'
                ' shift\ndone\n'
                '[[ "$url" == "https://raw.githubusercontent.com/Fred78290/nct6687d/'
                + NCT_PIN + '/"* ]] || exit 90\n'
                'echo "$url" >> "$FETCH_LOG"\n'
                'cp "$FETCH_PAYLOAD/${url##*/}" "$dest"\n'
            )
            curl.chmod(0o755)
            env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}",
                   "FETCH_LOG": str(root / "calls"), "FETCH_PAYLOAD": str(payload)}

            def fetch(destination):
                return subprocess.run(["bash", str(fetcher), str(destination)],
                                      env=env, capture_output=True, text=True)

            destination = root / "source"
            result = fetch(destination)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((destination / ".bc250-source").read_text().strip(), NCT_PIN)
            self.assertEqual(fetch(destination).returncode, 0)
            self.assertEqual(len((root / "calls").read_text().splitlines()), 5)
            (payload / "nct6687.c").write_text("corrupt payload\n")
            result = fetch(root / "bad-source")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("integrity verification failed", result.stderr)
            self.assertFalse((root / "bad-source").exists())
            unknown = root / "user-source"
            unknown.mkdir()
            (unknown / "keep").write_text("user data\n")
            self.assertNotEqual(fetch(unknown).returncode, 0)
            self.assertEqual((unknown / "keep").read_text(), "user data\n")

    @unittest.skipUnless(shutil.which("cc"), "C compiler unavailable")
    def test_monitor_callback_uses_header_type_not_kernel_version(self):
        source = (FDRV / "rwnx_main.c").read_text()
        wrappers = source[source.index("/* Newer cfg80211 stacks pass dev;"):
                          source.index("/**\n * @probe_client:")]
        choice = source.split(".set_monitor_channel = ", 1)[1].split(
            "#if AICWF_CFG80211_VERSION_CODE", 1)[0]
        for with_dev in (False, True):
            with self.subTest(with_dev=with_dev):
                args = "struct wiphy *, " + ("struct net_device *, " if with_dev else "")
                self.compile_run(
                    '#include <assert.h>\n'
                    'struct wiphy { int unused; }; struct net_device { int unused; };\n'
                    'struct cfg80211_chan_def { int unused; };\n'
                    'struct cfg80211_ops { int (*set_monitor_channel)('
                    + args + 'struct cfg80211_chan_def *); };\n'
                    'static int rwnx_cfg80211_set_monitor_channel(struct wiphy *w, '
                    'struct cfg80211_chan_def *c) { return 42; }\n'
                    + wrappers + '\nstatic struct cfg80211_ops ops = { .set_monitor_channel = '
                    + choice + '};\nint main(void) {\n'
                    'assert(ops.set_monitor_channel(0, ' + ('0, ' if with_dev else '')
                    + '0) == 42); return 0; }\n'
                )

    @unittest.skipUnless(shutil.which("cc"), "C compiler unavailable")
    def test_roc_callback_cookie_abi_for_native_and_backported_stacks(self):
        source = (FDRV / "rwnx_main.c").read_text()
        wrapper = source[source.index("static int\nrwnx_cfg80211_remain_on_channel("):
                         source.index("/**\n * @cancel_remain_on_channel:")]
        for kernel, wireless in (((6, 12, 0), (6, 12, 0)),
                                 ((6, 18, 0), (6, 18, 0)),
                                 ((7, 1, 0), (7, 1, 0)),
                                 ((7, 2, 0), (7, 2, 0)),
                                 ((7, 3, 0), (7, 3, 0)),
                                 ((6, 1, 0), (7, 3, 0))):
            with self.subTest(kernel=kernel, wireless=wireless):
                self.compile_run(
                    '#include <assert.h>\n#include <stdbool.h>\n'
                    'typedef unsigned long long u64; typedef unsigned char u8;\n'
                    '#define KERNEL_VERSION(a,b,c) (((a)<<16)+((b)<<8)+(c))\n'
                    f'#define LINUX_VERSION_CODE KERNEL_VERSION{kernel}\n'
                    f'#define AICWF_CFG80211_VERSION_CODE KERNEL_VERSION{wireless}\n'
                    'struct wiphy { int unused; }; struct wireless_dev { int unused; };\n'
                    'struct ieee80211_channel { int unused; };\n'
                    'static int rwnx_cfg80211_remain_on_channel_(struct wiphy *w, '
                    'struct wireless_dev *d, struct ieee80211_channel *c, '
                    'unsigned int duration, u64 *cookie, bool internal) {\n'
                    'assert(!internal); assert(duration == 30);\n'
                    '#if AICWF_CFG80211_VERSION_CODE >= KERNEL_VERSION(7,3,0)\n'
                    'assert(*cookie == 0x123456789abcdef0ULL);\n'
                    '#else\n*cookie = 66;\n#endif\nreturn 17; }\n'
                    + wrapper + '\nint main(void) {\n'
                    '#if AICWF_CFG80211_VERSION_CODE >= KERNEL_VERSION(7,3,0)\n'
                    'assert(rwnx_cfg80211_remain_on_channel(0,0,0,30,'
                    '0x123456789abcdef0ULL,0) == 17);\n'
                    '#else\nu64 cookie = 0;\n'
                    'assert(rwnx_cfg80211_remain_on_channel(0,0,0,30,&cookie\n'
                    '#if AICWF_CFG80211_VERSION_CODE >= KERNEL_VERSION(7,2,0)\n'
                    ',0\n#endif\n) == 17); assert(cookie == 66);\n'
                    '#endif\nreturn 0; }\n'
                )

    def test_aic_cookie_publication_and_internal_tx_initialization(self):
        source = (FDRV / "rwnx_main.c").read_text()
        probe = source[source.index("int rwnx_cfg80211_probe_client("):
                       source.index("void rwnx_cfg80211_mgmt_frame_register(")]
        self.assertLess(probe.index("vif->sta_probe.cookie = cookie;"),
                        probe.index("queue_work("))
        roc = source[source.index("rwnx_cfg80211_remain_on_channel_(struct wiphy"):
                     source.index("static int\nrwnx_cfg80211_remain_on_channel(")]
        self.assertLess(roc.index("roc_elem->cookie = roc_cookie;"),
                        roc.index("rwnx_hw->roc_elem = roc_elem;"))
        self.assertIn("mgmt_roc_flag ? (u64)(rwnx_hw->roc_cookie_cnt) : *cookie", roc)
        rx = (FDRV / "rwnx_msg_rx.c").read_text()
        notifications = re.findall(r"cfg80211_(?:ready_on_channel|remain_on_channel_expired)\(([^;]+);", rx)
        self.assertEqual(len(notifications), 6)
        self.assertTrue(all("roc_elem->cookie" in call for call in notifications))
        tx = (FDRV / "rwnx_tx.c").read_text()
        self.assertEqual(len(re.findall(r"sw_txhdr->skb\s*=", tx)), 5)
        self.assertEqual(len(re.findall(r"sw_txhdr->cookie\s*=", tx)), 5)
        self.assertIn("if (!use_given_cookie)\n        *cookie = (unsigned long)skb;", tx)
        self.assertRegex((FDRV / "rwnx_tx.h").read_text(),
                         r"struct rwnx_sw_txhdr\s*\{[\s\S]*?u64 cookie;")
        self.assertIn("&cookie, false)", (FDRV / "rwnx_tdls.c").read_text())

    def test_aic_local_adaptations_survive_source_rebase(self):
        self.assertIn("CONFIG_RWNX_MON_XMIT ?= n", (FDRV / "Makefile").read_text())
        self.assertIn("STEAMOS_KERNEL_PREPARER", (AIC / "Makefile").read_text())
        rx = (FDRV / "rwnx_rx.c").read_text()
        self.assertIn("reord_info_free_worker", rx)
        self.assertIn("queue_work(rx_priv->reord_free_wq", rx)
        self.assertIn("destroy_workqueue(rx_priv->reord_free_wq)",
                      (FDRV / "aicwf_txrxif.c").read_text())
        self.assertIn("eapol fixed-rate 6M (GO)", (FDRV / "rwnx_tx.c").read_text())
        self.assertIn("rate pinned to 6M OFDM + port open", (FDRV / "rwnx_main.c").read_text())
        self.assertIn('aic_fw_path, "aic8800D80", name',
                      (AIC / "aic_load_fw/aicbluetooth.c").read_text())
        zlp = (AIC / "aic_zlp_quirk/aic_zlp_quirk.c").read_text()
        self.assertIn("AIC_USB_VENDOR_ID_OEM", zlp)
        self.assertIn("usb:vA69Cp8D81", zlp)


if __name__ == "__main__":
    unittest.main()
