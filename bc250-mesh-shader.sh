#!/usr/bin/env bash
# Build and manage lonewolf0622's alternate Mesa/RADV mesh-shader ICD.
# The upstream patch is fetched only after explicit opt-in because that
# repository currently has no declared license.
set -euo pipefail

UPSTREAM_REPO="https://github.com/lonewolf0622/BC-250-Mesh-Shader-Patch---driconf-Edition-opt-in-per-application-"
UPSTREAM_COMMIT="b66203e012594204e5e3049856b28a2681112985"
RAW_BASE="https://raw.githubusercontent.com/lonewolf0622/BC-250-Mesh-Shader-Patch---driconf-Edition-opt-in-per-application-/$UPSTREAM_COMMIT"
DEFAULT_MESA_TAG="mesa-26.1.4"
MESA_COMMIT="6dfbc555b4128ee51139c5f78c5aba2594c9701b"
MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"

STATE_DIR="${BC250_MESH_STATE_DIR:-$HOME/.local/share/bc250-mesh-shader}"
CACHE_DIR="$STATE_DIR/upstream-$UPSTREAM_COMMIT"
MANIFEST="$STATE_DIR/install.conf"
TRANSACTION_DIR="$STATE_DIR/install-transaction"
DRIRC="${BC250_MESH_DRIRC:-$HOME/.drirc}"
DRIVER="${BC250_MESH_DRIVER:-/usr/lib/libvulkan_radeon_driconf.so}"
ICD="${BC250_MESH_ICD:-$HOME/radeon_driconf_icd.x86_64.json}"
BUILD_ROOT="$STATE_DIR/build"
LOCK_FILE="${BC250_MESH_LOCK_FILE:-$HOME/.cache/bc250-mesh-shader.lock}"

log() { echo "[bc250-mesh] $*"; }
die() { echo "[bc250-mesh] $*" >&2; exit 1; }

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
    local name="$1" expected="$2" target="$CACHE_DIR/$1" actual tmp
    if [[ -f "$target" && ! -L "$target" ]] \
        && [[ "$(sha256_file "$target")" == "$expected" ]]; then
        return 0
    fi
    mkdir -p "$CACHE_DIR"
    tmp=$(mktemp "$CACHE_DIR/.${name}.XXXXXX")
    curl --retry 3 --retry-all-errors -fsSL "$RAW_BASE/$name" -o "$tmp" \
        || { rm -f "$tmp"; die "Could not fetch $RAW_BASE/$name"; }
    actual=$(sha256_file "$tmp")
    [[ "$actual" == "$expected" ]] \
        || { rm -f "$tmp"; die "Checksum mismatch for upstream $name"; }
    chmod 0644 "$tmp"
    mv -f "$tmp" "$target"
}

stage_upstream() {
    fetch_verified bc250_driconf_fix.patch \
        56acd8c992025feff14d0105a158096fe69dfe74184c340e03ba9af4b45e91db
}

