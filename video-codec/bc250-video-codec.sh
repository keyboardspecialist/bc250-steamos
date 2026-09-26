#!/usr/bin/env bash
# Install the pinned BC-250 VA-API compute codec in persistent SteamOS storage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE=v0.5.1
SOURCE_COMMIT=180aab87fa84b68f8d4a9d6bf8d4c1fb0cac940e
ARCHIVE_NAME=bc250-driver-linux-x86_64.tar.gz
ARCHIVE_SHA256=b38347ffa7bbc2d9365edcf83ac5b161516eb3625946abeaa1cb600aef2d2b05
ARCHIVE_URL="https://github.com/simpmix/bc250-encoding-decoding-fix/releases/download/$RELEASE/$ARCHIVE_NAME"
PAYLOAD_MANIFEST="$SCRIPT_DIR/$RELEASE.sha256"

DATA_DIR="${BC250_VIDEO_DATA_DIR:-/var/lib/bc250-control/video-codec}"
RUNTIME_DIR="$DATA_DIR/runtime"
ENV_FILE="${BC250_VIDEO_ENV_FILE:-/etc/environment.d/90-bc250-video-codec.conf}"
LOCK_FILE="${BC250_VIDEO_LOCK_FILE:-/run/lock/bc250-video-codec.lock}"
MANAGED_MARKER="bc250-toolkit-video-codec-v1"
ENV_MARKER="# BC-250 toolkit managed VA-API video codec"
STAGE=""

log() { echo "[bc250-video-codec] $*"; }
die() { log "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "$STAGE" && -d "$STAGE" && ! -L "$STAGE" ]]; then
        rm -rf -- "$STAGE"
    fi
}
trap cleanup EXIT

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this action with sudo."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

runtime_marker() {
    cat <<EOF
$MANAGED_MARKER
release=$RELEASE
source_commit=$SOURCE_COMMIT
EOF
}

environment_config() {
    cat <<EOF
$ENV_MARKER
LIBVA_DRIVER_NAME=bc250
LIBVA_DRIVERS_PATH=$RUNTIME_DIR/dri
BC250_SHADER_DIR=$RUNTIME_DIR/shaders
BC250_FAST_MODE=1
BC250_SLICES_PER_FRAME=4
BC250_HEVC_SLICES=4
OMP_WAIT_POLICY=PASSIVE
GOMP_SPINCOUNT=0
OMP_NUM_THREADS=2
OMP_DYNAMIC=FALSE
EOF
}

is_managed_runtime() {
    [[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" \
        && -f "$RUNTIME_DIR/.bc250-toolkit-managed" \
        && ! -L "$RUNTIME_DIR/.bc250-toolkit-managed" ]] \
        && grep -qxF "$MANAGED_MARKER" "$RUNTIME_DIR/.bc250-toolkit-managed"
}

is_managed_environment() {
    [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] \
        && IFS= read -r first_line < "$ENV_FILE" \
        && [[ "$first_line" == "$ENV_MARKER" ]]
}

runtime_valid() {
    is_managed_runtime || return 1
    diff -q <(runtime_marker) "$RUNTIME_DIR/.bc250-toolkit-managed" >/dev/null 2>&1 \
        || return 1
    [[ -f "$RUNTIME_DIR/manifest.sha256" && ! -L "$RUNTIME_DIR/manifest.sha256" ]] \
        || return 1
    cmp -s "$PAYLOAD_MANIFEST" "$RUNTIME_DIR/manifest.sha256" || return 1
    (cd "$RUNTIME_DIR" && sha256sum -c --quiet manifest.sha256) >/dev/null 2>&1 \
        || return 1
    [[ -x "$RUNTIME_DIR/dri/bc250_drv_video.so" ]] || return 1
    runtime_dependencies_valid "$RUNTIME_DIR/dri/bc250_drv_video.so" || return 1
}

runtime_dependencies_valid() {
    local output
    command -v ldd >/dev/null 2>&1 || return 1
    output=$(ldd "$1" 2>&1) || return 1
    [[ "$output" != *"not found"* ]]
}

environment_valid() {
    is_managed_environment || return 1
    diff -q <(environment_config) "$ENV_FILE" >/dev/null 2>&1
}

session_active() {
    [[ "${LIBVA_DRIVER_NAME:-}" == bc250 \
        && "${LIBVA_DRIVERS_PATH:-}" == "$RUNTIME_DIR/dri" \
        && "${BC250_SHADER_DIR:-}" == "$RUNTIME_DIR/shaders" ]]
}

show_status() {
    local runtime_present=0 environment_present=0
    [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]] && runtime_present=1
    [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]] && environment_present=1

    if [[ $runtime_present -eq 0 && $environment_present -eq 0 ]]; then
        echo "state: not-installed"
        echo "release: $RELEASE"
        echo "session: stock"
        return 1
    fi

    if runtime_valid && environment_valid; then
        echo "state: installed"
        echo "release: $RELEASE"
        echo "driver: verified"
        echo "shaders: 11 verified"
        echo "configuration: installed"
        if session_active; then
            echo "session: active"
        else
            echo "session: restart-required"
        fi
        return 0
    fi

    echo "state: incomplete"
    echo "release: $RELEASE"
    if runtime_valid; then echo "driver: verified"; else echo "driver: missing-or-invalid"; fi
    if environment_valid; then echo "configuration: installed"; else echo "configuration: missing-or-invalid"; fi
    echo "session: unavailable"
    return 2
}

