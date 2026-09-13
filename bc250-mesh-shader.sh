#!/usr/bin/env bash
# Build and manage DryhoppedIPA's alternate GFX1013 Mesa/RADV ICD.
# Its compute queues require the matching kernel repair from bc250-audio-fix.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
UPSTREAM_REPO="https://github.com/DryhoppedIPA/bc250-gfx1013-fix"
UPSTREAM_COMMIT="d3e6dc062c34d2523db0abe5741d1f5b0dea00d9"
LEGACY_UPSTREAM_COMMIT="b66203e012594204e5e3049856b28a2681112985"
RADV_PROFILE_REVISION="production-fsr4-v4"
RAW_BASE="https://raw.githubusercontent.com/DryhoppedIPA/bc250-gfx1013-fix/$UPSTREAM_COMMIT"
FSR4_RADV_REPO="https://github.com/MastaG/linux-cachyos-bc250"
FSR4_RADV_COMMIT="db49878af40551b481f511053201fcf1e1bd5d90"
FSR4_RADV_BASE="https://raw.githubusercontent.com/MastaG/linux-cachyos-bc250/$FSR4_RADV_COMMIT/patches/mesa"
DEFAULT_MESA_TAG="mesa-26.2.2"
MESA_COMMIT="3281a69a8bfd9f997e91c15ed0e6290cae12dd32"
MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
LIBDRM_TARBALL="libdrm-2.4.133.tar.xz"
LIBDRM_URL="https://dri.freedesktop.org/libdrm/$LIBDRM_TARBALL"
LIBDRM_SHA256="fc68f9d0ba2ea63c9432a299e14fea09fad7a8a66e8039fcd7802ca59f77b4f5"

STATE_DIR="${BC250_MESH_STATE_DIR:-$HOME/.local/share/bc250-mesh-shader}"
CACHE_DIR="$STATE_DIR/upstream-$UPSTREAM_COMMIT"
MESA_GIT_CACHE="$CACHE_DIR/mesa.git"
MANIFEST="$STATE_DIR/install.conf"
TRANSACTION_DIR="$STATE_DIR/install-transaction"
DRIRC="${BC250_MESH_DRIRC:-$HOME/.drirc}"
DRIVER="${BC250_MESH_DRIVER:-/usr/lib/libvulkan_radeon_driconf.so}"
ICD="${BC250_MESH_ICD:-$HOME/radeon_driconf_icd.x86_64.json}"
FALLBACK_ICD="${BC250_MESH_32BIT_ICD:-/usr/share/vulkan/icd.d/radeon_icd.i686.json}"
GLOBAL_ICDS="$ICD:$FALLBACK_ICD"
GENERATOR="${BC250_GFX1013_GENERATOR:-/usr/lib/systemd/user-environment-generators/60-bc250-gfx1013}"
BUILD_ROOT="$STATE_DIR/build"
MESA_SOURCE="$BUILD_ROOT/$DEFAULT_MESA_TAG"
MESA_BUILD="$MESA_SOURCE/build"
MESA_OUTPUT="$MESA_BUILD/src/amd/vulkan/libvulkan_radeon.so"
MESA_NINJA="$MESA_BUILD/build.ninja"
MESA_COREDATA="$MESA_BUILD/meson-private/coredata.dat"
BUILD_STATE="$BUILD_ROOT/$DEFAULT_MESA_TAG.profile"
FSR4_DIR="$STATE_DIR/fsr4"
FSR4_DRIVER="$FSR4_DIR/libvulkan_radeon.so"
FSR4_ICD="$FSR4_DIR/radeon_fsr4_icd.x86_64.json"
FSR4_RUNNER="$FSR4_DIR/bc250-fsr4-run"
FSR4_MANIFEST="$FSR4_DIR/install.conf"
FSR4_TRANSACTION_DIR="$STATE_DIR/fsr4-install-transaction"
FSR4_UPSTREAM_COMMIT="741ff3e369026f34820c41a846cf5e55d08e2a61"
FSR4_PATCH_NAME="bc250-fsr4-v3.patch"
FSR4_PATCH_URL="https://raw.githubusercontent.com/dmorazasanchez/bc250-fsr4/$FSR4_UPSTREAM_COMMIT/$FSR4_PATCH_NAME"
FSR4_PATCH="$CACHE_DIR/$FSR4_PATCH_NAME"
FSR4_PATCH_SHA256="7fde37fad572b4ba4dcac6052792d10d8d3df65982b01236c63a3eff0a25d225"
FSR4_PROFILE_SHA256="835842eb8beccd6e0498a771c5ea4d8c9ac86ee994e4659045e9f3bf4321404d"
FSR4_DLL_TOOL="${BC250_FSR4_TOOL:-${SELF%/*}/bc250-fsr4.sh}"
FSR4_DLL_STATE="${BC250_FSR4_STATE_DIR:-$STATE_DIR/fsr4-dll}"
FSR4_DLL_LOCK="${BC250_FSR4_LOCK_FILE:-$HOME/.cache/bc250-fsr4.lock}"
LOCK_FILE="${BC250_MESH_LOCK_FILE:-$HOME/.cache/bc250-mesh-shader.lock}"
MODULE_UPDATES="/usr/lib/modules/$(uname -r)/updates"
DEFAULT_COMPUTE_MODULE="$MODULE_UPDATES/amdgpu.ko.zst"
DEFAULT_COMPUTE_MARKER="$MODULE_UPDATES/.bc250-gfx1013-fix"
DEFAULT_AUDIO_MARKER="$MODULE_UPDATES/.bc250-audio-fix"
DEFAULT_METRICS_MARKER="$MODULE_UPDATES/.bc250-metrics-fix"
DEFAULT_COMPUTE_ACTIVE="/sys/module/amdgpu/parameters/bc250_gfx1013_fix"
DEFAULT_SCHED_POLICY="/sys/module/amdgpu/parameters/sched_policy"
DEFAULT_BOOT_CONFIG="${SELF%/*}/bc250-audio-fix/boot-config.sh"
DEFAULT_AMDGPU_INSTALLER="${SELF%/*}/bc250-audio-fix/patch-driver.sh"
COMPUTE_MODULE="${BC250_GFX1013_MODULE:-$DEFAULT_COMPUTE_MODULE}"
COMPUTE_MARKER="${BC250_GFX1013_MARKER:-$DEFAULT_COMPUTE_MARKER}"
AUDIO_MARKER="${BC250_AUDIO_MARKER:-$DEFAULT_AUDIO_MARKER}"
METRICS_MARKER="${BC250_METRICS_MARKER:-$DEFAULT_METRICS_MARKER}"
COMPUTE_ACTIVE="${BC250_GFX1013_ACTIVE:-$DEFAULT_COMPUTE_ACTIVE}"
SCHED_POLICY="${BC250_SCHED_POLICY_PARAM:-$DEFAULT_SCHED_POLICY}"
BOOT_CONFIG="${BC250_AMDGPU_BOOT_CONFIG:-$DEFAULT_BOOT_CONFIG}"
AMDGPU_INSTALLER="${BC250_AMDGPU_INSTALLER:-$DEFAULT_AMDGPU_INSTALLER}"

C0=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'; CI=$'\033[7m'
CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'; CC=$'\033[36m'
TUI_CURSOR_HIDDEN=0

log() { echo "[bc250-mesh] $*"; }
die() { echo "[bc250-mesh] $*" >&2; exit 1; }

tui_show_cursor() {
    if [[ $TUI_CURSOR_HIDDEN -eq 1 ]]; then
        printf '\033[?25h'
        TUI_CURSOR_HIDDEN=0
    fi
}
trap tui_show_cursor EXIT

shell_word() {
    python3 - "$1" <<'PY'
import sys
print("'" + sys.argv[1].replace("'", "'\"'\"'") + "'")
PY
}

require_normal_user() {
    [[ $EUID -ne 0 ]] || die "Run as the logged-in user, not with sudo. Setup requests sudo when needed."
}

ensure_state_dir() {
    [[ ! -L "$STATE_DIR" ]] || die "Refusing symlinked state directory: $STATE_DIR"
    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"
    mkdir -p "${LOCK_FILE%/*}"
    [[ ! -L "$LOCK_FILE" ]] || die "Refusing symlinked lock file: $LOCK_FILE"
}

as_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || die "sudo is required for $DRIVER"
        sudo "$@"
    fi
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

mesa_source_diff_sha() {
    git -C "$MESA_SOURCE" diff HEAD --binary --full-index --no-ext-diff | sha256_stream
}

mesa_source_tree_sha() {
    python3 - "$MESA_SOURCE" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

base = Path(sys.argv[1]).resolve()
digest = hashlib.sha256()
for root, directories, files in os.walk(base, topdown=True, followlinks=False):
    relative_root = Path(root).relative_to(base)
    if relative_root == Path("."):
        directories[:] = [name for name in directories if name not in (".git", "build")]
    directories.sort()
    files.sort()
    entries = [(name, True) for name in directories] + [(name, False) for name in files]
    for name, is_directory in sorted(entries):
        path = Path(root) / name
        relative = os.fsencode(str(path.relative_to(base)))
        metadata = path.lstat()
        digest.update(len(relative).to_bytes(8, "little"))
        digest.update(relative)
        digest.update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "little"))
        if path.is_symlink():
            target = os.fsencode(os.readlink(path))
            resolved = path.resolve(strict=True)
            try:
                resolved.relative_to(base)
            except ValueError:
                raise SystemExit("external symlink in Mesa source cache: %s" % path)
            digest.update(b"L" + len(target).to_bytes(8, "little") + target)
            if is_directory:
                directories.remove(name)
        elif path.is_dir():
            digest.update(b"D")
        elif path.is_file():
            digest.update(b"F" + metadata.st_size.to_bytes(8, "little"))
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
        else:
            raise SystemExit("unsupported file in Mesa source cache: %s" % path)
print(digest.hexdigest())
PY
}

mesa_build_tree_sha() {
    python3 - "$MESA_BUILD" "$MESA_SOURCE" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

base = Path(sys.argv[1]).resolve()
source = Path(sys.argv[2]).resolve()
digest = hashlib.sha256()
for root, directories, files in os.walk(base, topdown=True, followlinks=False):
    directories.sort()
    files.sort()
    entries = [(name, True) for name in directories] + [(name, False) for name in files]
    for name, is_directory in sorted(entries):
        path = Path(root) / name
        relative = os.fsencode(str(path.relative_to(base)))
        metadata = path.lstat()
        digest.update(len(relative).to_bytes(8, "little"))
        digest.update(relative)
        digest.update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "little"))
        if path.is_symlink():
            target = os.fsencode(os.readlink(path))
            resolved = path.resolve(strict=True)
            if not any(
                resolved == allowed or allowed in resolved.parents
                for allowed in (base, source)
            ):
                raise SystemExit("external symlink in Mesa build cache: %s" % path)
            digest.update(b"L" + len(target).to_bytes(8, "little") + target)
            if is_directory:
                directories.remove(name)
        elif path.is_dir():
            digest.update(b"D")
        elif path.is_file():
            digest.update(b"F" + metadata.st_size.to_bytes(8, "little"))
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
        else:
            raise SystemExit("unsupported file in Mesa build cache: %s" % path)
print(digest.hexdigest())
PY
}

read_build_state() {
    local extra line
    BUILD_STATE_PROFILE="" BUILD_STATE_DRIVER_SHA="" BUILD_STATE_SOURCE_SHA=""
    BUILD_STATE_SOURCE_TREE_SHA="" BUILD_STATE_TREE_SHA="" BUILD_STATE_NINJA_SHA=""
    BUILD_STATE_COREDATA_SHA="" BUILD_STATE_MESA_COMMIT=""
    BUILD_STATE_UPSTREAM_COMMIT="" BUILD_STATE_FSR4_SHA="" BUILD_STATE_PROFILE_REVISION=""
    [[ -f "$BUILD_STATE" && ! -L "$BUILD_STATE" ]] || return 1
    IFS= read -r line < "$BUILD_STATE" || return 1
    read -r BUILD_STATE_PROFILE BUILD_STATE_DRIVER_SHA BUILD_STATE_SOURCE_SHA \
        BUILD_STATE_SOURCE_TREE_SHA BUILD_STATE_TREE_SHA BUILD_STATE_NINJA_SHA \
        BUILD_STATE_COREDATA_SHA BUILD_STATE_MESA_COMMIT BUILD_STATE_UPSTREAM_COMMIT \
        BUILD_STATE_FSR4_SHA BUILD_STATE_PROFILE_REVISION extra <<< "$line"
    [[ -z "$extra" && ( "$BUILD_STATE_PROFILE" == base || "$BUILD_STATE_PROFILE" == fsr4 ) \
        && "$BUILD_STATE_DRIVER_SHA" =~ ^[0-9a-f]{64}$ \
        && "$BUILD_STATE_SOURCE_SHA" =~ ^[0-9a-f]{64}$ \
        && "$BUILD_STATE_SOURCE_TREE_SHA" =~ ^[0-9a-f]{64}$ \
        && "$BUILD_STATE_TREE_SHA" =~ ^[0-9a-f]{64}$ \
        && "$BUILD_STATE_NINJA_SHA" =~ ^[0-9a-f]{64}$ \
        && "$BUILD_STATE_COREDATA_SHA" =~ ^[0-9a-f]{64}$ \
        && "$BUILD_STATE_MESA_COMMIT" == "$MESA_COMMIT" \
        && "$BUILD_STATE_UPSTREAM_COMMIT" == "$UPSTREAM_COMMIT" \
        && "$BUILD_STATE_PROFILE_REVISION" == "$RADV_PROFILE_REVISION" \
        && "$(wc -l < "$BUILD_STATE")" -eq 1 ]] || return 1
    if [[ "$BUILD_STATE_PROFILE" == base ]]; then
        [[ "$BUILD_STATE_FSR4_SHA" == - ]]
    else
        [[ "$BUILD_STATE_FSR4_SHA" == "$FSR4_PATCH_SHA256" ]]
    fi
}

verify_cached_build() {
    local expected_profile="$1" expected_driver_sha="${2:-}" actual
    read_build_state || return 1
    [[ "$BUILD_STATE_PROFILE" == "$expected_profile" \
        && -d "$MESA_SOURCE/.git" && ! -L "$MESA_SOURCE" \
        && -d "$MESA_BUILD" && ! -L "$MESA_BUILD" \
        && -f "$MESA_OUTPUT" && ! -L "$MESA_OUTPUT" \
        && -f "$MESA_NINJA" && ! -L "$MESA_NINJA" \
        && -f "$MESA_COREDATA" && ! -L "$MESA_COREDATA" \
        && "$(git -C "$MESA_SOURCE" rev-parse HEAD 2>/dev/null)" == "$MESA_COMMIT" ]] \
        || return 1
    [[ -z "$(git -C "$MESA_SOURCE" ls-files --others --exclude-standard)" ]] || return 1
    actual=$(sha256_file "$MESA_OUTPUT")
    [[ "$actual" == "$BUILD_STATE_DRIVER_SHA" \
        && "$(mesa_source_diff_sha)" == "$BUILD_STATE_SOURCE_SHA" \
        && "$(mesa_source_tree_sha)" == "$BUILD_STATE_SOURCE_TREE_SHA" \
        && "$(mesa_build_tree_sha)" == "$BUILD_STATE_TREE_SHA" \
        && "$(sha256_file "$MESA_NINJA")" == "$BUILD_STATE_NINJA_SHA" \
        && "$(sha256_file "$MESA_COREDATA")" == "$BUILD_STATE_COREDATA_SHA" ]] \
        || return 1
    [[ -z "$expected_driver_sha" || "$actual" == "$expected_driver_sha" ]]
}

