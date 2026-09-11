#!/usr/bin/env bash
# Install the pinned OptiScaler runtime into one game directory.
set -euo pipefail

RELEASE="${BC250_OPTISCALER_RELEASE:-v0.9.4}"
[[ "$RELEASE" =~ ^v[0-9][0-9A-Za-z._-]*$ ]] \
    || { printf '[bc250-optiscaler] Invalid release identifier.\n' >&2; exit 1; }
ARCHIVE_NAME=Optiscaler_0.9.4-final.20260718._MM.7z
ARCHIVE_URL="https://github.com/optiscaler/OptiScaler/releases/download/v0.9.4/$ARCHIVE_NAME"
ARCHIVE_SHA256="${BC250_OPTISCALER_ARCHIVE_SHA256:-575cb4df866116093df75af607e37fd70e10f5163e0f23fd5c804142e80ef0ad}"
[[ "$ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || { printf '[bc250-optiscaler] Invalid archive checksum.\n' >&2; exit 1; }
MESH_STATE="${BC250_MESH_STATE_DIR:-$HOME/.local/share/bc250-mesh-shader}"
STATE_DIR="${BC250_OPTISCALER_STATE_DIR:-$MESH_STATE/optiscaler}"
CACHE_DIR="$STATE_DIR/cache"
INSTALLS_DIR="$STATE_DIR/installs"
RELEASE_DIR="$CACHE_DIR/releases/$RELEASE"
ARCHIVE="$CACHE_DIR/$RELEASE-$ARCHIVE_NAME"
LOCK_FILE="$STATE_DIR.lock"
FSR4_STATE="${BC250_FSR4_STATE_DIR:-$MESH_STATE/fsr4-dll}"
FSR4_LOCK_FILE="${BC250_FSR4_LOCK_FILE:-$HOME/.cache/bc250-fsr4.lock}"

log() { printf '[bc250-optiscaler] %s\n' "$*"; }
die() { log "$*" >&2; exit 1; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }

require_normal_user() {
    [[ $EUID -ne 0 ]] || die "Run as the logged-in user, not with sudo."
}

fsync_paths() {
    python3 - "$@" <<'PY'
import os
import sys

for value in sys.argv[1:]:
    descriptor = os.open(value, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

ensure_state() {
    command -v flock >/dev/null 2>&1 || die "flock is required."
    command -v python3 >/dev/null 2>&1 || die "python3 is required."
    [[ "$STATE_DIR" == /* && "$LOCK_FILE" == /* && "$FSR4_LOCK_FILE" == /* ]] \
        || die "OptiScaler state paths must be absolute."
    [[ ! -L "$STATE_DIR" && ! -L "$CACHE_DIR" && ! -L "$CACHE_DIR/releases" \
        && ! -L "$INSTALLS_DIR" && ! -L "$LOCK_FILE" ]] \
        || die "Refusing symlinked OptiScaler state."
    mkdir -p "$CACHE_DIR/releases" "$INSTALLS_DIR" "${LOCK_FILE%/*}"
    [[ -d "$STATE_DIR" && -d "$CACHE_DIR" && -d "$CACHE_DIR/releases" \
        && -d "$INSTALLS_DIR" && ! -L "$STATE_DIR" && ! -L "$CACHE_DIR" \
        && ! -L "$CACHE_DIR/releases" && ! -L "$INSTALLS_DIR" ]] \
        || die "OptiScaler state is unsafe."
    chmod 0700 "$STATE_DIR" "$CACHE_DIR" "$CACHE_DIR/releases" "$INSTALLS_DIR"
}

prepare_fsr4_lock() {
    [[ ! -L "$FSR4_LOCK_FILE" ]] || die "Refusing symlinked FSR4 lock file."
    mkdir -p "${FSR4_LOCK_FILE%/*}"
    [[ -d "${FSR4_LOCK_FILE%/*}" && ! -L "${FSR4_LOCK_FILE%/*}" ]] \
        || die "FSR4 lock directory is unsafe."
}

python_core() {
    python3 - "$@" <<'PY'
import hashlib
import ctypes
import errno
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ARCHIVE_DIRS = ("D3D12_Optiscaler", "Licenses")
ARCHIVE_FILES = (
    "!! README_EXTRACT ALL FILES TO GAME FOLDER !!.txt",
    "D3D12_Optiscaler/D3D12Core.dll",
    "Licenses/DirectX_LICENSE.txt",
    "Licenses/FidelityFX_v1_LICENSE.md",
    "Licenses/FidelityFX_v2_LICENSE.md",
    "Licenses/XeSS_LICENSE.txt",
    "OptiScaler.dll",
    "OptiScaler.ini",
    "amd_fidelityfx_dx12.dll",
    "amd_fidelityfx_framegeneration_dx12.dll",
    "amd_fidelityfx_upscaler_dx12.dll",
    "amd_fidelityfx_vk.dll",
    "dlssg_to_fsr3_amd_is_better.dll",
    "fakenvapi.dll",
    "fakenvapi.ini",
    "libxell.dll",
    "libxess.dll",
    "libxess_dx11.dll",
    "libxess_fg.dll",
    "setup_linux.sh",
    "setup_windows.bat",
)
RUNTIME_SOURCES = (
    "D3D12_Optiscaler/D3D12Core.dll",
    "Licenses/DirectX_LICENSE.txt",
    "Licenses/FidelityFX_v1_LICENSE.md",
    "Licenses/FidelityFX_v2_LICENSE.md",
    "Licenses/XeSS_LICENSE.txt",
    "OptiScaler.dll",
    "amd_fidelityfx_dx12.dll",
    "amd_fidelityfx_framegeneration_dx12.dll",
    "amd_fidelityfx_upscaler_dx12.dll",
    "amd_fidelityfx_vk.dll",
    "dlssg_to_fsr3_amd_is_better.dll",
    "fakenvapi.dll",
    "libxell.dll",
    "libxess.dll",
    "libxess_dx11.dll",
    "libxess_fg.dll",
)
CONFIG_SOURCES = ("OptiScaler.ini", "fakenvapi.ini")
PROXIES = {
    "dxgi.dll", "winmm.dll", "version.dll", "dbghelp.dll", "d3d12.dll",
    "wininet.dll", "winhttp.dll",
}
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
RELEASE_RE = re.compile(r"^v[0-9][0-9A-Za-z._-]*$")
AT_FDCWD = -100
RENAME_NOREPLACE = 1
LIBC = ctypes.CDLL(None, use_errno=True)


class Refusal(Exception):
    pass


def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def fsync(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def regular(path):
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except FileNotFoundError:
        return False


def directory(path):
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except FileNotFoundError:
        return False


def condition_for_file(path, entry):
    if not os.path.lexists(path):
        return "missing"
    if not regular(path):
        return "modified"
    actual = digest(path)
    actual_mode = stat.S_IMODE(os.lstat(path).st_mode)
    if actual == entry["installedSha256"] and actual_mode == entry["installedMode"]:
        return "installed"
    if (
        actual == entry.get("previousInstalledSha256")
        and actual_mode == entry.get("previousInstalledMode")
    ):
        return "previous"
    original = entry["original"]
    if (
        original is not None and actual == original["sha256"]
        and actual_mode == original["mode"]
    ):
        return "original"
    return "modified"


def rename_noreplace(source, target):
    source_bytes = os.fsencode(source)
    target_bytes = os.fsencode(target)
    if LIBC.renameat2(
        AT_FDCWD,
        ctypes.c_char_p(source_bytes),
        AT_FDCWD,
        ctypes.c_char_p(target_bytes),
        RENAME_NOREPLACE,
    ) == 0:
        return
    error = ctypes.get_errno()
    if error == errno.EEXIST:
        raise FileExistsError(error, os.strerror(error), target)
    raise OSError(error, os.strerror(error), source, target)


def quarantine_path(target):
    name = hashlib.sha256(os.fsencode(os.path.basename(target))).hexdigest()[:24]
    return os.path.join(
        os.path.dirname(target), f".bc250-optiscaler-{name}.rollback"
    )


def quarantine_checked(target, entry, allowed):
    parent = os.path.dirname(target)
    quarantine = quarantine_path(target)
    if os.path.lexists(quarantine):
        if condition_for_file(quarantine, entry) not in allowed:
            raise Refusal(f"Unexpected recovery file must be preserved manually: {quarantine}")
        if not os.path.lexists(target):
            rename_noreplace(quarantine, target)
            fsync(parent)
        elif condition_for_file(target, entry) in allowed:
            os.unlink(quarantine)
            fsync(parent)
        else:
            raise Refusal(
                f"Target and recovery file both exist; refusing to overwrite either: {target}"
            )
    if not os.path.lexists(target):
        if "missing" not in allowed:
            raise Refusal(f"Target disappeared before mutation: {target}")
        return None
    try:
        try:
            rename_noreplace(target, quarantine)
        except FileNotFoundError as error:
            if "missing" in allowed:
                return None
            raise Refusal(f"Target disappeared before mutation: {target}") from error
        condition = condition_for_file(quarantine, entry)
        if condition not in allowed:
            try:
                rename_noreplace(quarantine, target)
            except FileExistsError:
                pass
            raise Refusal(
                f"Target changed during mutation; unexpected bytes were preserved: {target}"
            )
        return quarantine
    except Exception:
        if os.path.lexists(quarantine) and not os.path.lexists(target):
            try:
                rename_noreplace(quarantine, target)
            except FileExistsError:
                pass
        raise


def atomic_copy_checked(source, target, mode, entry, allowed):
    parent = os.path.dirname(target)
    if not os.path.isdir(parent):
        raise Refusal(f"Unsafe or missing target directory: {parent}")
    descriptor, temporary = tempfile.mkstemp(prefix=os.path.basename(target) + ".bc250.", dir=parent)
    quarantine = None
    try:
        with open(source, "rb") as source_stream, os.fdopen(descriptor, "wb") as output:
            shutil.copyfileobj(source_stream, output)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        quarantine = quarantine_checked(target, entry, allowed)
        try:
            rename_noreplace(temporary, target)
        except FileExistsError as error:
            raise Refusal(
                f"Target reappeared during mutation and was not overwritten: {target}"
            ) from error
        if quarantine is not None:
            os.unlink(quarantine)
        fsync(target)
        fsync(parent)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        if quarantine is not None and os.path.lexists(quarantine) \
            and not os.path.lexists(target):
            try:
                rename_noreplace(quarantine, target)
            except FileExistsError:
                pass
        raise


def remove_checked(target, entry, allowed):
    quarantine = quarantine_checked(target, entry, allowed)
    if quarantine is not None:
        os.unlink(quarantine)
        fsync(os.path.dirname(target))


def cleanup_completed_quarantine(target, entry, target_condition):
    quarantine = quarantine_path(target)
    if not os.path.lexists(quarantine):
        return
    if (
        condition_for_file(target, entry) != target_condition
        or condition_for_file(quarantine, entry)
        not in {"installed", "previous", "original"}
    ):
        raise Refusal(
            f"Target and recovery file conflict; refusing to remove either: {target}"
        )
    os.unlink(quarantine)
    fsync(os.path.dirname(target))


def atomic_json(path, payload):
    parent = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".record.", dir=parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        fsync(path)
        fsync(parent)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def validate_archive(path):
    result = subprocess.run(
        ["7z", "l", "-slt", "--", path], stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise Refusal("Could not list the verified OptiScaler archive.")
    text = result.stdout.decode("utf-8", "surrogateescape")
    if "----------\n" not in text:
        raise Refusal("OptiScaler archive listing is malformed.")
    listing = text.split("----------\n", 1)[1]
    entries = []
    current = {}
    for line in listing.splitlines() + [""]:
        if not line:
            if current:
                entries.append(current)
                current = {}
            continue
        if " = " in line:
            key, value = line.split(" = ", 1)
            if key in current:
                raise Refusal("OptiScaler archive metadata is ambiguous.")
            current[key] = value
    names = [entry.get("Path") for entry in entries]
    expected = set(ARCHIVE_DIRS + ARCHIVE_FILES)
    if len(names) != len(expected) or set(names) != expected or None in names:
        raise Refusal("OptiScaler archive has an unexpected payload layout.")
    for entry in entries:
        name = entry["Path"]
        attributes = entry.get("Attributes", "")
        if entry.get("Encrypted") not in (None, "-") or "Symbolic Link" in entry:
            raise Refusal(f"Unsafe archive entry: {name}")
        is_dir = attributes.startswith("D") or entry.get("Folder") == "+"
        if (name in ARCHIVE_DIRS) != is_dir:
            raise Refusal(f"Unexpected archive entry type: {name}")
        unix_mode = attributes.split()[-1] if " " in attributes else ""
        if unix_mode and unix_mode[0:1] not in ("-", "d"):
            raise Refusal(f"Special archive entry is not allowed: {name}")


def validate_release(root, write_manifest=False):
    if not directory(root):
        return False
    expected = set(ARCHIVE_DIRS + ARCHIVE_FILES)
    actual = set()
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        for name in dirs + files:
            path = os.path.join(current, name)
            relative = os.path.relpath(path, root)
            actual.add(relative)
            wanted_dir = relative in ARCHIVE_DIRS
            if wanted_dir and not directory(path):
                return False
            if not wanted_dir and not regular(path):
                return False
    manifest_path = os.path.join(root, ".bc250-sha256.json")
    actual.discard(".bc250-sha256.json")
    if actual != expected:
        return False
    hashes = {name: digest(os.path.join(root, name)) for name in ARCHIVE_FILES}
    if write_manifest:
        for name in ARCHIVE_FILES:
            fsync(os.path.join(root, name))
        for name in reversed(ARCHIVE_DIRS):
            fsync(os.path.join(root, name))
        atomic_json(manifest_path, hashes)
        fsync(root)
        return True
    if not regular(manifest_path):
        return False
    try:
        with open(manifest_path, encoding="utf-8") as stream:
            saved = json.load(stream)
    except (OSError, ValueError):
        return False
    return saved == hashes


def canonical_install(value, expected_id):
    if not value.startswith("/") or "\n" in value or "\r" in value:
        raise Refusal("Install directory must be an absolute path without line breaks.")
    if not isinstance(expected_id, str) or not SHA_RE.fullmatch(expected_id):
        raise Refusal("Candidate ID is invalid.")
    if os.path.islink(value) or not directory(value):
        raise Refusal(f"Install directory must be a real, non-symlinked directory: {value}")
    result = os.path.realpath(value)
    if not directory(result):
        raise Refusal(f"Install directory is unsafe: {value}")
    if candidate_id(result) != expected_id:
        raise Refusal("Candidate ID does not match the canonical install directory.")
    metadata = os.stat(result, follow_symlinks=False)
    return result, (metadata.st_dev, metadata.st_ino)


def candidate_id(path):
    return hashlib.sha256(path.encode("utf-8", "surrogateescape")).hexdigest()


def assert_install_identity(path, expected):
    try:
        metadata = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise Refusal(f"Install directory became unavailable: {path}") from error
    if not stat.S_ISDIR(metadata.st_mode) or (metadata.st_dev, metadata.st_ino) != expected:
        raise Refusal(f"Install directory changed during the operation: {path}")


def open_install_root(path, expected):
    try:
        descriptor = os.open(
            path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
        )
    except OSError as error:
        raise Refusal(f"Install directory became unsafe: {path}") from error
    metadata = os.fstat(descriptor)
    if (metadata.st_dev, metadata.st_ino) != expected:
        os.close(descriptor)
        raise Refusal(f"Install directory changed while opening it: {path}")
    return descriptor


def anchored_target(root_descriptor, relative):
    descriptor = os.dup(root_descriptor)
    try:
        components = relative.split("/")
        for component in components[:-1]:
            child = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = child
        return descriptor, f"/proc/self/fd/{descriptor}/{components[-1]}"
    except OSError as error:
        os.close(descriptor)
        raise Refusal(f"Install subdirectory became unsafe: {relative}") from error


def target_for(source, proxy):
    return proxy if source == "OptiScaler.dll" else source


def safe_relative(value):
    return (
        isinstance(value, str) and value and not value.startswith("/")
        and "\n" not in value and "\r" not in value
        and os.path.normpath(value) == value and not value.startswith("../")
    )


def read_record(record_dir):
    if not directory(record_dir):
        raise Refusal("record directory is not a real directory")
    path = os.path.join(record_dir, "record.json")
    if not regular(path):
        raise Refusal("record metadata is missing or unsafe")
    try:
        with open(path, encoding="utf-8") as stream:
            record = json.load(stream)
    except (OSError, ValueError) as error:
        raise Refusal("record metadata is malformed") from error
    required = {"schemaVersion", "candidateId", "installPath", "release", "proxy", "files", "directories"}
    if set(record) != required or record["schemaVersion"] != 1:
        raise Refusal("record schema is invalid")
    install_path = record["installPath"]
    identifier = record["candidateId"]
    if (
        not isinstance(install_path, str) or not install_path.startswith("/")
        or "\n" in install_path or "\r" in install_path
        or os.path.normpath(install_path) != install_path
        or not isinstance(identifier, str) or identifier != candidate_id(install_path)
        or os.path.basename(record_dir) != identifier
        or not isinstance(record["release"], str) or not RELEASE_RE.fullmatch(record["release"])
        or record["proxy"] not in PROXIES
        or not isinstance(record["files"], list) or not isinstance(record["directories"], list)
    ):
        raise Refusal("record identity is invalid")
    expected_runtime = {target_for(source, record["proxy"]) for source in RUNTIME_SOURCES}
    backups_dir = os.path.join(record_dir, "backups")
    if not directory(backups_dir):
        raise Refusal("record backup directory is missing or unsafe")
    seen = set()
    runtime_seen = set()
    for entry in record["files"]:
        keys = {"path", "kind", "installedSha256", "installedMode", "original"}
        pending_keys = keys | {"previousInstalledSha256", "previousInstalledMode"}
        if not isinstance(entry, dict) or set(entry) not in (keys, pending_keys):
            raise Refusal("record file entry is invalid")
        relative = entry["path"]
        if not safe_relative(relative) or relative in seen:
            raise Refusal("record file path is invalid")
        seen.add(relative)
        if entry["kind"] not in ("runtime", "config"):
            raise Refusal("record file kind is invalid")
        if entry["kind"] == "runtime":
            runtime_seen.add(relative)
        elif relative not in CONFIG_SOURCES:
            raise Refusal("record config path is invalid")
        if not isinstance(entry["installedSha256"], str) or not SHA_RE.fullmatch(entry["installedSha256"]):
            raise Refusal("record installed checksum is invalid")
        if not isinstance(entry["installedMode"], int) or not 0 <= entry["installedMode"] <= 0o7777:
            raise Refusal("record installed mode is invalid")
        if set(entry) == pending_keys and (
            not isinstance(entry["previousInstalledSha256"], str)
            or not SHA_RE.fullmatch(entry["previousInstalledSha256"])
            or not isinstance(entry["previousInstalledMode"], int)
            or not 0 <= entry["previousInstalledMode"] <= 0o7777
        ):
            raise Refusal("record pending-update metadata is invalid")
        original = entry["original"]
        if original is not None:
            if not isinstance(original, dict) or set(original) != {"backup", "sha256", "mode"}:
                raise Refusal("record backup entry is invalid")
            backup = original["backup"]
            if (
                not safe_relative(backup) or "/" in backup
                or not isinstance(original["sha256"], str) or not SHA_RE.fullmatch(original["sha256"])
                or not isinstance(original["mode"], int) or not 0 <= original["mode"] <= 0o7777
            ):
                raise Refusal("record backup metadata is invalid")
            backup_path = os.path.join(backups_dir, backup)
            if not regular(backup_path) or digest(backup_path) != original["sha256"]:
                raise Refusal("record backup is missing, unsafe, or modified")
    if runtime_seen != expected_runtime:
        raise Refusal("record runtime payload is incomplete")
    if len(record["directories"]) != len(set(record["directories"])):
        raise Refusal("record directory list is invalid")
    for relative in record["directories"]:
        if relative not in ARCHIVE_DIRS:
            raise Refusal("record owns an unexpected directory")
    return record


def file_condition(install_path, entry):
    if not directory(install_path):
        return "modified"
    parent = install_path
    for component in entry["path"].split("/")[:-1]:
        parent = os.path.join(parent, component)
        if not directory(parent):
            return "modified"
    path = os.path.join(install_path, entry["path"])
    return condition_for_file(path, entry)


def record_state(record, current_release):
    conditions = [
        file_condition(record["installPath"], entry)
        for entry in record["files"] if entry["kind"] == "runtime"
    ]
    if "modified" in conditions:
        return "modified"
    if any("previousInstalledSha256" in entry for entry in record["files"]):
        return "restorable"
    if "original" in conditions or "missing" in conditions:
        return "restorable"
    if record["release"] != current_release:
        return "upgrade-required"
    if any(
        file_condition(record["installPath"], entry) == "missing"
        for entry in record["files"] if entry["kind"] == "config"
    ):
        return "repair-required"
    return "ready"


def fsr4_blocked(fsr_state, install_path):
    installs = os.path.join(fsr_state, "installs")
    if os.path.islink(fsr_state) or os.path.islink(installs):
        if os.path.lexists(fsr_state) or os.path.lexists(installs):
            raise Refusal("FSR4 rollback state is unsafe; refusing this operation.")
        return
    if not os.path.isdir(installs):
        return
    for name in os.listdir(installs):
        record_dir = os.path.join(installs, name)
        target_file = os.path.join(record_dir, "target")
        if not SHA_RE.fullmatch(name) or not directory(record_dir) or not regular(target_file):
            raise Refusal("FSR4 rollback state contains an invalid record; refusing this operation.")
        try:
            with open(target_file, "r", encoding="utf-8", errors="surrogateescape") as stream:
                lines = stream.read().splitlines()
        except OSError as error:
            raise Refusal("FSR4 rollback state could not be read; refusing this operation.") from error
        if len(lines) != 1 or not lines[0].startswith("/"):
            raise Refusal("FSR4 rollback state contains an invalid target; refusing this operation.")
        target = os.path.abspath(os.path.normpath(lines[0]))
        if candidate_id(target) != name:
            raise Refusal("FSR4 rollback record identity is invalid; refusing this operation.")
        try:
            beneath = os.path.commonpath((install_path, target)) == install_path
        except ValueError:
            beneath = False
        if beneath:
            raise Refusal(f"FSR4 rollback record targets this install directory: {target}")


def prepare_directories(install_path, install_descriptor):
    owned = []
    try:
        for relative in ARCHIVE_DIRS:
            path = os.path.join(install_path, relative)
            try:
                metadata = os.stat(
                    relative, dir_fd=install_descriptor, follow_symlinks=False
                )
            except FileNotFoundError:
                metadata = None
            if metadata is not None:
                if not stat.S_ISDIR(metadata.st_mode):
                    raise Refusal(f"Refusing unsafe directory collision: {path}")
            else:
                os.mkdir(relative, 0o755, dir_fd=install_descriptor)
                os.fsync(install_descriptor)
                owned.append(relative)
        return owned
    except Exception:
        remove_owned_directories(install_descriptor, owned)
        raise


def remove_owned_directories(install_descriptor, directories):
    for relative in reversed(directories):
        try:
            os.rmdir(relative, dir_fd=install_descriptor)
            os.fsync(install_descriptor)
        except OSError:
            pass


def backup_name(relative):
    return hashlib.sha256(relative.encode("ascii")).hexdigest() + ".original"


def record_tombstone(installs_dir, identifier):
    return os.path.join(os.path.dirname(installs_dir), f".removed-{identifier}")


def cleanup_record_tombstone(installs_dir, identifier):
    tombstone = record_tombstone(installs_dir, identifier)
    if not os.path.lexists(tombstone):
        return
    if not directory(tombstone):
        raise Refusal(f"OptiScaler removal tombstone is unsafe: {tombstone}")
    shutil.rmtree(tombstone)
    fsync(os.path.dirname(installs_dir))


def build_fresh_record(
    release_dir, installs_dir, install_path, install_descriptor, release, proxy
):
    identifier = candidate_id(install_path)
    record_dir = os.path.join(installs_dir, identifier)
    cleanup_record_tombstone(installs_dir, identifier)
    if os.path.lexists(record_dir):
        raise Refusal(f"Existing OptiScaler record is malformed: {record_dir}")
    temporary = tempfile.mkdtemp(prefix=".optiscaler-record.", dir=os.path.dirname(installs_dir))
    backups = os.path.join(temporary, "backups")
    os.mkdir(backups, 0o700)
    owned_dirs = []
    published = False
    try:
        owned_dirs = prepare_directories(install_path, install_descriptor)
        files = []
        for source in RUNTIME_SOURCES:
            relative = target_for(source, proxy)
            parent_descriptor, target = anchored_target(install_descriptor, relative)
            try:
                if os.path.lexists(target) and not regular(target):
                    raise Refusal(f"Refusing non-regular or symlinked collision: {target}")
                original = None
                if regular(target):
                    original_sha = digest(target)
                    mode = stat.S_IMODE(os.lstat(target).st_mode)
                    name = backup_name(relative)
                    backup = os.path.join(backups, name)
                    shutil.copyfile(target, backup)
                    os.chmod(backup, 0o600)
                    fsync(backup)
                    if digest(target) != original_sha:
                        raise Refusal(f"Collision changed while being backed up: {target}")
                    original = {"backup": name, "sha256": original_sha, "mode": mode}
            finally:
                os.close(parent_descriptor)
            source_path = os.path.join(release_dir, source)
            files.append({
                "path": relative, "kind": "runtime", "installedSha256": digest(source_path),
                "installedMode": 0o644, "original": original,
            })
        for source in CONFIG_SOURCES:
            parent_descriptor, target = anchored_target(install_descriptor, source)
            try:
                if os.path.lexists(target):
                    if not regular(target):
                        raise Refusal(f"Refusing non-regular or symlinked config: {target}")
                    continue
            finally:
                os.close(parent_descriptor)
            source_path = os.path.join(release_dir, source)
            files.append({
                "path": source, "kind": "config", "installedSha256": digest(source_path),
                "installedMode": 0o644, "original": None,
            })
        record = {
            "schemaVersion": 1, "candidateId": identifier, "installPath": install_path,
            "release": release, "proxy": proxy, "files": files, "directories": owned_dirs,
        }
        atomic_json(os.path.join(temporary, "record.json"), record)
        fsync(backups)
        fsync(temporary)
        os.rename(temporary, record_dir)
        published = True
        fsync(installs_dir)
        return record, record_dir
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        if not published:
            remove_owned_directories(install_descriptor, owned_dirs)
        raise


def update_record(record, record_dir, release_dir, release):
    install_path = record["installPath"]
    old_entries = {entry["path"]: entry for entry in record["files"]}
    files = []
    for source in RUNTIME_SOURCES:
        relative = target_for(source, record["proxy"])
        old = old_entries[relative]
        condition = file_condition(install_path, old)
        if condition == "modified":
            raise Refusal(f"Installed runtime changed outside the toolkit: {os.path.join(install_path, relative)}")
        source_path = os.path.join(release_dir, source)
        entry = {
            "path": relative, "kind": "runtime", "installedSha256": digest(source_path),
            "installedMode": 0o644, "original": old["original"],
        }
        if (
            entry["installedSha256"] != old["installedSha256"]
            or entry["installedMode"] != old["installedMode"]
        ):
            entry["previousInstalledSha256"] = old["installedSha256"]
            entry["previousInstalledMode"] = old["installedMode"]
        files.append(entry)
    for source in CONFIG_SOURCES:
        old = old_entries.get(source)
        target = os.path.join(install_path, source)
        if old is not None and file_condition(install_path, old) == "installed":
            files.append(old)
        elif not os.path.lexists(target):
            source_path = os.path.join(release_dir, source)
            files.append({
                "path": source, "kind": "config", "installedSha256": digest(source_path),
                "installedMode": 0o644, "original": None,
            })
        elif not regular(target):
            raise Refusal(f"Refusing non-regular or symlinked config: {target}")
    updated = dict(record)
    updated["release"] = release
    updated["files"] = files
    return updated


def finalized_record(record):
    result = dict(record)
    result["files"] = []
    for entry in record["files"]:
        final = dict(entry)
        final.pop("previousInstalledSha256", None)
        final.pop("previousInstalledMode", None)
        result["files"].append(final)
    return result


def reconcile_ready_quarantines(record, install_descriptor):
    for entry in record["files"]:
        parent_descriptor, target = anchored_target(
            install_descriptor, entry["path"]
        )
        try:
            cleanup_completed_quarantine(target, entry, "installed")
        finally:
            os.close(parent_descriptor)


def install_runtime(release_dir, installs_dir, install_path, release, proxy, fsr_state, expected_id):
    if proxy not in PROXIES:
        raise Refusal(f"Unsupported proxy DLL: {proxy}")
    install_path, install_identity = canonical_install(install_path, expected_id)
    install_descriptor = open_install_root(install_path, install_identity)
    try:
        install_runtime_open(
            release_dir, installs_dir, install_path, install_identity,
            install_descriptor, release, proxy, fsr_state,
        )
    finally:
        os.close(install_descriptor)


def install_runtime_open(
    release_dir, installs_dir, install_path, install_identity,
    install_descriptor, release, proxy, fsr_state,
):
    identifier = candidate_id(install_path)
    record_dir = os.path.join(installs_dir, identifier)
    fsr4_blocked(fsr_state, install_path)
    existing = os.path.lexists(record_dir)
    if existing:
        previous_record = read_record(record_dir)
        if previous_record["installPath"] != install_path:
            raise Refusal("OptiScaler record path does not match the requested directory.")
        if previous_record["proxy"] != proxy:
            raise Refusal(f"OptiScaler is recorded with {previous_record['proxy']}; uninstall it before changing proxy.")
        state = record_state(previous_record, release)
        if state == "ready":
            reconcile_ready_quarantines(previous_record, install_descriptor)
            print(f"[bc250-optiscaler] {release} is already installed at {install_path}")
            return
        if state == "modified":
            raise Refusal("Installed runtime changed outside the toolkit; refusing update.")
        if state == "restorable":
            if previous_record["release"] != release:
                raise Refusal(
                    "An interrupted OptiScaler operation must be uninstalled before upgrading."
                )
            record = previous_record
        else:
            record = update_record(previous_record, record_dir, release_dir, release)
            atomic_json(os.path.join(record_dir, "record.json"), record)
            fsync(record_dir)
    else:
        record, record_dir = build_fresh_record(
            release_dir, installs_dir, install_path, install_descriptor, release, proxy
        )
    for source in RUNTIME_SOURCES:
        relative = target_for(source, proxy)
        entry = next(item for item in record["files"] if item["path"] == relative)
        assert_install_identity(install_path, install_identity)
        parent_descriptor, target = anchored_target(install_descriptor, relative)
        try:
            atomic_copy_checked(
                os.path.join(release_dir, source),
                target,
                entry["installedMode"],
                entry,
                {"missing", "installed", "previous", "original"},
            )
        finally:
            os.close(parent_descriptor)
    for source in CONFIG_SOURCES:
        entry = next((item for item in record["files"] if item["path"] == source), None)
        if entry is not None:
            parent_descriptor, target = anchored_target(install_descriptor, source)
            try:
                if not os.path.lexists(target):
                    atomic_copy_checked(
                        os.path.join(release_dir, source),
                        target,
                        entry["installedMode"],
                        entry,
                        {"missing"},
                    )
            finally:
                os.close(parent_descriptor)
    assert_install_identity(install_path, install_identity)
    final = finalized_record(record)
    for entry in final["files"]:
        if entry["kind"] != "runtime":
            continue
        parent_descriptor, target = anchored_target(install_descriptor, entry["path"])
        try:
            if condition_for_file(target, entry) != "installed":
                raise Refusal(
                    "Installed OptiScaler runtime failed verification; rollback record was retained."
                )
        finally:
            os.close(parent_descriptor)
    atomic_json(os.path.join(record_dir, "record.json"), final)
    fsync(record_dir)
    print(f"[bc250-optiscaler] Installed OptiScaler {release} at {install_path}")
    print(f'[bc250-optiscaler] Launch option: WINEDLLOVERRIDES="{proxy[:-4]}=n,b" %command%')


def uninstall_runtime(installs_dir, install_path, current_release, fsr_state, expected_id):
    install_path, install_identity = canonical_install(install_path, expected_id)
    install_descriptor = open_install_root(install_path, install_identity)
    try:
        uninstall_runtime_open(
            installs_dir, install_path, install_identity, install_descriptor,
            current_release, fsr_state,
        )
    finally:
        os.close(install_descriptor)


def uninstall_runtime_open(
    installs_dir, install_path, install_identity, install_descriptor,
    current_release, fsr_state,
):
    record_dir = os.path.join(installs_dir, candidate_id(install_path))
    if not os.path.lexists(record_dir):
        raise Refusal(f"No toolkit OptiScaler installation is recorded for {install_path}")
    record = read_record(record_dir)
    if record["installPath"] != install_path:
        raise Refusal("OptiScaler record path does not match the requested directory.")
    fsr4_blocked(fsr_state, install_path)
    for entry in record["files"]:
        if entry["kind"] != "runtime":
            continue
        parent_descriptor, target = anchored_target(install_descriptor, entry["path"])
        try:
            if condition_for_file(target, entry) == "modified":
                raise Refusal(
                    f"Installed runtime changed outside the toolkit: {os.path.join(install_path, entry['path'])}"
                )
        finally:
            os.close(parent_descriptor)
    for entry in record["files"]:
        assert_install_identity(install_path, install_identity)
        parent_descriptor, target = anchored_target(install_descriptor, entry["path"])
        try:
            condition = condition_for_file(target, entry)
            if entry["kind"] == "config":
                if condition in ("missing", "installed"):
                    remove_checked(target, entry, {"missing", "installed"})
                continue
            if condition == "modified":
                raise Refusal(f"Installed file changed before restoration: {target}")
            original = entry["original"]
            if original is not None:
                if condition == "original":
                    cleanup_completed_quarantine(target, entry, "original")
                else:
                    backup = os.path.join(record_dir, "backups", original["backup"])
                    atomic_copy_checked(
                        backup,
                        target,
                        original["mode"],
                        entry,
                        {"missing", "installed", "previous", "original"},
                    )
                    if (
                        digest(target) != original["sha256"]
                        or stat.S_IMODE(os.lstat(target).st_mode) != original["mode"]
                    ):
                        raise Refusal(f"Restored file failed verification: {target}")
            elif condition in ("missing", "installed", "previous"):
                remove_checked(target, entry, {"missing", "installed", "previous"})
        finally:
            os.close(parent_descriptor)
    for relative in reversed(record["directories"]):
        try:
            metadata = os.stat(relative, dir_fd=install_descriptor, follow_symlinks=False)
            if stat.S_ISDIR(metadata.st_mode):
                os.rmdir(relative, dir_fd=install_descriptor)
                os.fsync(install_descriptor)
        except OSError:
            pass
    assert_install_identity(install_path, install_identity)
    identifier = record["candidateId"]
    cleanup_record_tombstone(installs_dir, identifier)
    tombstone = record_tombstone(installs_dir, identifier)
    os.rename(record_dir, tombstone)
    fsync(installs_dir)
    fsync(os.path.dirname(installs_dir))
    shutil.rmtree(tombstone)
    fsync(os.path.dirname(installs_dir))
    print(f"[bc250-optiscaler] Uninstalled OptiScaler from {install_path}")


def records_json(installs_dir, current_release):
    records = []
    invalid = 0
    if not directory(installs_dir):
        invalid = 1
        records.append({
            "candidateId": hashlib.sha256(b"unsafe-state").hexdigest(), "installPath": None,
            "release": None, "proxy": None, "state": "invalid", "currentRelease": False,
            "launchOption": "",
        })
    else:
        for index, name in enumerate(sorted(os.listdir(installs_dir))):
            if index >= 4096:
                invalid += 1
                break
            record_dir = os.path.join(installs_dir, name)
            try:
                record = read_record(record_dir)
                state_value = record_state(record, current_release)
                current = record["release"] == current_release
                records.append({
                    "candidateId": record["candidateId"], "installPath": record["installPath"],
                    "release": record["release"], "proxy": record["proxy"], "state": state_value,
                    "currentRelease": current,
                    "launchOption": f'WINEDLLOVERRIDES="{record["proxy"][:-4]}=n,b" %command%',
                })
            except (OSError, Refusal, ValueError):
                invalid += 1
                identifier = name if SHA_RE.fullmatch(name) else hashlib.sha256(
                    name.encode("utf-8", "surrogateescape")
                ).hexdigest()
                records.append({
                    "candidateId": identifier, "installPath": None, "release": None,
                    "proxy": None, "state": "invalid", "currentRelease": False,
                    "launchOption": "",
                })
    states = [item["state"] for item in records]
    if not records:
        overall = "not-installed"
    elif invalid or any(value in ("invalid", "modified", "missing") for value in states):
        overall = "invalid"
    elif any(value == "restorable" for value in states):
        overall = "restorable"
    elif any(value == "upgrade-required" for value in states):
        overall = "upgrade-required"
    elif any(value == "repair-required" for value in states):
        overall = "repair-required"
    else:
        overall = "ready"
    print(json.dumps({
        "schemaVersion": 1, "currentRelease": current_release, "state": overall,
        "invalidRecordCount": invalid, "records": records,
    }, ensure_ascii=True, separators=(",", ":")))


def main():
    action = sys.argv[1]
    if action == "validate-archive":
        validate_archive(sys.argv[2])
    elif action == "validate-release":
        if not validate_release(sys.argv[2], sys.argv[3] == "write"):
            raise Refusal("Extracted OptiScaler payload failed validation.")
    elif action == "install":
        install_runtime(*sys.argv[2:])
    elif action == "uninstall":
        uninstall_runtime(*sys.argv[2:])
    elif action == "records-json":
        records_json(*sys.argv[2:])
    else:
        raise Refusal("Unknown internal operation.")


try:
    main()
except Refusal as error:
    print(f"[bc250-optiscaler] {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

stage_release() {
    local source_archive=${BC250_OPTISCALER_ARCHIVE:-} temporary stage
    if [[ -d "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] \
        && python_core validate-release "$RELEASE_DIR" check >/dev/null 2>&1; then
        return 0
    fi
    rm -rf -- "$RELEASE_DIR"
    if [[ -n "$source_archive" ]]; then
        [[ -f "$source_archive" && ! -L "$source_archive" ]] \
            || die "Local OptiScaler archive is missing or unsafe: $source_archive"
        [[ "$(sha256_file "$source_archive")" == "$ARCHIVE_SHA256" ]] \
            || die "Local OptiScaler archive checksum mismatch."
        temporary=$(mktemp "$CACHE_DIR/.archive.XXXXXX")
        install -m 0600 "$source_archive" "$temporary"
        fsync_paths "$temporary"
        mv -f -- "$temporary" "$ARCHIVE"
        fsync_paths "$ARCHIVE" "$CACHE_DIR"
    elif [[ ! -f "$ARCHIVE" || -L "$ARCHIVE" \
        || "$(sha256_file "$ARCHIVE")" != "$ARCHIVE_SHA256" ]]; then
        command -v curl >/dev/null 2>&1 || die "curl is required."
        rm -f -- "$ARCHIVE"
        temporary=$(mktemp "$CACHE_DIR/.archive.XXXXXX")
        curl --retry 3 --retry-all-errors -fsSL "$ARCHIVE_URL" -o "$temporary" \
            || { rm -f -- "$temporary"; die "Could not download $ARCHIVE_URL"; }
        [[ "$(sha256_file "$temporary")" == "$ARCHIVE_SHA256" ]] \
            || { rm -f -- "$temporary"; die "Downloaded OptiScaler archive checksum mismatch."; }
        chmod 0600 "$temporary"
        fsync_paths "$temporary"
        mv -f -- "$temporary" "$ARCHIVE"
        fsync_paths "$ARCHIVE" "$CACHE_DIR"
    fi
    [[ -f "$ARCHIVE" && ! -L "$ARCHIVE" \
        && "$(sha256_file "$ARCHIVE")" == "$ARCHIVE_SHA256" ]] \
        || die "Cached OptiScaler archive checksum mismatch."
    command -v 7z >/dev/null 2>&1 || die "7z is required."
    python_core validate-archive "$ARCHIVE"
    stage=$(mktemp -d "$CACHE_DIR/releases/.release.XXXXXX")
    if ! 7z x -y -snld -o"$stage" -- "$ARCHIVE" >/dev/null; then
        rm -rf -- "$stage"
        die "Could not extract the verified OptiScaler archive."
    fi
    python_core validate-release "$stage" write \
        || { rm -rf -- "$stage"; die "Extracted OptiScaler payload failed validation."; }
    chmod -R go-w "$stage"
    fsync_paths "$stage" "$CACHE_DIR/releases"
    mv -- "$stage" "$RELEASE_DIR"
    fsync_paths "$RELEASE_DIR" "$CACHE_DIR/releases"
    python_core validate-release "$RELEASE_DIR" check \
        || die "Cached OptiScaler release failed validation."
}

usage() {
    cat <<EOF
Usage: $0 records-json
       $0 install ABSOLUTE_DIRECTORY PROXY_DLL CANDIDATE_ID
       $0 uninstall ABSOLUTE_DIRECTORY CANDIDATE_ID

Installs checksum-pinned OptiScaler $RELEASE without running the upstream setup
or uninstaller. Supported proxies: dxgi.dll, winmm.dll, version.dll, dbghelp.dll,
d3d12.dll, wininet.dll, winhttp.dll.
EOF
}

case "${1:-help}" in
    records-json)
        (($# == 1)) || exit 2
        require_normal_user; ensure_state
        exec 9> "$LOCK_FILE"; flock -s 9
        python_core records-json "$INSTALLS_DIR" "$RELEASE"
        ;;
    install)
        (($# == 4)) || die "Usage: $0 install ABSOLUTE_DIRECTORY PROXY_DLL CANDIDATE_ID"
        require_normal_user; ensure_state
        exec 9> "$LOCK_FILE"; flock 9
        stage_release
        prepare_fsr4_lock
        exec 8> "$FSR4_LOCK_FILE"; flock 8
        python_core install "$RELEASE_DIR" "$INSTALLS_DIR" "$2" "$RELEASE" "$3" "$FSR4_STATE" "$4"
        ;;
    uninstall)
        (($# == 3)) || die "Usage: $0 uninstall ABSOLUTE_DIRECTORY CANDIDATE_ID"
        require_normal_user; ensure_state
        exec 9> "$LOCK_FILE"; flock 9
        prepare_fsr4_lock
        exec 8> "$FSR4_LOCK_FILE"; flock 8
        python_core uninstall "$INSTALLS_DIR" "$2" "$RELEASE" "$FSR4_STATE" "$3"
        ;;
    help|-h|--help) (($# == 1)) || exit 2; usage ;;
    *) usage >&2; exit 2 ;;
esac
