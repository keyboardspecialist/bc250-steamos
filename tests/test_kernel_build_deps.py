"""Offline, isolated SteamOS dependency-channel and runtime regression tests."""

import functools
import hashlib
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ("pahole", "bc", "libelf", "openssl", "zlib", "glibc",
            "linux-api-headers", "bison", "flex", "cpio", "gettext", "perl", "python")
TOOLS = ("make", "gcc", "ld", "ar", "nm", "objcopy", "objdump", "strip",
         "patch", "pkg-config", "zstd", "modinfo")


class Handler(http.server.SimpleHTTPRequestHandler):
    requests = None

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.requests.append(self.path)
        super().do_GET()


class KernelBuildDepsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.driver = self.root / "driver"
        self.driver.mkdir()
        for name in ("fetch-build-deps.sh", "build-env.sh"):
            shutil.copy2(ROOT / "bc250-audio-fix" / name, self.driver / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in TOOLS:
            # fetch-build-deps uses real tar's zstd subprocess, not this probe.
            if name != "zstd":
                self.executable(self.bin / name, "exit 0\n")
        self.executable(self.bin / "pacman-conf", "printf 'jupiter-3.9\\ncore-3.9\\nextra-3.9\\n'\n")
        self.requests = []
        handler = functools.partial(Handler, directory=str(self.root / "mirror"))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.server.RequestHandlerClass.func.requests = self.requests
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "MIRROR": f"http://127.0.0.1:{self.server.server_port}",
                    "PROBE_LOG": str(self.root / "probes")}
        self.env.pop("DEP_REPOS", None)
        self.env.pop("BC250_BUILD_DEPS", None)
        self.mirror("3.9")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def executable(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def mirror(self, channel, version="1.0", broken_python=False, bad_checksum=False):
        dbs = {f"extra-{channel}": {}, f"core-{channel}": {}}
        for pkg in PACKAGES:
            repo = f"{'extra' if pkg == 'pahole' else 'core'}-{channel}"
            entry = f"{pkg}-{version}-1"
            filename = f"{entry}-x86_64.pkg.tar.zst"
            work = self.root / f"payload-{channel}-{pkg}"
            if work.exists():
                shutil.rmtree(work)
            (work / "usr/include").mkdir(parents=True)
            (work / "usr/include" / pkg).write_text(channel + " " + version)
            command = {"python": "python3", "gettext": "msgfmt"}.get(pkg, pkg)
            if pkg in ("pahole", "bc", "bison", "flex", "cpio", "gettext", "perl", "python"):
                body = 'printf "%s|%s|%s|%s\\n" "$0" "$*" "$LD_LIBRARY_PATH" "$PERL5LIB" >> "$PROBE_LOG"\n'
                if broken_python and pkg == "python":
                    body += 'if [ "$1" != --version ]; then echo "GLIBC_2.44 not found" >&2; exit 1; fi\n'
                body += "exit 0\n"
                self.executable(work / "usr/bin" / command, body)
            if pkg == "perl":
                library = work / "usr/lib/perl5/5.44/core_perl/CORE/libperl.so"
                library.parent.mkdir(parents=True)
                library.write_text("synthetic private Perl library")
            if pkg == "glibc":
                library = work / "usr/lib/libc.so.6"
                library.parent.mkdir(parents=True)
                library.write_text("must not shadow the host libc")
            dest = self.root / "mirror" / repo / "os/x86_64"
            dest.mkdir(parents=True, exist_ok=True)
            archive = dest / filename
            subprocess.run(["tar", "--zstd", "-cf", str(archive), "-C", str(work), "usr"], check=True)
            sha = "0" * 64 if bad_checksum and pkg == "python" else hashlib.sha256(archive.read_bytes()).hexdigest()
            dbs[repo][entry] = f"%NAME%\n{pkg}\n\n%FILENAME%\n{filename}\n\n%SHA256SUM%\n{sha}\n"
        for repo, entries in dbs.items():
            dbroot = self.root / ("db-" + repo)
            if dbroot.exists():
                shutil.rmtree(dbroot)
            for name, desc in entries.items():
                (dbroot / name).mkdir(parents=True)
                (dbroot / name / "desc").write_text(desc)
            db = self.root / "mirror" / repo / "os/x86_64" / (repo + ".db")
            subprocess.run(["tar", "-cf", str(db), "-C", str(dbroot), *entries], check=True)

    def run_fetch(self, **changes):
        return subprocess.run(["bash", str(self.driver / "fetch-build-deps.sh")],
                              env={**self.env, **changes}, capture_output=True, text=True)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_default_uses_installed_versioned_repositories_not_main(self):
        self.mirror("main", "2.0", broken_python=True)
        result = self.run_fetch()
        self.assert_ok(result)
        self.assertIn("extra-3.9 core-3.9", result.stdout)
        self.assertFalse(any("-main/" in url for url in self.requests))
        deps = self.driver / "deps"
        self.assertEqual((deps / "usr/include/python").read_text(), "3.9 1.0")
        self.assertFalse((deps / "usr/lib/libc.so.6").exists())

    def test_matching_cross_host_override_is_supported(self):
        self.mirror("3.8.1x")
        self.assert_ok(self.run_fetch(DEP_REPOS="extra-3.8.1x core-3.8.1x"))
        self.assertTrue(any("core-3.8.1x/" in url for url in self.requests))

    def test_invalid_mixed_or_ambiguous_repositories_fail_before_download(self):
        for repos in ("extra-main core-3.9", "extra-3.9", "extra-3.9 extra-3.9", "extra-../../x core-../../x"):
            with self.subTest(repos=repos):
                self.assertNotEqual(self.run_fetch(DEP_REPOS=repos).returncode, 0)
        self.assertEqual(self.requests, [])
        self.assertFalse((self.driver / "deps").exists())

    def test_discovery_failure_does_not_fall_back_to_main(self):
        self.executable(self.bin / "pacman-conf", "exit 1\n")
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repository configuration", result.stderr)
        self.assertEqual(self.requests, [])

    def test_legacy_done_markers_do_not_preserve_incompatible_overlay(self):
        deps = self.driver / "deps"
        deps.mkdir()
        (deps / ".python-1.0-1.done").touch()
        (deps / "user-note").write_text("preserve old cache")
        self.assert_ok(self.run_fetch())
        self.assertFalse((deps / "user-note").exists())
        backups = list(self.driver.glob(".deps-previous.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "user-note").read_text(), "preserve old cache")

    def test_current_cache_is_reused_but_runtime_checks_still_execute(self):
        self.assert_ok(self.run_fetch())
        self.requests.clear()
        (self.root / "probes").write_text("")
        self.assert_ok(self.run_fetch())
        self.assertEqual(len(self.requests), 2)
        self.assertTrue(all(url.endswith(".db") for url in self.requests))
        self.assertIn("import math, subprocess, sysconfig", (self.root / "probes").read_text())
        self.assertFalse(list(self.driver.glob(".deps-previous.*")))

    def test_channel_change_replaces_whole_tree_without_stale_files(self):
        self.assert_ok(self.run_fetch())
        deps = self.driver / "deps"
        (deps / "stale-library").touch()
        self.mirror("3.10", "2.0")
        self.assert_ok(self.run_fetch(DEP_REPOS="extra-3.10 core-3.10"))
        self.assertFalse((deps / "stale-library").exists())
        self.assertEqual((deps / "usr/include/python").read_text(), "3.10 2.0")

    def test_changed_package_set_refreshes_cache(self):
        self.assert_ok(self.run_fetch())
        self.mirror("3.9", "2.0")
        self.assert_ok(self.run_fetch())
        self.assertEqual((self.driver / "deps/usr/include/python").read_text(), "3.9 2.0")

    def test_broken_current_cache_is_repaired_from_verified_archives(self):
        self.assert_ok(self.run_fetch())
        self.executable(self.driver / "deps/usr/bin/python3",
                        'if [ "$1" = --version ]; then exit 0; fi\necho broken-import >&2\nexit 1\n')
        self.requests.clear()
        result = self.run_fetch()
        self.assert_ok(result)
        self.assertIn("broken-import", result.stderr)
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(len(list(self.driver.glob(".deps-previous.*"))), 1)

    def test_unusable_host_tool_fails_runtime_checks(self):
        self.executable(self.bin / "gcc", "exit 127\n")
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gcc cannot run", result.stderr)
        self.assertFalse((self.driver / "deps").exists())

    def test_unusable_host_headers_fail_runtime_checks(self):
        self.executable(self.bin / "gcc", 'if [ "$1" = --version ]; then exit 0; fi\nexit 1\n')
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("host C headers are unusable", result.stderr)
        self.assertFalse((self.driver / "deps").exists())

    def test_broken_python_import_aborts_before_replacing_good_cache(self):
        self.assert_ok(self.run_fetch())
        manifest = self.driver / "deps/.bc250-build-deps"
        before = manifest.read_bytes()
        self.mirror("3.9", "2.0", broken_python=True)
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GLIBC_2.44", result.stderr)
        self.assertIn("Python build modules", result.stderr)
        self.assertEqual(manifest.read_bytes(), before)
        self.assertFalse(list(self.driver.glob(".deps-stage.*")))
        self.assertFalse(list(self.driver.glob(".deps-previous.*")))

    def test_corrupt_archive_cache_is_replaced_with_verified_download(self):
        archive = self.driver / "python-1.0-1-x86_64.pkg.tar.zst"
        archive.write_text("bad old download")
        self.assert_ok(self.run_fetch())
        self.assertNotEqual(archive.read_bytes(), b"bad old download")

    def test_download_checksum_mismatch_never_publishes_dependencies(self):
        self.mirror("3.9", bad_checksum=True)
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checksum mismatch", result.stderr)
        self.assertFalse((self.driver / "deps").exists())

    def test_symlinked_dependency_directory_is_refused(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "keep").write_text("user data")
        (self.driver / "deps").symlink_to(outside, target_is_directory=True)
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((outside / "keep").read_text(), "user data")
        self.assertEqual(self.requests, [])

    def test_private_perl_library_and_modules_are_visible_during_checks(self):
        self.assert_ok(self.run_fetch())
        probes = (self.root / "probes").read_text()
        line = next(line for line in probes.splitlines() if "|-MConfig -MFile::Spec -e 1|" in line)
        self.assertIn("/usr/lib/perl5/5.44/core_perl/CORE:", line)
        self.assertIn("/usr/share/perl5/core_perl:", line)


if __name__ == "__main__":
    unittest.main()