detect_bc250() {
    local device vendor
    for vendor in /sys/bus/pci/devices/*/vendor; do
        [[ -r "$vendor" && "$(<"$vendor")" == 0x1002 ]] || continue
        device="${vendor%/vendor}/device"
        [[ -r "$device" && "$(<"$device")" == 0x13fe ]] && return 0
    done
    command -v lspci >/dev/null 2>&1 \
        && lspci -Dn 2>/dev/null | grep -Eqi '1002:13fe([[:space:]]|$)'
}

validate_elf64() {
    local class
    class=$(od -An -tu1 -j4 -N1 "$1" | tr -d '[:space:]')
    [[ "$class" == 2 ]] || die "The release driver is not a 64-bit ELF file."
}

extract_payload() {
    local archive="$1" destination="$2"
    python3 - "$archive" "$destination" <<'PY'
import pathlib
import shutil
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
shader_names = (
    "color_convert.comp.spv",
    "dct_transform.comp.spv",
    "deblock_filter.comp.spv",
    "entropy_encode.comp.spv",
    "intra_wavefront.comp.spv",
    "motion_estimation.comp.spv",
    "quantize.comp.spv",
    "reconstruct.comp.spv",
    "residual_predict.comp.spv",
    "video_proc.comp.spv",
    "video_proc10.comp.spv",
)
expected = {
    "bc250-driver/bc250_drv_video.so": "dri/bc250_drv_video.so",
    "bc250-driver/LICENSE": "LICENSE.upstream",
    "bc250-driver/README.md": "README.upstream.md",
}
expected.update({
    f"bc250-driver/shaders/{name}": f"shaders/{name}" for name in shader_names
})

with tarfile.open(archive, "r:gz") as bundle:
    members = {}
    for member in bundle.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe archive path: {member.name}")
        if not member.isdir() and not member.isreg():
            raise SystemExit(f"unsafe archive entry type: {member.name}")
        if member.name in members:
            raise SystemExit(f"duplicate archive entry: {member.name}")
        members[member.name] = member

    for source, relative in expected.items():
        member = members.get(source)
        if member is None or not member.isreg() or member.size > 64 * 1024 * 1024:
            raise SystemExit(f"missing or invalid release file: {source}")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        stream = bundle.extractfile(member)
        if stream is None:
            raise SystemExit(f"could not read release file: {source}")
        with stream, target.open("xb") as output:
            shutil.copyfileobj(stream, output)

(destination / "dri/bc250_drv_video.so").chmod(0o755)
for path in destination.rglob("*"):
    if path.is_file() and path.name != "bc250_drv_video.so":
        path.chmod(0o644)
PY
}

write_environment_atomically() {
    local environment_dir temporary
    environment_dir=$(dirname "$ENV_FILE")
    [[ ! -L "$environment_dir" ]] || die "Refusing symlinked environment directory: $environment_dir"
    install -d -m 0755 "$environment_dir"
    temporary=$(mktemp "$environment_dir/.bc250-video-codec.XXXXXX")
    environment_config > "$temporary"
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$ENV_FILE"
}

install_codec() {
    local archive actual parent dependency_status="" backup=""
    require_root
    for command in curl flock ldd od python3 sha256sum; do require_command "$command"; done
    [[ -f "$PAYLOAD_MANIFEST" && ! -L "$PAYLOAD_MANIFEST" ]] \
        || die "The pinned payload manifest is missing or unsafe."
    detect_bc250 || die "AMD BC-250 PCI device 1002:13fe was not detected."
    [[ "$DATA_DIR" == /* && "$DATA_DIR" != / ]] || die "The runtime path is invalid."
    [[ ! -L "$DATA_DIR" ]] || die "Refusing symlinked runtime directory: $DATA_DIR"
    if [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]]; then
        is_managed_runtime \
            || die "Refusing to replace an unrecognized runtime at $RUNTIME_DIR"
    fi
    if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
        is_managed_environment \
            || die "Refusing to replace an unrecognized environment file: $ENV_FILE"
    fi

    install -d -m 0755 "$DATA_DIR"
    install -d -m 0755 "$(dirname "$LOCK_FILE")"
    exec 9> "$LOCK_FILE"
    flock 9

    parent=$(dirname "$DATA_DIR")
    STAGE=$(mktemp -d "$parent/.bc250-video-codec.XXXXXX")
    archive="$STAGE/$ARCHIVE_NAME"
    log "Downloading verified upstream release $RELEASE..."
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --output "$archive" "$ARCHIVE_URL"
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [[ "$actual" == "$ARCHIVE_SHA256" ]] \
        || die "Release archive checksum mismatch."

    mkdir "$STAGE/runtime"
    extract_payload "$archive" "$STAGE/runtime"
    install -m 0644 "$PAYLOAD_MANIFEST" "$STAGE/runtime/manifest.sha256"
    runtime_marker > "$STAGE/runtime/.bc250-toolkit-managed"
    chmod 0644 "$STAGE/runtime/.bc250-toolkit-managed"
    (cd "$STAGE/runtime" && sha256sum -c --quiet manifest.sha256) \
        || die "Extracted release files failed verification."
    validate_elf64 "$STAGE/runtime/dri/bc250_drv_video.so"
    if ! dependency_status=$(ldd "$STAGE/runtime/dri/bc250_drv_video.so" 2>&1) \
        || [[ "$dependency_status" == *"not found"* ]]; then
        printf '%s\n' "$dependency_status" >&2
        die "The upstream release has unavailable runtime dependencies. No driver was activated."
    fi
    chmod 0755 "$STAGE/runtime" "$STAGE/runtime/dri" "$STAGE/runtime/shaders"

    if [[ -d "$RUNTIME_DIR" ]]; then
        backup="$DATA_DIR/.runtime.previous.$$"
        mv -- "$RUNTIME_DIR" "$backup"
    fi
    mv -- "$STAGE/runtime" "$RUNTIME_DIR"
    if ! write_environment_atomically; then
        rm -rf -- "$RUNTIME_DIR"
        [[ -z "$backup" ]] || mv -- "$backup" "$RUNTIME_DIR"
        die "Could not install the managed environment configuration."
    fi
    if ! runtime_valid || ! environment_valid; then
        rm -rf -- "$RUNTIME_DIR"
        [[ -z "$backup" ]] || mv -- "$backup" "$RUNTIME_DIR"
        die "The installed runtime failed final verification."
    fi
    [[ -z "$backup" ]] || rm -rf -- "$backup"
    log "Installed BC-250 VA-API video codec $RELEASE."
    log "Sign out or reboot before using the new VA-API selection."
}

uninstall_codec() {
    require_root
    require_command flock
    install -d -m 0755 "$(dirname "$LOCK_FILE")"
    exec 9> "$LOCK_FILE"
    flock 9

    if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
        is_managed_environment \
            || die "Refusing to remove an unrecognized environment file: $ENV_FILE"
        rm -f -- "$ENV_FILE"
    fi
    if [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]]; then
        [[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" \
            && -f "$RUNTIME_DIR/.bc250-toolkit-managed" \
            && ! -L "$RUNTIME_DIR/.bc250-toolkit-managed" ]] \
            || die "Refusing to remove an unrecognized runtime at $RUNTIME_DIR"
        grep -qxF "$MANAGED_MARKER" "$RUNTIME_DIR/.bc250-toolkit-managed" \
            || die "Refusing to remove an unrecognized runtime at $RUNTIME_DIR"
        rm -rf -- "$RUNTIME_DIR"
    fi
    rmdir "$DATA_DIR" 2>/dev/null || true
    log "Removed the BC-250 VA-API video codec."
    log "Sign out or reboot to restore the stock VA-API selection."
}

usage() {
    cat <<EOF
Usage: $0 {install|status|uninstall}

  install    Download, verify, and install upstream $RELEASE
  status     Verify the runtime, environment, and current session
  uninstall  Remove only toolkit-managed codec files
EOF
}

case "${1:-help}" in
    install) (($# == 1)) || die "Usage: $0 install"; install_codec ;;
    status) (($# == 1)) || die "Usage: $0 status"; show_status ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; uninstall_codec ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 1 ;;
esac
