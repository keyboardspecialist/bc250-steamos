#!/usr/bin/env bash
# Build and manage DryhoppedIPA's alternate GFX1013 Mesa/RADV ICD.
# Its compute queues require the matching kernel repair from bc250-audio-fix.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
UPSTREAM_REPO="https://github.com/DryhoppedIPA/bc250-gfx1013-fix"
UPSTREAM_COMMIT="d3e6dc062c34d2523db0abe5741d1f5b0dea00d9"
LEGACY_UPSTREAM_COMMIT="b66203e012594204e5e3049856b28a2681112985"
RAW_BASE="https://raw.githubusercontent.com/DryhoppedIPA/bc250-gfx1013-fix/$UPSTREAM_COMMIT"
DEFAULT_MESA_TAG="mesa-26.2.0-rc3"
MESA_TARBALL="mesa-26.2.0-rc3.tar.xz"
MESA_URL="https://archive.mesa3d.org/$MESA_TARBALL"
MESA_SHA256="f733c005660d342a51c6727d1ad481f43d05b4c601ac72247fa641e1d73a8ad1"
LIBDRM_TARBALL="libdrm-2.4.133.tar.xz"
LIBDRM_URL="https://dri.freedesktop.org/libdrm/$LIBDRM_TARBALL"
LIBDRM_SHA256="fc68f9d0ba2ea63c9432a299e14fea09fad7a8a66e8039fcd7802ca59f77b4f5"

STATE_DIR="${BC250_MESH_STATE_DIR:-$HOME/.local/share/bc250-mesh-shader}"
CACHE_DIR="$STATE_DIR/upstream-$UPSTREAM_COMMIT"
MANIFEST="$STATE_DIR/install.conf"
TRANSACTION_DIR="$STATE_DIR/install-transaction"
DRIRC="${BC250_MESH_DRIRC:-$HOME/.drirc}"
DRIVER="${BC250_MESH_DRIVER:-/usr/lib/libvulkan_radeon_driconf.so}"
ICD="${BC250_MESH_ICD:-$HOME/radeon_driconf_icd.x86_64.json}"
FALLBACK_ICD="${BC250_MESH_32BIT_ICD:-/usr/share/vulkan/icd.d/radeon_icd.i686.json}"
GLOBAL_ICDS="$ICD:$FALLBACK_ICD"
GENERATOR="${BC250_GFX1013_GENERATOR:-/usr/lib/systemd/user-environment-generators/60-bc250-gfx1013}"
BUILD_ROOT="$STATE_DIR/build"
LOCK_FILE="${BC250_MESH_LOCK_FILE:-$HOME/.cache/bc250-mesh-shader.lock}"
COMPUTE_MARKER="${BC250_GFX1013_MARKER:-/usr/lib/modules/$(uname -r)/updates/.bc250-gfx1013-fix}"
COMPUTE_MODULE="${BC250_GFX1013_MODULE:-${COMPUTE_MARKER%/*}/amdgpu.ko.zst}"
COMPUTE_ACTIVE="${BC250_GFX1013_ACTIVE:-/sys/module/amdgpu/parameters/bc250_gfx1013_fix}"

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
        78bccb8022955b3e4e11ab76d8373e95e5cd0b4e8b09f5a9abbe87dce8d92484 \
        "$RAW_BASE/patches/mesa/0001-gfx1013-compute-queue-fix.patch"
    fetch_verified 0002-gfx1013-mesh-task-shaders.patch \
        f01fea1aa7c639ede8289059fe6ec0fde30ffecd13f4c3c3f50c14ef6a7aea47 \
        "$RAW_BASE/patches/mesa/0002-gfx1013-mesh-task-shaders.patch"
    fetch_verified 0003-gfx1013-taskmesh-queries.patch \
        8056be93d6f15358275cffe8798b13f90e41c228a8832c563dc30116372d2995 \
        "$RAW_BASE/patches/mesa/0003-gfx1013-taskmesh-queries.patch"
    fetch_verified "$MESA_TARBALL" "$MESA_SHA256" "$MESA_URL"
    fetch_verified "$LIBDRM_TARBALL" "$LIBDRM_SHA256" "$LIBDRM_URL"
}

verify_compute_kernel() {
    local expected actual active
    [[ -f "$COMPUTE_MARKER" && ! -L "$COMPUTE_MARKER" \
        && -f "$COMPUTE_MODULE" && ! -L "$COMPUTE_MODULE" ]] || return 1
    read -r expected < "$COMPUTE_MARKER" || return 1
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256_file "$COMPUTE_MODULE")
    [[ "$actual" == "$expected" ]] || return 1
    [[ -r "$COMPUTE_ACTIVE" && ! -L "$COMPUTE_ACTIVE" ]] || return 1
    active=$(<"$COMPUTE_ACTIVE")
    [[ "$active" == "$UPSTREAM_COMMIT" ]]
}