read_manifest() {
    STORED_DRIVER_SHA="" STORED_ICD_SHA="" STORED_MESA_TAG="" STORED_COMMIT=""
    [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || return 1
    read -r STORED_DRIVER_SHA STORED_ICD_SHA STORED_MESA_TAG STORED_COMMIT < "$MANIFEST" \
        || return 1
    [[ "$STORED_DRIVER_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_ICD_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_MESA_TAG" =~ ^mesa-[0-9][0-9A-Za-z._-]*$ \
        && "$STORED_COMMIT" == "$UPSTREAM_COMMIT" ]]
}

verify_owned_runtime() {
    local actual
    read_manifest || return 1
    [[ -f "$DRIVER" && ! -L "$DRIVER" && -f "$ICD" && ! -L "$ICD" ]] || return 1
    actual=$(sha256_file "$DRIVER")
    [[ "$actual" == "$STORED_DRIVER_SHA" ]] || return 1
    actual=$(sha256_file "$ICD")
    [[ "$actual" == "$STORED_ICD_SHA" ]] || return 1
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
}

preflight_runtime_ownership() {
    if [[ -e "$DRIVER" || -L "$DRIVER" || -e "$ICD" || -L "$ICD" ]]; then
        verify_recorded_parts \
            || die "Existing alternate driver/ICD is not a recorded toolkit install; refusing replacement."
    elif [[ -e "$MANIFEST" || -L "$MANIFEST" ]]; then
        read_manifest || die "Install manifest is malformed; refusing replacement."
    fi
}

recover_install_transaction() (
    [[ -d "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" ]] || return 0
    local conf="$TRANSACTION_DIR/transaction.conf" version old_driver driver_sha
    local old_icd icd_sha old_manifest manifest_sha ro_restore=0
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
    read -r version old_driver driver_sha old_icd icd_sha old_manifest manifest_sha < "$conf" \
        || die "Malformed mesh-shader install transaction; manual recovery required."
    [[ "$version" == 1 && "$old_driver" =~ ^[01]$ && "$old_icd" =~ ^[01]$ \
        && "$old_manifest" =~ ^[01]$ ]] \
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
    if [[ -f "$DRIVER" ]]; then as_root sync -f "$DRIVER"; fi
    as_root sync -d "${DRIVER%/*}"
    python3 - "$ICD" "$MANIFEST" "${ICD%/*}" "$STATE_DIR" <<'PY'
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
    local old_driver=0 old_icd=0 old_manifest=0 driver_sha=- icd_sha=- manifest_sha=- tmp
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
    tmp="$TRANSACTION_DIR/.transaction.conf"
    printf '1 %s %s %s %s %s %s\n' \
        "$old_driver" "$driver_sha" "$old_icd" "$icd_sha" "$old_manifest" "$manifest_sha" > "$tmp"
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
    ensure_state_dir
    exec 9> "$LOCK_FILE"
    flock 9
    recover_install_transaction
    preflight_runtime_ownership
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

    local required_commands=(git gcc g++ meson ninja patch pkg-config vulkaninfo)
    local command
    for command in "${required_commands[@]}"; do
        command -v "$command" >/dev/null 2>&1 || need_packages=1
    done
    for command in libdrm_amdgpu expat zlib libzstd libelf wayland-client xcb; do
        pkg-config --exists "$command" 2>/dev/null || need_packages=1
    done
    if [[ $need_packages -eq 1 ]]; then
        command -v steamos-readonly >/dev/null 2>&1 || die "SteamOS package prerequisites are missing."
        unlock_root
        as_root pacman-key --init
        as_root pacman-key --populate archlinux holo 2>/dev/null || as_root pacman-key --populate
        as_root pacman -S --needed --noconfirm \
            base-devel git meson ninja python-mako python-yaml pkgconf vulkan-tools \
            libdrm expat libelf zlib zstd wayland wayland-protocols \
            libffi libxau libxdmcp xorgproto libxcb xcb-util xcb-util-wm \
            xcb-util-keysyms xcb-util-renderutil xcb-util-image libx11 libxext \
            libxdamage libxfixes libxrandr libxshmfence libxxf86vm libxrender
        # SteamOS images can record these packages while omitting development
        # files, so force a signed reinstall instead of trusting --needed.
        as_root pacman -S --noconfirm libelf zlib zstd
        relock_root
    fi
    for command in "${required_commands[@]}"; do
        command -v "$command" >/dev/null 2>&1 \
            || die "Signed SteamOS packages did not provide required tool: $command"
    done
    for command in libdrm_amdgpu expat zlib libzstd libelf wayland-client xcb; do
        pkg-config --exists "$command" 2>/dev/null \
            || die "Signed SteamOS packages did not provide development metadata: $command"
    done

    source="$BUILD_ROOT/mesa-$MESA_COMMIT"
    build="$source/build"
    rm -rf "$source"
    mkdir -p "$source"
    git -C "$source" init -q
    git -C "$source" remote add origin "$MESA_REPO"
    git -C "$source" fetch --depth 1 origin "$MESA_COMMIT"
    git -C "$source" checkout -q --detach FETCH_HEAD
    [[ "$(git -C "$source" rev-parse HEAD)" == "$MESA_COMMIT" ]] \
        || die "Mesa source commit verification failed"
    patch -d "$source" -p1 --fuzz=0 --dry-run -i "$CACHE_DIR/bc250_driconf_fix.patch"
    patch -d "$source" -p1 --fuzz=0 -i "$CACHE_DIR/bc250_driconf_fix.patch"
    grep -qF spoof_gfx1013_as_gfx10_3 "$source/src/amd/vulkan/radv_physical_device.c" \
        || die "Patched Mesa source is missing the mesh-shader marker"

    export TMPDIR="$STATE_DIR/tmp"
    mkdir -p "$TMPDIR"
    meson setup "$build" "$source" \
        -Dvulkan-drivers=amd -Dgallium-drivers=zink \
        -Dglx=disabled -Degl=disabled -Dgles2=disabled \
        -Dshared-llvm=disabled -Dllvm=disabled -Dxmlconfig=enabled \
        -Dlmsensors=disabled -Dvalgrind=disabled
    ninja -C "$build" src/amd/vulkan/libvulkan_radeon.so
    output="$build/src/amd/vulkan/libvulkan_radeon.so"
    [[ -s "$output" && ! -L "$output" ]] || die "Mesa build did not produce the alternate RADV driver"

    cat > "$work/test-icd.json" <<EOF
{"file_format_version":"1.0.0","ICD":{"library_path":"$output","api_version":"1.4.309"}}
EOF
    VK_ICD_FILENAMES="$work/test-icd.json" vulkaninfo --summary >/dev/null \
        || die "Staged alternate RADV driver failed vulkaninfo"

    log "Installing audited Mesa $mesa_tag ($MESA_COMMIT) with upstream patch ${UPSTREAM_COMMIT:0:7}."
    log "The alternate ICD is not registered globally; games remain opt-in."
    arm_install_transaction
    unlock_root
    as_root install -o root -g root -m 0755 "$output" "$staged_driver"
    as_root mv -f "$staged_driver" "$DRIVER"
    as_root sync -f "$DRIVER"
    as_root sync -d "${DRIVER%/*}"
    relock_root
    cat > "$work/icd" <<EOF
{
  "file_format_version": "1.0.0",
  "ICD": {"library_path": "$DRIVER", "api_version": "1.4.309"}
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
    VK_ICD_FILENAMES="$ICD" vulkaninfo --summary >/dev/null \
        || die "Installed alternate RADV ICD failed vulkaninfo"
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
    log "Alternate RADV ICD installed and ownership-recorded."
    log "It remains inactive until a game is enabled and given this launch option:"
    printf 'VK_ICD_FILENAMES="%s" %%command%%\n' "$ICD"
)

manage_games() {
    local action="$1" executable="${2:-}" name="${3:-}"
    [[ ! -L "$DRIRC" ]] || die "Refusing symlinked driconf file: $DRIRC"
    [[ "$action" == list ]] || ensure_state_dir
    python3 - "$action" "$executable" "$name" "$DRIRC" <<'PY'
from html import escape
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
else:
    raise SystemExit("unknown game action")

content = pattern.sub("\n", content, count=1)
if games:
    lines = [begin, '  <device driver="radv">']
    for game in games:
        lines.extend([
            '    <application name="%s" executable="%s">' %
            (escape(game["name"], quote=True), escape(game["executable"], quote=True)),
            '      <option name="radv_spoof_gfx1013_as_gfx10_3" value="true" />',
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
    require_normal_user
    local action="${1:-}" executable="${2:-}" name="${3:-}"
    if [[ "$action" != list ]]; then
        command -v flock >/dev/null 2>&1 || die "flock is required"
        ensure_state_dir
        exec 9> "$LOCK_FILE"
        flock 9
    fi
    case "$action" in
        enable)
            [[ $# -ge 2 && $# -le 3 ]] || die "Usage: $0 game enable <executable> [friendly-name]"
            verify_owned_runtime || die "Install the alternate ICD first with '$0 setup'."
            manage_games enable "$executable" "$name"
            log "Enabled mesh-shader spoof for process: $executable"
            printf 'Steam launch option: VK_ICD_FILENAMES="%s" %%command%%\n' "$ICD"
            ;;
        disable)
            [[ $# -eq 2 ]] || die "Usage: $0 game disable <executable>"
            manage_games disable "$executable"
            log "Disabled mesh-shader spoof for process: $executable"
            log "Also remove its VK_ICD_FILENAMES launch option in Steam."
            ;;
        list)
            [[ $# -eq 1 ]] || die "Usage: $0 game list"
            manage_games list
            ;;
        *) die "Usage: $0 game {enable <executable> [friendly-name]|disable <executable>|list}" ;;
    esac
}

cmd_status() {
    local failed=0
    echo "BC-250 mesh-shader alternate RADV ICD"
    echo "  upstream: $UPSTREAM_REPO/tree/Steam-OS @ ${UPSTREAM_COMMIT:0:7}"
    if verify_owned_runtime; then
        echo "  runtime: installed ($STORED_MESA_TAG)"
        echo "  driver:  $DRIVER"
        echo "  ICD:     $ICD"
    elif [[ -e "$DRIVER" || -L "$DRIVER" || -e "$ICD" || -L "$ICD" \
        || -e "$MANIFEST" || -e "$TRANSACTION_DIR" ]]; then
        echo "  runtime: incomplete or ownership mismatch"
        failed=2
    else
        echo "  runtime: not installed"
        return 1
    fi
    echo "  globally registered: no"
    echo "  enabled games:"
    local games
    if ! games=$(manage_games list); then
        echo "    configuration invalid"
        return 2
    fi
    if [[ -n "$games" ]]; then printf '%s\n' "$games" | sed 's/^/    /'; else echo "    none"; fi
    return "$failed"
}

cmd_uninstall() (
    require_normal_user
    local ro_was_enabled=0
    ensure_state_dir
    command -v flock >/dev/null 2>&1 || die "flock is required"
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
    if [[ -e "$DRIVER" || -L "$DRIVER" || -e "$ICD" || -L "$ICD" || -e "$MANIFEST" ]]; then
        verify_recorded_parts \
            || die "Alternate runtime is not a recorded toolkit install; refusing removal."
    fi
    # Clean user configuration first. If this fails, leave the runtime intact
    # so uninstall can be retried without creating a half-removed component.
    manage_games clear
    if [[ -e "$DRIVER" || -L "$DRIVER" ]]; then
        if command -v steamos-readonly >/dev/null 2>&1 \
            && steamos-readonly status 2>/dev/null | grep -qi enabled; then
            ro_was_enabled=1
            as_root steamos-readonly disable
        fi
        as_root rm -f "$DRIVER"
    fi
    rm -f "$ICD" "$MANIFEST"
    log "Removed the alternate RADV driver, ICD, and all toolkit-managed game toggles."
    log "Remove VK_ICD_FILENAMES from each game's Steam launch options."
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
        && ! -e "$MANIFEST" && ! -e "$TRANSACTION_DIR" ]] \
        || die "Mesh-shader runtime remains; run '$0 uninstall' before purge."
    if grep -qF '<!-- BEGIN BC250 MESH SHADER MANAGED -->' "$DRIRC" 2>/dev/null; then
        die "Managed game entries remain; run '$0 uninstall' before purge."
    fi
    [[ ! -L "$STATE_DIR" ]] || die "Refusing symlinked state directory: $STATE_DIR"
    rm -rf "$STATE_DIR"
    log "Removed downloaded patch and toolkit-owned Mesa build cache."
)

cmd_menu() {
    require_normal_user
    [[ -t 0 && -t 1 ]] || die "The menu requires an interactive terminal."
    local choice executable name
    while true; do
        cat <<'EOF'

BC-250 mesh shader patch (per-application opt-in)
  1) Status
  2) Build/install alternate RADV ICD
  3) Enable one game
  4) Disable one game
  5) List enabled games
  6) Uninstall
  q) Back
