#!/usr/bin/env bash
# Install the pinned BC-250 GE-Proton build as a user-local Steam compatibility tool.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
TOOL_NAME=protonge-latest-bc250
PACKAGE_VERSION="${BC250_PROTON_PACKAGE_VERSION:-11.6-155}"
PACKAGE_NAME="${BC250_PROTON_PACKAGE_NAME:-protonge-latest-bc250-11.6-155-x86_64.pkg.tar.zst}"
PACKAGE_URL="${BC250_PROTON_PACKAGE_URL:-https://github.com/MastaG/linux-cachyos-bc250/releases/download/repo/$PACKAGE_NAME}"
PACKAGE_SHA256="${BC250_PROTON_PACKAGE_SHA256:-f2b4b30c5fcd73756906e6ce452b9cfbb38ab87eadc3de645bf92eb7b36e1cd7}"
COMPAT_ROOT="${BC250_PROTON_COMPAT_DIR:-$HOME/.local/share/Steam/compatibilitytools.d}"
TARGET="$COMPAT_ROOT/$TOOL_NAME"
STATE_DIR="${BC250_PROTON_STATE_DIR:-$HOME/.local/share/bc250-proton}"
LOCK_FILE="${BC250_PROTON_LOCK_FILE:-$HOME/.cache/bc250-proton.lock}"
TRANSACTION_DIR="$STATE_DIR/transaction"
BACKUP="$COMPAT_ROOT/.$TOOL_NAME.bc250-backup"
REMOVAL_TRANSACTION="$STATE_DIR/removal"
REMOVAL_TARGET="$COMPAT_ROOT/.$TOOL_NAME.bc250-removing"
MARKER=.bc250-steamos-install
INTEGRITY_MANIFEST=.bc250-steamos-files.json
MESH_TOOL="${BC250_MESH_TOOL:-${SELF%/*}/bc250-mesh-shader.sh}"

log() { printf '[bc250-proton] %s\n' "$*"; }
die() { log "$*" >&2; exit 1; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }

require_normal_user() {
    [[ $EUID -ne 0 ]] || die "Run as the logged-in Deck user, not with sudo."
}