require_compute_kernel() {
    verify_compute_kernel || die "The active amdgpu lacks the GFX1013 compute repair. Run bc250-audio-fix/patch-driver.sh, reboot, and retry."
}

manager_environment_active() {
    local environment
    verify_compute_kernel && verify_current_runtime || return 1
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
        with library.open("rb") as stream:
            valid = stream.read(5) == b"\x7fELF\x01"
except (KeyError, OSError, TypeError, ValueError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
}

read_manifest() {
    STORED_DRIVER_SHA="" STORED_ICD_SHA="" STORED_MESA_TAG="" STORED_COMMIT=""
    [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || return 1
    read -r STORED_DRIVER_SHA STORED_ICD_SHA STORED_MESA_TAG STORED_COMMIT < "$MANIFEST" \
        || return 1
    [[ "$STORED_DRIVER_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_ICD_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_MESA_TAG" =~ ^mesa-[0-9][0-9A-Za-z._-]*$ \
        && ( "$STORED_COMMIT" == "$UPSTREAM_COMMIT" \
            || "$STORED_COMMIT" == "$LEGACY_UPSTREAM_COMMIT" ) ]]
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

render_generator() {
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

generator_owned() {
    [[ -f "$GENERATOR" && ! -L "$GENERATOR" && -x "$GENERATOR" ]] \
        && cmp -s "$GENERATOR" <(render_generator)
}

generator_recorded() {
    generator_owned || {
        [[ -f "$GENERATOR" && ! -L "$GENERATOR" && -x "$GENERATOR" ]] \
            && cmp -s "$GENERATOR" <(render_legacy_generator)
    }
}

verify_current_runtime() {
    verify_owned_runtime && [[ "$STORED_COMMIT" == "$UPSTREAM_COMMIT" ]] \
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
    printf '%s %s %s %s\n' "$driver_sha" "$icd_sha" "$1" "$UPSTREAM_COMMIT" > "$tmp"
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

cmd_setup() (
    require_normal_user
    local mesa_tag="$DEFAULT_MESA_TAG" work source build output staged_driver committed=0
    local ro_was_enabled=0 root_unlocked=0 need_packages=0
    command -v curl >/dev/null 2>&1 || die "curl is required"
    command -v python3 >/dev/null 2>&1 || die "python3 is required"
    command -v flock >/dev/null 2>&1 || die "flock is required"
    command -v systemctl >/dev/null 2>&1 || die "systemctl is required for global RADV activation"
    ensure_state_dir
    exec 9> "$LOCK_FILE"
    flock 9
    recover_install_transaction
    preflight_runtime_ownership
    require_compute_kernel
    verify_32bit_fallback \
        || die "SteamOS's 32-bit RADV ICD is unavailable or invalid. Install lib32-vulkan-radeon and retry."
    stage_upstream

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
        fi
        if [[ -e "$staged_driver" || -L "$staged_driver" ]]; then
            unlock_root || rc=1
            as_root rm -f "$staged_driver" >/dev/null 2>&1 || rc=1
        fi
        relock_root || rc=1
        rm -rf "$work"
        exit "$rc"
    }
    trap cleanup_setup EXIT

    if command -v steamos-readonly >/dev/null 2>&1 \
        && steamos-readonly status 2>/dev/null | grep -qi enabled; then
        ro_was_enabled=1
    fi

    local required_commands=(gcc g++ meson ninja patch pkg-config tar vulkaninfo glslangValidator spirv-as)
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
            base-devel meson ninja python-mako python-packaging python-yaml pkgconf vulkan-tools \
            glslang spirv-tools \
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

    source="$BUILD_ROOT/$DEFAULT_MESA_TAG"
    build="$source/build"
    rm -rf "$source"
    tar -C "$BUILD_ROOT" -xf "$CACHE_DIR/$MESA_TARBALL"
    mkdir -p "$source/subprojects/packagecache"
    cp "$CACHE_DIR/$LIBDRM_TARBALL" "$source/subprojects/packagecache/"
    local patch_name
    for patch_name in \
        0001-gfx1013-compute-queue-fix.patch \
        0002-gfx1013-mesh-task-shaders.patch \
        0003-gfx1013-taskmesh-queries.patch; do
        patch -d "$source" -p1 --fuzz=0 --dry-run -i "$CACHE_DIR/$patch_name"
        patch -d "$source" -p1 --fuzz=0 -i "$CACHE_DIR/$patch_name"
    done
    grep -qF has_async_compute_threadgroup_bug "$source/src/amd/common/ac_gpu_info.c" \
        && grep -qF has_gfx1013_mesh_queries "$source/src/amd/common/ac_gpu_info.c" \
        || die "Patched Mesa source is missing the GFX1013 compute/mesh markers"

    export TMPDIR="$STATE_DIR/tmp"
    mkdir -p "$TMPDIR"
    meson setup "$build" "$source" \
        -Dbuildtype=release \
        -Dvulkan-drivers=amd -Dgallium-drivers= -Dplatforms=x11,wayland \
        -Dglx=disabled -Degl=disabled -Dgles2=disabled -Dvideo-codecs= \
        -Dshared-llvm=disabled -Dllvm=disabled -Dxmlconfig=enabled \
        -Dlmsensors=disabled -Dvalgrind=disabled \
        -Dallow-fallback-for=libdrm -Dlibdrm:default_library=static
    ninja -C "$build" src/amd/vulkan/libvulkan_radeon.so
    output="$build/src/amd/vulkan/libvulkan_radeon.so"
    [[ -s "$output" && ! -L "$output" ]] || die "Mesa build did not produce the alternate RADV driver"

    cat > "$work/test-icd.json" <<EOF
{"file_format_version":"1.0.1","ICD":{"library_path":"$output","api_version":"1.4.309","library_arch":"64"}}
EOF
    VK_DRIVER_FILES="$work/test-icd.json" vulkaninfo --summary >/dev/null \
        || die "Staged alternate RADV driver failed vulkaninfo"

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
  "ICD": {"library_path": "$DRIVER", "api_version": "1.4.309", "library_arch": "64"}
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
    VK_DRIVER_FILES="$ICD" vulkaninfo --summary >/dev/null \
        || die "Installed alternate RADV ICD failed vulkaninfo"
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
    committed=1
    log "Alternate RADV ICD installed and enabled globally for this user."
    log "Sign out and back in so the complete graphical session inherits the new Vulkan environment."
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
    die "Per-game controls were removed; the Mesa / RADV performance patch is global for the user session."
}

cmd_legacy_clear() {
    require_normal_user
    command -v flock >/dev/null 2>&1 || die "flock is required"
    ensure_state_dir
    exec 9> "$LOCK_FILE"
    flock 9
    manage_games clear
    log "Cleared legacy per-game records. Confirm their old Steam launch options were removed separately."
}

cmd_status() {
    local failed=0
    echo "BC-250 Mesa / RADV performance patch"
    echo "  upstream: $UPSTREAM_REPO @ ${UPSTREAM_COMMIT:0:7}"
    if verify_compute_kernel; then
        echo "  kernel:  active GFX1013 compute repair"
    else
        echo "  kernel:  repair not active"
        failed=2
    fi
    if verify_current_runtime; then
        echo "  runtime: installed ($STORED_MESA_TAG)"
        echo "  driver:  $DRIVER"
        echo "  ICD:     $ICD"
    elif verify_owned_runtime; then
        echo "  runtime: legacy install requires '$0 setup'"
        failed=2
    elif [[ -e "$DRIVER" || -L "$DRIVER" || -e "$ICD" || -L "$ICD" \
        || -e "$GENERATOR" || -L "$GENERATOR" || -e "$MANIFEST" || -e "$TRANSACTION_DIR" ]]; then
        echo "  runtime: incomplete or ownership mismatch"
        failed=2
    else
        echo "  runtime: not installed"
        return 1
    fi
    echo "  activation: global user environment"
    echo "  generator:  $GENERATOR"
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
    local global_enabled=0 restart_required=0
    verify_compute_kernel && kernel_ready=1
    if verify_current_runtime; then
        runtime_state="ready"
        mesa_version="$STORED_MESA_TAG"
        if manager_environment_active; then
            global_enabled=1
        elif [[ $kernel_ready == 1 ]]; then
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
    if ! games=$(manage_games list-json 2>&1); then
        config_valid=0
        error="$games"
        games="[]"
    fi
    python3 - "$runtime_state" "$mesa_version" "$ICD" "$config_valid" "$error" "$games" "$kernel_ready" "$global_enabled" "$restart_required" <<'PY'
import json
import sys

runtime_state, mesa_version, icd_path, config_valid, error, games, kernel_ready, global_enabled, restart_required = sys.argv[1:]
print(json.dumps({
    "scriptAvailable": True,
    "runtimeState": runtime_state,
    "mesaVersion": mesa_version or None,
    "icdPath": icd_path,
    "configValid": config_valid == "1",
    "error": error or None,
    "games": json.loads(games),
    "kernelReady": kernel_ready == "1",
    "globalEnabled": global_enabled == "1",
    "restartRequired": restart_required == "1",
}, ensure_ascii=True, separators=(",", ":")))
PY
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
    [[ ! -e "$DRIVER" && ! -L "$DRIVER" && ! -e "$ICD" && ! -L "$ICD" \
        && ! -e "$GENERATOR" && ! -L "$GENERATOR" \
        && ! -e "$MANIFEST" && ! -e "$TRANSACTION_DIR" ]] \
        || die "Mesa / RADV runtime remains; run '$0 uninstall' before purge."
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
    local items=("$@") n=$# cur=0 drawn=0 key rest i label badge hint
    local lines=$((n + 4))
    printf '\033[?25l'
    TUI_CURSOR_HIDDEN=1
    while true; do
        if [[ $drawn -eq 1 ]]; then printf '\033[%dA' "$lines"; fi
        printf '\r\033[K%s\n' "${CB}${CC}${title}${C0}"
        printf '\033[K%s\n' "${CD}  up/down move - Enter select - q back${C0}"
        for i in "${!items[@]}"; do
            IFS='|' read -r label badge hint <<< "${items[$i]}"
            if [[ $i -eq $cur ]]; then
                printf '\033[K%s\n' "  ${CI}${CB} > ${label} ${C0} ${badge}"
            else
                printf '\033[K%s\n' "     ${label}  ${badge}"
            fi
        done
        IFS='|' read -r label badge hint <<< "${items[$cur]}"
        printf '\033[K\n\033[K%s\n' "  ${CD}${hint}${C0}"
        drawn=1
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

cmd_menu() {
    require_normal_user
    [[ -t 0 && -t 1 ]] \
        || die "The menu needs an interactive terminal. Use '$0 help' for CLI commands."
    while true; do
        local runtime_state
        runtime_state=$(runtime_badge)
        local items=(
            "Status overview|${runtime_state}|Verify the required AMDGPU kernel fixes, Mesa / RADV runtime, and global user activation."
            "Build / install Mesa / RADV patch|${runtime_state}|Optional but highly recommended: build audited Mesa $DEFAULT_MESA_TAG and enable it globally. May take 20-40+ minutes."
            "Clear legacy per-game records||After manually removing old Steam launch options, clear their migration records."
            "Uninstall Mesa / RADV runtime|${runtime_state}|Remove the alternate driver, ICD, and user environment generator; preserve build caches."
            "Full help||Show CLI commands, activation behavior, and upstream source."
        )
        menu_select "BC-250 Mesa / RADV performance patch  ${CD}(global user driver)${C0}" "${items[@]}" \
            || { echo; break; }
        case $MENU_CHOICE in
            0) show_menu_status ;;
            1) confirm_menu_action \
                "Build and install the global Mesa / RADV performance patch?" setup ;;
            2) confirm_menu_action \
                "Have you removed the old per-game Steam launch options?" legacy-clear ;;
            3) confirm_menu_action \
                "Remove the global Mesa / RADV runtime?" uninstall ;;
            4) echo; cmd_help; pause_key ;;
        esac
    done
}