write_build_state() {
    local profile="$1" driver_sha source_sha source_tree_sha tree_sha
    local ninja_sha coredata_sha fsr4_sha=- tmp
    [[ "$profile" == base || "$profile" == fsr4 ]] || die "Invalid Mesa build profile: $profile"
    driver_sha=$(sha256_file "$MESA_OUTPUT")
    source_sha=$(mesa_source_diff_sha)
    source_tree_sha=$(mesa_source_tree_sha)
    tree_sha=$(mesa_build_tree_sha)
    ninja_sha=$(sha256_file "$MESA_NINJA")
    coredata_sha=$(sha256_file "$MESA_COREDATA")
    if [[ "$profile" == fsr4 ]]; then fsr4_sha=$FSR4_PATCH_SHA256; fi
    tmp=$(mktemp "$BUILD_ROOT/.profile.XXXXXX")
    printf '%s %s %s %s %s %s %s %s %s %s %s\n' "$profile" "$driver_sha" \
        "$source_sha" "$source_tree_sha" "$tree_sha" "$ninja_sha" \
        "$coredata_sha" "$MESA_COMMIT" "$UPSTREAM_COMMIT" "$fsr4_sha" \
        "$RADV_PROFILE_REVISION" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$BUILD_STATE"
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

fetch_verified() {
    local name="$1" expected="$2" url="${3:-$RAW_BASE/$1}" target="$CACHE_DIR/$1" actual tmp
    if [[ -f "$target" && ! -L "$target" ]] \
        && [[ "$(sha256_file "$target")" == "$expected" ]]; then
        return 0
    fi
    [[ ! -L "$CACHE_DIR" ]] || die "Refusing symlinked upstream cache: $CACHE_DIR"
    mkdir -p "$CACHE_DIR"
    tmp=$(mktemp "$CACHE_DIR/.${name}.XXXXXX")
    curl --retry 3 --retry-all-errors -fsSL "$url" -o "$tmp" \
        || { rm -f "$tmp"; die "Could not fetch $url"; }
    actual=$(sha256_file "$tmp")
    [[ "$actual" == "$expected" ]] \
        || { rm -f "$tmp"; die "Checksum mismatch for upstream $name"; }
    chmod 0644 "$tmp"
    mv -f "$tmp" "$target"
}

stage_upstream() {
    local profile="${1:-default}"
    fetch_verified upstream-MIT-LICENSE \
        ddf5d9be5c762bcc5237e36235a1c5f00be521cfc92d8c264dfcce392e2c1313 \
        "$RAW_BASE/LICENSE"
    fetch_verified GPL-2.0-only.txt \
        8780e78a1a737e127f25a65f6d95269bffd36158dc261114de7859b490bfc5aa \
        "$RAW_BASE/LICENSES/GPL-2.0-only.txt"
    fetch_verified upstream-NOTICE.md \
        ccf962b0b8aca2b9a67a2e2081d4edf6a66f8403fdf66a54d08a1ef10367f3eb \
        "$RAW_BASE/NOTICE.md"
    fetch_verified 0001-gfx1013-compute-queue-fix.patch \
        b30db62d989977e0cf7c99813f029ade75da128623966616330b0dacc98a5788 \
        "$FSR4_RADV_BASE/0001-gfx1013-compute-queue-fix.patch"
    fetch_verified 0005-bc250-fsr4-v3.patch \
        43202e01e3a3cad51c9d879b49a56ef8b06232daf6f30e2d196e13df634bb502 \
        "$FSR4_RADV_BASE/0005-bc250-fsr4-v3.patch"
    fetch_verified 0006-bc250-fsr4-combined-unroll.patch \
        b19281863aa2b8465649d370a39bf436d65ae6f06c51fb8f79228d0277d848ec \
        "$FSR4_RADV_BASE/0006-bc250-fsr4-combined-unroll.patch"
    fetch_verified 0007-bc250-fsr4-imageprep-texture.patch \
        004644a2704e69b1083cf26c8d250f860eb9595573188343137615afdcc31c93 \
        "$FSR4_RADV_BASE/0007-bc250-fsr4-imageprep-texture.patch"
    fetch_verified 0008-bc250-fsr4-resolution-variants.patch \
        517cf1be2d9e69031793121d9b80a1d968411cc06b982a3155de927690aa1d42 \
        "$FSR4_RADV_BASE/0008-bc250-fsr4-resolution-variants.patch"
    fetch_verified 0009-bc250-fsr4-production-defaults.patch \
        f0a38daa798f681b44ba07f6222ff3338726f64b78d4a33b3c04c9e424025496 \
        "$FSR4_RADV_BASE/0009-bc250-fsr4-production-defaults.patch"
    if [[ "$profile" == fsr4 ]]; then
        fetch_verified "$FSR4_PATCH_NAME" "$FSR4_PATCH_SHA256" "$FSR4_PATCH_URL"
    fi
    fetch_verified "$LIBDRM_TARBALL" "$LIBDRM_SHA256" "$LIBDRM_URL"
    [[ ! -L "$MESA_GIT_CACHE" ]] || die "Refusing symlinked Mesa Git cache: $MESA_GIT_CACHE"
    if [[ ! -d "$MESA_GIT_CACHE" ]]; then
        git init --bare "$MESA_GIT_CACHE" >/dev/null
        git --git-dir="$MESA_GIT_CACHE" remote add origin "$MESA_REPO"
    fi
    [[ "$(git --git-dir="$MESA_GIT_CACHE" remote get-url origin)" == "$MESA_REPO" ]] \
        || die "Mesa Git cache has an unexpected origin"
    if [[ "$(git --git-dir="$MESA_GIT_CACHE" rev-parse --verify \
        refs/heads/bc250-pinned-mesa 2>/dev/null || true)" != "$MESA_COMMIT" ]]; then
        git --git-dir="$MESA_GIT_CACHE" fetch --depth=1 origin \
            "+$MESA_COMMIT:refs/heads/bc250-pinned-mesa"
    fi
    [[ "$(git --git-dir="$MESA_GIT_CACHE" rev-parse "$MESA_COMMIT")" == "$MESA_COMMIT" ]] \
        || die "Fetched Mesa source does not match pinned commit $MESA_COMMIT"
}

verify_fsr4_patch() {
    [[ -f "$FSR4_PATCH" && ! -L "$FSR4_PATCH" ]] \
        && [[ "$(sha256_file "$FSR4_PATCH")" == "$FSR4_PATCH_SHA256" ]]
}

verify_compute_kernel() {
    local expected actual active marker resolved owner mode
    [[ -f "$COMPUTE_MODULE" && ! -L "$COMPUTE_MODULE" ]] || return 1
    actual=$(sha256_file "$COMPUTE_MODULE")
    for marker in "$COMPUTE_MARKER" "$AUDIO_MARKER" "$METRICS_MARKER"; do
        [[ -f "$marker" && ! -L "$marker" ]] || return 1
        read -r expected < "$marker" || return 1
        [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] || return 1
    done
    read -r expected < "$COMPUTE_MARKER" || return 1
    [[ -r "$COMPUTE_ACTIVE" && ! -L "$COMPUTE_ACTIVE" ]] || return 1
    active=$(<"$COMPUTE_ACTIVE")
    [[ "$active" == "$UPSTREAM_COMMIT" ]] || return 1
    if [[ "$COMPUTE_MODULE" == "$DEFAULT_COMPUTE_MODULE" \
        && "$COMPUTE_MARKER" == "$DEFAULT_COMPUTE_MARKER" \
        && "$AUDIO_MARKER" == "$DEFAULT_AUDIO_MARKER" \
        && "$METRICS_MARKER" == "$DEFAULT_METRICS_MARKER" \
        && "$COMPUTE_ACTIVE" == "$DEFAULT_COMPUTE_ACTIVE" ]]; then
        command -v modinfo >/dev/null 2>&1 || return 1
        resolved=$(modinfo -k "$(uname -r)" -F filename amdgpu 2>/dev/null) || return 1
        [[ "$(readlink -f "$resolved")" == "$(readlink -f "$COMPUTE_MODULE")" ]] || return 1
        for marker in "$COMPUTE_MODULE" "$COMPUTE_MARKER" "$AUDIO_MARKER" "$METRICS_MARKER"; do
            owner=$(stat -c %u "$marker") || return 1
            mode=$(stat -c %a "$marker") || return 1
            [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ ]] || return 1
            (( (8#$mode & 8#022) == 0 )) || return 1
        done
    fi
}

verify_scheduler_active() {
    local value
    [[ -r "$SCHED_POLICY" && ! -L "$SCHED_POLICY" ]] || return 1
    read -r value < "$SCHED_POLICY" || return 1
    [[ "$value" == 2 ]]
}

verify_scheduler_configured() {
    [[ -f "$BOOT_CONFIG" && ! -L "$BOOT_CONFIG" ]] \
        && bash "$BOOT_CONFIG" configured >/dev/null 2>&1
}

require_production_kernel_paths() {
    [[ "$COMPUTE_MODULE" == "$DEFAULT_COMPUTE_MODULE" \
        && "$COMPUTE_MARKER" == "$DEFAULT_COMPUTE_MARKER" \
        && "$AUDIO_MARKER" == "$DEFAULT_AUDIO_MARKER" \
        && "$METRICS_MARKER" == "$DEFAULT_METRICS_MARKER" \
        && "$COMPUTE_ACTIVE" == "$DEFAULT_COMPUTE_ACTIVE" \
        && "$SCHED_POLICY" == "$DEFAULT_SCHED_POLICY" \
        && "$BOOT_CONFIG" == "$DEFAULT_BOOT_CONFIG" \
        && "$AMDGPU_INSTALLER" == "$DEFAULT_AMDGPU_INSTALLER" ]] \
        || die "RADV setup refuses overridden AMDGPU safety-check paths."
}

require_compute_kernel() {
    verify_compute_kernel || die "The patched AMDGPU module is not installed, selected, and active for this kernel. Run bc250-audio-fix/patch-driver.sh, reboot, and retry."
}

json_string_field() {
    local json="$1" key="$2" tail
    tail=${json#*\"$key\":\"}
    [[ "$tail" != "$json" ]] || return 1
    printf '%s' "${tail%%\"*}"
}

ensure_compute_kernel_prerequisite() {
    local status state
    verify_compute_kernel && return 0
    [[ -f "$AMDGPU_INSTALLER" && ! -L "$AMDGPU_INSTALLER" ]] \
        || die "AMDGPU prerequisite installer is missing or unsafe: $AMDGPU_INSTALLER"
    status=$(bash "$AMDGPU_INSTALLER" status-json 2>/dev/null) \
        || die "Could not determine current-kernel AMDGPU state."
    state=$(json_string_field "$status" state || true)
    case "$state" in
        not-installed)
            log "Installing the required AMDGPU kernel fixes first."
            bash "$AMDGPU_INSTALLER"
            status=$(bash "$AMDGPU_INSTALLER" status-json 2>/dev/null) \
                || die "AMDGPU installation completed, but its state could not be verified."
            state=$(json_string_field "$status" state || true)
            ;;
        reboot-required) ;;
        invalid) die "Current-kernel AMDGPU state is incomplete or unsafe. Review '$AMDGPU_INSTALLER status' before continuing." ;;
        *) die "Unknown current-kernel AMDGPU state: ${state:-unavailable}" ;;
    esac
    if [[ "$state" == reboot-required ]]; then
        log "CHECKPOINT: Reboot to activate the AMDGPU kernel fixes, then select this same option again."
        return 1
    fi
    verify_compute_kernel \
        || die "AMDGPU installation did not reach a safe reboot or active state."
}

install_signed_steamos_packages() (
    local ro_was_enabled=0
    restore_readonly() {
        local rc=${1:-$?}
        trap - EXIT INT TERM HUP
        if [[ $ro_was_enabled -eq 1 ]]; then
            as_root steamos-readonly enable || rc=1
        fi
        exit "$rc"
    }
    trap restore_readonly EXIT
    trap 'restore_readonly 130' INT
    trap 'restore_readonly 143' TERM
    trap 'restore_readonly 129' HUP
    command -v steamos-readonly >/dev/null 2>&1 \
        || die "SteamOS package prerequisites are missing."
    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        ro_was_enabled=1
        as_root steamos-readonly disable
    fi
    as_root pacman-key --init
    as_root pacman-key --populate archlinux holo 2>/dev/null \
        || as_root pacman-key --populate
    as_root pacman -S --noconfirm "$@"
    if [[ $ro_was_enabled -eq 1 ]]; then
        as_root steamos-readonly enable
        ro_was_enabled=0
    fi
)

