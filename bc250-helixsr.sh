#!/usr/bin/env bash
# Prepare and install pinned or latest HelixSR with verified rollback records.
set -euo pipefail
umask 077

RELEASE="${BC250_HELIXSR_RELEASE:-v1.4.3}"
[[ "$RELEASE" =~ ^v[0-9][0-9A-Za-z._-]*$ ]] \
    || { printf '[bc250-helixsr] Invalid release identifier.\n' >&2; exit 1; }
ARCHIVE_NAME="${BC250_HELIXSR_ARCHIVE_NAME:-HelixSR-${RELEASE#v}.zip}"
[[ -n "$ARCHIVE_NAME" && "$ARCHIVE_NAME" != */* && "$ARCHIVE_NAME" != *$'\n'* \
    && "$ARCHIVE_NAME" != *$'\r'* ]] \
    || { printf '[bc250-helixsr] Invalid archive name.\n' >&2; exit 1; }
ARCHIVE_URL="https://github.com/lonewolf0622/HelixSR/releases/download/$RELEASE/$ARCHIVE_NAME"
ARCHIVE_SHA256="${BC250_HELIXSR_ARCHIVE_SHA256:-d79e849444e0ea8928c0b8df22ec21368ac08ec038417c087a3d2df7a6722119}"
DLL_SHA256="${BC250_HELIXSR_DLL_SHA256:-3fe8d532516b6441bd8893d986c494a19795375ebd2a6dffb1a9742e3db7dcfd}"
WEIGHTS_SHA256="${BC250_HELIXSR_WEIGHTS_SHA256:-762adfde720035f7ac43910846e0ce6826c239bcd41f863196f77c547ae57153}"
DLSS_SHA256="${BC250_HELIXSR_DLSS_SHA256:-be6e434a94ca32499515eb62ca0e6c274526055d568d0426e4c652dcdfb6ee6e}"
for checksum in "$ARCHIVE_SHA256" "$DLL_SHA256" "$WEIGHTS_SHA256" "$DLSS_SHA256"; do
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] \
        || { printf '[bc250-helixsr] Invalid pinned checksum.\n' >&2; exit 1; }
done
STABLE_RELEASE="$RELEASE"
STABLE_DLL_SHA256="$DLL_SHA256"
STABLE_WEIGHTS_SHA256="$WEIGHTS_SHA256"

MESH_STATE="${BC250_MESH_STATE_DIR:-$HOME/.local/share/bc250-mesh-shader}"
STATE_DIR="${BC250_HELIXSR_STATE_DIR:-$MESH_STATE/helixsr}"
CACHE_DIR="$STATE_DIR/cache"
INSTALLS_DIR="$STATE_DIR/installs"
PAYLOAD_DIR="$STATE_DIR/payload"
SETUP_DATA="$STATE_DIR/setup-data"
ARCHIVE="$CACHE_DIR/$ARCHIVE_NAME"
LOCK_FILE="${BC250_HELIXSR_LOCK_FILE:-$STATE_DIR.lock}"
FSR4_STATE="${BC250_FSR4_STATE_DIR:-$MESH_STATE/fsr4-dll}"
FSR4_LOCK_FILE="${BC250_FSR4_LOCK_FILE:-$HOME/.cache/bc250-fsr4.lock}"
OPTISCALER_STATE="${BC250_OPTISCALER_STATE_DIR:-$MESH_STATE/optiscaler}"
OPTISCALER_LOCK_FILE="${BC250_OPTISCALER_LOCK_FILE:-$OPTISCALER_STATE.lock}"

log() { printf '[bc250-helixsr] %s\n' "$*"; }
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
    [[ "$STATE_DIR" == /* && "$LOCK_FILE" == /* && "$FSR4_LOCK_FILE" == /* \
        && "$OPTISCALER_LOCK_FILE" == /* ]] \
        || die "HelixSR state and lock paths must be absolute."
    [[ ! -L "$STATE_DIR" && ! -L "$CACHE_DIR" && ! -L "$INSTALLS_DIR" \
        && ! -L "$PAYLOAD_DIR" && ! -L "$SETUP_DATA" && ! -L "$LOCK_FILE" ]] \
        || die "Refusing symlinked HelixSR state."
    [[ ! -e "$SETUP_DATA" || -d "$SETUP_DATA" ]] \
        || die "HelixSR setup cache is unsafe."
    mkdir -p "$CACHE_DIR" "$INSTALLS_DIR" "${LOCK_FILE%/*}"
    [[ -d "$STATE_DIR" && -d "$CACHE_DIR" && -d "$INSTALLS_DIR" \
        && ! -L "$STATE_DIR" && ! -L "$CACHE_DIR" && ! -L "$INSTALLS_DIR" ]] \
        || die "HelixSR state is unsafe."
    chmod 0700 "$STATE_DIR" "$CACHE_DIR" "$INSTALLS_DIR"
}

prepare_cross_locks() {
    local lock
    for lock in "$OPTISCALER_LOCK_FILE" "$FSR4_LOCK_FILE"; do
        [[ ! -L "$lock" ]] || die "Refusing symlinked manager lock file: $lock"
        mkdir -p "${lock%/*}"
        [[ -d "${lock%/*}" && ! -L "${lock%/*}" ]] \
            || die "Manager lock directory is unsafe: ${lock%/*}"
    done
}

prepare_query_lock() {
    command -v flock >/dev/null 2>&1 || die "flock is required."
    command -v python3 >/dev/null 2>&1 || die "python3 is required."
    [[ "$STATE_DIR" == /* && "$LOCK_FILE" == /* ]] \
        || die "HelixSR state and lock paths must be absolute."
    [[ ! -L "$LOCK_FILE" ]] || die "Refusing symlinked HelixSR lock file."
    mkdir -p "${LOCK_FILE%/*}"
    [[ -d "${LOCK_FILE%/*}" && ! -L "${LOCK_FILE%/*}" ]] \
        || die "HelixSR lock directory is unsafe."
}

lock_all_managers() {
    # Global mutation order: OptiScaler, FSR4, HelixSR.
    prepare_cross_locks
    exec 7> "$OPTISCALER_LOCK_FILE"; flock 7
    exec 8> "$FSR4_LOCK_FILE"; flock 8
    exec 9> "$LOCK_FILE"; flock 9
}

python_core() {
    python3 - "$@" <<'PY'
import ctypes
import errno
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import sys
import tempfile
import zipfile

SHA_RE = re.compile(r"^[0-9a-f]{64}$")
RELEASE_RE = re.compile(r"^v[0-9][0-9A-Za-z._-]*$")
TARGET_NAMES = {"amd_fidelityfx_upscaler_dx12.dll", "amd_fidelityfx_dx12.dll"}
RUNTIME_NAMES = ("helixsr_weights.bin", "helixsr_kernels.pak")
CONFIG_NAME = "helixsr.ini"
FORWARD_NAME = "amd_fidelityfx_dx12.bc250-helixsr-original.dll"
AT_FDCWD = -100
RENAME_NOREPLACE = 1
LIBC = ctypes.CDLL(None, use_errno=True)

ARCHIVE_FILES = (
    "LICENSE", "README.md", "SOURCE.md", "THIRD_PARTY_NOTICES.md",
    "amd_fidelityfx_dx12.dll", "helixsr-setup.bat", "helixsr-setup.ps1",
    "helixsr-setup.sh", "helixsr.ini", "setup/helixsr_setup.py",
    "setup/kernels/common/fp16.h", "setup/kernels/common/port_cpp.h",
    "setup/kernels/common/port_hlsl.hlsli", "setup/kernels/rt/px_common.h",
    "setup/kernels/rt/px_cpp.h", "setup/kernels/rt/px_hlsl.h",
    "setup/kernels/u5/u5_memory.h", "setup/lib/compact_hlsl.py",
    "setup/lib/compact_u5.py", "setup/lib/extract_ptx.py",
    "setup/lib/extract_weights.py", "setup/lib/family_hlsl.py",
    "setup/lib/fast_tiles.py", "setup/lib/kernels.py", "setup/lib/load_fence.py",
    "setup/lib/ptx2hlsl.py", "setup/lib/ptxsim.py", "setup/lib/regen_kernels.py",
    "setup/lib/samplers.py", "setup/lib/trace_tables.py", "setup/lib/u5_roll.py",
    "setup/lib/u5_rows.py", "setup/lib/family_k/gen_helper.py",
    "setup/lib/family_k/trace_frags.py", "setup/lib/family_k/two_sites.json",
    "setup/lib/family_k/validate.py", "setup/lib/family_u/gen_helper.py",
    "setup/lib/family_u/ptxsim_up.py", "setup/lib/family_u/trace_frags.py",
    "setup/lib/family_u/two_sites.json", "setup/lib/family_u/validate.py",
    "setup/lib/model/launch_synth", "setup/lib/model/launch_synth.cpp",
    "setup/lib/model/launch_synth.exe", "setup/lib/model/model.cpp",
    "setup/lib/model/model.h", "setup/lib/model/model_gen.inc",
)
PINNED_ARCHIVE_EXTRA_FILES = (
    "LICENSE-APACHE-2.0", "helixsr-install.bat", "helixsr-install.sh",
    "setup/helixsr_install.py", "setup/lib/splitk_hlsl.py",
)


class Refusal(Exception):
    pass


def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


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


def fsync(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def target_id(path):
    return hashlib.sha256(path.encode("utf-8", "surrogateescape")).hexdigest()


def verify_expected_id(target, expected_id):
    if not expected_id:
        return
    if not SHA_RE.fullmatch(expected_id):
        raise Refusal("Expected HelixSR target ID must be exactly 64 lowercase hexadecimal characters.")
    if target_id(target) != expected_id:
        raise Refusal("Expected HelixSR target ID does not match the canonical target path.")


def validate_archive(archive, destination, root_name, allow_extra=False):
    required = {f"{root_name}/{name}" for name in ARCHIVE_FILES}
    pinned = required | {f"{root_name}/{name}" for name in PINNED_ARCHIVE_EXTRA_FILES}
    try:
        source = zipfile.ZipFile(archive)
    except (OSError, zipfile.BadZipFile) as error:
        raise Refusal("Verified HelixSR archive is not a valid zip file.") from error
    with source:
        entries = source.infolist()
        names = [entry.filename for entry in entries]
        expected = required if allow_extra else pinned
        if len(names) != len(set(names)) or not required.issubset(names) \
                or (not allow_extra and (len(names) != len(expected) or set(names) != expected)):
            raise Refusal("HelixSR archive has an unexpected payload layout.")
        if sum(entry.file_size for entry in entries) > 128 * 1024 * 1024:
            raise Refusal("HelixSR archive is unexpectedly large.")
        for entry in entries:
            name = entry.filename
            parts = name.split("/")
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if (
                "" in parts or "." in parts or ".." in parts
                or name.startswith("/") or "\\" in name or entry.is_dir()
                or not name.startswith(root_name + "/")
                or entry.flag_bits & 1
                or kind not in (0, stat.S_IFREG)
            ):
                raise Refusal(f"Unsafe HelixSR archive entry: {name}")
        os.mkdir(destination, 0o700)
        for entry in entries:
            if entry.filename not in expected:
                continue
            relative = entry.filename[len(root_name) + 1:]
            target = os.path.join(destination, relative)
            os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
            with source.open(entry) as input_stream, open(target, "xb") as output:
                shutil.copyfileobj(input_stream, output)
            os.chmod(target, 0o600)
    actual = set()
    for current, dirs, files in os.walk(destination, topdown=True, followlinks=False):
        for name in dirs + files:
            path = os.path.join(current, name)
            relative = os.path.relpath(path, destination)
            if os.path.islink(path):
                raise Refusal(f"Unsafe extracted HelixSR entry: {relative}")
            if name in dirs and not directory(path):
                raise Refusal(f"Unsafe extracted HelixSR directory: {relative}")
            if name in files:
                if not regular(path):
                    raise Refusal(f"Unsafe extracted HelixSR file: {relative}")
                actual.add(relative)
    wanted_files = set(ARCHIVE_FILES) if allow_extra else set(ARCHIVE_FILES) | set(PINNED_ARCHIVE_EXTRA_FILES)
    if actual != wanted_files:
        raise Refusal("Extracted HelixSR payload failed validation.")


def latest_metadata(path):
    try:
        with open(path, encoding="utf-8") as stream:
            release_data = json.load(stream)
    except (OSError, ValueError) as error:
        raise Refusal("Could not parse GitHub's latest HelixSR release metadata.") from error
    if not isinstance(release_data, dict) or not isinstance(release_data.get("assets"), list):
        raise Refusal("GitHub returned malformed latest HelixSR release metadata.")
    release = release_data.get("tag_name")
    if not isinstance(release, str) or not RELEASE_RE.fullmatch(release):
        raise Refusal("GitHub returned an invalid latest HelixSR release tag.")
    name = f"HelixSR-{release[1:]}.zip"
    matches = [item for item in release_data.get("assets", [])
               if isinstance(item, dict) and item.get("name") == name]
    if len(matches) != 1:
        raise Refusal("Latest HelixSR release does not have its expected ZIP asset.")
    asset = matches[0]
    digest_value = asset.get("digest")
    url = f"https://github.com/lonewolf0622/HelixSR/releases/download/{release}/{name}"
    if asset.get("browser_download_url") != url or not isinstance(digest_value, str) \
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest_value):
        raise Refusal("Latest HelixSR release asset lacks a valid GitHub SHA-256 digest.")
    print(f"{release}\t{name}\t{digest_value[7:]}")


def payload_identity(root):
    manifest_path = os.path.join(root, "manifest.json")
    if not regular(manifest_path):
        raise Refusal("Prepared HelixSR payload has no valid identity manifest.")
    try:
        with open(manifest_path, encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, ValueError) as error:
        raise Refusal("Prepared HelixSR identity manifest is malformed.") from error
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion", "release", "dllSha256", "weightsSha256", "kernelsSha256",
        "iniSha256", "setupSha256", "sourceSha256", "shaderCount",
    } or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1 \
            or not isinstance(value["release"], str) or not RELEASE_RE.fullmatch(value["release"]) \
            or any(not isinstance(value[key], str) or not SHA_RE.fullmatch(value[key]) for key in (
                "dllSha256", "weightsSha256", "kernelsSha256", "iniSha256",
                "setupSha256", "sourceSha256",
            )) or type(value["shaderCount"]) is not int or value["shaderCount"] not in (30, 60):
        raise Refusal("Prepared HelixSR identity manifest is invalid.")
    print(f"{value['release']}\t{value['dllSha256']}\t{value['weightsSha256']}")


def setup_source_sha(path, weights_sha):
    metadata = setup_metadata(path, weights_sha)
    if metadata is None:
        raise Refusal("Generated HelixSR setup metadata is invalid.")
    print(metadata["source_sha256"])


def kernel_pack_count(path):
    if not regular(path):
        return None
    try:
        data = open(path, "rb").read()
    except OSError:
        return None
    if len(data) < 16 or data[:8] != b"HXSRKPAK":
        return None
    version, count = struct.unpack_from("<II", data, 8)
    valid_counts = {1: {30}, 2: {30, 60}}
    if version not in valid_counts or count not in valid_counts[version] \
            or len(data) < 16 + count * 40:
        return None
    previous_end = 16 + count * 40
    names = set()
    for index in range(count):
        raw_name, offset, size = struct.unpack_from("<32sII", data, 16 + index * 40)
        name = raw_name.split(b"\0", 1)[0]
        if not name or name in names or offset != previous_end or offset + size > len(data):
            return None
        names.add(name)
        previous_end = offset + size
    return count if previous_end == len(data) else None
def setup_metadata(path, weights_sha, source_sha=None, shader_count=None):
    if not regular(path):
        return None
    try:
        with open(path, encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, ValueError):
        return None
    required = {"source_sha256", "ptx_target", "shaders", "weights_sha256"}
    if not isinstance(value, dict) or set(value) not in (required, required | {"wave64"}):
        return None
    if (
        not isinstance(value["source_sha256"], str)
        or not SHA_RE.fullmatch(value["source_sha256"])
        or value["ptx_target"] not in ("sm_80", "sm_89")
        or type(value["shaders"]) is not int
        or value["shaders"] not in (30, 60)
        or value["weights_sha256"] != weights_sha
        or ("wave64" in value and type(value["wave64"]) is not bool)
        or ("wave64" in value and value["shaders"] != (60 if value["wave64"] else 30))
        or ("wave64" not in value and value["shaders"] != 30)
        or (shader_count is not None and value["shaders"] != shader_count)
        or (source_sha is not None and value["source_sha256"] != source_sha)
    ):
        return None
    return value


def payload_values(root, release, dll_sha, weights_sha):
    files = {
        "amd_fidelityfx_dx12.dll": dll_sha,
        "helixsr_weights.bin": weights_sha,
    }
    if not directory(root):
        return None
    for name, expected in files.items():
        path = os.path.join(root, name)
        if not regular(path) or digest(path) != expected:
            return None
    kernel = os.path.join(root, "helixsr_kernels.pak")
    ini = os.path.join(root, "helixsr.ini")
    setup = os.path.join(root, "helixsr_setup.json")
    manifest_path = os.path.join(root, "manifest.json")
    shader_count = kernel_pack_count(kernel)
    if shader_count is None or not regular(ini):
        return None
    metadata = setup_metadata(setup, weights_sha, shader_count=shader_count)
    if metadata is None or not regular(manifest_path):
        return None
    values = {
        "schemaVersion": 1,
        "release": release,
        "dllSha256": dll_sha,
        "weightsSha256": weights_sha,
        "kernelsSha256": digest(kernel),
        "iniSha256": digest(ini),
        "setupSha256": digest(setup),
        "sourceSha256": metadata["source_sha256"],
        "shaderCount": metadata["shaders"],
    }
    try:
        with open(manifest_path, encoding="utf-8") as stream:
            manifest = json.load(stream)
    except (OSError, ValueError):
        return None
    return values if manifest == values else None


def validate_payload(root, release, dll_sha, weights_sha, repair=False):
    expected = {
        "amd_fidelityfx_dx12.dll", "helixsr_weights.bin", "helixsr_kernels.pak",
        "helixsr.ini", "helixsr_setup.json", "manifest.json",
    }
    if repair and directory(root):
        os.chmod(root, 0o700)
        try:
            repair_entries = set(os.listdir(root))
        except OSError:
            repair_entries = set()
        if repair_entries == expected and all(
            regular(os.path.join(root, name)) for name in expected
        ):
            for name in expected:
                os.chmod(os.path.join(root, name), 0o600)
    values = payload_values(root, release, dll_sha, weights_sha)
    if values is None:
        raise Refusal("Prepared HelixSR payload failed validation.")
    actual = set(os.listdir(root))
    if actual != expected:
        raise Refusal("Prepared HelixSR payload has an unexpected layout.")
    if repair:
        os.chmod(root, 0o700)
        for name in expected:
            os.chmod(os.path.join(root, name), 0o600)
    elif stat.S_IMODE(os.lstat(root).st_mode) != 0o700 or any(
        stat.S_IMODE(os.lstat(os.path.join(root, name)).st_mode) != 0o600
        for name in expected
    ):
        raise Refusal("Prepared HelixSR payload permissions are unsafe.")


def write_manifest(root, release, dll_sha, weights_sha, source_sha):
    dll = os.path.join(root, "amd_fidelityfx_dx12.dll")
    weights = os.path.join(root, "helixsr_weights.bin")
    kernel = os.path.join(root, "helixsr_kernels.pak")
    ini = os.path.join(root, "helixsr.ini")
    setup = os.path.join(root, "helixsr_setup.json")
    if not regular(dll) or digest(dll) != dll_sha:
        raise Refusal("Generated HelixSR DLL failed validation.")
    if not regular(weights) or digest(weights) != weights_sha:
        raise Refusal("Generated HelixSR weights failed validation.")
    shader_count = kernel_pack_count(kernel)
    if shader_count is None or not regular(ini):
        raise Refusal("Generated HelixSR kernel pack or configuration failed validation.")
    metadata = setup_metadata(setup, weights_sha, source_sha, shader_count)
    if metadata is None:
        raise Refusal("Generated HelixSR setup metadata failed validation.")
    manifest = {
        "schemaVersion": 1, "release": release, "dllSha256": dll_sha,
        "weightsSha256": weights_sha, "kernelsSha256": digest(kernel),
        "iniSha256": digest(ini), "setupSha256": digest(setup),
        "sourceSha256": metadata["source_sha256"], "shaderCount": metadata["shaders"],
    }
    path = os.path.join(root, "manifest.json")
    with open(path, "x", encoding="ascii") as stream:
        json.dump(manifest, stream, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(root, 0o700)
    for name in os.listdir(root):
        os.chmod(os.path.join(root, name), 0o600)
        fsync(os.path.join(root, name))
    fsync(root)
    validate_payload(root, release, dll_sha, weights_sha)


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


def canonical_target(value, require_file=True):
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        raise Refusal("Target must be an absolute DLL path without line breaks.")
    if not os.path.isabs(value):
        value = os.path.abspath(value)
    if os.path.islink(value) or (require_file and not regular(value)) \
            or (os.path.lexists(value) and not regular(value)):
        raise Refusal(f"Target DLL is missing, non-regular, or a symlink: {value}")
    parent = os.path.realpath(os.path.dirname(value))
    if not directory(parent):
        raise Refusal(f"Target directory is unsafe: {parent}")
    name = os.path.basename(value)
    if name not in TARGET_NAMES:
        raise Refusal(f"Unsupported HelixSR target DLL name: {name}")
    result = os.path.join(parent, name)
    if os.path.islink(result) or (require_file and not regular(result)) \
            or (os.path.lexists(result) and not regular(result)):
        raise Refusal(f"Target DLL is missing, non-regular, or a symlink: {result}")
    return result


def manager_records(state, kind):
    installs = os.path.join(state, "installs")
    if os.path.islink(state) or os.path.islink(installs):
        if os.path.lexists(state) or os.path.lexists(installs):
            raise Refusal(f"{kind} state is unsafe; refusing this operation.")
        return []
    if not os.path.exists(installs):
        return []
    if not directory(installs):
        raise Refusal(f"{kind} state is unsafe; refusing this operation.")
    return [(name, os.path.join(installs, name)) for name in os.listdir(installs)]


def check_cross_managers(target, fsr_state, opti_state):
    for name, record_dir in manager_records(fsr_state, "FSR4"):
        target_file = os.path.join(record_dir, "target")
        if not SHA_RE.fullmatch(name) or not directory(record_dir) or not regular(target_file):
            raise Refusal("FSR4 state contains an invalid record; refusing this operation.")
        try:
            lines = open(target_file, encoding="utf-8", errors="surrogateescape").read().splitlines()
        except OSError as error:
            raise Refusal("FSR4 state could not be read; refusing this operation.") from error
        if len(lines) != 1 or not lines[0].startswith("/"):
            raise Refusal("FSR4 state contains an invalid target; refusing this operation.")
        recorded = os.path.abspath(os.path.normpath(lines[0]))
        if target_id(recorded) != name:
            raise Refusal("FSR4 record identity is invalid; refusing this operation.")
        if recorded == target:
            raise Refusal(f"Target is managed by FSR4: {target}")
    parent = os.path.dirname(target)
    for name, record_dir in manager_records(opti_state, "OptiScaler"):
        path = os.path.join(record_dir, "record.json")
        if not SHA_RE.fullmatch(name) or not directory(record_dir) or not regular(path):
            raise Refusal("OptiScaler state contains an invalid record; refusing this operation.")
        try:
            record = json.load(open(path, encoding="utf-8"))
            install_path = record["installPath"]
            candidate = record["candidateId"]
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise Refusal("OptiScaler state contains an invalid record; refusing this operation.") from error
        if (
            not isinstance(install_path, str) or not install_path.startswith("/")
            or candidate != name or target_id(install_path) != name
        ):
            raise Refusal("OptiScaler record identity is invalid; refusing this operation.")
        if os.path.normpath(install_path) == parent:
            raise Refusal(f"Target directory is managed by OptiScaler: {parent}")


def desired_ini(payload, target_name):
    value = open(os.path.join(payload, CONFIG_NAME), "rb").read()
    if target_name != "amd_fidelityfx_dx12.dll":
        return value
    text = value.decode("utf-8")
    lines = text.splitlines(keepends=True)
    section = False
    changed = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped.lower() == "[forwarding]"
        elif section and re.match(r"^\s*Dll\s*=", line, re.IGNORECASE):
            ending = "\r\n" if line.endswith("\r\n") else "\n"
            lines[index] = f"Dll = {FORWARD_NAME}{ending}"
            changed = True
            break
    if not changed:
        raise Refusal("Pinned helixsr.ini lacks the forwarding setting.")
    return "".join(lines).encode("utf-8")


def expected_names(target_name):
    result = [target_name, *RUNTIME_NAMES, CONFIG_NAME]
    if target_name == "amd_fidelityfx_dx12.dll":
        result.append(FORWARD_NAME)
    return result


def read_record(record_dir):
    if not directory(record_dir):
        raise Refusal("record directory is not a real directory")
    path = os.path.join(record_dir, "record.json")
    if not regular(path):
        raise Refusal("record metadata is missing or unsafe")
    try:
        record = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Refusal("record metadata is malformed") from error
    required = {"schemaVersion", "targetId", "targetPath", "release", "dllSha256", "files"}
    if set(record) != required or type(record["schemaVersion"]) is not int \
            or record["schemaVersion"] != 1:
        raise Refusal("record schema is invalid")
    target = record["targetPath"]
    identifier = record["targetId"]
    if (
        not isinstance(target, str) or not target.startswith("/")
        or "\n" in target or "\r" in target or os.path.normpath(target) != target
        or not isinstance(identifier, str) or identifier != target_id(target)
        or os.path.basename(record_dir) != identifier
        or os.path.basename(target) not in TARGET_NAMES
        or not isinstance(record["release"], str) or not RELEASE_RE.fullmatch(record["release"])
        or not isinstance(record["dllSha256"], str) or not SHA_RE.fullmatch(record["dllSha256"])
        or not isinstance(record["files"], list)
    ):
        raise Refusal("record identity is invalid")
    wanted = expected_names(os.path.basename(target))
    if [entry.get("name") if isinstance(entry, dict) else None for entry in record["files"]] != wanted:
        raise Refusal("record file list is invalid")
    expected_roles = {
        os.path.basename(target): "target",
        "helixsr_weights.bin": "runtime",
        "helixsr_kernels.pak": "runtime",
        CONFIG_NAME: "config",
        FORWARD_NAME: "forward",
    }
    backups = os.path.join(record_dir, "backups")
    if not directory(backups):
        raise Refusal("record backups are missing or unsafe")
    for entry in record["files"]:
        keys = {"name", "role", "installedSha256", "installedMode", "original", "preserve"}
        pending = keys | {"previousSha256", "previousMode"}
        if set(entry) not in (keys, pending):
            raise Refusal("record file entry is invalid")
        if entry["role"] != expected_roles[entry["name"]]:
            raise Refusal("record file role is invalid")
        if not isinstance(entry["installedSha256"], str) \
                or not SHA_RE.fullmatch(entry["installedSha256"]):
            raise Refusal("record installed checksum is invalid")
        if type(entry["installedMode"]) is not int \
                or not 0 <= entry["installedMode"] <= 0o7777:
            raise Refusal("record installed mode is invalid")
        if type(entry["preserve"]) is not bool \
                or entry["preserve"] and entry["role"] != "config":
            raise Refusal("record preservation flag is invalid")
        if set(entry) == pending and (
            not isinstance(entry["previousSha256"], str)
            or not SHA_RE.fullmatch(entry["previousSha256"])
            or type(entry["previousMode"]) is not int
            or not 0 <= entry["previousMode"] <= 0o7777
        ):
            raise Refusal("record pending-update metadata is invalid")
        original = entry["original"]
        if original is not None:
            if not isinstance(original, dict) or set(original) != {"backup", "sha256", "mode"}:
                raise Refusal("record backup metadata is invalid")
            if (
                not isinstance(original["backup"], str) or not original["backup"]
                or "/" in original["backup"] or "\\" in original["backup"]
                or original["backup"] != backup_name(entry["name"])
                or not isinstance(original["sha256"], str)
                or not SHA_RE.fullmatch(original["sha256"])
                or type(original["mode"]) is not int
                or not 0 <= original["mode"] <= 0o7777
            ):
                raise Refusal("record backup is missing, unsafe, or modified")
            backup = os.path.join(backups, original["backup"])
            if not regular(backup) or digest(backup) != original["sha256"]:
                raise Refusal("record backup is missing, unsafe, or modified")
        if entry["preserve"] and original is not None:
            raise Refusal("record preservation metadata is invalid")
        if entry["role"] == "target" and original is None:
            raise Refusal("record target rollback backup is missing")
    target_entry = record["files"][0]
    if target_entry["role"] != "target" or target_entry["installedSha256"] != record["dllSha256"]:
        raise Refusal("record DLL identity is invalid")
    return record


def file_condition(parent, entry):
    path = os.path.join(parent, entry["name"])
    if not os.path.lexists(path):
        return "missing"
    if not regular(path):
        return "modified"
    actual = digest(path)
    mode = stat.S_IMODE(os.lstat(path).st_mode)
    if actual == entry["installedSha256"] and mode == entry["installedMode"]:
        return "installed"
    if actual == entry.get("previousSha256") and mode == entry.get("previousMode"):
        return "previous"
    original = entry["original"]
    if original is not None and actual == original["sha256"] and mode == original["mode"]:
        return "original"
    if entry["preserve"] and regular(path):
        return "preserved"
    return "modified"


def record_state(record, current_release, current_dll):
    parent = os.path.dirname(record["targetPath"])
    conditions = [file_condition(parent, entry) for entry in record["files"]]
    for entry, condition in zip(record["files"], conditions):
        if condition == "modified":
            if entry["role"] == "config" and entry["original"] is None:
                continue
            return "modified"
    runtime = [condition for entry, condition in zip(record["files"], conditions) if entry["role"] != "config"]
    if any("previousSha256" in entry for entry in record["files"]):
        return "restorable"
    if any(condition != "installed" for condition in runtime):
        if all(condition in ("original", "missing") for condition in runtime):
            return "restored"
        return "restorable"
    if record["release"] != current_release or record["dllSha256"] != current_dll:
        return "upgrade-required"
    return "ready"


def rename_noreplace(source, target):
    if LIBC.renameat2(
        AT_FDCWD, ctypes.c_char_p(os.fsencode(source)),
        AT_FDCWD, ctypes.c_char_p(os.fsencode(target)), RENAME_NOREPLACE,
    ) == 0:
        return
    error = ctypes.get_errno()
    if error == errno.EEXIST:
        raise FileExistsError(error, os.strerror(error), target)
    raise OSError(error, os.strerror(error), source, target)


def quarantine_path(path):
    suffix = hashlib.sha256(os.fsencode(os.path.basename(path))).hexdigest()[:24]
    return os.path.join(os.path.dirname(path), f".bc250-helixsr-{suffix}.rollback")


def quarantine(path, entry, allowed):
    recovery = quarantine_path(path)
    if os.path.lexists(recovery):
        recovery_condition = file_condition(os.path.dirname(recovery), {**entry, "name": os.path.basename(recovery)})
        target_condition = file_condition(os.path.dirname(path), entry)
        if not os.path.lexists(path) and recovery_condition in allowed:
            rename_noreplace(recovery, path)
            fsync(os.path.dirname(path))
        elif target_condition in allowed and recovery_condition in allowed:
            os.unlink(recovery)
            fsync(os.path.dirname(path))
        else:
            raise Refusal(f"Target and recovery file conflict; refusing to overwrite either: {path}")
    condition = file_condition(os.path.dirname(path), entry)
    if condition == "missing":
        if "missing" not in allowed:
            raise Refusal(f"Managed file disappeared before mutation: {path}")
        return None
    try:
        rename_noreplace(path, recovery)
    except FileNotFoundError as error:
        if "missing" in allowed:
            return None
        raise Refusal(f"Managed file disappeared before mutation: {path}") from error
    condition = file_condition(os.path.dirname(recovery), {**entry, "name": os.path.basename(recovery)})
    if condition not in allowed:
        try:
            rename_noreplace(recovery, path)
        except FileExistsError:
            pass
        raise Refusal(f"Managed file changed during mutation: {path}")
    return recovery


def atomic_bytes(value, path, mode, entry, allowed):
    parent = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(prefix=os.path.basename(path) + ".bc250.", dir=parent)
    recovery = None
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(value)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        recovery = quarantine(path, entry, allowed)
        rename_noreplace(temporary, path)
        if recovery is not None:
            os.unlink(recovery)
        fsync(path)
        fsync(parent)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        if recovery is not None and os.path.lexists(recovery) and not os.path.lexists(path):
            try:
                rename_noreplace(recovery, path)
            except FileExistsError:
                pass
        raise


def remove_checked(path, entry, allowed):
    recovery = quarantine(path, entry, allowed)
    if recovery is not None:
        os.unlink(recovery)
        fsync(os.path.dirname(path))


def backup_name(name):
    return hashlib.sha256(name.encode("ascii")).hexdigest() + ".original"


def fresh_record(payload, installs, target, release, dll_sha):
    parent = os.path.dirname(target)
    target_name = os.path.basename(target)
    identifier = target_id(target)
    record_dir = os.path.join(installs, identifier)
    if os.path.lexists(record_dir):
        raise Refusal(f"Existing HelixSR record is malformed: {record_dir}")
    temporary = tempfile.mkdtemp(prefix=".helixsr-record.", dir=installs)
    os.chmod(temporary, 0o700)
    backups = os.path.join(temporary, "backups")
    os.mkdir(backups, 0o700)
    try:
        target_bytes = open(target, "rb").read()
        ini = desired_ini(payload, target_name)
        desired = {
            target_name: open(os.path.join(payload, "amd_fidelityfx_dx12.dll"), "rb").read(),
            "helixsr_weights.bin": open(os.path.join(payload, "helixsr_weights.bin"), "rb").read(),
            "helixsr_kernels.pak": open(os.path.join(payload, "helixsr_kernels.pak"), "rb").read(),
            CONFIG_NAME: ini,
        }
        if target_name == "amd_fidelityfx_dx12.dll":
            desired[FORWARD_NAME] = target_bytes
        roles = {target_name: "target", CONFIG_NAME: "config", FORWARD_NAME: "forward"}
        files = []
        for name in expected_names(target_name):
            path = os.path.join(parent, name)
            if os.path.lexists(path) and not regular(path):
                raise Refusal(f"Refusing non-regular or symlinked collision: {path}")
            original = None
            mode = 0o644
            if regular(path):
                original_sha = digest(path)
                original_mode = stat.S_IMODE(os.lstat(path).st_mode)
                backup_file = backup_name(name)
                backup_path = os.path.join(backups, backup_file)
                shutil.copyfile(path, backup_path)
                os.chmod(backup_path, 0o600)
                fsync(backup_path)
                if digest(path) != original_sha:
                    raise Refusal(f"Collision changed while being backed up: {path}")
                original = {"backup": backup_file, "sha256": original_sha, "mode": original_mode}
                if name == target_name:
                    mode = original_mode
            files.append({
                "name": name, "role": roles.get(name, "runtime"),
                "installedSha256": digest_bytes(desired[name]), "installedMode": mode,
                "original": original, "preserve": False,
            })
        record = {
            "schemaVersion": 1, "targetId": identifier, "targetPath": target,
            "release": release, "dllSha256": dll_sha, "files": files,
        }
        atomic_json(os.path.join(temporary, "record.json"), record)
        fsync(backups)
        fsync(temporary)
        os.rename(temporary, record_dir)
        fsync(installs)
        return record, record_dir, desired
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def update_record(payload, record, record_dir, release, dll_sha):
    parent = os.path.dirname(record["targetPath"])
    target_name = os.path.basename(record["targetPath"])
    original_target = record["files"][0]["original"]
    if original_target is None:
        raise Refusal("HelixSR target rollback backup is missing.")
    backup = os.path.join(record_dir, "backups", original_target["backup"])
    desired = {
        target_name: open(os.path.join(payload, "amd_fidelityfx_dx12.dll"), "rb").read(),
        "helixsr_weights.bin": open(os.path.join(payload, "helixsr_weights.bin"), "rb").read(),
        "helixsr_kernels.pak": open(os.path.join(payload, "helixsr_kernels.pak"), "rb").read(),
        CONFIG_NAME: desired_ini(payload, target_name),
    }
    if target_name == "amd_fidelityfx_dx12.dll":
        desired[FORWARD_NAME] = open(backup, "rb").read()
    files = []
    for old in record["files"]:
        condition = file_condition(parent, old)
        if condition == "modified":
            if old["role"] == "config" and old["original"] is None:
                preserved = dict(old)
                path = os.path.join(parent, old["name"])
                if not regular(path):
                    raise Refusal(f"Installed configuration is unsafe: {path}")
                preserved["installedSha256"] = digest(path)
                preserved["installedMode"] = stat.S_IMODE(os.lstat(path).st_mode)
                preserved["preserve"] = True
                files.append(preserved)
                desired.pop(old["name"], None)
                continue
            raise Refusal(f"Installed file changed outside the toolkit: {os.path.join(parent, old['name'])}")
        if old["preserve"]:
            files.append(old)
            desired.pop(old["name"], None)
            continue
        new = dict(old)
        new_sha = digest_bytes(desired[old["name"]])
        if new_sha != old["installedSha256"]:
            new["previousSha256"] = old["installedSha256"]
            new["previousMode"] = old["installedMode"]
            new["installedSha256"] = new_sha
        files.append(new)
    updated = dict(record)
    updated.update(release=release, dllSha256=dll_sha, files=files)
    atomic_json(os.path.join(record_dir, "record.json"), updated)
    return updated, desired


def finalized(record):
    result = dict(record)
    result["files"] = []
    for entry in record["files"]:
        item = dict(entry)
        item.pop("previousSha256", None)
        item.pop("previousMode", None)
        result["files"].append(item)
    return result


def install(payload, installs, target_value, release, dll_sha, weights_sha, fsr_state, opti_state, expected_id):
    validate_payload(payload, release, dll_sha, weights_sha)
    target = canonical_target(target_value, require_file=False)
    verify_expected_id(target, expected_id)
    check_cross_managers(target, fsr_state, opti_state)
    parent = os.path.dirname(target)
    identity = os.stat(parent, follow_symlinks=False)
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        identifier = target_id(target)
        record_dir = os.path.join(installs, identifier)
        if not os.path.lexists(record_dir) and not regular(target):
            raise Refusal(f"Target DLL is missing, non-regular, or a symlink: {target}")
        if os.path.lexists(record_dir):
            record = read_record(record_dir)
            if record["targetPath"] != target:
                raise Refusal("HelixSR record path does not match the requested target.")
            state_value = record_state(record, release, dll_sha)
            if state_value == "ready":
                print(f"[bc250-helixsr] {release} is already installed at {target}")
                return
            if state_value == "modified":
                raise Refusal("Installed HelixSR files changed outside the toolkit; refusing update.")
            if state_value in ("restorable", "restored") and record["release"] != release:
                raise Refusal("An interrupted HelixSR operation must be uninstalled before upgrading.")
            if record["release"] == release and record["dllSha256"] == dll_sha:
                target_name = os.path.basename(target)
                original = record["files"][0]["original"]
                backup = os.path.join(record_dir, "backups", original["backup"])
                desired = {
                    target_name: open(os.path.join(payload, "amd_fidelityfx_dx12.dll"), "rb").read(),
                    "helixsr_weights.bin": open(os.path.join(payload, "helixsr_weights.bin"), "rb").read(),
                    "helixsr_kernels.pak": open(os.path.join(payload, "helixsr_kernels.pak"), "rb").read(),
                    CONFIG_NAME: desired_ini(payload, target_name),
                }
                if target_name == "amd_fidelityfx_dx12.dll":
                    desired[FORWARD_NAME] = open(backup, "rb").read()
                for entry in record["files"]:
                    if entry["preserve"]:
                        desired.pop(entry["name"], None)
            else:
                record, desired = update_record(payload, record, record_dir, release, dll_sha)
        else:
            record, record_dir, desired = fresh_record(payload, installs, target, release, dll_sha)
        for entry in record["files"]:
            if entry["preserve"]:
                continue
            current = os.stat(parent, follow_symlinks=False)
            if (current.st_dev, current.st_ino) != (identity.st_dev, identity.st_ino):
                raise Refusal("Target directory changed during the operation.")
            path = f"/proc/self/fd/{parent_fd}/{entry['name']}"
            atomic_bytes(
                desired[entry["name"]], path, entry["installedMode"], entry,
                {"missing", "installed", "previous", "original"},
            )
        final = finalized(record)
        for entry in final["files"]:
            condition = file_condition(parent, entry)
            if entry["preserve"]:
                if condition not in ("installed", "preserved"):
                    raise Refusal("Preserved HelixSR configuration became unsafe.")
            elif condition != "installed":
                raise Refusal("Installed HelixSR payload failed verification; rollback was retained.")
        atomic_json(os.path.join(record_dir, "record.json"), final)
        fsync(record_dir)
        print(f"[bc250-helixsr] Installed HelixSR {release} at {target}")
    finally:
        os.close(parent_fd)


def uninstall_record(record_dir, current_release, current_dll, fsr_state, opti_state):
    record = read_record(record_dir)
    target = record["targetPath"]
    check_cross_managers(target, fsr_state, opti_state)
    parent = os.path.dirname(target)
    if not directory(parent) or os.path.islink(parent):
        raise Refusal(f"Target directory is missing or unsafe: {parent}")
    descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        for entry in record["files"]:
            condition = file_condition(parent, entry)
            if condition == "modified":
                path = os.path.join(parent, entry["name"])
                if entry["role"] == "config" and entry["original"] is None \
                        and regular(path):
                    continue
                raise Refusal(f"Installed file changed outside the toolkit: {path}")
        for entry in reversed(record["files"]):
            path = f"/proc/self/fd/{descriptor}/{entry['name']}"
            condition = file_condition(parent, entry)
            if entry["preserve"] and entry["original"] is None:
                continue
            if entry["role"] == "config" and entry["original"] is None \
                    and condition in ("modified", "preserved"):
                continue
            original = entry["original"]
            if original is not None:
                if condition == "original":
                    continue
                backup = os.path.join(record_dir, "backups", original["backup"])
                atomic_bytes(
                    open(backup, "rb").read(), path, original["mode"], entry,
                    {"missing", "installed", "previous", "original"},
                )
                if digest(path) != original["sha256"] \
                        or stat.S_IMODE(os.lstat(path).st_mode) != original["mode"]:
                    raise Refusal(f"Restored file failed verification: {os.path.join(parent, entry['name'])}")
            elif condition in ("missing", "installed", "previous"):
                remove_checked(path, entry, {"missing", "installed", "previous"})
        tombstone = os.path.join(os.path.dirname(os.path.dirname(record_dir)), f".removed-{record['targetId']}")
        if os.path.lexists(tombstone):
            if not directory(tombstone):
                raise Refusal(f"HelixSR removal tombstone is unsafe: {tombstone}")
            shutil.rmtree(tombstone)
        os.rename(record_dir, tombstone)
        fsync(os.path.dirname(record_dir))
        shutil.rmtree(tombstone)
        fsync(os.path.dirname(os.path.dirname(record_dir)))
        print(f"[bc250-helixsr] Restored original files at {parent}")
    finally:
        os.close(descriptor)


def uninstall(installs, target_value, current_release, current_dll, fsr_state, opti_state, expected_id):
    target = canonical_target(target_value, require_file=False)
    verify_expected_id(target, expected_id)
    record_dir = os.path.join(installs, target_id(target))
    if not os.path.lexists(record_dir):
        raise Refusal(f"No toolkit HelixSR installation is recorded for {target}")
    uninstall_record(record_dir, current_release, current_dll, fsr_state, opti_state)


def records_data(installs, release, dll_sha, payload_state):
    records = []
    invalid = 0
    state = os.path.dirname(installs)
    unsafe = (
        os.path.islink(state) or os.path.islink(installs)
        or (os.path.lexists(state) and not directory(state))
        or (os.path.lexists(installs) and not directory(installs))
    )
    if unsafe:
        records.append({
            "targetId": hashlib.sha256(b"unsafe-state").hexdigest(), "targetPath": None,
            "release": None, "state": "invalid", "currentRelease": False,
        })
        invalid = 1
    elif directory(installs):
        for index, name in enumerate(sorted(os.listdir(installs))):
            if index >= 4096:
                invalid += 1
                records.append({
                    "targetId": hashlib.sha256(b"record-limit").hexdigest(), "targetPath": None,
                    "release": None, "state": "invalid", "currentRelease": False,
                })
                break
            try:
                record = read_record(os.path.join(installs, name))
                state_value = record_state(record, release, dll_sha)
                current = record["release"] == release and record["dllSha256"] == dll_sha
                records.append({
                    "targetId": record["targetId"], "targetPath": record["targetPath"],
                    "release": record["release"], "state": state_value,
                    "currentRelease": current,
                })
            except (OSError, Refusal, ValueError):
                invalid += 1
                identifier = name if SHA_RE.fullmatch(name) else hashlib.sha256(
                    name.encode("utf-8", "surrogateescape")
                ).hexdigest()
                records.append({
                    "targetId": identifier, "targetPath": None, "release": None,
                    "state": "invalid", "currentRelease": False,
                })
    states = [item["state"] for item in records]
    if not records:
        overall = "not-installed"
    elif invalid or any(value in ("invalid", "modified") for value in states):
        overall = "invalid"
    elif any(value in ("restorable", "restored") for value in states):
        overall = "restorable"
    elif any(value == "upgrade-required" for value in states):
        overall = "upgrade-required"
    else:
        overall = "ready"
    return {
        "schemaVersion": 1, "release": release, "dllSha256": dll_sha,
        "payloadState": payload_state, "state": overall,
        "invalidRecordCount": invalid, "records": records,
    }


def main():
    action = sys.argv[1]
    if action == "extract":
        validate_archive(*sys.argv[2:5], allow_extra=sys.argv[5] == "allow-extra")
    elif action == "latest-metadata":
        latest_metadata(sys.argv[2])
    elif action == "payload-identity":
        payload_identity(sys.argv[2])
    elif action == "setup-source-sha":
        setup_source_sha(sys.argv[2], sys.argv[3])
    elif action == "manifest":
        write_manifest(*sys.argv[2:])
    elif action == "validate-payload":
        validate_payload(*sys.argv[2:6], repair=sys.argv[6] == "repair")
    elif action == "check-target-id":
        target = canonical_target(sys.argv[2], require_file=sys.argv[4] == "required")
        verify_expected_id(target, sys.argv[3])
    elif action == "install":
        install(*sys.argv[2:])
    elif action == "uninstall":
        uninstall(*sys.argv[2:])
    elif action == "uninstall-record":
        uninstall_record(*sys.argv[2:])
    elif action == "records":
        print(json.dumps(records_data(*sys.argv[2:]), ensure_ascii=True, separators=(",", ":")))
    else:
        raise Refusal("Unknown internal operation.")


try:
    main()
except Refusal as error:
    print(f"[bc250-helixsr] {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

resolve_latest_release() {
    local metadata resolved
    command -v curl >/dev/null 2>&1 || die "curl is required to resolve the latest HelixSR release."
    metadata=$(mktemp "$CACHE_DIR/.release.XXXXXX")
    if ! curl --retry 3 --retry-all-errors -fsSL \
        -H 'Accept: application/vnd.github+json' \
        'https://api.github.com/repos/lonewolf0622/HelixSR/releases/latest' \
        -o "$metadata"; then
        rm -f -- "$metadata"
        die "Could not resolve the latest HelixSR release from GitHub."
    fi
    if ! resolved=$(python_core latest-metadata "$metadata"); then
        rm -f -- "$metadata"
        die "GitHub's latest HelixSR release metadata is invalid."
    fi
    rm -f -- "$metadata"
    IFS=$'\t' read -r RELEASE ARCHIVE_NAME ARCHIVE_SHA256 <<< "$resolved"
    [[ "$RELEASE" =~ ^v[0-9][0-9A-Za-z._-]*$ \
        && "$ARCHIVE_NAME" == "HelixSR-${RELEASE#v}.zip" \
        && "$ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        || die "Latest HelixSR release metadata failed validation."
    ARCHIVE_URL="https://github.com/lonewolf0622/HelixSR/releases/download/$RELEASE/$ARCHIVE_NAME"
    ARCHIVE="$CACHE_DIR/$ARCHIVE_NAME"
    DLL_SHA256=""
    WEIGHTS_SHA256=""
    log "Latest HelixSR release resolved to $RELEASE (YMMV; the stable pinned release remains v1.4.3)."
}

use_payload_identity() {
    local identity active_release active_dll active_weights
    [[ -d "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]] || return 1
    identity=$(python_core payload-identity "$PAYLOAD_DIR" 2>/dev/null) || return 1
    IFS=$'\t' read -r active_release active_dll active_weights <<< "$identity"
    [[ "$active_release" =~ ^v[0-9][0-9A-Za-z._-]*$ \
        && "$active_dll" =~ ^[0-9a-f]{64}$ \
        && "$active_weights" =~ ^[0-9a-f]{64}$ ]] || return 1
    # Keep the known stable pins authoritative; use the local manifest only for
    # payloads whose versions are outside the stable pin.
    if [[ "$active_release" == "$STABLE_RELEASE" ]]; then
        [[ "$active_dll" == "$STABLE_DLL_SHA256" \
            && "$active_weights" == "$STABLE_WEIGHTS_SHA256" ]] || return 1
        RELEASE=$STABLE_RELEASE
        DLL_SHA256=$STABLE_DLL_SHA256
        WEIGHTS_SHA256=$STABLE_WEIGHTS_SHA256
    else
        RELEASE=$active_release
        DLL_SHA256=$active_dll
        WEIGHTS_SHA256=$active_weights
    fi
    ARCHIVE_NAME="HelixSR-${RELEASE#v}.zip"
    ARCHIVE_URL="https://github.com/lonewolf0622/HelixSR/releases/download/$RELEASE/$ARCHIVE_NAME"
    ARCHIVE="$CACHE_DIR/$ARCHIVE_NAME"
}

payload_state() {
    use_payload_identity || true
    if [[ -L "$STATE_DIR" || ( -e "$STATE_DIR" && ! -d "$STATE_DIR" ) ]]; then
        printf 'invalid\n'
        return 2
    fi
    if [[ ! -e "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]]; then
        printf 'not-prepared\n'
        return 1
    fi
    if [[ -d "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]] \
        && python_core validate-payload "$PAYLOAD_DIR" "$RELEASE" "$DLL_SHA256" "$WEIGHTS_SHA256" check \
            >/dev/null 2>&1; then
        printf 'ready\n'
        return 0
    fi
    printf 'invalid\n'
    return 2
}

prepare_payload() {
    local dlss=${1:-} latest=${2:-0} source_archive=${BC250_HELIXSR_ARCHIVE:-}
    local temporary extract output old expected_source_sha active_identity
    local active_release active_dll active_weights requested_release=$RELEASE
    expected_source_sha=$DLSS_SHA256
    if [[ "$latest" == 1 ]]; then
        if [[ -d "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]] \
            && active_identity=$(python_core payload-identity "$PAYLOAD_DIR" 2>/dev/null); then
            IFS=$'\t' read -r active_release active_dll active_weights <<< "$active_identity"
            if [[ "$active_release" == "$requested_release" ]] \
                && [[ -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] \
                && [[ "$(sha256_file "$ARCHIVE")" == "$ARCHIVE_SHA256" ]] \
                && python_core validate-payload "$PAYLOAD_DIR" "$active_release" "$active_dll" "$active_weights" repair \
                    >/dev/null 2>&1; then
                RELEASE=$active_release
                DLL_SHA256=$active_dll
                WEIGHTS_SHA256=$active_weights
                log "HelixSR $RELEASE payload is already prepared."
                return
            fi
        fi
        DLL_SHA256=""
        WEIGHTS_SHA256=""
        expected_source_sha=""
    elif [[ -d "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]] \
        && python_core validate-payload "$PAYLOAD_DIR" "$RELEASE" "$DLL_SHA256" "$WEIGHTS_SHA256" repair \
            >/dev/null 2>&1; then
        log "HelixSR $RELEASE payload is already prepared."
        return
    fi
    if [[ -n "$dlss" ]]; then
        [[ -f "$dlss" && ! -L "$dlss" ]] || die "Local DLSS DLL is missing or unsafe: $dlss"
        dlss=$(realpath -- "$dlss")
        expected_source_sha=$(sha256_file "$dlss")
    fi
    if [[ -n "$source_archive" ]]; then
        [[ -f "$source_archive" && ! -L "$source_archive" ]] \
            || die "Local HelixSR archive is missing or unsafe: $source_archive"
        [[ "$(sha256_file "$source_archive")" == "$ARCHIVE_SHA256" ]] \
            || die "Local HelixSR archive checksum mismatch."
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
            || { rm -f -- "$temporary"; die "Downloaded HelixSR archive checksum mismatch."; }
        chmod 0600 "$temporary"
        fsync_paths "$temporary"
        mv -f -- "$temporary" "$ARCHIVE"
        fsync_paths "$ARCHIVE" "$CACHE_DIR"
    fi
    [[ -f "$ARCHIVE" && ! -L "$ARCHIVE" \
        && "$(sha256_file "$ARCHIVE")" == "$ARCHIVE_SHA256" ]] \
        || die "Cached HelixSR archive checksum mismatch."

    extract=$(mktemp -d "$STATE_DIR/.source.XXXXXX")
    output=$(mktemp -d "$STATE_DIR/.payload.XXXXXX")
    trap 'rm -rf -- "$extract" "$output"' RETURN
    rmdir "$extract"
    if [[ "$latest" == 1 ]]; then
        python_core extract "$ARCHIVE" "$extract" "HelixSR-${RELEASE#v}" allow-extra
        DLL_SHA256=$(sha256_file "$extract/amd_fidelityfx_dx12.dll")
    else
        python_core extract "$ARCHIVE" "$extract" "HelixSR-${RELEASE#v}" strict
    fi
    chmod 0755 "$extract/helixsr-setup.sh" "$extract/setup" "$extract/setup/lib" \
        "$extract/setup/lib/model" "$extract/setup/lib/model/launch_synth"
    install -m 0600 "$extract/amd_fidelityfx_dx12.dll" "$output/amd_fidelityfx_dx12.dll"
    install -m 0600 "$extract/helixsr.ini" "$output/helixsr.ini"
    mkdir -p "$SETUP_DATA"
    chmod 0700 "$SETUP_DATA"
    if [[ -n "$dlss" ]]; then
        XDG_DATA_HOME="$SETUP_DATA" "$extract/helixsr-setup.sh" "$output" --dlss "$dlss"
    else
        XDG_DATA_HOME="$SETUP_DATA" "$extract/helixsr-setup.sh" "$output" --yes
    fi
    chmod -R go-rwx "$SETUP_DATA"
    if [[ "$latest" == 1 ]]; then
        WEIGHTS_SHA256=$(sha256_file "$output/helixsr_weights.bin")
        if [[ -z "$dlss" ]]; then
            expected_source_sha=$(python_core setup-source-sha \
                "$output/helixsr_setup.json" "$WEIGHTS_SHA256") \
                || die "Could not verify HelixSR's generated setup metadata."
        fi
    fi
    python_core manifest "$output" "$RELEASE" "$DLL_SHA256" "$WEIGHTS_SHA256" \
        "$expected_source_sha"
    old="$STATE_DIR/.payload-old"
    if [[ -e "$old" || -L "$old" ]]; then
        [[ -d "$old" && ! -L "$old" ]] || die "HelixSR payload recovery directory is unsafe."
        rm -rf -- "$old"
    fi
    if [[ -e "$PAYLOAD_DIR" || -L "$PAYLOAD_DIR" ]]; then
        [[ -d "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]] \
            || die "Existing HelixSR payload path is unsafe."
        mv -- "$PAYLOAD_DIR" "$old"
        fsync_paths "$STATE_DIR"
    fi
    mv -- "$output" "$PAYLOAD_DIR"
    output=""
    fsync_paths "$PAYLOAD_DIR" "$STATE_DIR"
    rm -rf -- "$old" "$extract"
    extract=""
    fsync_paths "$STATE_DIR"
    trap - RETURN
    if [[ "$latest" == 1 ]]; then
        log "Prepared latest HelixSR $RELEASE payload at $PAYLOAD_DIR (YMMV)."
    else
        log "Prepared pinned HelixSR $RELEASE payload at $PAYLOAD_DIR"
    fi
}

records_json() {
    local state_value
    use_payload_identity || true
    if state_value=$(payload_state); then :; else :; fi
    python_core records "$INSTALLS_DIR" "$RELEASE" "$DLL_SHA256" "$state_value"
}

probe_installs() {
    local data
    data=$(records_json) || return 2
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["state"] == "ready" else 1 if d["state"] == "not-installed" else 2)' <<< "$data"
}

count_installs() {
    local data
    data=$(records_json) || { printf '1\n'; return 2; }
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["records"])); sys.exit(2 if d["invalidRecordCount"] else 0)' <<< "$data"
}

purge_payload() {
    local path
    for path in "$PAYLOAD_DIR" "$CACHE_DIR" "$SETUP_DATA" "$STATE_DIR/.payload-old"; do
        if [[ -e "$path" || -L "$path" ]]; then
            [[ ! -L "$path" && -d "$path" ]] || die "Refusing unsafe HelixSR purge path: $path"
            rm -rf -- "$path"
        fi
    done
    mkdir -p "$CACHE_DIR"
    chmod 0700 "$CACHE_DIR"
    fsync_paths "$STATE_DIR"
    log "Purged the HelixSR payload cache. Rollback records were preserved."
}

usage() {
    cat <<EOF
Usage: $0 prepare [--latest] [DLSS_DLL]
       $0 payload-status
       $0 records-json
       $0 probe
       $0 count
       $0 install TARGET_DLL [EXPECTED_ID]
       $0 uninstall TARGET_DLL [EXPECTED_ID]
       $0 uninstall --all
       $0 purge

By default, prepares checksum-pinned HelixSR $RELEASE. --latest opts into the
current GitHub latest release (YMMV) and verifies its published asset digest.
Both modes install over either
amd_fidelityfx_upscaler_dx12.dll or amd_fidelityfx_dx12.dll. The target and
all sidecar collisions are retained for exact, verified rollback.
EOF
}

prepare_command() {
    shift
    local latest=0 dlss=""
    while (($#)); do
        case "$1" in
            --latest)
                [[ "$latest" == 0 ]] || die "Usage: $0 prepare [--latest] [DLSS_DLL]"
                latest=1
                ;;
            --*) die "Usage: $0 prepare [--latest] [DLSS_DLL]" ;;
            *)
                [[ -z "$dlss" ]] || die "Usage: $0 prepare [--latest] [DLSS_DLL]"
                dlss=$1
                ;;
        esac
        shift
    done
    require_normal_user; ensure_state
    exec 9> "$LOCK_FILE"; flock 9
    if [[ "$latest" == 1 ]]; then resolve_latest_release; fi
    prepare_payload "$dlss" "$latest"
}

case "${1:-help}" in
    prepare) prepare_command "$@" ;;
    payload-status)
        (($# == 1)) || exit 2
        require_normal_user; prepare_query_lock
        exec 9> "$LOCK_FILE"; flock -s 9
        payload_state
        ;;
    records-json)
        (($# == 1)) || exit 2
        require_normal_user; prepare_query_lock
        exec 9> "$LOCK_FILE"; flock -s 9
        records_json
        ;;
    probe)
        (($# == 1)) || exit 2
        require_normal_user; prepare_query_lock
        exec 9> "$LOCK_FILE"; flock -s 9
        probe_installs
        ;;
    count)
        (($# == 1)) || exit 2
        require_normal_user; prepare_query_lock
        exec 9> "$LOCK_FILE"; flock -s 9
        count_installs
        ;;
    install)
        (($# == 2 || $# == 3)) || die "Usage: $0 install TARGET_DLL [EXPECTED_ID]"
        if (($# == 3)); then
            [[ "$3" =~ ^[0-9a-f]{64}$ ]] \
                || die "Expected HelixSR target ID must be exactly 64 lowercase hexadecimal characters."
        fi
        require_normal_user
        if (($# == 3)); then
            command -v python3 >/dev/null 2>&1 || die "python3 is required."
            python_core check-target-id "$2" "$3" optional
        fi
        ensure_state; lock_all_managers
        use_payload_identity || true
        python_core install "$PAYLOAD_DIR" "$INSTALLS_DIR" "$2" "$RELEASE" \
            "$DLL_SHA256" "$WEIGHTS_SHA256" "$FSR4_STATE" "$OPTISCALER_STATE" \
            "${3:-}"
        ;;
    uninstall)
        (($# == 2 || $# == 3)) \
            || die "Usage: $0 uninstall TARGET_DLL [EXPECTED_ID]|--all"
        if [[ "$2" == --all ]]; then
            (($# == 2)) || die "Usage: $0 uninstall --all"
        elif (($# == 3)); then
            [[ "$3" =~ ^[0-9a-f]{64}$ ]] \
                || die "Expected HelixSR target ID must be exactly 64 lowercase hexadecimal characters."
        fi
        require_normal_user
        if [[ "$2" != --all && $# == 3 ]]; then
            command -v python3 >/dev/null 2>&1 || die "python3 is required."
            python_core check-target-id "$2" "$3" optional
        fi
        ensure_state; lock_all_managers
        if [[ "$2" == --all ]]; then
            found=0
            for record in "$INSTALLS_DIR"/* "$INSTALLS_DIR"/.[!.]* "$INSTALLS_DIR"/..?*; do
                [[ -e "$record" || -L "$record" ]] || continue
                found=1
                python_core uninstall-record "$record" "$RELEASE" "$DLL_SHA256" \
                    "$FSR4_STATE" "$OPTISCALER_STATE"
            done
            [[ $found -eq 1 ]] || log "No HelixSR installations are recorded."
        else
            python_core uninstall "$INSTALLS_DIR" "$2" "$RELEASE" "$DLL_SHA256" \
                "$FSR4_STATE" "$OPTISCALER_STATE" "${3:-}"
        fi
        ;;
    purge)
        (($# == 1)) || exit 2
        require_normal_user; ensure_state
        exec 9> "$LOCK_FILE"; flock 9
        purge_payload
        ;;
    help|-h|--help) (($# == 1)) || exit 2; usage ;;
    *) usage >&2; exit 2 ;;
esac