cmd_help() {
    cat <<EOF
Usage: $0 [menu|setup|status|status-json|legacy-clear|uninstall|purge|help]

  setup                        Fetch the verified upstream series, build the
                               audited Mesa release, install a separate ICD, and
                               enable it globally for this user session.
  status                       Verify the kernel gate and global runtime ownership.
  status-json                  Print machine-readable runtime status.
  legacy-clear                Clear old per-game records after manually
                               removing their Steam launch options.
  uninstall                    Remove the alternate ICD and global activation.
  purge                        After uninstall, remove patch/source/build caches.

The environment generator exports VK_DRIVER_FILES and VK_ICD_FILENAMES only
when the patched AMDGPU module is active. Sign out and back in after setup or
uninstall so the complete graphical session inherits the changed environment.
The patched ICD serves 64-bit processes; SteamOS's stock RADV serves 32-bit
processes through the same global driver list.

Upstream (pinned to $UPSTREAM_COMMIT):
  $UPSTREAM_REPO
EOF
}

case "${1:-menu}" in
    menu) (($# <= 1)) || die "Usage: $0 menu"; cmd_menu ;;
    setup) (($# == 1)) || die "Usage: $0 setup"; cmd_setup ;;
    status) (($# == 1)) || die "Usage: $0 status"; cmd_status ;;
    status-json) (($# == 1)) || die "Usage: $0 status-json"; cmd_status_json ;;
    game) shift; cmd_game "$@" ;;
    legacy-clear) (($# == 1)) || die "Usage: $0 legacy-clear"; cmd_legacy_clear ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; cmd_uninstall ;;
    purge) (($# == 1)) || die "Usage: $0 purge"; cmd_purge ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; cmd_help ;;
    *) cmd_help >&2; exit 2 ;;
esac