ensure_paths() {
    command -v bsdtar >/dev/null 2>&1 || die "bsdtar is required."
    command -v python3 >/dev/null 2>&1 || die "python3 is required."
    command -v flock >/dev/null 2>&1 || die "flock is required."
    [[ "$COMPAT_ROOT" == /* && "$STATE_DIR" == /* && "$LOCK_FILE" == /* ]] \
        || die "Proton state and Steam paths must be absolute."
    [[ ! -L "$COMPAT_ROOT" && ! -L "$STATE_DIR" && ! -L "$LOCK_FILE" ]] \
        || die "Refusing symlinked Proton state or compatibility-tool directory."
    mkdir -p "$COMPAT_ROOT" "$STATE_DIR" "${LOCK_FILE%/*}"
    chmod 0700 "$STATE_DIR"
}

read_marker() {
    local directory=$1 line extra
    MARKER_VERSION= MARKER_PACKAGE_SHA=
    [[ -d "$directory" && ! -L "$directory" \
        && -f "$directory/$MARKER" && ! -L "$directory/$MARKER" ]] || return 1
    IFS= read -r line < "$directory/$MARKER" || return 1
    read -r MARKER_VERSION MARKER_PACKAGE_SHA extra <<< "$line"
    [[ -z "$extra" && "$MARKER_VERSION" =~ ^[0-9][0-9A-Za-z._-]*$ \
        && "$MARKER_PACKAGE_SHA" =~ ^[0-9a-f]{64}$ \
        && "$(wc -l < "$directory/$MARKER")" -eq 1 ]]
}

verify_tool() {
    local directory=$1
    read_marker "$directory" || return 1
    [[ "$(stat -c %a "$directory/$MARKER")" == 644 ]] || return 1
    [[ -x "$directory/proton" && ! -L "$directory/proton" \
        && -f "$directory/compatibilitytool.vdf" \
        && ! -L "$directory/compatibilitytool.vdf" \
        && -f "$directory/toolmanifest.vdf" && ! -L "$directory/toolmanifest.vdf" \
        && -f "$directory/bc250-fsr4-launch.py" \
        && ! -L "$directory/bc250-fsr4-launch.py" \
        && -f "$directory/bc250-fsr4-config.json" \
        && ! -L "$directory/bc250-fsr4-config.json" \
        && -L "$directory/files" && -d "$directory/files" \
        && "$(readlink "$directory/files")" == ge/files \
        && -x "$directory/ge/proton" && ! -L "$directory/ge/proton" \
        && -x "$directory/ge/files/bin/wine" \
        && -f "$directory/ge/upscaler-manifest.json" \
        && ! -L "$directory/ge/upscaler-manifest.json" \
        && -f "$directory/$INTEGRITY_MANIFEST" \
        && ! -L "$directory/$INTEGRITY_MANIFEST" ]] || return 1
    [[ "$(stat -c %a "$directory/$INTEGRITY_MANIFEST")" == 644 ]] || return 1
    grep -qF '"protonge-latest-bc250"' "$directory/compatibilitytool.vdf" \
        && grep -qF '"commandline" "/proton %verb%"' "$directory/toolmanifest.vdf" \
        && verify_integrity_manifest "$directory"
}

write_integrity_manifest() {
    local directory=$1
    python3 - "$directory" "$INTEGRITY_MANIFEST" "$MARKER" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1]).resolve()
manifest_name, marker_name = sys.argv[2:]
files = {}
links = {}
directories = {}
def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root).as_posix()
    if relative in (manifest_name, marker_name):
        continue
    metadata = path.lstat()
    if stat.S_ISDIR(metadata.st_mode):
        directories[relative] = stat.S_IMODE(metadata.st_mode)
        continue
    if stat.S_ISLNK(metadata.st_mode):
        target = os.readlink(path)
        resolved = path.resolve(strict=True)
        try:
            resolved.relative_to(root)
        except ValueError:
            raise SystemExit("External symlink in GE-Proton payload: " + relative)
        links[relative] = target
        continue
    if not stat.S_ISREG(metadata.st_mode):
        raise SystemExit("Unsupported GE-Proton payload entry: " + relative)
    files[relative] = {
        "mode": stat.S_IMODE(metadata.st_mode),
        "sha256": digest(path),
    }
(root / manifest_name).write_text(json.dumps({
    "schemaVersion": 1,
    "rootMode": stat.S_IMODE(root.stat().st_mode),
    "directories": directories,
    "files": files,
    "symlinks": links,
}, sort_keys=True, separators=(",", ":")) + "\n", encoding="ascii")
PY
    chmod 0644 "$directory/$INTEGRITY_MANIFEST"
}

verify_integrity_manifest() {
    local directory=$1
    python3 - "$directory" "$INTEGRITY_MANIFEST" "$MARKER" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

root = Path(sys.argv[1]).resolve()
manifest_name, marker_name = sys.argv[2:]
try:
    manifest_path = root / manifest_name
    data = json.loads(manifest_path.read_text(encoding="ascii"))
    expected_files = data["files"]
    expected_links = data["symlinks"]
    expected_directories = data["directories"]
    if data.get("schemaVersion") != 1 or not isinstance(expected_files, dict) \
            or not isinstance(expected_links, dict) \
            or not isinstance(expected_directories, dict) \
            or not isinstance(data.get("rootMode"), int):
        raise ValueError
except (KeyError, OSError, TypeError, ValueError):
    raise SystemExit(1)
files = {}
links = {}
directories = {}
def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()
try:
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if relative in (manifest_name, marker_name):
            continue
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            directories[relative] = stat.S_IMODE(metadata.st_mode)
            continue
        if stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(path)
            resolved = path.resolve(strict=True)
            resolved.relative_to(root)
            links[relative] = target
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError
        files[relative] = {
            "mode": stat.S_IMODE(metadata.st_mode),
            "sha256": digest(path),
        }
except (OSError, RuntimeError, ValueError):
    raise SystemExit(1)
valid_hashes = all(
    isinstance(path, str) and isinstance(record, dict)
    and isinstance(record.get("mode"), int) and 0 <= record["mode"] <= 0o7777
    and isinstance(record.get("sha256"), str)
    and re.fullmatch(r"[0-9a-f]{64}", record["sha256"])
    for path, record in expected_files.items()
)
valid_links = all(
    isinstance(path, str) and isinstance(target, str)
    for path, target in expected_links.items()
)
valid_directories = all(
    isinstance(path, str) and isinstance(mode, int) and 0 <= mode <= 0o7777
    for path, mode in expected_directories.items()
)
raise SystemExit(0 if valid_hashes and valid_links
                 and valid_directories and data["rootMode"] == stat.S_IMODE(root.stat().st_mode)
                 and files == expected_files and links == expected_links
                 and directories == expected_directories else 1)
PY
}

verify_current_tool() {
    verify_tool "$TARGET" \
        && [[ "$MARKER_VERSION" == "$PACKAGE_VERSION" \
            && "$MARKER_PACKAGE_SHA" == "$PACKAGE_SHA256" ]]
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

fsync_tree() {
    python3 - "$1" <<'PY'
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
directories = []
for current, names, files in os.walk(root, topdown=True, followlinks=False):
    directory = Path(current)
    directories.append(directory)
    names[:] = [name for name in names if not (directory / name).is_symlink()]
    for name in files:
        path = directory / name
        if stat.S_ISREG(path.lstat().st_mode):
            descriptor = os.open(path, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
for directory in reversed(directories):
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

write_transaction_state() {
    local phase=$1 had_old=$2 temporary="$TRANSACTION_DIR/.state-new"
    printf '%s %s\n' "$phase" "$had_old" > "$temporary"
    chmod 0600 "$temporary"
    fsync_paths "$temporary"
    mv -f "$temporary" "$TRANSACTION_DIR/state"
    fsync_paths "$TRANSACTION_DIR/state" "$TRANSACTION_DIR" "$STATE_DIR"
}

recover_transaction() {
    local phase had_old extra
    if [[ ! -e "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" ]]; then
        [[ ! -e "$BACKUP" && ! -L "$BACKUP" ]] \
            || die "An unrecorded GE-Proton backup exists at $BACKUP; refusing to modify it."
        return 0
    fi
    [[ -d "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" \
        && -f "$TRANSACTION_DIR/state" && ! -L "$TRANSACTION_DIR/state" ]] \
        || die "Proton install transaction is malformed; manual recovery is required."
    read -r phase had_old extra < "$TRANSACTION_DIR/state" \
        || die "Proton install transaction state is unreadable."
    [[ ( "$phase" == prepared || "$phase" == backed-up || "$phase" == published ) \
        && ( "$had_old" == 0 || "$had_old" == 1 ) && -z "$extra" ]] \
        || die "Proton install transaction state is malformed."
    if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
        [[ -d "$BACKUP" && ! -L "$BACKUP" ]] \
            || die "Proton transaction backup is unsafe: $BACKUP"
    fi

    if [[ "$phase" == published ]] && verify_current_tool; then
        if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
            rm -rf "$BACKUP"
            fsync_paths "$COMPAT_ROOT"
        fi
    else
        if [[ -e "$TARGET" || -L "$TARGET" ]]; then
            if [[ "$phase" == prepared && "$had_old" == 1 \
                && ! -e "$BACKUP" && ! -L "$BACKUP" ]]; then
                read_marker "$TARGET" \
                    || die "Interrupted install left an unowned target; manual recovery is required."
            else
                read_marker "$TARGET" \
                    || die "Interrupted install left an unowned target; manual recovery is required."
                rm -rf "$TARGET"
                fsync_paths "$COMPAT_ROOT"
            fi
        fi
        if [[ "$had_old" == 1 && ( -e "$BACKUP" || -L "$BACKUP" ) ]]; then
            [[ ! -e "$TARGET" && ! -L "$TARGET" ]] \
                || die "Proton recovery target is unexpectedly occupied."
            verify_tool "$BACKUP" \
                || die "Proton transaction backup is incomplete or unverified."
            mv "$BACKUP" "$TARGET"
            fsync_paths "$COMPAT_ROOT"
        elif [[ "$had_old" == 1 && ! -e "$TARGET" && ! -L "$TARGET" ]]; then
            die "Proton transaction backup is missing; manual recovery is required."
        fi
    fi
    rm -rf "$TRANSACTION_DIR"
    fsync_paths "$STATE_DIR"
    log "Recovered an interrupted GE-Proton installation."
}

recover_removal() {
    local line version package_sha extra
    if [[ ! -e "$REMOVAL_TRANSACTION" && ! -L "$REMOVAL_TRANSACTION" ]]; then
        [[ ! -e "$REMOVAL_TARGET" && ! -L "$REMOVAL_TARGET" ]] \
            || die "An unrecorded GE-Proton removal tombstone exists at $REMOVAL_TARGET"
        return 0
    fi
    [[ -d "$REMOVAL_TRANSACTION" && ! -L "$REMOVAL_TRANSACTION" \
        && -f "$REMOVAL_TRANSACTION/state" \
        && ! -L "$REMOVAL_TRANSACTION/state" ]] \
        || die "GE-Proton removal transaction is malformed; manual recovery is required."
    IFS= read -r line < "$REMOVAL_TRANSACTION/state" \
        || die "GE-Proton removal transaction is unreadable."
    read -r version package_sha extra <<< "$line"
    [[ -z "$extra" && "$version" =~ ^[0-9][0-9A-Za-z._-]*$ \
        && "$package_sha" =~ ^[0-9a-f]{64}$ ]] \
        || die "GE-Proton removal transaction is malformed."
    if [[ -e "$REMOVAL_TARGET" || -L "$REMOVAL_TARGET" ]]; then
        [[ -d "$REMOVAL_TARGET" && ! -L "$REMOVAL_TARGET" ]] \
            || die "GE-Proton removal tombstone is unsafe."
        rm -rf "$REMOVAL_TARGET"
        fsync_paths "$COMPAT_ROOT"
    fi
    rm -rf "$REMOVAL_TRANSACTION"
    fsync_paths "$STATE_DIR"
    log "Recovered an interrupted GE-Proton removal."
}

require_production_radv() {
    local status
    [[ -f "$MESH_TOOL" && ! -L "$MESH_TOOL" ]] \
        || die "The RADV manager is missing: $MESH_TOOL"
    status=$(bash "$MESH_TOOL" status-json 2>/dev/null) \
        || die "FSR4 RADV is not ready. Run '$MESH_TOOL setup', reboot or sign out as instructed, then retry."
    python3 - "$status" <<'PY' || die "FSR4 RADV is not active. Run the RADV setup and complete its reboot/sign-out step first."
import json
import sys

try:
    status = json.loads(sys.argv[1])
except (TypeError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if status.get("runtimeState") == "ready" and status.get("globalEnabled") is True else 1)
PY
}

validate_archive_names() {
    local archive=$1
    bsdtar -tf "$archive" | python3 -c '
import pathlib
import sys
for raw in sys.stdin:
    name = raw.rstrip("\n")
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\x00" in name:
        raise SystemExit("Unsafe path in Proton package: " + repr(name))
'
}

stage_package() {
    local archive=$1 stage=$2 package_tool package_licenses candidate license
    validate_archive_names "$archive" || die "The Proton package contains an unsafe path."
    bsdtar -xf "$archive" -C "$stage" \
        "usr/share/steam/compatibilitytools.d/$TOOL_NAME" \
        "usr/share/licenses/$TOOL_NAME" \
        || die "Could not extract the GE-Proton compatibility tool."
    package_tool="$stage/usr/share/steam/compatibilitytools.d/$TOOL_NAME"
    package_licenses="$stage/usr/share/licenses/$TOOL_NAME"
    candidate="$stage/candidate"
    [[ -d "$package_tool" && ! -L "$package_tool" \
        && -d "$package_licenses" && ! -L "$package_licenses" ]] \
        || die "The Proton package layout is not the expected upstream layout."
    mv "$package_tool" "$candidate"
    for license in "$package_licenses"/*; do
        [[ -f "$license" && ! -L "$license" ]] \
            || die "The Proton package contains an unsafe license entry."
        [[ ! -e "$candidate/${license##*/}" && ! -L "$candidate/${license##*/}" ]] \
            || die "The Proton package license collides with its tool payload."
        mv "$license" "$candidate/"
    done
    write_integrity_manifest "$candidate" \
        || die "Could not record GE-Proton payload integrity."
    printf '%s %s\n' "$PACKAGE_VERSION" "$PACKAGE_SHA256" > "$candidate/$MARKER"
    chmod 0644 "$candidate/$MARKER"
    verify_tool "$candidate" || die "The staged GE-Proton tool failed validation."
    fsync_tree "$candidate"
}

install_tool() {
    local supplied=${BC250_PROTON_ARCHIVE:-} archive= temporary= stage old=0 committed=0
    require_normal_user
    ensure_paths
    exec 9> "$LOCK_FILE"
    flock 9
    recover_removal
    recover_transaction
    require_production_radv
    if verify_current_tool; then
        log "GE-Proton $PACKAGE_VERSION is already installed and verified."
        return 0
    fi
    if [[ -e "$TARGET" || -L "$TARGET" ]]; then
        read_marker "$TARGET" \
            || die "An unowned compatibility tool already exists at $TARGET"
        old=1
    fi
    cleanup_download() {
        local rc=$?
        [[ -z "${temporary:-}" ]] || rm -f "$temporary"
        return "$rc"
    }
    trap cleanup_download EXIT
    trap 'exit 130' INT TERM HUP
    if [[ -n "$supplied" ]]; then
        [[ -f "$supplied" && ! -L "$supplied" ]] \
            || die "Local Proton package is missing or unsafe: $supplied"
        archive=$supplied
    else
        temporary=$(mktemp "${TMPDIR:-/tmp}/bc250-proton.XXXXXX.pkg.tar.zst")
        archive=$temporary
        log "Downloading GE-Proton $PACKAGE_VERSION (about 731 MB)."
        curl --retry 3 --retry-all-errors -fL "$PACKAGE_URL" -o "$archive" \
            || die "Could not download $PACKAGE_URL"
    fi
    [[ "$(sha256_file "$archive")" == "$PACKAGE_SHA256" ]] \
        || die "GE-Proton package checksum mismatch."
    stage=$(mktemp -d "$COMPAT_ROOT/.bc250-proton-stage.XXXXXX")
    cleanup_install() {
        local rc=$?
        trap - EXIT INT TERM HUP
        [[ -z "${temporary:-}" ]] || rm -f "$temporary"
        if [[ $committed -eq 0 ]]; then
            recover_transaction || rc=1
        fi
        rm -rf "$stage" || rc=1
        exit "$rc"
    }
    trap cleanup_install EXIT
    trap 'exit 130' INT TERM HUP
    stage_package "$archive" "$stage"
    mkdir -m 0700 "$TRANSACTION_DIR"
    fsync_paths "$TRANSACTION_DIR" "$STATE_DIR"
    write_transaction_state prepared "$old"
    if [[ $old -eq 1 ]]; then
        mv "$TARGET" "$BACKUP"
        fsync_paths "$COMPAT_ROOT"
        write_transaction_state backed-up "$old"
    fi
    mv "$stage/candidate" "$TARGET"
    fsync_paths "$COMPAT_ROOT"
    verify_current_tool || die "Installed GE-Proton failed validation."
    write_transaction_state published "$old"
    committed=1
    if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
        rm -rf "$BACKUP"
        fsync_paths "$COMPAT_ROOT"
    fi
    rm -rf "$TRANSACTION_DIR" "$stage"
    fsync_paths "$STATE_DIR"
    [[ -z "${temporary:-}" ]] || rm -f "$temporary"
    trap - EXIT INT TERM HUP
    log "Installed GE-Proton $PACKAGE_VERSION at $TARGET"
    log "Restart Steam, then select 'GE-Proton 11-6 (BC-250 FSR4)' per game."
    log "Do not use FSR4 injection with anti-cheat games; use ordinary Proton or PROTON_FSR4_UPGRADE=0."
}

show_status() {
    if verify_current_tool; then
        log "state: installed"
        log "version: $MARKER_VERSION"
        log "path: $TARGET"
        return 0
    fi
    if verify_tool "$TARGET"; then
        log "state: upgrade-required"
        log "version: $MARKER_VERSION"
        return 2
    fi
    if [[ -e "$TARGET" || -L "$TARGET" || -e "$TRANSACTION_DIR" \
        || -L "$TRANSACTION_DIR" || -e "$BACKUP" || -L "$BACKUP" \
        || -e "$REMOVAL_TRANSACTION" || -L "$REMOVAL_TRANSACTION" \
        || -e "$REMOVAL_TARGET" || -L "$REMOVAL_TARGET" ]]; then
        log "state: incomplete"
        return 2
    fi
    log "state: not-installed"
    return 1
}

status_json() {
    local state=not-installed installed_version= rc=1
    if verify_current_tool; then
        state=ready; installed_version=$MARKER_VERSION; rc=0
    elif verify_tool "$TARGET"; then
        state=upgrade-required; installed_version=$MARKER_VERSION; rc=2
    elif [[ -e "$TARGET" || -L "$TARGET" || -e "$TRANSACTION_DIR" \
        || -L "$TRANSACTION_DIR" || -e "$BACKUP" || -L "$BACKUP" \
        || -e "$REMOVAL_TRANSACTION" || -L "$REMOVAL_TRANSACTION" \
        || -e "$REMOVAL_TARGET" || -L "$REMOVAL_TARGET" ]]; then
        state=invalid; rc=2
    fi
    python3 - "$state" "$installed_version" "$PACKAGE_VERSION" "$TARGET" <<'PY'
import json
import sys

state, installed, current, path = sys.argv[1:]
print(json.dumps({
    "schemaVersion": 1,
    "state": state,
    "installedVersion": installed or None,
    "currentVersion": current,
    "toolPath": path,
}, ensure_ascii=True, separators=(",", ":")))
PY
    return "$rc"
}

uninstall_tool() {
    require_normal_user
    ensure_paths
    exec 9> "$LOCK_FILE"
    flock 9
    recover_removal
    recover_transaction
    if [[ ! -e "$TARGET" && ! -L "$TARGET" ]]; then
        log "GE-Proton is not installed."
        return 0
    fi
    read_marker "$TARGET" \
        || die "GE-Proton is not a recorded toolkit install; refusing removal."
    mkdir -m 0700 "$REMOVAL_TRANSACTION"
    printf '%s %s\n' "$MARKER_VERSION" "$MARKER_PACKAGE_SHA" \
        > "$REMOVAL_TRANSACTION/state"
    chmod 0600 "$REMOVAL_TRANSACTION/state"
    fsync_paths "$REMOVAL_TRANSACTION/state" "$REMOVAL_TRANSACTION" "$STATE_DIR"
    mv "$TARGET" "$REMOVAL_TARGET"
    fsync_paths "$COMPAT_ROOT"
    rm -rf "$REMOVAL_TARGET"
    fsync_paths "$COMPAT_ROOT"
    rm -rf "$REMOVAL_TRANSACTION"
    fsync_paths "$STATE_DIR"
    log "Removed GE-Proton. Steam prefixes and game saves were preserved."
    log "Restart Steam to remove it from the compatibility-tool list."
}

usage() {
    cat <<EOF
Usage: $0 {install|update|status|status-json|uninstall|help}

Installs the checksum-pinned BC-250 GE-Proton $PACKAGE_VERSION build beneath
$COMPAT_ROOT. FSR4 RADV must already be active. No root filesystem
changes are made, and Steam prefixes and saves are never removed.
EOF
}

case "${1:-help}" in
    install|update) (($# == 1)) || die "Usage: $0 ${1}"
        install_tool ;;
    status) (($# == 1)) || exit 2; show_status ;;
    status-json) (($# == 1)) || exit 2; status_json ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; uninstall_tool ;;
    help|-h|--help) (($# == 1)) || exit 2; usage ;;
    *) usage >&2; exit 2 ;;
esac
