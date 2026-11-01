#!/usr/bin/env python3
"""Record one shell mutation without running a full inventory scan."""

import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
for directory in (ROOT / "scripts", ROOT / "backend/bc250_control", ROOT / "py_modules/bc250_control"):
    if (directory / "feature_state.py").is_file():
        sys.path.insert(0, str(directory))
        break
from feature_state import record_event  # noqa: E402


def main():
    if len(sys.argv) != 5:
        raise ValueError("Expected component, action, exit status and helper path")
    component, action, code, helper = sys.argv[1:]
    success = code == "0"
    ram = None
    if component == "ram":
        result = subprocess.run(["bash", helper, "status-json"], capture_output=True,
                                text=True, timeout=20, check=True)
        ram = json.loads(result.stdout)
    # Partial removals (game DLLs, subfeatures) remain tracked. Full component
    # uninstall forgets intent so a later repair cannot re-enable it.
    removed = success and action == "uninstall" and component not in {
        "fsr4", "helixsr", "optiscaler", "persistence"
    }
    record_event(component, action, success, ram, removed)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"[bc250-tracking] {error}", file=sys.stderr)
        sys.exit(1)