ensure_radv_core_tools() {
    local packages=()
    command -v python3 >/dev/null 2>&1 || packages+=(python)
    command -v flock >/dev/null 2>&1 || packages+=(util-linux)
    if ((${#packages[@]})); then
        log "Installing signed SteamOS tools required for locked RADV recovery."
        install_signed_steamos_packages "${packages[@]}"
    fi
    command -v python3 >/dev/null 2>&1 \
        || die "Signed SteamOS packages did not provide required tool: python3"
    command -v flock >/dev/null 2>&1 \
        || die "Signed SteamOS packages did not provide required tool: flock"
}

ensure_radv_prerequisites() {
    local packages=()
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    if ! verify_32bit_fallback; then
        packages+=(lib32-vulkan-radeon)
    fi
    if ((${#packages[@]})); then
        log "Installing signed SteamOS RADV prerequisites."
        install_signed_steamos_packages "${packages[@]}"
    fi
    command -v curl >/dev/null 2>&1 \
        || die "Signed SteamOS packages did not provide required tool: curl"
    verify_32bit_fallback \
        || die "Signed SteamOS package lib32-vulkan-radeon did not provide a valid 32-bit RADV ICD."
}

manager_environment_active() {
    local environment
    verify_compute_kernel && verify_scheduler_active && verify_current_runtime || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    environment=$(systemctl --user show-environment 2>/dev/null) || return 1
    grep -qxF "VK_DRIVER_FILES=$GLOBAL_ICDS" <<< "$environment" \
        && grep -qxF "VK_ICD_FILENAMES=$GLOBAL_ICDS" <<< "$environment"
}

verify_32bit_fallback() {
    [[ -f "$FALLBACK_ICD" && ! -L "$FALLBACK_ICD" ]] || return 1
    python3 - "$FALLBACK_ICD" <<'PY'
import json
from pathlib import Path
import struct
import sys

manifest = Path(sys.argv[1])
try:
    data = json.loads(manifest.read_text(encoding="utf-8"))
    icd = data["ICD"]
    library = Path(icd["library_path"])
    if not library.is_absolute():
        library = manifest.parent / library
    valid = (
        data.get("file_format_version") == "1.0.1"
        and icd.get("library_arch") == "32"
        and library.is_file()
        and not library.is_symlink()
    )
    if valid:
        content = library.read_bytes()
        valid = len(content) >= 52 and content[:7] == b"\x7fELF\x01\x01\x01"
    if valid:
        e_type, e_machine, e_version = struct.unpack_from("<HHI", content, 16)
        e_phoff = struct.unpack_from("<I", content, 28)[0]
        e_ehsize, e_phentsize, e_phnum = struct.unpack_from("<HHH", content, 40)
        valid = (
            e_type == 3 and e_machine == 3 and e_version == 1
            and e_ehsize >= 52 and e_phentsize >= 32 and e_phnum > 0
            and e_phoff + e_phentsize * e_phnum <= len(content)
        )
    if valid:
        types = {
            struct.unpack_from("<I", content, e_phoff + index * e_phentsize)[0]
            for index in range(e_phnum)
        }
        valid = 1 in types and 2 in types
except (KeyError, OSError, struct.error, TypeError, ValueError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
}

read_manifest() {
    local extra line
    STORED_DRIVER_SHA="" STORED_ICD_SHA="" STORED_MESA_TAG="" STORED_COMMIT=""
    STORED_PROFILE_REVISION=""
    [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || return 1
    IFS= read -r line < "$MANIFEST" || return 1
    read -r STORED_DRIVER_SHA STORED_ICD_SHA STORED_MESA_TAG STORED_COMMIT \
        STORED_PROFILE_REVISION extra <<< "$line"
    [[ -z "$extra" && "$STORED_DRIVER_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_ICD_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_MESA_TAG" =~ ^mesa-[0-9][0-9A-Za-z._-]*$ \
        && ( "$STORED_COMMIT" == "$UPSTREAM_COMMIT" \
            || "$STORED_COMMIT" == "$LEGACY_UPSTREAM_COMMIT" ) \
        && ( -z "$STORED_PROFILE_REVISION" \
            || "$STORED_PROFILE_REVISION" == "compute-only-v2" \
            || "$STORED_PROFILE_REVISION" == "$RADV_PROFILE_REVISION" ) \
        && "$(wc -l < "$MANIFEST")" -eq 1 ]]
}

read_fsr4_manifest() {
    local extra line
    STORED_FSR4_DRIVER_SHA="" STORED_FSR4_ICD_SHA="" STORED_FSR4_RUNNER_SHA=""
    STORED_FSR4_MESA_TAG="" STORED_FSR4_PROFILE_SHA=""
    [[ -f "$FSR4_MANIFEST" && ! -L "$FSR4_MANIFEST" ]] || return 1
    IFS= read -r line < "$FSR4_MANIFEST" || return 1
    read -r STORED_FSR4_DRIVER_SHA STORED_FSR4_ICD_SHA STORED_FSR4_RUNNER_SHA \
        STORED_FSR4_MESA_TAG STORED_FSR4_PROFILE_SHA extra <<< "$line"
    [[ -z "$extra" \
        && "$STORED_FSR4_DRIVER_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_FSR4_ICD_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_FSR4_RUNNER_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_FSR4_MESA_TAG" =~ ^mesa-[0-9][0-9A-Za-z._-]*$ \
        && "$STORED_FSR4_PROFILE_SHA" =~ ^[0-9a-f]{64}$ \
        && "$(wc -l < "$FSR4_MANIFEST")" -eq 1 ]]
}

verify_owned_runtime() {
    local actual
    read_manifest || return 1
    [[ -f "$DRIVER" && ! -L "$DRIVER" && -f "$ICD" && ! -L "$ICD" ]] || return 1
    actual=$(sha256_file "$DRIVER")
    [[ "$actual" == "$STORED_DRIVER_SHA" ]] || return 1
    actual=$(sha256_file "$ICD")
    [[ "$actual" == "$STORED_ICD_SHA" ]] \
        && grep -qF "\"library_path\": \"$DRIVER\"" "$ICD" \
        && grep -Eq '"library_arch"[[:space:]]*:[[:space:]]*"64"' "$ICD"
}

render_previous_generator() {
    local marker_q audio_marker_q metrics_marker_q module_q active_q policy_q
    local driver_q fallback_icd_q commit_q
    marker_q=$(shell_word "$COMPUTE_MARKER")
    audio_marker_q=$(shell_word "$AUDIO_MARKER")
    metrics_marker_q=$(shell_word "$METRICS_MARKER")
    module_q=$(shell_word "$COMPUTE_MODULE")
    active_q=$(shell_word "$COMPUTE_ACTIVE")
    policy_q=$(shell_word "$SCHED_POLICY")
    driver_q=$(shell_word "$DRIVER")
    fallback_icd_q=$(shell_word "$FALLBACK_ICD")
    commit_q=$(shell_word "$UPSTREAM_COMMIT")
    cat <<EOF
#!/usr/bin/env bash
set -u
MARKER=$marker_q
AUDIO_MARKER=$audio_marker_q
METRICS_MARKER=$metrics_marker_q
MODULE=$module_q
ACTIVE=$active_q
SCHED_POLICY=$policy_q
DRIVER=$driver_q
FALLBACK_ICD=$fallback_icd_q
COMMIT=$commit_q
ICD="\$HOME/radeon_driconf_icd.x86_64.json"
MANIFEST="\$HOME/.local/share/bc250-mesh-shader/install.conf"
[ -f "\$MARKER" ] && [ ! -L "\$MARKER" ] \
    && [ -f "\$AUDIO_MARKER" ] && [ ! -L "\$AUDIO_MARKER" ] \
    && [ -f "\$METRICS_MARKER" ] && [ ! -L "\$METRICS_MARKER" ] \
    && [ -f "\$MODULE" ] \
    && [ ! -L "\$MODULE" ] && [ -f "\$DRIVER" ] && [ ! -L "\$DRIVER" ] \
    && [ -f "\$ICD" ] && [ ! -L "\$ICD" ] \
    && [ -f "\$FALLBACK_ICD" ] && [ ! -L "\$FALLBACK_ICD" ] \
    && [ -f "\$MANIFEST" ] && [ ! -L "\$MANIFEST" ] \
    && [ -r "\$ACTIVE" ] && [ ! -L "\$ACTIVE" ] \
    && [ -r "\$SCHED_POLICY" ] && [ ! -L "\$SCHED_POLICY" ] || exit 0
actual=\$(sha256sum "\$MODULE" | awk '{print \$1}')
for marker in "\$MARKER" "\$AUDIO_MARKER" "\$METRICS_MARKER"; do
    read -r expected < "\$marker" || exit 0
    [[ "\$expected" =~ ^[0-9a-f]{64}\$ ]] && [ "\$actual" = "\$expected" ] || exit 0
done
resolved=\$(modinfo -k "\$(uname -r)" -F filename amdgpu 2>/dev/null) || exit 0
[ "\$(readlink -f "\$resolved")" = "\$(readlink -f "\$MODULE")" ] || exit 0
for path in "\$MODULE" "\$MARKER" "\$AUDIO_MARKER" "\$METRICS_MARKER" "\$DRIVER"; do
    [ "\$(stat -c %u "\$path")" = 0 ] || exit 0
    mode=\$(stat -c %a "\$path") || exit 0
    [[ "\$mode" =~ ^[0-7]+\$ ]] && (( (8#\$mode & 8#022) == 0 )) || exit 0
done
[ "\$(cat "\$ACTIVE")" = "\$COMMIT" ] || exit 0
[ "\$(cat "\$SCHED_POLICY")" = 2 ] || exit 0
read -r driver_sha icd_sha mesa_version commit < "\$MANIFEST" || exit 0
[[ "\$driver_sha" =~ ^[0-9a-f]{64}\$ && "\$icd_sha" =~ ^[0-9a-f]{64}\$ \
    && "\$commit" = "\$COMMIT" ]] || exit 0
[ "\$(sha256sum "\$DRIVER" | awk '{print \$1}')" = "\$driver_sha" ] || exit 0
[ "\$(sha256sum "\$ICD" | awk '{print \$1}')" = "\$icd_sha" ] || exit 0
grep -qF "\"library_path\": \"\$DRIVER\"" "\$ICD" || exit 0
grep -Eq '"library_arch"[[:space:]]*:[[:space:]]*"64"' "\$ICD" || exit 0
grep -Eq '"library_arch"[[:space:]]*:[[:space:]]*"32"' "\$FALLBACK_ICD" || exit 0
printf 'VK_DRIVER_FILES=%s:%s\n' "\$ICD" "\$FALLBACK_ICD"
printf 'VK_ICD_FILENAMES=%s:%s\n' "\$ICD" "\$FALLBACK_ICD"
EOF
}

render_generator() {
    local marker_q audio_marker_q metrics_marker_q module_q active_q policy_q
    local driver_q fallback_icd_q commit_q profile_revision_q
    marker_q=$(shell_word "$COMPUTE_MARKER")
    audio_marker_q=$(shell_word "$AUDIO_MARKER")
    metrics_marker_q=$(shell_word "$METRICS_MARKER")
    module_q=$(shell_word "$COMPUTE_MODULE")
    active_q=$(shell_word "$COMPUTE_ACTIVE")
    policy_q=$(shell_word "$SCHED_POLICY")
    driver_q=$(shell_word "$DRIVER")
    fallback_icd_q=$(shell_word "$FALLBACK_ICD")
    commit_q=$(shell_word "$UPSTREAM_COMMIT")
    profile_revision_q=$(shell_word "$RADV_PROFILE_REVISION")
    cat <<EOF
#!/usr/bin/env bash
set -u
MARKER=$marker_q
AUDIO_MARKER=$audio_marker_q
METRICS_MARKER=$metrics_marker_q
MODULE=$module_q
ACTIVE=$active_q
SCHED_POLICY=$policy_q
DRIVER=$driver_q
FALLBACK_ICD=$fallback_icd_q
COMMIT=$commit_q
PROFILE_REVISION=$profile_revision_q
ICD="\$HOME/radeon_driconf_icd.x86_64.json"
MANIFEST="\$HOME/.local/share/bc250-mesh-shader/install.conf"
[ -f "\$MARKER" ] && [ ! -L "\$MARKER" ] \
    && [ -f "\$AUDIO_MARKER" ] && [ ! -L "\$AUDIO_MARKER" ] \
    && [ -f "\$METRICS_MARKER" ] && [ ! -L "\$METRICS_MARKER" ] \
    && [ -f "\$MODULE" ] \
    && [ ! -L "\$MODULE" ] && [ -f "\$DRIVER" ] && [ ! -L "\$DRIVER" ] \
    && [ -f "\$ICD" ] && [ ! -L "\$ICD" ] \
    && [ -f "\$FALLBACK_ICD" ] && [ ! -L "\$FALLBACK_ICD" ] \
    && [ -f "\$MANIFEST" ] && [ ! -L "\$MANIFEST" ] \
    && [ -r "\$ACTIVE" ] && [ ! -L "\$ACTIVE" ] \
    && [ -r "\$SCHED_POLICY" ] && [ ! -L "\$SCHED_POLICY" ] || exit 0
actual=\$(sha256sum "\$MODULE" | awk '{print \$1}')
for marker in "\$MARKER" "\$AUDIO_MARKER" "\$METRICS_MARKER"; do
    read -r expected < "\$marker" || exit 0
    [[ "\$expected" =~ ^[0-9a-f]{64}\$ ]] && [ "\$actual" = "\$expected" ] || exit 0
done
resolved=\$(modinfo -k "\$(uname -r)" -F filename amdgpu 2>/dev/null) || exit 0
[ "\$(readlink -f "\$resolved")" = "\$(readlink -f "\$MODULE")" ] || exit 0
for path in "\$MODULE" "\$MARKER" "\$AUDIO_MARKER" "\$METRICS_MARKER" "\$DRIVER"; do
    [ "\$(stat -c %u "\$path")" = 0 ] || exit 0
    mode=\$(stat -c %a "\$path") || exit 0
    [[ "\$mode" =~ ^[0-7]+\$ ]] && (( (8#\$mode & 8#022) == 0 )) || exit 0
done
[ "\$(cat "\$ACTIVE")" = "\$COMMIT" ] || exit 0
[ "\$(cat "\$SCHED_POLICY")" = 2 ] || exit 0
read -r driver_sha icd_sha mesa_version commit profile_revision extra < "\$MANIFEST" || exit 0
[[ -z "\${extra:-}" && "\$driver_sha" =~ ^[0-9a-f]{64}\$ \
    && "\$icd_sha" =~ ^[0-9a-f]{64}\$ && "\$commit" = "\$COMMIT" \
    && "\$profile_revision" = "\$PROFILE_REVISION" ]] || exit 0
[ "\$(sha256sum "\$DRIVER" | awk '{print \$1}')" = "\$driver_sha" ] || exit 0
[ "\$(sha256sum "\$ICD" | awk '{print \$1}')" = "\$icd_sha" ] || exit 0
grep -qF "\"library_path\": \"\$DRIVER\"" "\$ICD" || exit 0
grep -Eq '"library_arch"[[:space:]]*:[[:space:]]*"64"' "\$ICD" || exit 0
grep -Eq '"library_arch"[[:space:]]*:[[:space:]]*"32"' "\$FALLBACK_ICD" || exit 0
printf 'VK_DRIVER_FILES=%s:%s\n' "\$ICD" "\$FALLBACK_ICD"
printf 'VK_ICD_FILENAMES=%s:%s\n' "\$ICD" "\$FALLBACK_ICD"
EOF
}

render_pre_policy_generator() {
    local marker_q module_q active_q driver_q fallback_icd_q commit_q
    marker_q=$(shell_word "$COMPUTE_MARKER")
    module_q=$(shell_word "$COMPUTE_MODULE")
    active_q=$(shell_word "$COMPUTE_ACTIVE")
    driver_q=$(shell_word "$DRIVER")
    fallback_icd_q=$(shell_word "$FALLBACK_ICD")
    commit_q=$(shell_word "$UPSTREAM_COMMIT")
    cat <<EOF
#!/usr/bin/env bash
set -u
MARKER=$marker_q
MODULE=$module_q
ACTIVE=$active_q
DRIVER=$driver_q
FALLBACK_ICD=$fallback_icd_q
COMMIT=$commit_q
ICD="\$HOME/radeon_driconf_icd.x86_64.json"
MANIFEST="\$HOME/.local/share/bc250-mesh-shader/install.conf"
[ -f "\$MARKER" ] && [ ! -L "\$MARKER" ] && [ -f "\$MODULE" ] \
    && [ ! -L "\$MODULE" ] && [ -f "\$DRIVER" ] && [ ! -L "\$DRIVER" ] \
    && [ -f "\$ICD" ] && [ ! -L "\$ICD" ] \
    && [ -f "\$FALLBACK_ICD" ] && [ ! -L "\$FALLBACK_ICD" ] \
    && [ -f "\$MANIFEST" ] && [ ! -L "\$MANIFEST" ] \
    && [ -r "\$ACTIVE" ] && [ ! -L "\$ACTIVE" ] || exit 0
read -r expected < "\$MARKER" || exit 0
[[ "\$expected" =~ ^[0-9a-f]{64}\$ ]] || exit 0
actual=\$(sha256sum "\$MODULE" | awk '{print \$1}')
[ "\$actual" = "\$expected" ] || exit 0
[ "\$(cat "\$ACTIVE")" = "\$COMMIT" ] || exit 0
read -r driver_sha icd_sha mesa_version commit < "\$MANIFEST" || exit 0
[[ "\$driver_sha" =~ ^[0-9a-f]{64}\$ && "\$icd_sha" =~ ^[0-9a-f]{64}\$ \
    && "\$commit" = "\$COMMIT" ]] || exit 0
[ "\$(sha256sum "\$DRIVER" | awk '{print \$1}')" = "\$driver_sha" ] || exit 0
[ "\$(sha256sum "\$ICD" | awk '{print \$1}')" = "\$icd_sha" ] || exit 0
grep -qF "\"library_path\": \"\$DRIVER\"" "\$ICD" || exit 0
grep -Eq '"library_arch"[[:space:]]*:[[:space:]]*"64"' "\$ICD" || exit 0
grep -Eq '"library_arch"[[:space:]]*:[[:space:]]*"32"' "\$FALLBACK_ICD" || exit 0
printf 'VK_DRIVER_FILES=%s:%s\n' "\$ICD" "\$FALLBACK_ICD"
printf 'VK_ICD_FILENAMES=%s:%s\n' "\$ICD" "\$FALLBACK_ICD"
EOF
}

render_legacy_generator() {
    local marker_q module_q active_q driver_q commit_q
    marker_q=$(shell_word "$COMPUTE_MARKER")
    module_q=$(shell_word "$COMPUTE_MODULE")
    active_q=$(shell_word "$COMPUTE_ACTIVE")
    driver_q=$(shell_word "$DRIVER")
    commit_q=$(shell_word "$UPSTREAM_COMMIT")
    cat <<EOF
#!/usr/bin/env bash
set -u
MARKER=$marker_q
MODULE=$module_q
ACTIVE=$active_q
DRIVER=$driver_q
COMMIT=$commit_q
ICD="\$HOME/radeon_driconf_icd.x86_64.json"
MANIFEST="\$HOME/.local/share/bc250-mesh-shader/install.conf"
[ -f "\$MARKER" ] && [ ! -L "\$MARKER" ] && [ -f "\$MODULE" ] \
    && [ ! -L "\$MODULE" ] && [ -f "\$DRIVER" ] && [ ! -L "\$DRIVER" ] \
    && [ -f "\$ICD" ] && [ ! -L "\$ICD" ] \
    && [ -f "\$MANIFEST" ] && [ ! -L "\$MANIFEST" ] \
    && [ -r "\$ACTIVE" ] && [ ! -L "\$ACTIVE" ] || exit 0
read -r expected < "\$MARKER" || exit 0
[[ "\$expected" =~ ^[0-9a-f]{64}\$ ]] || exit 0
actual=\$(sha256sum "\$MODULE" | awk '{print \$1}')
[ "\$actual" = "\$expected" ] || exit 0
[ "\$(cat "\$ACTIVE")" = "\$COMMIT" ] || exit 0
read -r driver_sha icd_sha mesa_version commit < "\$MANIFEST" || exit 0
[[ "\$driver_sha" =~ ^[0-9a-f]{64}\$ && "\$icd_sha" =~ ^[0-9a-f]{64}\$ \
    && "\$commit" = "\$COMMIT" ]] || exit 0
[ "\$(sha256sum "\$DRIVER" | awk '{print \$1}')" = "\$driver_sha" ] || exit 0
[ "\$(sha256sum "\$ICD" | awk '{print \$1}')" = "\$icd_sha" ] || exit 0
grep -qF "\"library_path\": \"\$DRIVER\"" "\$ICD" || exit 0
printf 'VK_DRIVER_FILES=%s\n' "\$ICD"
printf 'VK_ICD_FILENAMES=%s\n' "\$ICD"
EOF
}

render_fsr4_runner() {
    local marker_q audio_marker_q metrics_marker_q module_q active_q policy_q
    local driver_q icd_q fallback_icd_q manifest_q runner_q commit_q profile_sha_q
    marker_q=$(shell_word "$COMPUTE_MARKER")
    audio_marker_q=$(shell_word "$AUDIO_MARKER")
    metrics_marker_q=$(shell_word "$METRICS_MARKER")
    module_q=$(shell_word "$COMPUTE_MODULE")
    active_q=$(shell_word "$COMPUTE_ACTIVE")
    policy_q=$(shell_word "$SCHED_POLICY")
    driver_q=$(shell_word "$FSR4_DRIVER")
    icd_q=$(shell_word "$FSR4_ICD")
    fallback_icd_q=$(shell_word "$FALLBACK_ICD")
    manifest_q=$(shell_word "$FSR4_MANIFEST")
    runner_q=$(shell_word "$FSR4_RUNNER")
    commit_q=$(shell_word "$UPSTREAM_COMMIT")
    profile_sha_q=$(shell_word "$FSR4_PROFILE_SHA256")
    cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
MARKER=$marker_q
AUDIO_MARKER=$audio_marker_q
METRICS_MARKER=$metrics_marker_q
MODULE=$module_q
ACTIVE=$active_q
SCHED_POLICY=$policy_q
DRIVER=$driver_q
ICD=$icd_q
FALLBACK_ICD=$fallback_icd_q
MANIFEST=$manifest_q
RUNNER=$runner_q
COMMIT=$commit_q
PROFILE_SHA=$profile_sha_q
fail() { printf '[bc250-fsr4] %s\n' "\$*" >&2; exit 1; }
[[ \$# -gt 0 ]] || fail "No game command was provided."
for path in "\$MARKER" "\$AUDIO_MARKER" "\$METRICS_MARKER" "\$MODULE" \
    "\$DRIVER" "\$ICD" "\$FALLBACK_ICD" "\$MANIFEST" "\$RUNNER"; do
    [[ -f "\$path" && ! -L "\$path" ]] || fail "Required attested file is missing or unsafe: \$path"
done
[[ -r "\$ACTIVE" && ! -L "\$ACTIVE" && -r "\$SCHED_POLICY" && ! -L "\$SCHED_POLICY" ]] \
    || fail "The patched AMDGPU runtime is not active."
actual=\$(sha256sum "\$MODULE" | awk '{print \$1}')
for marker in "\$MARKER" "\$AUDIO_MARKER" "\$METRICS_MARKER"; do
    read -r expected < "\$marker" || fail "Could not read \$marker"
    [[ "\$expected" =~ ^[0-9a-f]{64}\$ && "\$actual" == "\$expected" ]] \
        || fail "The selected AMDGPU module does not match its attestations."
done
resolved=\$(modinfo -k "\$(uname -r)" -F filename amdgpu 2>/dev/null) \
    || fail "Could not resolve the selected AMDGPU module."
[[ "\$(readlink -f "\$resolved")" == "\$(readlink -f "\$MODULE")" ]] \
    || fail "The selected AMDGPU module is not the attested module."
[[ "\$(cat "\$ACTIVE")" == "\$COMMIT" ]] || fail "The loaded AMDGPU repair does not match RADV."
[[ "\$(cat "\$SCHED_POLICY")" == 2 ]] || fail "amdgpu.sched_policy=2 is not active."
read -r driver_sha icd_sha runner_sha mesa_version profile_sha extra < "\$MANIFEST" \
    || fail "The FSR4 profile manifest is malformed."
[[ -z "\${extra:-}" && "\$driver_sha" =~ ^[0-9a-f]{64}\$ \
    && "\$icd_sha" =~ ^[0-9a-f]{64}\$ && "\$runner_sha" =~ ^[0-9a-f]{64}\$ \
    && "\$mesa_version" == "$DEFAULT_MESA_TAG" && "\$profile_sha" == "\$PROFILE_SHA" ]] \
    || fail "The FSR4 profile manifest is invalid."
[[ "\$(sha256sum "\$DRIVER" | awk '{print \$1}')" == "\$driver_sha" \
    && "\$(sha256sum "\$ICD" | awk '{print \$1}')" == "\$icd_sha" \
    && "\$(sha256sum "\$RUNNER" | awk '{print \$1}')" == "\$runner_sha" ]] \
    || fail "The FSR4 profile failed hash verification."
grep -qF "\"library_path\": \"\$DRIVER\"" "\$ICD" \
    && grep -Eq '"library_arch"[[:space:]]*:[[:space:]]*"64"' "\$ICD" \
    || fail "The Vulkan ICD architecture routing is invalid."
python3 - "\$FALLBACK_ICD" <<'PY' || fail "The 32-bit Vulkan fallback is invalid."
import json
from pathlib import Path
import struct
import sys

manifest = Path(sys.argv[1])
try:
    data = json.loads(manifest.read_text(encoding="utf-8"))
    icd = data["ICD"]
    library = Path(icd["library_path"])
    if not library.is_absolute():
        library = manifest.parent / library
    valid = (
        data.get("file_format_version") == "1.0.1"
        and icd.get("library_arch") == "32"
        and library.is_file()
        and not library.is_symlink()
    )
    if valid:
        content = library.read_bytes()
        valid = len(content) >= 52 and content[:7] == b"\x7fELF\x01\x01\x01"
    if valid:
        e_type, e_machine, e_version = struct.unpack_from("<HHI", content, 16)
        e_phoff = struct.unpack_from("<I", content, 28)[0]
        e_ehsize, e_phentsize, e_phnum = struct.unpack_from("<HHH", content, 40)
        valid = (
            e_type == 3 and e_machine == 3 and e_version == 1
            and e_ehsize >= 52 and e_phentsize >= 32 and e_phnum > 0
            and e_phoff + e_phentsize * e_phnum <= len(content)
        )
    if valid:
        types = {
            struct.unpack_from("<I", content, e_phoff + index * e_phentsize)[0]
            for index in range(e_phnum)
        }
        valid = 1 in types and 2 in types
except (KeyError, OSError, struct.error, TypeError, ValueError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
export VK_DRIVER_FILES="\$ICD:\$FALLBACK_ICD"
export VK_ICD_FILENAMES="\$VK_DRIVER_FILES"
exec "\$@"
EOF
}

verify_owned_fsr4_runtime() {
    local actual
    read_fsr4_manifest || return 1
    [[ -d "$FSR4_DIR" && ! -L "$FSR4_DIR" \
        && -f "$FSR4_DRIVER" && ! -L "$FSR4_DRIVER" \
        && -f "$FSR4_ICD" && ! -L "$FSR4_ICD" \
        && -f "$FSR4_RUNNER" && ! -L "$FSR4_RUNNER" && -x "$FSR4_RUNNER" ]] || return 1
    actual=$(sha256_file "$FSR4_DRIVER")
    [[ "$actual" == "$STORED_FSR4_DRIVER_SHA" ]] || return 1
    actual=$(sha256_file "$FSR4_ICD")
    [[ "$actual" == "$STORED_FSR4_ICD_SHA" ]] || return 1
    actual=$(sha256_file "$FSR4_RUNNER")
    [[ "$actual" == "$STORED_FSR4_RUNNER_SHA" ]] || return 1
    grep -qF "\"library_path\": \"$FSR4_DRIVER\"" "$FSR4_ICD" \
        && grep -Eq '"library_arch"[[:space:]]*:[[:space:]]*"64"' "$FSR4_ICD"
}

verify_current_fsr4_profile() {
    verify_owned_fsr4_runtime \
        && [[ "$STORED_FSR4_MESA_TAG" == "$DEFAULT_MESA_TAG" \
            && "$STORED_FSR4_PROFILE_SHA" == "$FSR4_PROFILE_SHA256" ]] \
        && cmp -s "$FSR4_RUNNER" <(render_fsr4_runner)
}

verify_current_fsr4_runtime() {
    verify_current_runtime && verify_current_fsr4_profile
}

report_fsr4_preserved() {
    [[ -e "$FSR4_DIR" || -L "$FSR4_DIR" ]] || return 0
    if verify_current_fsr4_profile; then
        log "The private legacy FSR4 V3 profile remains installed and verified."
    else
        log "The private legacy FSR4 V3 files were left unchanged but require validation; rerun legacy setup before using them."
    fi
}

recover_fsr4_install_transaction() {
    [[ -e "$FSR4_TRANSACTION_DIR" || -L "$FSR4_TRANSACTION_DIR" ]] || return 0
    [[ -d "$FSR4_TRANSACTION_DIR" && ! -L "$FSR4_TRANSACTION_DIR" \
        && -f "$FSR4_TRANSACTION_DIR/transaction.conf" \
        && ! -L "$FSR4_TRANSACTION_DIR/transaction.conf" ]] \
        || die "Invalid FSR4 install transaction; manual recovery required."
    local phase had_previous extra
    read -r phase had_previous extra < "$FSR4_TRANSACTION_DIR/transaction.conf" \
        || die "Malformed FSR4 install transaction; manual recovery required."
    [[ ( "$phase" == prepared || "$phase" == swapping ) \
        && ( "$had_previous" == 0 || "$had_previous" == 1 ) && -z "$extra" ]] \
        || die "Malformed FSR4 install transaction; manual recovery required."
    if [[ "$phase" == prepared ]]; then
        rm -rf "$FSR4_TRANSACTION_DIR"
        fsync_paths "$STATE_DIR"
        return 0
    fi
    if verify_owned_fsr4_runtime; then
        rm -rf "$FSR4_TRANSACTION_DIR"
        fsync_paths "$STATE_DIR"
        log "Completed recovery of an intact FSR4 profile installation."
        return 0
    fi
    rm -rf "$FSR4_DIR"
    if [[ "$had_previous" == 1 ]]; then
        [[ -d "$FSR4_TRANSACTION_DIR/previous" \
            && ! -L "$FSR4_TRANSACTION_DIR/previous" ]] \
            || die "FSR4 transaction backup is missing; manual recovery required."
        mv "$FSR4_TRANSACTION_DIR/previous" "$FSR4_DIR"
    fi
    rm -rf "$FSR4_TRANSACTION_DIR"
    fsync_paths "$STATE_DIR"
    log "Recovered an interrupted FSR4 profile installation."
}

generator_owned() {
    [[ -f "$GENERATOR" && ! -L "$GENERATOR" && -x "$GENERATOR" ]] \
        && cmp -s "$GENERATOR" <(render_generator)
}

generator_recorded() {
    generator_owned || {
        [[ -f "$GENERATOR" && ! -L "$GENERATOR" && -x "$GENERATOR" ]] \
            && { cmp -s "$GENERATOR" <(render_previous_generator) \
                || cmp -s "$GENERATOR" <(render_pre_policy_generator) \
                || cmp -s "$GENERATOR" <(render_legacy_generator); }
    }
}

verify_current_runtime() {
    verify_owned_runtime && [[ "$STORED_COMMIT" == "$UPSTREAM_COMMIT" \
        && "$STORED_MESA_TAG" == "$DEFAULT_MESA_TAG" \
        && "$STORED_PROFILE_REVISION" == "$RADV_PROFILE_REVISION" ]] \
        && generator_owned && verify_32bit_fallback
}

verify_recorded_parts() {
    local actual
    read_manifest || return 1
    if [[ -e "$DRIVER" || -L "$DRIVER" ]]; then
        [[ -f "$DRIVER" && ! -L "$DRIVER" ]] || return 1
        actual=$(sha256_file "$DRIVER")
        [[ "$actual" == "$STORED_DRIVER_SHA" ]] || return 1
    fi
    if [[ -e "$ICD" || -L "$ICD" ]]; then
        [[ -f "$ICD" && ! -L "$ICD" ]] || return 1
        actual=$(sha256_file "$ICD")
        [[ "$actual" == "$STORED_ICD_SHA" ]] || return 1
    fi
    if [[ -e "$GENERATOR" || -L "$GENERATOR" ]]; then
        generator_recorded || return 1
    fi
}

preflight_runtime_ownership() {
    if [[ -e "$DRIVER" || -L "$DRIVER" || -e "$ICD" || -L "$ICD" \
        || -e "$GENERATOR" || -L "$GENERATOR" ]]; then
        verify_recorded_parts \
            || die "Existing alternate driver/ICD is not a recorded toolkit install; refusing replacement."
    elif [[ -e "$MANIFEST" || -L "$MANIFEST" ]]; then
        read_manifest || die "Install manifest is malformed; refusing replacement."
    fi
}

recover_install_transaction() (
    [[ -d "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" ]] || return 0
    local conf="$TRANSACTION_DIR/transaction.conf" version old_driver driver_sha
    local old_icd icd_sha old_manifest manifest_sha old_generator=0 generator_sha=- ro_restore=0 environment
    finish_recovery() {
        local rc=$?
        trap - EXIT INT TERM HUP
        if [[ $ro_restore -eq 1 ]]; then as_root steamos-readonly enable || rc=1; fi
        exit "$rc"
    }
    trap finish_recovery EXIT INT TERM HUP
    if [[ ! -f "$conf" || -L "$conf" ]]; then
        rm -rf "$TRANSACTION_DIR"
        return 0
    fi
    read -r version old_driver driver_sha old_icd icd_sha old_manifest manifest_sha \
        old_generator generator_sha < "$conf" \
        || die "Malformed mesh-shader install transaction; manual recovery required."
    if [[ "$version" == 1 ]]; then
        old_generator=0
        generator_sha=-
    fi
    [[ ( "$version" == 1 || "$version" == 2 ) \
        && "$old_driver" =~ ^[01]$ && "$old_icd" =~ ^[01]$ \
        && "$old_manifest" =~ ^[01]$ && "$old_generator" =~ ^[01]$ ]] \
        || die "Invalid mesh-shader install transaction; manual recovery required."
    if [[ "$old_driver" == 1 ]]; then
        [[ -f "$TRANSACTION_DIR/driver" && ! -L "$TRANSACTION_DIR/driver" \
            && "$(sha256_file "$TRANSACTION_DIR/driver")" == "$driver_sha" ]] \
            || die "Driver transaction backup failed verification; manual recovery required."
    fi
    if [[ "$old_icd" == 1 ]]; then
        [[ -f "$TRANSACTION_DIR/icd" && ! -L "$TRANSACTION_DIR/icd" \
            && "$(sha256_file "$TRANSACTION_DIR/icd")" == "$icd_sha" ]] \
            || die "ICD transaction backup failed verification; manual recovery required."
    fi
    if [[ "$old_manifest" == 1 ]]; then
        [[ -f "$TRANSACTION_DIR/manifest" && ! -L "$TRANSACTION_DIR/manifest" \
            && "$(sha256_file "$TRANSACTION_DIR/manifest")" == "$manifest_sha" ]] \
            || die "Manifest transaction backup failed verification; manual recovery required."
    fi
    if [[ "$old_generator" == 1 ]]; then
        [[ -f "$TRANSACTION_DIR/generator" && ! -L "$TRANSACTION_DIR/generator" \
            && "$(sha256_file "$TRANSACTION_DIR/generator")" == "$generator_sha" ]] \
            || die "Generator transaction backup failed verification; manual recovery required."
    fi

    if command -v steamos-readonly >/dev/null 2>&1 \
        && steamos-readonly status 2>/dev/null | grep -qi enabled; then
        ro_restore=1
        as_root steamos-readonly disable
    fi
    if [[ "$old_driver" == 1 ]]; then
        as_root install -o root -g root -m 0755 "$TRANSACTION_DIR/driver" "$DRIVER"
    else
        as_root rm -f "$DRIVER"
    fi
    as_root rm -f "${DRIVER}.bc250-new"
    if [[ "$old_icd" == 1 ]]; then cp -p "$TRANSACTION_DIR/icd" "$ICD"; else rm -f "$ICD"; fi
    if [[ "$old_manifest" == 1 ]]; then
        cp -p "$TRANSACTION_DIR/manifest" "$MANIFEST"
    else
        rm -f "$MANIFEST"
    fi
    if [[ "$old_generator" == 1 ]]; then
        as_root mkdir -p "${GENERATOR%/*}"
        as_root install -m 0755 "$TRANSACTION_DIR/generator" "$GENERATOR"
    else
        as_root rm -f "$GENERATOR"
    fi
    if [[ -f "$DRIVER" ]]; then as_root sync -f "$DRIVER"; fi
    as_root sync -d "${DRIVER%/*}"
    python3 - "$ICD" "$MANIFEST" "$GENERATOR" "${ICD%/*}" "${GENERATOR%/*}" "$STATE_DIR" <<'PY'
import os
from pathlib import Path
import sys
for value in sys.argv[1:]:
    path = Path(value)
    if not path.exists():
        continue
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
    if [[ $ro_restore -eq 1 ]]; then as_root steamos-readonly enable; ro_restore=0; fi
    if [[ "$old_generator" == 0 ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload >/dev/null 2>&1 \
            || die "Could not reload the restored user environment; retry recovery."
        environment=$(systemctl --user show-environment 2>/dev/null) || environment=
        ! grep -qxF "VK_DRIVER_FILES=$GLOBAL_ICDS" <<< "$environment" \
            && ! grep -qxF "VK_ICD_FILENAMES=$GLOBAL_ICDS" <<< "$environment" \
            || die "Interrupted global Vulkan environment remains active; sign out and retry recovery."
    fi
    rm -rf "$TRANSACTION_DIR"
    python3 - "$STATE_DIR" <<'PY'
import os
import sys
descriptor = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
    log "Recovered an interrupted mesh-shader runtime installation."
)

arm_install_transaction() {
    local old_driver=0 old_icd=0 old_manifest=0 old_generator=0
    local driver_sha=- icd_sha=- manifest_sha=- generator_sha=- tmp
    rm -rf "$TRANSACTION_DIR"
    mkdir -m 0700 "$TRANSACTION_DIR"
    if [[ -f "$DRIVER" && ! -L "$DRIVER" ]]; then
        as_root cat "$DRIVER" > "$TRANSACTION_DIR/driver"
        driver_sha=$(sha256_file "$TRANSACTION_DIR/driver")
        old_driver=1
    fi
    if [[ -f "$ICD" && ! -L "$ICD" ]]; then
        cp -p "$ICD" "$TRANSACTION_DIR/icd"
        icd_sha=$(sha256_file "$TRANSACTION_DIR/icd")
        old_icd=1
    fi
    if [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]]; then
        cp -p "$MANIFEST" "$TRANSACTION_DIR/manifest"
        manifest_sha=$(sha256_file "$TRANSACTION_DIR/manifest")
        old_manifest=1
    fi
    if [[ -f "$GENERATOR" && ! -L "$GENERATOR" ]]; then
        as_root cat "$GENERATOR" > "$TRANSACTION_DIR/generator"
        generator_sha=$(sha256_file "$TRANSACTION_DIR/generator")
        old_generator=1
    fi
    tmp="$TRANSACTION_DIR/.transaction.conf"
    printf '2 %s %s %s %s %s %s %s %s\n' \
        "$old_driver" "$driver_sha" "$old_icd" "$icd_sha" "$old_manifest" "$manifest_sha" \
        "$old_generator" "$generator_sha" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$TRANSACTION_DIR/transaction.conf"
    python3 - "$TRANSACTION_DIR" <<'PY'
import os
from pathlib import Path
import sys
directory = Path(sys.argv[1])
for path in list(directory.iterdir()) + [directory]:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

write_manifest() {
    local driver_sha icd_sha tmp
    driver_sha=$(sha256_file "$DRIVER")
    icd_sha=$(sha256_file "$ICD")
    tmp=$(mktemp "$STATE_DIR/.install.XXXXXX")
    printf '%s %s %s %s %s\n' "$driver_sha" "$icd_sha" "$1" \
        "$UPSTREAM_COMMIT" "$RADV_PROFILE_REVISION" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$MANIFEST"
    python3 - "$MANIFEST" "$STATE_DIR" <<'PY'
import os
import sys
for path in sys.argv[1:]:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

install_default_profile() {
    local output="$1" mesa_tag="$2"
    log "Installing audited $mesa_tag with DryhoppedIPA's patch series ${UPSTREAM_COMMIT:0:7}."
    log "The alternate ICD will become global for this user after the user manager reloads."
    arm_install_transaction
    unlock_root
    as_root install -o root -g root -m 0755 "$output" "$staged_driver"
    as_root mv -f "$staged_driver" "$DRIVER"
    as_root sync -f "$DRIVER"
    as_root sync -d "${DRIVER%/*}"
    relock_root
    cat > "$work/icd" <<EOF
{
  "file_format_version": "1.0.1",
  "ICD": {"library_path": "$DRIVER", "api_version": "1.4.354", "library_arch": "64"}
}
EOF
    chmod 0644 "$work/icd"
    mv -f "$work/icd" "$ICD"
    python3 - "$ICD" "${ICD%/*}" <<'PY'
import os
import sys
for path in sys.argv[1:]:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY

    [[ -f "$DRIVER" && ! -L "$DRIVER" ]] || die "Driver installation failed: $DRIVER"
    [[ -f "$ICD" && ! -L "$ICD" ]] || die "Upstream build did not create $ICD"
    grep -qF "\"library_path\": \"$DRIVER\"" "$ICD" \
        || die "Generated ICD does not reference the expected alternate driver"
    [[ ! -L "$GENERATOR" ]] || die "Refusing symlinked environment generator: $GENERATOR"
    render_generator > "$work/generator"
    chmod 0755 "$work/generator"
    unlock_root
    as_root install -D -o root -g root -m 0755 "$work/generator" "$GENERATOR"
    as_root sync -f "$GENERATOR"
    as_root sync -d "${GENERATOR%/*}"
    relock_root
    generator_owned || die "Installed GFX1013 environment generator failed verification"
    write_manifest "$mesa_tag"
    rm -rf "$TRANSACTION_DIR"
    python3 - "$STATE_DIR" <<'PY'
import os
import sys
descriptor = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
    if ! verify_scheduler_configured; then
        as_root bash "$BOOT_CONFIG" install \
            || die "RADV was installed but amdgpu.sched_policy=2 could not be configured. The safety gate will keep RADV disabled; fix the boot policy and retry."
    fi
    log "Patched RADV async-compute support is installed."
    if verify_scheduler_active; then
        log "Sign out and back in so the complete graphical session inherits the new Vulkan environment."
    else
        log "Reboot to activate amdgpu.sched_policy=2 and the patched RADV driver together."
    fi
}

validate_mesa_output() {
    local output="$1" linkage
    [[ -s "$output" && ! -L "$output" ]] || die "Mesa build did not produce the alternate RADV driver"
    python3 - "$output" <<'PY'
from pathlib import Path
import sys
with Path(sys.argv[1]).open("rb") as stream:
    valid = stream.read(5) == b"\x7fELF\x02"
raise SystemExit(0 if valid else 1)
PY
    LC_ALL=C readelf -h "$output" | grep -Eq 'Class:[[:space:]]+ELF64' \
        || die "Mesa build did not produce a valid 64-bit ELF driver"
    linkage=$(LC_ALL=C ldd -r "$output" 2>&1) \
        || die "Built RADV driver failed dynamic-link validation: $linkage"
    ! grep -Eq 'not found|undefined symbol:' <<< "$linkage" \
        || die "Built RADV driver has unresolved dynamic dependencies: $linkage"
    local marker
    for marker in bc250-fsr4-integrated-v3 BC250_FSR4_DISABLE \
        BC250_FSR4_IMAGEPREP BC250_FSR4_TEXTURE \
        BC250_FSR4_RESOLUTION_VARIANTS BC250_FSR4_RESOLUTION_GUARD; do
        grep -aqF "$marker" "$output" \
            || die "Built RADV driver is missing FSR4 marker: $marker"
    done
}

cmd_setup() (
    require_normal_user
    local profile="${1:-default}" mesa_tag="$DEFAULT_MESA_TAG"
    local work source build output staged_driver base_output base_driver_sha
    local cache_profile="" expected_sha="" committed=0 default_ready=0 default_bootstrapped=0
    local ro_was_enabled=0 root_unlocked=0 need_packages=0
    [[ "$profile" == default || "$profile" == fsr4 ]] || die "Unknown RADV profile: $profile"
    command -v systemctl >/dev/null 2>&1 || die "systemctl is required for global RADV activation"
    require_production_kernel_paths
    [[ -f "$BOOT_CONFIG" && ! -L "$BOOT_CONFIG" ]] \
        || die "AMDGPU scheduler-policy helper is missing or unsafe: $BOOT_CONFIG"
    if ! ensure_compute_kernel_prerequisite; then
        return 0
    fi
    if [[ ! -e "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" \
        && ! -e "$FSR4_TRANSACTION_DIR" && ! -L "$FSR4_TRANSACTION_DIR" ]]; then
        preflight_runtime_ownership
        if [[ -e "$FSR4_DIR" || -L "$FSR4_DIR" ]]; then
            verify_owned_fsr4_runtime \
                || die "Existing legacy FSR4 V3 profile is incomplete or not a recorded toolkit install."
        fi
    fi
    ensure_radv_core_tools
    ensure_state_dir
    exec 9> "$LOCK_FILE"
    flock 9
    recover_install_transaction
    recover_fsr4_install_transaction
    if [[ "$profile" == default ]]; then
        preflight_runtime_ownership
    else
        if verify_current_runtime; then
            default_ready=1
        else
            preflight_runtime_ownership
            log "The async-compute RADV prerequisite is missing or stale; legacy FSR4 V3 setup will install it first."
        fi
        if [[ -e "$FSR4_DIR" || -L "$FSR4_DIR" ]]; then
            verify_owned_fsr4_runtime \
                || die "Existing legacy FSR4 V3 profile is incomplete or not a recorded toolkit install."
        fi
    fi
    ensure_radv_prerequisites
    if [[ "$profile" == default ]] && verify_current_runtime; then
        if ! verify_scheduler_configured; then
            if ! as_root bash "$BOOT_CONFIG" install; then
                report_fsr4_preserved
                die "RADV is installed, but amdgpu.sched_policy=2 could not be configured."
            fi
        fi
        log "The async-compute RADV profile is already installed and verified; no Mesa rebuild is needed."
        if verify_scheduler_active; then
            log "The async-compute profile is active."
        else
            log "Reboot to activate amdgpu.sched_policy=2 and the patched RADV driver together."
        fi
        report_fsr4_preserved
        return 0
    fi
    work=$(mktemp -d "$STATE_DIR/.setup.XXXXXX")
    staged_driver="${DRIVER}.bc250-new"
    [[ ! -e "$staged_driver" && ! -L "$staged_driver" ]] \
        || die "Refusing unexpected staged-driver path: $staged_driver"
    [[ ! -L "$BUILD_ROOT" ]] || die "Refusing symlinked build root: $BUILD_ROOT"
    mkdir -p "$BUILD_ROOT"

    unlock_root() {
        if [[ $ro_was_enabled -eq 1 && $root_unlocked -eq 0 ]]; then
            root_unlocked=1
            as_root steamos-readonly disable
        fi
    }
    relock_root() {
        if [[ $root_unlocked -eq 1 ]]; then
            as_root steamos-readonly enable
            root_unlocked=0
        fi
    }

    cleanup_setup() {
        local rc=$?
        trap - EXIT
        if [[ $committed -eq 0 && $rc -ne 0 ]]; then
            relock_root || rc=1
            recover_install_transaction || rc=1
            recover_fsr4_install_transaction || rc=1
        fi
        if [[ -e "$staged_driver" || -L "$staged_driver" ]]; then
            unlock_root || rc=1
            as_root rm -f "$staged_driver" >/dev/null 2>&1 || rc=1
        fi
        relock_root || rc=1
        if [[ $rc -ne 0 && "$profile" == default ]]; then
            report_fsr4_preserved || rc=1
        fi
        rm -rf "$work"
        exit "$rc"
    }
    trap cleanup_setup EXIT

    if command -v steamos-readonly >/dev/null 2>&1 \
        && steamos-readonly status 2>/dev/null | grep -qi enabled; then
        ro_was_enabled=1
    fi

    local required_commands=(gcc g++ git meson ninja patch pkg-config tar readelf ldd glslangValidator spirv-as)
    local development_packages=(
        glibc linux-api-headers libdrm expat libelf zlib zstd wayland wayland-protocols
        libffi libxau libxdmcp xorgproto libxcb xcb-util xcb-util-wm
        xcb-util-keysyms xcb-util-renderutil xcb-util-image libx11 libxext
        libxdamage libxfixes libxrandr libxshmfence libxxf86vm libxrender
    )
    local command
    for command in "${required_commands[@]}"; do
        command -v "$command" >/dev/null 2>&1 || need_packages=1
    done
    printf '#include <errno.h>\nint main(void) { return ETIME; }\n' \
        | gcc -x c -fsyntax-only - >/dev/null 2>&1 || need_packages=1
    python3 -c 'import mako, packaging, yaml' >/dev/null 2>&1 || need_packages=1
    for command in libdrm_amdgpu expat zlib libzstd libelf wayland-client xcb; do
        pkg-config --exists "$command" 2>/dev/null || need_packages=1
    done
    if [[ $need_packages -eq 1 ]]; then
        command -v steamos-readonly >/dev/null 2>&1 || die "SteamOS package prerequisites are missing."
        unlock_root
        as_root pacman-key --init
        as_root pacman-key --populate archlinux holo 2>/dev/null || as_root pacman-key --populate
        as_root pacman -S --needed --noconfirm \
            base-devel curl git meson ninja python python-mako python-packaging python-yaml \
            pkgconf glslang spirv-tools util-linux lib32-vulkan-radeon \
            "${development_packages[@]}"
        # SteamOS images can record these packages while omitting development
        # files, so force a signed reinstall instead of trusting --needed.
        as_root pacman -S --noconfirm "${development_packages[@]}"
        relock_root
    fi
    for command in "${required_commands[@]}"; do
        command -v "$command" >/dev/null 2>&1 \
            || die "Signed SteamOS packages did not provide required tool: $command"
    done
    printf '#include <errno.h>\nint main(void) { return ETIME; }\n' \
        | gcc -x c -fsyntax-only - >/dev/null 2>&1 \
        || die "Signed SteamOS packages did not provide required C development headers"
    python3 -c 'import mako, packaging, yaml' >/dev/null 2>&1 \
        || die "Signed SteamOS packages did not provide required Python build modules"
    for command in libdrm_amdgpu expat zlib libzstd libelf wayland-client xcb; do
        pkg-config --exists "$command" 2>/dev/null \
            || die "Signed SteamOS packages did not provide development metadata: $command"
    done

    stage_upstream "$profile"
    if [[ "$profile" == fsr4 ]]; then
        verify_fsr4_patch || die "The upstream FSR4 patch failed checksum verification."
    fi

    source="$MESA_SOURCE"
    build="$MESA_BUILD"
    output="$MESA_OUTPUT"
    export TMPDIR="$STATE_DIR/tmp"
    mkdir -p "$TMPDIR"

    if [[ "$profile" == fsr4 && $default_ready -eq 1 ]] \
        && verify_current_fsr4_runtime \
        && verify_cached_build fsr4 "$STORED_FSR4_DRIVER_SHA" \
        && [[ "$BUILD_STATE_DRIVER_SHA" != "$STORED_DRIVER_SHA" ]]; then
        cache_profile=fsr4
        log "Reusing the verified FSR4 Mesa build output."
    else
        expected_sha=""
        if verify_current_runtime; then expected_sha=$STORED_DRIVER_SHA; fi
        if verify_cached_build base "$expected_sha"; then
            cache_profile=base
            log "Reusing the verified FSR4 RADV build output."
        else
            log "Preparing a clean pinned Mesa tree for the async-compute base build."
            rm -f "$BUILD_STATE"
            rm -rf "$source"
            git clone --no-checkout "$MESA_GIT_CACHE" "$source"
            git -C "$source" checkout --detach "$MESA_COMMIT"
            [[ "$(git -C "$source" rev-parse HEAD)" == "$MESA_COMMIT" ]] \
                || die "Mesa worktree does not match pinned commit $MESA_COMMIT"
            mkdir -p "$source/subprojects/packagecache"
            cp "$CACHE_DIR/$LIBDRM_TARBALL" "$source/subprojects/packagecache/"
            local patch_name
            for patch_name in \
                0001-gfx1013-compute-queue-fix.patch \
                0005-bc250-fsr4-v3.patch \
                0006-bc250-fsr4-combined-unroll.patch \
                0007-bc250-fsr4-imageprep-texture.patch \
                0008-bc250-fsr4-resolution-variants.patch \
                0009-bc250-fsr4-production-defaults.patch; do
                patch -d "$source" -p1 --fuzz=0 --no-backup-if-mismatch \
                    --dry-run -i "$CACHE_DIR/$patch_name"
                patch -d "$source" -p1 --fuzz=0 --no-backup-if-mismatch \
                    -i "$CACHE_DIR/$patch_name"
            done
            grep -qF has_async_compute_threadgroup_bug "$source/src/amd/common/ac_gpu_info.c" \
                || die "Patched Mesa source is missing the GFX1013 async-compute marker"
            grep -qF bc250-fsr4-integrated-v3 "$source/src/amd/vulkan/radv_physical_device.c" \
                && grep -qF bc250_imageprep_spirv "$source/src/amd/vulkan/radv_shader.c" \
                || die "Patched Mesa source is missing FSR4 markers"
            meson setup "$build" "$source" \
                -Dbuildtype=release \
                -Dvulkan-drivers=amd -Dgallium-drivers= -Dplatforms=x11,wayland \
                -Dglx=disabled -Degl=disabled -Dgles2=disabled -Dvideo-codecs= \
                -Dshared-llvm=disabled -Dllvm=disabled -Dxmlconfig=enabled \
                -Dlmsensors=disabled -Dvalgrind=disabled \
                -Dallow-fallback-for=libdrm -Dlibdrm:default_library=static
            ninja -C "$build" src/amd/vulkan/libvulkan_radeon.so
            validate_mesa_output "$output"
            write_build_state base
            cache_profile=base
        fi
    fi

    validate_mesa_output "$output"
    require_compute_kernel

    if [[ "$profile" == default ]]; then
        install_default_profile "$output" "$mesa_tag"
        report_fsr4_preserved
        committed=1
        return 0
    fi

    if [[ "$cache_profile" == base ]]; then
        base_driver_sha=$(sha256_file "$output")
        if [[ $default_ready -eq 0 ]]; then
            base_output="$work/libvulkan_radeon-async.so"
            install -m 0755 "$output" "$base_output"
            log "Installing the async-compute RADV prerequisite before the FSR4 profile."
            install_default_profile "$base_output" "$mesa_tag"
            verify_current_runtime \
                || die "The automatically installed async-compute RADV prerequisite failed validation."
            default_ready=1
            default_bootstrapped=1
        fi
        log "Replacing the duplicated compute-queue patch with the pinned legacy FSR4 V3 patch."
        patch -d "$source" -R -p1 --fuzz=0 --dry-run \
            -i "$CACHE_DIR/0001-gfx1013-compute-queue-fix.patch"
        patch -d "$source" -R -p1 --fuzz=0 \
            -i "$CACHE_DIR/0001-gfx1013-compute-queue-fix.patch"
        patch -d "$source" -p1 --fuzz=0 --dry-run -i "$FSR4_PATCH"
        patch -d "$source" -p1 --fuzz=0 -i "$FSR4_PATCH"
        grep -qF bc250_lower_dense_sdot4x8 "$source/src/amd/vulkan/radv_shader.c" \
            && grep -qF 'debug_get_bool_option("RADV_GFX103"' \
                "$source/src/amd/vulkan/radv_physical_device.c" \
            || die "Patched Mesa source is missing the legacy FSR4 V3 markers"
        log "Incrementally rebuilding only the Mesa targets affected by legacy FSR4 V3."
        ninja -C "$build" src/amd/vulkan/libvulkan_radeon.so
        validate_mesa_output "$output"
        [[ "$(sha256_file "$output")" != "$base_driver_sha" ]] \
            || die "Incremental FSR4 build did not change the async-compute driver."
        write_build_state fsr4
    fi

    ! cmp -s "$output" "$DRIVER" \
        || die "Refusing to install an FSR4 profile identical to the global async-compute driver."

    if [[ "$profile" == fsr4 ]]; then
        local profile_stage="$work/fsr4" transaction_stage="$work/fsr4-transaction"
        local had_previous=0 transaction_tmp
        mkdir -m 0700 "$profile_stage"
        install -m 0755 "$output" "$profile_stage/libvulkan_radeon.so"
        render_fsr4_runner > "$profile_stage/bc250-fsr4-run"
        chmod 0755 "$profile_stage/bc250-fsr4-run"
        cat > "$profile_stage/radeon_fsr4_icd.x86_64.json" <<EOF
{
  "file_format_version": "1.0.1",
  "ICD": {"library_path": "$FSR4_DRIVER", "api_version": "1.4.354", "library_arch": "64"}
}
EOF
        chmod 0644 "$profile_stage/radeon_fsr4_icd.x86_64.json"
        printf '%s %s %s %s %s\n' \
            "$(sha256_file "$profile_stage/libvulkan_radeon.so")" \
            "$(sha256_file "$profile_stage/radeon_fsr4_icd.x86_64.json")" \
            "$(sha256_file "$profile_stage/bc250-fsr4-run")" \
            "$DEFAULT_MESA_TAG" "$FSR4_PROFILE_SHA256" > "$profile_stage/install.conf"
        chmod 0600 "$profile_stage/install.conf"
        mkdir -m 0700 "$transaction_stage"
        if [[ -d "$FSR4_DIR" ]]; then
            cp -a "$FSR4_DIR" "$transaction_stage/previous"
            if ! { cmp -s "$FSR4_DRIVER" "$transaction_stage/previous/libvulkan_radeon.so" \
                && cmp -s "$FSR4_ICD" "$transaction_stage/previous/radeon_fsr4_icd.x86_64.json" \
                && cmp -s "$FSR4_RUNNER" "$transaction_stage/previous/bc250-fsr4-run" \
                && cmp -s "$FSR4_MANIFEST" "$transaction_stage/previous/install.conf"; }; then
                die "Could not verify the previous FSR4 profile backup."
            fi
            had_previous=1
        fi
        printf 'prepared %s\n' "$had_previous" > "$transaction_stage/transaction.conf"
        if [[ "$had_previous" == 1 ]]; then
            fsync_paths "$transaction_stage/previous/libvulkan_radeon.so" \
                "$transaction_stage/previous/radeon_fsr4_icd.x86_64.json" \
                "$transaction_stage/previous/bc250-fsr4-run" \
                "$transaction_stage/previous/install.conf" "$transaction_stage/previous"
        fi
        fsync_paths "$transaction_stage/transaction.conf" "$transaction_stage"
        mv "$transaction_stage" "$FSR4_TRANSACTION_DIR"
        fsync_paths "$STATE_DIR"
        transaction_tmp=$(mktemp "$FSR4_TRANSACTION_DIR/.transaction.XXXXXX")
        printf 'swapping %s\n' "$had_previous" > "$transaction_tmp"
        fsync_paths "$transaction_tmp"
        mv -f "$transaction_tmp" "$FSR4_TRANSACTION_DIR/transaction.conf"
        fsync_paths "$FSR4_TRANSACTION_DIR/transaction.conf" "$FSR4_TRANSACTION_DIR"
        rm -rf "$FSR4_DIR"
        if ! mv "$profile_stage" "$FSR4_DIR"; then
            recover_fsr4_install_transaction
            die "Could not install the private FSR4 profile."
        fi
        if ! verify_current_fsr4_runtime; then
            recover_fsr4_install_transaction
            die "Installed FSR4 profile failed attestation; the previous profile was restored."
        fi
        fsync_paths "$FSR4_DRIVER" "$FSR4_ICD" "$FSR4_RUNNER" "$FSR4_MANIFEST" \
            "$FSR4_DIR" "$STATE_DIR"
        rm -rf "$FSR4_TRANSACTION_DIR"
        fsync_paths "$STATE_DIR"
        committed=1
        log "Installed the legacy experimental FSR4 V3 profile for private per-game activation."
        log "Steam launch option: $FSR4_RUNNER %command%"
        if [[ $default_bootstrapped -eq 1 ]]; then
            log "The global async-compute runtime was installed as the FSR4 prerequisite."
        else
            log "The global Vulkan environment was not changed."
        fi
        return 0
    fi
)

manage_games() {
    local action="$1" executable="${2:-}" name="${3:-}"
    [[ ! -L "$DRIRC" ]] || die "Refusing symlinked driconf file: $DRIRC"
    if [[ "$action" != list && "$action" != list-json ]]; then ensure_state_dir; fi
    python3 - "$action" "$executable" "$name" "$DRIRC" <<'PY'
from html import escape
import json
from pathlib import Path
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

action, executable, name, drirc_name = sys.argv[1:]
drirc_path = Path(drirc_name)
begin = "<!-- BEGIN BC250 MESH SHADER MANAGED -->"
end = "<!-- END BC250 MESH SHADER MANAGED -->"
drirc_existed = drirc_path.exists()
try:
    content = drirc_path.read_text()
except FileNotFoundError:
    content = "<driconf>\n</driconf>\n"

pattern = re.compile(r"\s*" + re.escape(begin) + r".*?" + re.escape(end) + r"\s*", re.S)
if content.count(begin) != content.count(end) or content.count(begin) > 1:
    raise SystemExit("malformed or duplicate BC-250 managed block in ~/.drirc")
if begin in content and content.index(end) < content.index(begin):
    raise SystemExit("reversed BC-250 managed block in ~/.drirc")
try:
    ET.fromstring(content)
except ET.ParseError as error:
    raise SystemExit("existing ~/.drirc is not valid XML: %s" % error)

games = []
match = pattern.search(content)
if match:
    managed = content[match.start():match.end()]
    start = managed.index(begin) + len(begin)
    finish = managed.index(end)
    try:
        device = ET.fromstring(managed[start:finish].strip())
    except ET.ParseError as error:
        raise SystemExit("managed BC-250 block is not valid XML: %s" % error)
    for application in device.findall("application"):
        value = application.get("executable")
        if value:
            games.append({"executable": value, "name": application.get("name") or value})

if action == "enable":
    if not executable or any(ord(c) < 32 for c in executable) or len(executable) > 256:
        raise SystemExit("executable must be a non-empty printable process name")
    if not name:
        name = executable
    if any(ord(c) < 32 for c in name) or len(name) > 256:
        raise SystemExit("friendly name must be printable and at most 256 characters")
    games = [game for game in games if game["executable"] != executable]
    games.append({"executable": executable, "name": name})
    games.sort(key=lambda game: game["executable"].lower())
elif action == "disable":
    games = [game for game in games if game["executable"] != executable]
elif action == "clear":
    games = []
elif action == "list":
    for game in games:
        print("%s\t%s" % (game["executable"], game["name"]))
    raise SystemExit(0)
elif action == "list-json":
    print(json.dumps(games, ensure_ascii=True, separators=(",", ":")))
    raise SystemExit(0)
else:
    raise SystemExit("unknown game action")

content = pattern.sub("\n", content, count=1)
if games:
    lines = [begin, '  <device driver="radv">']
    for game in games:
        lines.extend([
            '    <application name="%s" executable="%s">' %
            (escape(game["name"], quote=True), escape(game["executable"], quote=True)),
            '    </application>',
        ])
    lines.extend(['  </device>', end])
    index = content.rfind("</driconf>")
    content = content[:index].rstrip() + "\n" + "\n".join(lines) + "\n" + content[index:]
try:
    ET.fromstring(content)
except ET.ParseError as error:
    raise SystemExit("managed game data would produce invalid XML: %s" % error)

if drirc_existed or games:
    drirc_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".bc250-drirc.", dir=str(drirc_path.parent))
    with open(descriptor, "w") as output:
        output.write(content)
    Path(temporary).chmod(0o600)
    Path(temporary).replace(drirc_path)
PY
}

cmd_game() {
    die "Per-game controls were removed; the Mesa / RADV async-compute patch is global for the user session."
}

cmd_legacy_clear() {
    require_normal_user
    command -v flock >/dev/null 2>&1 || die "flock is required"
    ensure_state_dir
    exec 9> "$LOCK_FILE"
    flock 9
    recover_fsr4_install_transaction
    manage_games clear
    log "Cleared migration records from the older per-game workflow."
    log "Confirm MESA_DRICONF_EXECUTABLE_OVERRIDE and VK_ICD_FILENAMES were removed from those games' Steam launch options."
}

fsr4_dll_probe() {
    [[ -f "$FSR4_DLL_TOOL" && ! -L "$FSR4_DLL_TOOL" ]] || return 2
    bash "$FSR4_DLL_TOOL" probe
}

fsr4_dll_count() {
    [[ -f "$FSR4_DLL_TOOL" && ! -L "$FSR4_DLL_TOOL" ]] || { printf '0\n'; return; }
    bash "$FSR4_DLL_TOOL" count
}

cmd_status() {
    local failed=0 fsr4_dll_rc=0 fsr4_dll_installs
    echo "BC-250 Mesa / RADV async-compute patch"
    echo "  upstream: $UPSTREAM_REPO @ ${UPSTREAM_COMMIT:0:7}"
    if verify_compute_kernel; then
        echo "  kernel:  patched AMDGPU module installed and active"
    else
        echo "  kernel:  repair not active"
        failed=2
    fi
    if verify_scheduler_active; then
        echo "  policy:  active (amdgpu.sched_policy=2)"
    elif verify_scheduler_configured; then
        echo "  policy:  configured; reboot required"
    else
        echo "  policy:  disabled until RADV setup completes"
    fi
    if verify_current_runtime; then
        echo "  runtime: installed ($STORED_MESA_TAG)"
        echo "  driver:  $DRIVER"
        echo "  ICD:     $ICD"
    elif verify_owned_runtime; then
        echo "  runtime: legacy install requires '$0 setup'"
        if [[ -z "$STORED_PROFILE_REVISION" ]]; then
            echo "  warning: the active legacy driver may contain unsafe mesh/task patches; rebuild and sign out before launching games"
        fi
        failed=2
    elif [[ -e "$DRIVER" || -L "$DRIVER" || -e "$ICD" || -L "$ICD" \
        || -e "$GENERATOR" || -L "$GENERATOR" || -e "$MANIFEST" || -e "$TRANSACTION_DIR" ]]; then
        echo "  runtime: incomplete or ownership mismatch"
        failed=2
    else
        echo "  runtime: not installed"
        failed=1
    fi
    if [[ -e "$DRIVER" || -L "$DRIVER" || -e "$ICD" || -L "$ICD" ]]; then
        echo "  activation: global user environment"
        echo "  generator:  $GENERATOR"
    fi
    fsr4_dll_probe >/dev/null 2>&1 || fsr4_dll_rc=$?
    if ! fsr4_dll_installs=$(fsr4_dll_count); then
        fsr4_dll_installs=${fsr4_dll_installs:-1}
        fsr4_dll_rc=2
    fi
    if [[ $fsr4_dll_rc -eq 0 ]]; then
        echo "  FSR4 RC9:  installed ($fsr4_dll_installs game-local DLL target(s))"
    elif [[ $fsr4_dll_rc -eq 1 ]]; then
        echo "  FSR4 RC9:  not installed"
    else
        echo "  FSR4 RC9:  incomplete or ownership mismatch"
        failed=2
    fi
    if [[ -e "$FSR4_TRANSACTION_DIR" || -L "$FSR4_TRANSACTION_DIR" ]]; then
        echo "  legacy FSR4 V3: interrupted installation requires recovery"
        failed=2
    elif verify_current_fsr4_runtime; then
        echo "  legacy FSR4 V3: installed (experimental private RADV profile)"
        echo "  launcher:  $FSR4_RUNNER"
    elif verify_owned_fsr4_runtime; then
        echo "  legacy FSR4 V3: previous patch composition; remove with '$0 uninstall --fsr4-legacy'"
        echo "  warning: do not launch the recorded runner until that rebuild completes"
        failed=2
    elif [[ -e "$FSR4_DIR" || -L "$FSR4_DIR" ]]; then
        echo "  legacy FSR4 V3: incomplete or ownership mismatch"
        failed=2
    else
        echo "  legacy FSR4 V3: not installed"
    fi
    local legacy_games
    if ! legacy_games=$(manage_games list); then
        echo "  legacy games: configuration invalid"
        return 2
    elif [[ -n "$legacy_games" ]]; then
        echo "  legacy games requiring Steam launch-option cleanup:"
        printf '%s\n' "$legacy_games" | sed 's/^/    /'
    fi
    return "$failed"
}

cmd_status_json() {
    local runtime_state="not-installed" mesa_version="" config_valid=1 error="" games="[]" kernel_ready=0
    local global_enabled=0 restart_required=0 scheduler_configured=0 scheduler_active=0
    local fsr4_state="not-installed" fsr4_dll_state="not-installed" fsr4_dll_install_count=0 fsr4_dll_rc=0
    verify_compute_kernel && kernel_ready=1
    verify_scheduler_configured && scheduler_configured=1
    verify_scheduler_active && scheduler_active=1
    if verify_current_runtime; then
        runtime_state="ready"
        mesa_version="$STORED_MESA_TAG"
        if manager_environment_active; then
            global_enabled=1
        elif [[ $kernel_ready == 1 && $scheduler_configured == 1 ]]; then
            restart_required=1
        fi
    elif verify_owned_runtime; then
        runtime_state="invalid"
        mesa_version="$STORED_MESA_TAG"
    elif [[ -e "$DRIVER" || -L "$DRIVER" || -e "$ICD" || -L "$ICD" \
        || -e "$GENERATOR" || -L "$GENERATOR" || -e "$MANIFEST" || -e "$TRANSACTION_DIR" ]]; then
        runtime_state="invalid"
        if read_manifest; then mesa_version="$STORED_MESA_TAG"; fi
    fi
    fsr4_dll_probe >/dev/null 2>&1 || fsr4_dll_rc=$?
    if ! fsr4_dll_install_count=$(fsr4_dll_count); then
        fsr4_dll_install_count=${fsr4_dll_install_count:-1}
        fsr4_dll_rc=2
    fi
    if [[ $fsr4_dll_rc -eq 0 ]]; then
        fsr4_dll_state="ready"
    elif [[ $fsr4_dll_rc -gt 1 ]]; then
        fsr4_dll_state="invalid"
    fi
    if [[ -e "$FSR4_TRANSACTION_DIR" || -L "$FSR4_TRANSACTION_DIR" ]]; then
        fsr4_state="invalid"
    elif verify_current_fsr4_runtime; then
        fsr4_state="ready"
    elif [[ -e "$FSR4_DIR" || -L "$FSR4_DIR" ]]; then
        fsr4_state="invalid"
    fi
    if ! games=$(manage_games list-json 2>&1); then
        config_valid=0
        error="$games"
        games="[]"
    fi
    python3 - "$runtime_state" "$mesa_version" "$ICD" "$config_valid" "$error" "$games" "$kernel_ready" "$global_enabled" "$restart_required" "$scheduler_configured" "$scheduler_active" "$fsr4_state" "$FSR4_ICD" "$FSR4_RUNNER" "$fsr4_dll_state" "$fsr4_dll_install_count" <<'PY'
import json
import sys

runtime_state, mesa_version, icd_path, config_valid, error, games, kernel_ready, global_enabled, restart_required, scheduler_configured, scheduler_active, fsr4_state, fsr4_icd, fsr4_runner, fsr4_dll_state, fsr4_dll_install_count = sys.argv[1:]
print(json.dumps({
    "scriptAvailable": True,
    "runtimeState": runtime_state,
    "mesaVersion": mesa_version or None,
    "icdPath": icd_path,
    "configValid": config_valid == "1",
    "error": error or None,
    "games": json.loads(games),
    "kernelReady": kernel_ready == "1",
    "schedulerConfigured": scheduler_configured == "1",
    "schedulerActive": scheduler_active == "1",
    "globalEnabled": global_enabled == "1",
    "restartRequired": restart_required == "1",
    "fsr4State": fsr4_state,
    "fsr4IcdPath": fsr4_icd,
    "fsr4RunnerPath": fsr4_runner,
    "fsr4DllState": fsr4_dll_state,
    "fsr4DllInstallCount": int(fsr4_dll_install_count),
}, ensure_ascii=True, separators=(",", ":")))
PY
}

cmd_uninstall_fsr4() (
    require_normal_user
    command -v flock >/dev/null 2>&1 || die "flock is required"
    ensure_state_dir
    exec 9> "$LOCK_FILE"
    flock 9
    recover_fsr4_install_transaction
    if [[ ! -e "$FSR4_DIR" && ! -L "$FSR4_DIR" ]]; then
        log "The private FSR4 profile is not installed."
        return 0
    fi
    verify_owned_fsr4_runtime \
        || die "FSR4 profile is not a recorded toolkit install; refusing removal."
    rm -rf "$FSR4_DIR"
    log "Removed the private FSR4 profile. The global RADV runtime was unchanged."
)

cmd_setup_fsr4_dll() {
    require_normal_user
    [[ -f "$FSR4_DLL_TOOL" && ! -L "$FSR4_DLL_TOOL" ]] \
        || die "The BC-250 FSR4 DLL installer is unavailable: $FSR4_DLL_TOOL"
    bash "$FSR4_DLL_TOOL" install "$1"
}

cmd_uninstall_fsr4_dll() {
    require_normal_user
    [[ -f "$FSR4_DLL_TOOL" && ! -L "$FSR4_DLL_TOOL" ]] \
        || die "The BC-250 FSR4 DLL installer is unavailable: $FSR4_DLL_TOOL"
    bash "$FSR4_DLL_TOOL" uninstall "$1"
}

cmd_uninstall() (
    require_normal_user
    local ro_was_enabled=0 legacy_games environment
    ensure_state_dir
    command -v flock >/dev/null 2>&1 || die "flock is required"
    command -v systemctl >/dev/null 2>&1 || die "systemctl is required for global RADV removal"
    exec 9> "$LOCK_FILE"
    flock 9
    recover_install_transaction
    recover_fsr4_install_transaction
    if [[ -e "$FSR4_DIR" || -L "$FSR4_DIR" ]]; then
        verify_owned_fsr4_runtime \
            || die "FSR4 profile is not a recorded toolkit install; refusing removal."
    fi
    restore_readonly() {
        local rc=$?
        trap - EXIT INT TERM HUP
        if [[ $ro_was_enabled -eq 1 ]]; then as_root steamos-readonly enable || rc=1; fi
        exit "$rc"
    }
    trap restore_readonly EXIT INT TERM HUP
    if [[ -e "$DRIVER" || -L "$DRIVER" || -e "$ICD" || -L "$ICD" \
        || -e "$GENERATOR" || -L "$GENERATOR" || -e "$MANIFEST" ]]; then
        verify_recorded_parts \
            || die "Alternate runtime is not a recorded toolkit install; refusing removal."
    fi
    legacy_games=$(manage_games list) \
        || die "Legacy game configuration is invalid; repair it before uninstall."
    [[ -z "$legacy_games" ]] \
        || die "Legacy per-game records remain. Remove their Steam launch options, run '$0 legacy-clear', then uninstall."
    # Clean user configuration first. If this fails, leave the runtime intact
    # so uninstall can be retried without creating a half-removed component.
    manage_games clear
    if [[ -e "$GENERATOR" || -L "$GENERATOR" ]]; then
        if command -v steamos-readonly >/dev/null 2>&1 \
            && steamos-readonly status 2>/dev/null | grep -qi enabled; then
            ro_was_enabled=1
            as_root steamos-readonly disable
        fi
        as_root rm -f "$GENERATOR"
        if [[ $ro_was_enabled == 1 ]]; then
            as_root steamos-readonly enable
            ro_was_enabled=0
        fi
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload >/dev/null 2>&1 \
            || die "Could not deactivate the global Vulkan environment; retry uninstall."
        environment=$(systemctl --user show-environment 2>/dev/null) || environment=
        ! grep -qxF "VK_DRIVER_FILES=$GLOBAL_ICDS" <<< "$environment" \
            && ! grep -qxF "VK_ICD_FILENAMES=$GLOBAL_ICDS" <<< "$environment" \
            || die "Global Vulkan environment remains active; sign out and retry uninstall."
    fi
    if [[ "$COMPUTE_MODULE" == "$DEFAULT_COMPUTE_MODULE" \
        && "$COMPUTE_MARKER" == "$DEFAULT_COMPUTE_MARKER" \
        && "$SCHED_POLICY" == "$DEFAULT_SCHED_POLICY" \
        && -f "$BOOT_CONFIG" && ! -L "$BOOT_CONFIG" ]]; then
        as_root env BC250_FORCE_GRUB_REGEN=1 bash "$BOOT_CONFIG" policy-remove
    fi
    if [[ "$SCHED_POLICY" == "$DEFAULT_SCHED_POLICY" ]] \
        && verify_scheduler_active; then
        die "amdgpu.sched_policy=2 remains active for this boot. Reboot to deactivate it, then rerun uninstall; the patched RADV runtime was left intact."
    fi
    if [[ -e "$FSR4_DIR" || -L "$FSR4_DIR" ]]; then rm -rf "$FSR4_DIR"; fi
    if [[ -e "$DRIVER" || -L "$DRIVER" ]]; then
        if command -v steamos-readonly >/dev/null 2>&1 \
            && steamos-readonly status 2>/dev/null | grep -qi enabled; then
            ro_was_enabled=1
            as_root steamos-readonly disable
        fi
        as_root rm -f "$DRIVER"
    fi
    rm -f "$ICD" "$MANIFEST"
    log "Removed the alternate RADV driver, ICD, global environment generator, and legacy game entries."
    log "Sign out and back in to clear the inherited Vulkan environment."
    log "Downloaded upstream patch and Mesa build output were preserved for rebuilds."
)

cmd_purge() (
    require_normal_user
    command -v flock >/dev/null 2>&1 || die "flock is required"
    mkdir -p "${LOCK_FILE%/*}"
    [[ ! -L "$LOCK_FILE" ]] || die "Refusing symlinked lock file: $LOCK_FILE"
    exec 9> "$LOCK_FILE"
    flock 9
    mkdir -p "${FSR4_DLL_LOCK%/*}"
    [[ ! -L "$FSR4_DLL_LOCK" ]] || die "Refusing symlinked FSR4 DLL lock file: $FSR4_DLL_LOCK"
    exec 8> "$FSR4_DLL_LOCK"
    flock 8
    [[ ! -e "$DRIVER" && ! -L "$DRIVER" && ! -e "$ICD" && ! -L "$ICD" \
        && ! -e "$GENERATOR" && ! -L "$GENERATOR" \
        && ! -e "$MANIFEST" && ! -e "$TRANSACTION_DIR" \
        && ! -e "$FSR4_DIR" && ! -L "$FSR4_DIR" \
        && ! -e "$FSR4_TRANSACTION_DIR" && ! -L "$FSR4_TRANSACTION_DIR" ]] \
        || die "Mesa / RADV runtime remains; run '$0 uninstall' before purge."
    if [[ -x "$FSR4_DLL_TOOL" && ! -L "$FSR4_DLL_TOOL" ]]; then
        [[ "$(fsr4_dll_count)" -eq 0 ]] \
            || die "Game-local FSR4 DLL rollback records remain; uninstall those targets before purge."
    else
        [[ ! -e "$FSR4_DLL_STATE" && ! -L "$FSR4_DLL_STATE" ]] \
            || die "FSR4 DLL rollback state exists but its helper is unavailable; refusing purge."
    fi
    if grep -qF '<!-- BEGIN BC250 MESH SHADER MANAGED -->' "$DRIRC" 2>/dev/null; then
        die "Managed game entries remain; run '$0 uninstall' before purge."
    fi
    [[ ! -L "$STATE_DIR" ]] || die "Refusing symlinked state directory: $STATE_DIR"
    rm -rf "$STATE_DIR"
    log "Removed downloaded patch and toolkit-owned Mesa build cache."
)

menu_select() {
    local title="$1"
    shift
    local items=("$@") n=$# cur=0 key rest i label badge hint label_width=0
    for i in "${!items[@]}"; do
        IFS='|' read -r label badge hint <<< "${items[$i]}"
        if ((${#label} > label_width)); then label_width=${#label}; fi
    done
    printf '\033[?25l'
    TUI_CURSOR_HIDDEN=1
    while true; do
        printf '\033[H\033[2J'
        printf '\r\033[K%s\n' "${CB}${CC}${title}${C0}"
        printf '\033[K%s\n' "${CB}${CC}  CONTROLS  [Up/Down or J/K] Move  [Enter] Select  [Q/Esc] Back${C0}"
        printf '\033[K\n'
        for i in "${!items[@]}"; do
            IFS='|' read -r label badge hint <<< "${items[$i]}"
            if [[ $i -eq $cur ]]; then
                printf '\033[K  %s > %-*s %s %s\n' "${CI}${CB}" "$label_width" "$label" "${C0}" "$badge"
            else
                printf '\033[K     %-*s  %s\n' "$label_width" "$label" "$badge"
            fi
        done
        IFS='|' read -r label badge hint <<< "${items[$cur]}"
        printf '\033[K\n\033[K%s\n' "  ${CD}${hint}${C0}"
        IFS= read -rsn1 key || { tui_show_cursor; return 1; }
        if [[ $key == $'\033' ]]; then
            rest=""
            IFS= read -rsn2 -t 0.05 rest || true
            key+="$rest"
        fi
        case "$key" in
            $'\033[A'|k) if ((cur > 0)); then cur=$((cur - 1)); else cur=$((n - 1)); fi ;;
            $'\033[B'|j) if ((cur < n - 1)); then cur=$((cur + 1)); else cur=0; fi ;;
            "") MENU_CHOICE=$cur; tui_show_cursor; return 0 ;;
            q|Q|$'\033') tui_show_cursor; return 1 ;;
        esac
    done
}

pause_key() {
    echo
    printf '%s' "${CD}-- press any key to return to the menu --${C0}"
    IFS= read -rsn1 || true
    printf '\r\033[K'
}

runtime_badge() {
    if verify_current_runtime; then
        printf '%s' "${CG}[ready]${C0}"
    elif verify_owned_runtime; then
        printf '%s' "${CY}[upgrade]${C0}"
    elif [[ -e "$DRIVER" || -L "$DRIVER" || -e "$ICD" || -L "$ICD" \
        || -e "$GENERATOR" || -L "$GENERATOR" || -e "$MANIFEST" || -e "$TRANSACTION_DIR" ]]; then
        printf '%s' "${CR}[repair]${C0}"
    else
        printf '%s' "${CY}[setup]${C0}"
    fi
}

legacy_fsr4_badge() {
    if [[ -e "$FSR4_TRANSACTION_DIR" || -L "$FSR4_TRANSACTION_DIR" ]]; then
        printf '%s' "${CR}[recover]${C0}"
    elif verify_current_fsr4_runtime; then
        printf '%s' "${CG}[ready]${C0}"
    elif [[ -e "$FSR4_DIR" || -L "$FSR4_DIR" ]]; then
        printf '%s' "${CR}[repair]${C0}"
    else
        printf '%s' "${CY}[setup]${C0}"
    fi
}

fsr4_dll_badge() {
    local rc=0
    fsr4_dll_probe >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) printf '%s' "${CG}[ready]${C0}" ;;
        1) printf '%s' "${CY}[setup]${C0}" ;;
        *) printf '%s' "${CR}[repair]${C0}" ;;
    esac
}

run_menu_action() {
    local rc=0
    echo
    bash "$SELF" "$@" || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s\n' "${CR}${CB}[bc250-mesh]${C0} action failed (exit $rc)"
    fi
    pause_key
}

show_menu_status() {
    local rc=0
    echo
    cmd_status || rc=$?
    if [[ $rc -gt 1 ]]; then
        printf '%s\n' "${CR}${CB}[bc250-mesh]${C0} status failed (exit $rc)"
    fi
    pause_key
}

confirm_menu_action() {
    local prompt="$1" answer
    shift
    printf '%s' "${CB}${prompt} [y/N] ${C0}"
    IFS= read -r answer
    case "$answer" in
        y|Y|yes|YES) run_menu_action "$@" ;;
        *) log "Cancelled."; pause_key ;;
    esac
}

prompt_fsr4_target() {
    local target
    printf '%s' "${CB}Exact existing DLL file (absolute path recommended; no quotes): ${C0}"
    IFS= read -r target
    if [[ -z "$target" ]]; then log "Cancelled."; pause_key; return; fi
    run_menu_action setup --fsr4 "$target"
}

cmd_menu() {
    require_normal_user
    [[ -t 0 && -t 1 ]] \
        || die "The menu needs an interactive terminal. Use '$0 help' for CLI commands."
    while true; do
        local runtime_state fsr4_state legacy_fsr4_state
        runtime_state=$(runtime_badge)
        fsr4_state=$(fsr4_dll_badge)
        legacy_fsr4_state=$(legacy_fsr4_badge)
        local legacy_games legacy_state
        if ! legacy_games=$(manage_games list 2>/dev/null); then
            legacy_state="${CR}[invalid]${C0}"
        elif [[ -n "$legacy_games" ]]; then
            legacy_state="${CY}[cleanup needed]${C0}"
        else
            legacy_state="${CD}[not needed]${C0}"
        fi
        local items=(
            "Status overview|${runtime_state}|Verify the patched AMDGPU module, scheduler policy, RADV runtime, and global activation."
            "Install FSR4 RC9 game DLL (recommended)|${fsr4_state}|Portable FSR4 route. Replaces one exact existing DLL and retains the original; no custom RADV installation is needed."
            "Install / resume FSR4 RADV|${runtime_state}|Installs AMDGPU first when needed, then builds async compute plus the FSR4 v4 driver for GE Proton."
            "Older per-game setup cleanup|${legacy_state}|Migration only: remove old MESA_DRICONF_EXECUTABLE_OVERRIDE and VK_ICD_FILENAMES Steam launch options, then clear their records."
            "Uninstall Mesa / RADV runtime|${runtime_state}|Remove the alternate driver, ICD, and user environment generator; preserve build caches."
            "Full help||Show CLI commands, activation behavior, and upstream source."
        )
        menu_select "BC-250 GPU driver and FSR4" "${items[@]}" \
            || { echo; break; }
        case $MENU_CHOICE in
            0) show_menu_status ;;
            1) prompt_fsr4_target ;;
            2) confirm_menu_action \
                "Install or resume FSR4 RADV and its AMDGPU prerequisite? This is not required for the portable FSR4 RC9 route." setup ;;
            3) confirm_menu_action \
                "Have you removed MESA_DRICONF_EXECUTABLE_OVERRIDE and VK_ICD_FILENAMES from the old per-game Steam launch options?" legacy-clear ;;
            4) confirm_menu_action \
                "Remove the global Mesa / RADV runtime?" uninstall ;;
            5) echo; cmd_help; pause_key ;;
        esac
    done
}

cmd_help() {
    cat <<EOF
Usage: $0 [menu|setup [--fsr4 TARGET_DLL|--fsr4-legacy]|status|status-json|legacy-clear|uninstall [--fsr4 TARGET_DLL|--fsr4-legacy]|purge|help]

  setup                        Fetch the verified upstream series, build the
                               audited Mesa RADV driver with GFX1013 async
                               compute, install a separate ICD, and configure
                               safe global activation. The default profile includes
                               the FSR4 v4 patches required by BC-250 GE
                               Proton. Usually takes 3-5 minutes.
  setup --fsr4 TARGET_DLL      Recommended FSR4 route. Replace one exact existing
                               game or OptiScaler DLL, retaining the original.
                               Absolute paths are recommended; quote spaces at the shell.
  setup --fsr4-legacy          Retired compatibility command; exits without
                               changing an existing legacy profile.
  status                       Verify the AMDGPU module, scheduler policy, and
                               global runtime ownership.
  status-json                  Print machine-readable runtime status.
  legacy-clear                Migration cleanup for older toolkit installs only.
                               First remove MESA_DRICONF_EXECUTABLE_OVERRIDE and
                               VK_ICD_FILENAMES from their Steam launch options.
  uninstall                    Remove the alternate ICD, legacy V3 profile, and global activation.
  uninstall --fsr4 TARGET_DLL  Restore one game-local DLL from its recorded backup.
  uninstall --fsr4-legacy      Remove only the private legacy V3 profile.
  purge                        After uninstall, remove patch/source/build caches.

The environment generator exports VK_DRIVER_FILES and VK_ICD_FILENAMES only
when the installed, selected, and active patched AMDGPU module validates and
amdgpu.sched_policy=2 is active. Fresh setup configures that policy only after
RADV is installed; reboot to activate both together. Sign out and back in after
an update when the policy is already active.
The patched ICD serves 64-bit processes; SteamOS's stock RADV serves 32-bit
processes through the same global driver list.

Legacy FSR4 V3 RADV setup has been retired. Existing recorded legacy profiles can
still be inspected and removed with 'uninstall --fsr4-legacy'.

Async-compute upstream (pinned to $UPSTREAM_COMMIT):
  $UPSTREAM_REPO
FSR4 patches (pinned to $FSR4_RADV_COMMIT):
  $FSR4_RADV_REPO
EOF
}

case "${1:-menu}" in
    menu) (($# <= 1)) || die "Usage: $0 menu"; cmd_menu ;;
    setup)
        if (($# == 1)); then cmd_setup default
        elif (($# == 3)) && [[ "$2" == --fsr4 ]]; then cmd_setup_fsr4_dll "$3"
        elif (($# == 2)) && [[ "$2" == --fsr4-legacy ]]; then
            die "Legacy FSR4 V3 builds are retired; use FSR4 RADV or the portable RC9 DLL."
        else die "Usage: $0 setup [--fsr4 TARGET_DLL|--fsr4-legacy]"
        fi ;;
    status) (($# == 1)) || die "Usage: $0 status"; cmd_status ;;
    status-json) (($# == 1)) || die "Usage: $0 status-json"; cmd_status_json ;;
    game) shift; cmd_game "$@" ;;
    legacy-clear) (($# == 1)) || die "Usage: $0 legacy-clear"; cmd_legacy_clear ;;
    uninstall)
        if (($# == 1)); then cmd_uninstall
        elif (($# == 3)) && [[ "$2" == --fsr4 ]]; then cmd_uninstall_fsr4_dll "$3"
        elif (($# == 2)) && [[ "$2" == --fsr4-legacy ]]; then cmd_uninstall_fsr4
        else die "Usage: $0 uninstall [--fsr4 TARGET_DLL|--fsr4-legacy]"
        fi ;;
    purge) (($# == 1)) || die "Usage: $0 purge"; cmd_purge ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; cmd_help ;;
    *) cmd_help >&2; exit 2 ;;
esac
