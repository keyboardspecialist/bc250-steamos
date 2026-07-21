import functools
import http.server
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FETCHER = ROOT / "fetch-steamos-package.sh"
WIFI_MAKEFILE = ROOT / "aic8800/src/USB/driver_fw/drivers/aic8800/Makefile"
RELEASE = "6.16.12-valve24.5-1-neptune-616-gb2f7cfe85e45"
PACKAGE = "linux-neptune-616-headers-6.16.12.valve24.5-1-x86_64.pkg.tar.zst"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, _format, *args):
        pass

    def do_HEAD(self):
        if self.path.startswith("/jupiter-broken/"):
            self.send_error(500)
            return
        super().do_HEAD()


class HeaderFetchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        package_dir = self.root / "mirror/jupiter-3.8.1x/os/x86_64"
        package_dir.mkdir(parents=True)

        payload = (
            self.root / "payload/usr/lib/modules" / RELEASE / "build/include/config"
        )
        payload.mkdir(parents=True)
        (payload / "kernel.release").write_text(RELEASE + "\n", encoding="ascii")
        subprocess.run(
            ["tar", "--zstd", "-cf", str(package_dir / PACKAGE), "-C", str(self.root / "payload"), "usr"],
            check=True,
        )

        handler = functools.partial(QuietHandler, directory=str(self.root / "mirror"))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.mirror = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def test_fetcher_discovers_versioned_channel_and_replaces_bad_cache(self):
        destination = self.root / "download" / PACKAGE
        destination.parent.mkdir()
        destination.write_text("failed download", encoding="ascii")

        result = subprocess.run(
            ["bash", str(FETCHER), PACKAGE, str(destination)],
            env={**os.environ, "MIRROR": self.mirror},
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertIn("from jupiter-3.8.1x", result.stdout)
        subprocess.run(
            ["tar", "--zstd", "-tf", str(destination)],
            check=True,
            stdout=subprocess.DEVNULL,
        )

    def test_fetcher_returns_three_when_package_is_absent(self):
        destination = self.root / "download" / "missing.pkg.tar.zst"

        result = subprocess.run(
            ["bash", str(FETCHER), destination.name, str(destination)],
            env={
                **os.environ,
                "MIRROR": self.mirror,
                "HDR_REPOS": "jupiter-main jupiter-3.8.1x",
            },
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 3)
        self.assertIn("Could not find", result.stderr)
        self.assertFalse(destination.exists())

    def test_fetcher_does_not_report_server_errors_as_absent(self):
        destination = self.root / "download" / "missing.pkg.tar.zst"

        result = subprocess.run(
            ["bash", str(FETCHER), destination.name, str(destination)],
            env={**os.environ, "MIRROR": self.mirror, "HDR_REPOS": "jupiter-broken"},
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("Could not reliably retrieve", result.stderr)

    def test_fetcher_does_not_report_invalid_repositories_as_absent(self):
        destination = self.root / "download" / "missing.pkg.tar.zst"

        result = subprocess.run(
            ["bash", str(FETCHER), destination.name, str(destination)],
            env={**os.environ, "MIRROR": self.mirror, "HDR_REPOS": "not-a-jupiter-repo"},
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid-repository", result.stderr)

    def test_wifi_target_uses_discovered_channel_and_checks_release(self):
        driver = self.root / "driver"
        driver.mkdir()
        shutil.copy2(WIFI_MAKEFILE, driver / "Makefile")
        pkgbase = self.root / "pkgbase"
        pkgbase.write_text("linux-neptune-616\n", encoding="ascii")

        subprocess.run(
            [
                "make",
                "-C",
                str(driver),
                "steamos-headers",
                f"UNAME_R={RELEASE}",
                f"PKGBASE_FILE={pkgbase}",
                f"STEAMOS_HEADER_FETCHER={FETCHER}",
                f"STEAMOS_MIRROR={self.mirror}",
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        release_file = (
            driver
            / "steamos-headers/usr/lib/modules"
            / RELEASE
            / "build/include/config/kernel.release"
        )
        self.assertEqual(release_file.read_text(encoding="ascii").strip(), RELEASE)

    def test_wifi_target_falls_back_to_prepared_source_tree(self):
        driver = self.root / "driver-fallback"
        driver.mkdir()
        shutil.copy2(WIFI_MAKEFILE, driver / "Makefile")
        pkgbase = self.root / "pkgbase-fallback"
        pkgbase.write_text("linux-neptune-616\n", encoding="ascii")
        tree = self.root / "kernel-tree"
        preparer = self.root / "prepare-kernel.sh"
        preparer.write_text(
            "#!/bin/bash\n"
            "set -eu\n"
            "mkdir -p \"$1/include/config\"\n"
            f"printf '%s\\n' '{RELEASE}' > \"$1/include/config/kernel.release\"\n",
            encoding="ascii",
        )

        subprocess.run(
            [
                "make",
                "-C",
                str(driver),
                "steamos-headers",
                f"UNAME_R={RELEASE}",
                f"PKGBASE_FILE={pkgbase}",
                f"STEAMOS_HEADER_FETCHER={FETCHER}",
                f"STEAMOS_MIRROR={self.mirror}",
                "STEAMOS_HEADER_REPOS=jupiter-main",
                f"STEAMOS_KERNEL_PREPARER={preparer}",
                f"STEAMOS_KERNEL_TREE={tree}",
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        build = driver / "steamos-headers/usr/lib/modules" / RELEASE / "build"
        self.assertTrue(build.is_symlink())
        self.assertEqual(build.resolve(), tree.resolve())


if __name__ == "__main__":
    unittest.main()
