import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TABLES = ROOT / "acpi-tables"
POWER = ROOT / "bc250-power.sh"
WORKFLOW = ROOT / ".github/workflows/release-artifacts.yml"


def synthetic_dsdt(thread_count):
    processors = []
    for index in range(thread_count):
        processors.append(
            "        Processor (P00{:X}, 0x{:02X}, 0x00000000, 0x00) {{}}".format(
                index, index
            )
        )
    return "\n".join(
        [
            'DefinitionBlock ("", "DSDT", 2, "BC250", "CPUTEST", 1)',
            "{",
            "    Scope (\\_PR)",
            "    {",
            *processors,
            "    }",
            "}",
            "",
        ]
    )


class AcpiTableTests(unittest.TestCase):
    def test_optional_processor_scopes_and_aliases_are_guarded(self):
        cst = (TABLES / "SSDT-CST.dsl").read_text(encoding="utf-8")
        pst = (TABLES / "SSDT-PST.dsl").read_text(encoding="utf-8")

        for suffix in "CDEF":
            processor = r"\\_PR\.P00{}".format(suffix)
            guard = r"If \(CondRefOf \({}\)\)".format(processor)
            self.assertRegex(cst, guard)
            self.assertRegex(pst, guard)
            self.assertRegex(
                cst,
                r"{}[\s\S]*?Scope \({}\)[\s\S]*?Alias \({}, C00{}\)".format(
                    guard, processor, processor, suffix
                ),
            )
            self.assertRegex(
                pst,
                r"{}[\s\S]*?Scope \({}\)".format(guard, processor),
            )

    def test_state_definitions_match_the_published_tables(self):
        cst = (TABLES / "SSDT-CST.dsl").read_text(encoding="utf-8")
        pst = (TABLES / "SSDT-PST.dsl").read_text(encoding="utf-8")

        for address in ("0x0000000000000414", "0x0000000000000415"):
            self.assertIn(address, cst)
        for frequency in (3200, 2550, 2325, 1960, 1820, 1600, 1271, 800):
            self.assertRegex(pst, r"Package \(\) \{{\s*{}[, ]".format(frequency))

    def test_installer_versions_and_packages_the_universal_payload(self):
        power = POWER.read_text(encoding="utf-8")
        workflow = WORKFLOW.read_text(encoding="utf-8")
        decky = (ROOT / "decky-plugin/install.sh").read_text(encoding="utf-8")

        self.assertIn('ACPI_PAYLOAD_VERSION="universal-6c8c-v1"', power)
        self.assertIn("acpi_payload_current", power)
        self.assertIn("build_acpi_payload", power)
        self.assertIn("iasl -vs -we", power)
        self.assertIn('packages+=(acpica)', power)
        self.assertIn("bc250_platform_present", power)
        self.assertIn("acpi_source_digest", power)
        self.assertIn('acpi_source_digest "$work"', power)
        self.assertIn('ACPI_LIFECYCLE_LOCK="/run/lock/bc250-acpi.lock"', power)
        self.assertIn("BC250_ACPI_LOCK_HELD=1", power)
        self.assertIn('archive_actual=$(sha256sum "$CPIO_MASTER"', power)
        self.assertIn('mv -f "$archive_tmp" "$CPIO_MASTER"', power)
        self.assertIn('mv -f "$boot_tmp" "$CPIO_BOOT"', power)
        self.assertNotIn("ACPI_RAW_BASE", power)
        self.assertIn("acpi-tables decky-plugin", workflow)
        self.assertIn('acpi-tables/SSDT-CST.dsl', decky)
        self.assertIn('acpi-tables/SSDT-PST.dsl', decky)
        self.assertIn('bc250-power.sh" acpi', decky)

        backend = (ROOT / "backend/bc250_control/backend.py").read_text(
            encoding="utf-8"
        )
        self.assertIn('glob("cpu[0-9]*")', backend)
        self.assertIn('self._read(path / "online") != "0"', backend)
        self.assertIn("all((path / \"cpufreq\").is_dir()", backend)
        self.assertIn("min(c_state_counts, default=0)", backend)

    def test_payload_hashes_and_platform_identity_are_enforced(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    r'''
script=$1
base=$2
set -- help
source "$script" >/dev/null
ACPI_DIR="$base/state"
CPIO_MASTER="$ACPI_DIR/acpi_override.cpio"
ACPI_PAYLOAD_MARKER="$ACPI_DIR/payload-version"
ACPI_TABLE_DIR="$base/tables"
PCI_DEVICES_ROOT="$base/pci"
mkdir -p "$ACPI_DIR" "$ACPI_TABLE_DIR" "$PCI_DEVICES_ROOT/0000:00:00.0"
printf '%s\n' cst > "$ACPI_TABLE_DIR/SSDT-CST.dsl"
printf '%s\n' pst > "$ACPI_TABLE_DIR/SSDT-PST.dsl"
printf '%s\n' archive > "$CPIO_MASTER"
source_hash=$(acpi_source_digest)
archive_hash=$(sha256sum "$CPIO_MASTER" | awk '{print $1}')
printf '%s %s %s\n' "$ACPI_PAYLOAD_VERSION" "$source_hash" "$archive_hash" \
    > "$ACPI_PAYLOAD_MARKER"
acpi_payload_current
printf '%s\n' corrupt >> "$CPIO_MASTER"
! acpi_payload_current
printf '%s\n' archive > "$CPIO_MASTER"
printf '%s\n' changed >> "$ACPI_TABLE_DIR/SSDT-CST.dsl"
! acpi_payload_current
printf '%s\n' 0x1002 > "$PCI_DEVICES_ROOT/0000:00:00.0/vendor"
printf '%s\n' 0x13fe > "$PCI_DEVICES_ROOT/0000:00:00.0/device"
bc250_platform_present
printf '%s\n' 0xffff > "$PCI_DEVICES_ROOT/0000:00:00.0/device"
! bc250_platform_present
''',
                    "_",
                    str(POWER),
                    directory,
                ],
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "REAL_USER": "acpi-test",
                    "REAL_HOME": directory,
                },
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(
        shutil.which("iasl") and shutil.which("acpiexec") and shutil.which("cpio"),
        "ACPICA tools are not installed",
    )
    def test_tables_load_and_evaluate_in_six_and_eight_core_namespaces(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            compiled_tables = []
            for table in ("SSDT-CST", "SSDT-PST"):
                prefix = work / table
                result = subprocess.run(
                    [
                        "iasl",
                        "-vs",
                        "-we",
                        "-p",
                        str(prefix),
                        str(TABLES / "{}.dsl".format(table)),
                    ],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                compiled_tables.append(str(prefix.with_suffix(".aml")))

            payload = work / "payload/kernel/firmware/acpi"
            payload.mkdir(parents=True)
            for table in ("SSDT-CST", "SSDT-PST"):
                shutil.copyfile(work / "{}.aml".format(table), payload / "{}.aml".format(table))
            entries = "\n".join(
                (
                    "kernel",
                    "kernel/firmware",
                    "kernel/firmware/acpi",
                    "kernel/firmware/acpi/SSDT-CST.aml",
                    "kernel/firmware/acpi/SSDT-PST.aml",
                    "",
                )
            )
            archive = subprocess.run(
                ["cpio", "-o", "-H", "newc"],
                cwd=str(work / "payload"),
                input=entries.encode("ascii"),
                capture_output=True,
            )
            self.assertEqual(archive.returncode, 0, archive.stderr.decode())
            listing = subprocess.run(
                ["cpio", "-it"], input=archive.stdout, capture_output=True
            )
            self.assertEqual(listing.returncode, 0, listing.stderr.decode())
            self.assertEqual(
                listing.stdout.decode().splitlines(), entries.strip().splitlines()
            )

            for threads, endpoint in ((12, "B"), (16, "F")):
                source = work / "DSDT-{}.dsl".format(threads)
                prefix = work / "DSDT-{}".format(threads)
                source.write_text(synthetic_dsdt(threads), encoding="utf-8")
                compiled = subprocess.run(
                    ["iasl", "-vs", "-p", str(prefix), str(source)],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    compiled.returncode, 0, compiled.stdout + compiled.stderr
                )

                command = (
                    "evaluate \\_PR.P00{}._CST;"
                    "evaluate \\_PR.P00{}._PCT;"
                    "evaluate \\_PR.P00{}._PSS;"
                    "evaluate \\_PR.P00{}._PSD;"
                    "namespace \\_PR 2"
                ).format(endpoint, endpoint, endpoint, endpoint)
                loaded = subprocess.run(
                    [
                        "acpiexec",
                        "-b",
                        command,
                        str(prefix.with_suffix(".aml")),
                        *compiled_tables,
                    ],
                    capture_output=True,
                    text=True,
                )
                output = loaded.stdout + loaded.stderr
                self.assertEqual(loaded.returncode, 0, output)
                self.assertIn(
                    "3 ACPI AML tables successfully acquired and loaded", output
                )
                for method in ("_CST", "_PCT", "_PSS", "_PSD"):
                    self.assertIn(
                        "Evaluation of \\_PR.P00{}.{} returned object".format(
                            endpoint, method
                        ),
                        output,
                    )
                self.assertNotIn("AE_NOT_FOUND", output)
                if threads == 12:
                    self.assertNotIn("P00C Processor", output)
                    self.assertNotIn("C00C Alias", output)
                else:
                    self.assertIn("P00F Processor", output)
                    self.assertIn("C00F Alias", output)


if __name__ == "__main__":
    unittest.main()
