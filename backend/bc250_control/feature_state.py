"""Private, atomic local feature state shared by CLI and graphical mutations.

This module is also a standalone program. Privileged callers execute it as the
requesting user; it never writes a user's state with root privileges.
"""

import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


INVENTORY_COMPONENTS = {
    "storage", "audio", "fan", "aic", "ram", "proton", "trainer", "desktop",
    "decky", "coolercontrol", "cec", "ac3", "power", "swap", "compute",
    "helixsr", "native-mesh", "video-codec", "mesh",
}
COMPONENTS = INVENTORY_COMPONENTS | {
    "fsr4", "optiscaler", "memory-temperature", "wifi-backend", "persistence", "toolkit", "amdgpu-options",
}


def state_path():
    base = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    if not base.is_absolute():
        raise ValueError("XDG_STATE_HOME must be absolute")
    return base / "bc250-toolkit" / "features.json"


def validate_state(value):
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise ValueError("Invalid feature journal schema")
    if type(value.get("revision", 0)) is not int or value.get("revision", 0) < 0:
        raise ValueError("Invalid feature revision")
    features = value.get("features")
    if not isinstance(features, dict) or set(features) - COMPONENTS:
        raise ValueError("Invalid feature IDs")
    for component, record in features.items():
        if not isinstance(record, dict) or set(record) - {
            "firstSeen", "lastSeen", "ram", "lastAction", "lastResult", "lastChanged"
        }:
            raise ValueError("Invalid feature record")
        for key in ("firstSeen", "lastSeen", "lastChanged"):
            if key not in record and key == "lastChanged":
                continue
            if not isinstance(record.get(key), str) or len(record[key]) > 40:
                raise ValueError("Invalid feature timestamp")
        if "lastAction" in record and not valid_action(record["lastAction"]):
            raise ValueError("Invalid feature action")
        if "lastResult" in record and record["lastResult"] not in {"success", "failed"}:
            raise ValueError("Invalid feature result")
        if "ram" in record:
            ram = record["ram"]
            if component != "ram" or not isinstance(ram, dict) or set(ram) != {"toolUsed", "ttmPages"}:
                raise ValueError("Invalid RAM record")
            pages = ram["ttmPages"]
            if type(ram["toolUsed"]) is not bool or not (
                pages is None or type(pages) is int and 65536 <= pages <= 3670016
            ):
                raise ValueError("Invalid saved RAM settings")
    return value


def checked_file(path, flags):
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        os.close(fd)
        raise ValueError(f"Unsafe feature state file: {path}")
    return fd


def read_state(path):
    try:
        fd = checked_file(path, os.O_RDONLY)
    except FileNotFoundError:
        return {"schemaVersion": 1, "features": {}}
    with os.fdopen(fd) as stream:
        text = stream.read(65537)
    if len(text) > 65536:
        raise ValueError("Feature journal is too large")
    return validate_state(json.loads(text))


@contextlib.contextmanager
def journal(write=False):
    path = state_path()
    for parent in reversed(path.parent.parents):
        if parent.is_symlink():
            raise ValueError(f"Symlinked state directory: {parent}")
    if path.parent.is_symlink():
        raise ValueError(f"Symlinked state directory: {path.parent}")
    if not write and not path.parent.exists():
        yield {"schemaVersion": 1, "features": {}}
        return
    if write:
        path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = path.parent.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError(f"Feature state directory must be private: {path.parent}")
    lock = checked_file(path.parent / ".lock", os.O_RDWR | os.O_CREAT) if write else None
    try:
        if lock is not None:
            fcntl.flock(lock, fcntl.LOCK_EX)
        value = read_state(path)
        yield value
        if write:
            validate_state(value)
            fd, temporary = tempfile.mkstemp(prefix=".features-", dir=path.parent)
            try:
                with os.fdopen(fd, "w") as stream:
                    json.dump(value, stream, indent=2, sort_keys=True)
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
                directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    finally:
        if lock is not None:
            os.close(lock)


def valid_action(action):
    return isinstance(action, str) and re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_-]{0,63}", action) is not None


def record_event(component, action, success=True, ram=None, removed=False):
    if os.geteuid() == 0:
        raise ValueError("Record feature changes as the requesting user, not root")
    if component not in COMPONENTS or not valid_action(action):
        raise ValueError("Invalid feature mutation")
    result = "success" if success else "failed"
    with journal(write=True) as value:
        now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds")
        features = value["features"]
        value["revision"] = value.get("revision", 0) + 1
        value["lastMutation"] = {"component": component, "action": action, "result": result, "time": now}
        if success and removed:
            features.pop(component, None)
            return
        if success:
            record = features.setdefault(component, {"firstSeen": now, "lastSeen": now})
        else:
            record = features.get(component)
        if record is None:
            return  # A failed attempt is not evidence that a feature was installed.
        record.update(lastAction=action, lastResult=result, lastChanged=now)
        if success:
            record["lastSeen"] = now
        if component == "ram" and isinstance(ram, dict) and ram.get("ttmState") != "foreign":
            previous = record.get("ram", {})
            pages = ram.get("ttmConfiguredPages")
            if pages is None:
                pages = ram.get("ttmLastRequestedPages")
            if pages is not None and not (type(pages) is int and 65536 <= pages <= 3670016):
                raise ValueError("Invalid observed TTM limit")
            record["ram"] = {
                "toolUsed": ram.get("toolState") == "verified" or previous.get("toolUsed", False),
                "ttmPages": (None if ram.get("ttmOverrideRemoved") and pages is None
                             else pages if pages is not None else previous.get("ttmPages")),
            }


def main():
    if len(sys.argv) not in (4, 5):
        raise ValueError("Expected component, action, result, and optional RAM JSON")
    component, action, result = sys.argv[1:4]
    if result not in {"success", "failed", "removed"}:
        raise ValueError("Invalid mutation result")
    ram = json.loads(sys.argv[4]) if len(sys.argv) == 5 else None
    record_event(component, action, result != "failed", ram, result == "removed")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(f"[bc250-tracking] {error}", file=sys.stderr)
        sys.exit(1)
