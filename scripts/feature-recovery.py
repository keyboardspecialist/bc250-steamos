#!/usr/bin/env python3
"""Local feature inventory and conservative, opt-in post-update recovery.

The journal is data only. Commands and privilege boundaries are fixed here,
never loaded from the journal. Existing component helpers retain ownership,
checksum, hardware and transaction checks.
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend/bc250_control"))
from feature_state import (  # noqa: E402
    COMPONENTS, INVENTORY_COMPONENTS, journal, state_path, validate_state,
)
SCRIPTS = {
    "storage": ("STORAGE_SH", "bc250-storage.sh"),
    "audio": ("AUDIO_SH", "bc250-audio-fix/patch-driver.sh"),
    "fan": ("FAN_SH", "nct6687d/steamdeck-setup.sh"),
    "aic": ("AIC_SH", "aic8800/steamdeck-setup.sh"),
    "ram": ("RAM_SH", "bc250-ram-split.sh"),
    "proton": ("PROTON_SH", "bc250-proton.sh"),
}
ORDER = list(SCRIPTS) + sorted(COMPONENTS - set(SCRIPTS))
MANUAL = "Review the component's own status/setup; automatic replay could change tuning, unlocks, game files or frontend choices."


def script_command(component, *arguments, privileged=False):
    variable, relative = SCRIPTS[component]
    path = Path(os.environ.get(variable, str(ROOT / relative)))
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Missing or unsafe helper: {path}")
    return (["sudo"] if privileged else []) + ["bash", str(path), *arguments]


def probe(component, *arguments):
    return subprocess.run(script_command(component, *arguments), text=True,
                          capture_output=True, timeout=60)


def json_probe(component):
    result = probe(component, "status-json")
    if result.returncode:
        raise ValueError(f"{component}: status probe failed")
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise ValueError(f"{component}: invalid status")
    if component == "ram":
        if (value.get("schemaVersion") != 1
                or value.get("toolState") not in {"verified", "invalid", "not-installed"}
                or value.get("ttmState") not in {"configured", "default", "foreign"}
                or type(value.get("protected")) is not bool
                or type(value.get("rebootRequired")) is not bool
                or type(value.get("ttmOverrideRemoved", False)) is not bool):
            raise ValueError("ram: incomplete/invalid status")
        pages = value.get("ttmConfiguredPages")
        if value["ttmState"] == "configured" and not (
            type(pages) is int and 65536 <= pages <= 3670016
        ):
            raise ValueError("ram: invalid configured TTM limit")
        for key in ("ttmConfiguredPages", "ttmBootPages", "ttmLivePages"):
            if key not in value or not (value[key] is None or type(value[key]) is int and value[key] >= 0):
                raise ValueError(f"ram: invalid {key}")
        requested = value.get("ttmLastRequestedPages")
        if requested is not None and not (type(requested) is int and 65536 <= requested <= 3670016):
            raise ValueError("ram: invalid last requested TTM limit")
    return value


def inventory():
    result = subprocess.run(["bash", str(ROOT / "bc250-maintenance.sh"), "status-json"],
                            text=True, capture_output=True, timeout=120, check=True)
    value = json.loads(result.stdout)
    if not isinstance(value, dict) or value.get("schemaVersion") != 1 or not isinstance(value.get("components"), list):
        raise ValueError("Invalid component inventory")
    states = {}
    for row in value["components"]:
        if not isinstance(row, dict) or row.get("id") not in INVENTORY_COMPONENTS or row.get("state") not in {
            "installed", "partial", "not-installed", "data-preserved"
        } or row["id"] in states:
            raise ValueError("Invalid component inventory row")
        states[row["id"]] = row["state"]
    if set(states) != INVENTORY_COMPONENTS:
        raise ValueError("Incomplete component inventory")
    return states


def track():
    started = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds")
    states = inventory()
    ram = json_probe("ram")
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    with journal(write=True) as value:
        for component, state in states.items():
            if state not in {"installed", "partial"} and not (
                component == "ram" and ram.get("ttmLastRequestedPages") is not None
            ):
                continue  # Missing after an update must not erase prior use.
            record = value["features"].setdefault(component, {"firstSeen": now})
            if record.get("lastChanged", "") > started:
                continue  # A concurrent mutation is newer than this scan.
            record["lastSeen"] = now
            if component == "ram" and ram.get("ttmState") != "foreign":
                previous = record.get("ram", {})
                pages = ram.get("ttmConfiguredPages")
                if pages is None:
                    pages = ram.get("ttmLastRequestedPages")
                # A missing drop-in might be update damage. Only explicit forget
                # or a successful toolkit removal clears remembered intent.
                record["ram"] = {
                    "toolUsed": ram.get("toolState") == "verified" or previous.get("toolUsed", False),
                    "ttmPages": (None if ram.get("ttmOverrideRemoved") and pages is None
                                 else pages if pages is not None else previous.get("ttmPages")),
                }
    print(f"Local feature inventory saved: {state_path()}")


def health(component, record, states):
    """Return (state, explanation); no mutating or privileged probes."""
    if component == "ram":
        desired = record.get("ram")
        if not desired:
            return "manual", "No verified RAM settings were recorded."
        ram = json_probe("ram")
        if ram.get("ttmState") == "foreign" or ram.get("toolState") == "invalid":
            return "blocked", "Foreign/unverified RAM state; ownership checks require manual review."
        pages = desired["ttmPages"]
        configured = ram.get("ttmConfiguredPages")
        if pages is not None and configured is None and ram.get("ttmOverrideRemoved"):
            return "manual", "TTM was explicitly removed; track again or forget ram. It will not be re-enabled."
        if pages is not None and ram.get("ttmLastRequestedPages") not in (None, pages):
            return "manual", "A newer TTM request is recorded; track again instead of overwriting it."
        if pages is not None and configured not in (None, pages):
            return "manual", "A different TTM value is configured; track it explicitly instead of overwriting it."
        if desired["toolUsed"] and ram.get("toolState") == "not-installed":
            return "repair", "Restore the previously used verified memory utility (no CMOS write)."
        if pages is not None and (configured is None or not ram.get("protected")
                                  or probe("ram", "ttm-verify").returncode):
            return "repair", f"Restore TTM {pages} pages and verify generated GRUB/update protection (no CMOS write)."
        if ram.get("rebootRequired") or (pages is not None and ram.get("ttmLivePages") not in (None, pages)):
            return "reboot", "Saved TTM configuration is present; reboot to apply it."
        return "healthy", "Verified saved RAM configuration."
    if component == "audio":
        state = json_probe("audio").get("state")
        if state == "ready":
            return "healthy", "AMDGPU override is verified and active for the running kernel."
        if state == "reboot-required":
            return "reboot", "The verified AMDGPU module is installed; reboot, do not rebuild."
        if state in {"not-installed", "rebuild-required"}:
            return "repair", "Build/install AMDGPU fixes for the running kernel; reboot afterwards."
        return "blocked", "Invalid AMDGPU override requires manual ownership/rollback review."
    if component in {"fan", "aic", "proton", "storage"}:
        result = probe(component, "verify" if component == "storage" else "status")
        if result.returncode == 0:
            return "healthy", "Component health checks passed."
        return "repair", {
            "storage": "Repair persistent storage and boot recovery first.",
            "fan": "Restore the NCT6687 driver and boot integration (no force-unknown option).",
            "aic": "Restore the previously used AIC8800 driver and device rules.",
            "proton": "Run the transactional GE-Proton update/repair; prefixes and saves are retained.",
        }[component]
    return "manual", f"Lifecycle: {states.get(component, 'not-probed')}. {MANUAL}"


def plan(features, requested):
    states = inventory()
    rows = []
    for component in ORDER:
        if component not in features or requested not in ("all", component):
            continue
        try:
            state, reason = health(component, features[component], states)
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            state, reason = "blocked", f"Health probe unavailable: {error}"
        rows.append((component, state, reason))
    return rows


def repair_commands(component, record):
    if component == "ram":
        ram = json_probe("ram")
        desired = record["ram"]
        commands = []
        if desired["toolUsed"] and ram.get("toolState") == "not-installed":
            commands.append(script_command("ram", "install", privileged=True))
        if desired["ttmPages"] is not None:
            commands.append(script_command("ram", "ttm-set", str(desired["ttmPages"]), "--yes", privileged=True))
        return commands
    arguments = {
        "storage": ("repair",), "audio": (), "fan": ("install",),
        "aic": ("install",), "proton": ("update",),
    }[component]
    return [script_command(component, *arguments, privileged=component in {"storage", "fan", "aic"})]


def repair(requested, yes):
    # Never hold the journal lock while running helpers: their automatic
    # mutation hooks update this same file, including across sudo boundaries.
    with journal() as value:
        features = value["features"]
    rows = plan(features, requested)
    for component, state, reason in rows:
        print(f"{component:16} {state:8} {reason}", flush=True)
    if not rows:
        print("No matching tracked features. Run track before an OS update.")
        return 0
    if not yes:
        if not sys.stdin.isatty() or not sys.stdout.isatty():
            raise ValueError("Repair needs confirmation; use --yes for automation.")
        if input("Repair only the listed repairable features? [y/N] ").lower() not in {"y", "yes"}:
            print("Cancelled.")
            return 0
    failed = False
    for component, state, _ in rows:
        if state in {"blocked", "manual"}:
            failed = True
            if component == "storage":
                print("Storage health is unknown; no dependent repairs were attempted.", file=sys.stderr)
                break
            continue
        if state != "repair":
            continue
        try:
            # Re-read intent as well as health after confirmation/earlier repairs.
            # A concurrent explicit uninstall/forget must never be resurrected.
            with journal() as current_value:
                current_record = current_value["features"].get(component)
            if current_record is None:
                print(f"{component}: no longer tracked; skipping", flush=True)
                continue
            if current_record.get("ram") != features[component].get("ram"):
                raise ValueError("Recorded settings changed; review a fresh repair plan")
            current, _ = health(component, current_record, inventory())
            if current in {"healthy", "reboot"}:
                continue
            if current != "repair":
                raise ValueError("State changed; review a fresh repair plan")
            for command in repair_commands(component, current_record):
                subprocess.run(command, check=True)
            current, reason = health(component, current_record, inventory())
            print(f"{component}: {current}: {reason}", flush=True)
            if current not in {"healthy", "reboot"}:
                raise ValueError("Post-repair health checks did not pass")
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            print(f"{component}: repair failed: {error}", file=sys.stderr)
            failed = True
            if component == "storage":
                print("Storage repair failed; no dependent repairs were attempted.", file=sys.stderr)
                break
    print("Repair never replays CMOS, CPU/GPU unlocks, overclocks or game DLL injection. Reboot when indicated.")
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("track", "features", "repair-plan", "repair", "forget"))
    parser.add_argument("component", nargs="?", default="all", choices=sorted(COMPONENTS | {"all"}))
    parser.add_argument("--yes", action="store_true")
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise ValueError("Run as the logged-in user, not with sudo")
    if args.command in {"track", "features"} and (args.component != "all" or args.yes):
        parser.error("track/features accept no additional arguments")
    if args.command == "track":
        track()
    elif args.command == "features":
        with journal() as value:
            print(json.dumps(value, indent=2, sort_keys=True))
    elif args.command == "repair-plan":
        if args.yes:
            parser.error("repair-plan is read-only and does not accept --yes")
        with journal() as value:
            rows = plan(value["features"], args.component)
            for component, state, reason in rows:
                print(f"{component:16} {state:8} {reason}")
            if not rows:
                print("No matching tracked features. Run track before an OS update.")
    elif args.command == "forget":
        if not args.yes:
            parser.error("forget requires --yes; this only removes tracking, not installed files")
        with journal(write=True) as value:
            if args.component == "all":
                value["features"].clear()
            else:
                value["features"].pop(args.component, None)
    else:
        return repair(args.component, args.yes)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"[bc250-recovery] {error}", file=sys.stderr)
        sys.exit(1)