EOF
        read -rp "> " choice
        case "$choice" in
            1) cmd_status || true ;;
            2) echo "Setup builds audited Mesa $DEFAULT_MESA_TAG and may install signed SteamOS build dependencies (20-40+ minutes)."
               read -rp "Continue? [y/N] " choice
               if [[ "$choice" =~ ^[Yy]$ ]]; then
                   cmd_setup
               fi ;;
            3) read -rp "Game executable/process name (for example ff7rebirth_.exe): " executable
               read -rp "Friendly name [$executable]: " name
               cmd_game enable "$executable" "${name:-$executable}" ;;
            4) read -rp "Game executable/process name: " executable; cmd_game disable "$executable" ;;
            5) cmd_game list ;;
            6) read -rp "Remove alternate driver and all managed game toggles? [y/N] " name
               [[ "$name" =~ ^[Yy]$ ]] && cmd_uninstall || true ;;
            q|Q) return 0 ;;
            *) log "Unknown selection." ;;
        esac
    done
}

cmd_help() {
    cat <<EOF
Usage: $0 [menu|setup|status|game ACTION|uninstall|purge|help]

  setup                        Fetch the verified upstream patch, build the
                               audited Mesa commit, and install a separate ICD.
  game enable EXE [NAME]       Opt one executable into the mesh-shader spoof.
  game disable EXE             Remove one executable from the managed .drirc block.
  game list                    List opted-in executables.
  status                       Verify runtime ownership and list enabled games.
  uninstall                    Remove the alternate ICD and managed game entries.
  purge                        After uninstall, remove patch/source/build caches.

The alternate ICD is never registered globally. Each enabled game also needs:
  VK_ICD_FILENAMES="$ICD" %command%

Upstream (pinned to $UPSTREAM_COMMIT):
  $UPSTREAM_REPO/tree/Steam-OS
EOF
}

case "${1:-menu}" in
    menu) (($# <= 1)) || die "Usage: $0 menu"; cmd_menu ;;
    setup) (($# == 1)) || die "Usage: $0 setup"; cmd_setup ;;
    status) (($# == 1)) || die "Usage: $0 status"; cmd_status ;;
    game) shift; cmd_game "$@" ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; cmd_uninstall ;;
    purge) (($# == 1)) || die "Usage: $0 purge"; cmd_purge ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; cmd_help ;;
    *) cmd_help >&2; exit 2 ;;
esac
