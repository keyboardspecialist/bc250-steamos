#!/usr/bin/env bash
# Configure the BC-250 CMOS UMA minimum and Linux's dynamic TTM VRAM limit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
ROOT_DATA_DIR="${ROOT_DATA_DIR:-/var/lib/bc250-control}"
BIN_DIR="$ROOT_DATA_DIR/bin"
STATE_DIR="$ROOT_DATA_DIR/ram-split"
MEMCFG_BIN="${MEMCFG_BIN:-$BIN_DIR/bc250memcfg}"
MANIFEST="${RAM_MANIFEST:-$STATE_DIR/install.conf}"
PROFILE="${RAM_PROFILE:-$STATE_DIR/settings.conf}"
RELEASE_API="${MEMCFG_RELEASE_API:-https://api.github.com/repos/fanoush/bc250_memcfg/releases/latest}"
ASSET_NAME=bc250_memcfg.zip
TTM_CONFIG="${TTM_CONFIG:-/etc/default/grub.d/bc250-ttm.cfg}"
GRUB_DEFAULT="${GRUB_DEFAULT:-/etc/default/grub}"
GRUB_CFG="${GRUB_CFG:-/efi/EFI/steamos/grub.cfg}"
GRUB_CONFIG_LOCK="${GRUB_CONFIG_LOCK:-/run/lock/bc250-grub-config.lock}"
TTM_SYS_PARAM="${TTM_SYS_PARAM:-/sys/module/ttm/parameters/pages_limit}"
PROC_CMDLINE="${PROC_CMDLINE:-/proc/cmdline}"
KEEP_FILE="${RAM_KEEP_FILE:-/etc/atomic-update.conf.d/bc250-ram.conf}"
STORAGE_SH="${STORAGE_SH:-$SCRIPT_DIR/bc250-storage.sh}"
PERSISTENCE_SH="${PERSISTENCE_SH:-$SCRIPT_DIR/bc250-update-persistence.sh}"

C0=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'; CI=$'\033[7m'
CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'; CC=$'\033[36m'
TUI_CURSOR_HIDDEN=0
TEMP_DIRS=()
GRUB_LOCK_HELD=0

log() { echo "[bc250-ram] $*"; }
die() { echo "[bc250-ram] $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run this command with sudo."; }
require_normal_user() {
    [[ $EUID -ne 0 ]] \
        || die "Run the menu as the logged-in user, not with sudo. It requests administrator access when needed."
}

tui_show_cursor() {
    if [[ $TUI_CURSOR_HIDDEN -eq 1 ]]; then
        printf '\033[?25h'
        TUI_CURSOR_HIDDEN=0
    fi
}

cleanup() {
    local directory
    tui_show_cursor
    for directory in "${TEMP_DIRS[@]-}"; do
        [[ -n "$directory" ]] || continue
        rm -rf "$directory"
    done
    if [[ $GRUB_LOCK_HELD -eq 1 ]]; then
        flock -u 6 2>/dev/null || true
        exec 6>&-
        GRUB_LOCK_HELD=0
    fi
}
trap cleanup EXIT

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

install_storage() {
    [[ -f "$STORAGE_SH" && ! -L "$STORAGE_SH" ]] \
        || die "Storage helper missing or unsafe: $STORAGE_SH"
    bash "$STORAGE_SH" install
}

install_update_persistence() {
    [[ -f "$PERSISTENCE_SH" && ! -L "$PERSISTENCE_SH" ]] \
        || die "Update persistence helper missing or unsafe: $PERSISTENCE_SH"
    bash "$PERSISTENCE_SH" install ram
}

remove_update_persistence() {
    [[ -f "$PERSISTENCE_SH" && ! -L "$PERSISTENCE_SH" ]] \
        || die "Update persistence helper missing or unsafe: $PERSISTENCE_SH"
    bash "$PERSISTENCE_SH" remove ram
}

read_manifest() {
    STORED_VERSION="" STORED_TAG="" STORED_ASSET_ID="" STORED_ARCHIVE_SHA=""
    STORED_BINARY_SHA="" STORED_URL=""
    [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || return 1
    read -r STORED_VERSION STORED_TAG STORED_ASSET_ID STORED_ARCHIVE_SHA \
        STORED_BINARY_SHA STORED_URL < "$MANIFEST" || return 1
    [[ "$STORED_VERSION" == 1 \
        && "$STORED_TAG" =~ ^v[0-9][0-9A-Za-z._-]*$ \
        && "$STORED_ASSET_ID" =~ ^[0-9]+$ \
        && "$STORED_ARCHIVE_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_BINARY_SHA" =~ ^[0-9a-f]{64}$ \
        && "$STORED_URL" == "https://github.com/fanoush/bc250_memcfg/releases/download/$STORED_TAG/$ASSET_NAME" ]]
}

verify_installed_tool() {
    read_manifest || return 1
    [[ -f "$MEMCFG_BIN" && ! -L "$MEMCFG_BIN" ]] || return 1
    [[ "$(sha256_file "$MEMCFG_BIN")" == "$STORED_BINARY_SHA" ]]
}

tool_has_artifacts() {
    [[ -e "$MEMCFG_BIN" || -L "$MEMCFG_BIN" \
        || -e "$MANIFEST" || -L "$MANIFEST" ]]
}

preflight_tool_ownership() {
    if [[ -e "$MEMCFG_BIN" || -L "$MEMCFG_BIN" ]]; then
        verify_installed_tool \
            || die "Existing bc250memcfg payload is not a verified toolkit install; refusing replacement."
    elif [[ -e "$MANIFEST" || -L "$MANIFEST" ]]; then
        read_manifest \
            || die "Existing bc250memcfg manifest is malformed; refusing replacement."
    fi
}

fetch_release_metadata() {
    local target="$1"
    curl --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors -fsSL \
        "$RELEASE_API" -o "$target" \
        || die "Could not fetch the latest bc250_memcfg release metadata."
}

parse_release_metadata() {
    local metadata="$1"
    python3 -I - "$metadata" "$ASSET_NAME" <<'PY'
import json
import re
import sys

path, wanted = sys.argv[1:]
with open(path, "r", encoding="utf-8") as stream:
    release = json.load(stream)
if release.get("draft") or release.get("prerelease"):
    raise SystemExit("latest release is not a stable published release")
tag = release.get("tag_name")
if not isinstance(tag, str) or not re.fullmatch(r"v[0-9][0-9A-Za-z._-]*", tag):
    raise SystemExit("invalid release tag")
assets = [asset for asset in release.get("assets", []) if asset.get("name") == wanted]
if len(assets) != 1:
    raise SystemExit("release must contain exactly one bc250_memcfg.zip asset")
asset = assets[0]
asset_id = asset.get("id")
url = asset.get("browser_download_url")
digest = asset.get("digest")
size = asset.get("size")
prefix = f"https://github.com/fanoush/bc250_memcfg/releases/download/{tag}/"
if not isinstance(asset_id, int) or asset_id <= 0:
    raise SystemExit("invalid release asset id")
if url != prefix + wanted:
    raise SystemExit("unexpected release download URL")
if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    raise SystemExit("release asset has no valid SHA-256 digest")
if not isinstance(size, int) or size <= 0 or size > 1024 * 1024:
    raise SystemExit("release asset size is invalid or exceeds 1 MiB")
print(tag, asset_id, digest.split(":", 1)[1], size, url)
PY
}

extract_release_binary() {
    local archive="$1" target="$2"
    python3 -I - "$archive" "$target" <<'PY'
import pathlib
import stat
import sys
import zipfile

archive, target = sys.argv[1:]
member = "bc250_memcfg/bc250memcfg"
with zipfile.ZipFile(archive) as bundle:
    matches = [info for info in bundle.infolist() if info.filename == member]
    if len(matches) != 1:
        raise SystemExit("release archive must contain exactly one bc250memcfg binary")
    info = matches[0]
    mode = info.external_attr >> 16
    if info.is_dir() or stat.S_ISLNK(mode) or info.file_size <= 0 or info.file_size > 1024 * 1024:
        raise SystemExit("unsafe bc250memcfg archive member")
    payload = bundle.read(info)
if len(payload) < 20 or payload[:6] != b"\x7fELF\x02\x01" or int.from_bytes(payload[18:20], "little") != 62:
    raise SystemExit("bc250memcfg is not an x86-64 ELF binary")
path = pathlib.Path(target)
path.write_bytes(payload)
path.chmod(0o700)
PY
}

cmd_install() {
    require_root
    preflight_tool_ownership
    install_storage
    command -v curl >/dev/null 2>&1 || die "curl is required."
    command -v python3 >/dev/null 2>&1 || die "python3 is required."

    local work metadata archive extracted tag asset_id expected_sha asset_size url
    local actual_sha binary_sha staged_bin staged_manifest had_bin=0 had_manifest=0
    work=$(mktemp -d /tmp/bc250-memcfg.XXXXXX)
    TEMP_DIRS+=("$work")
    metadata="$work/release.json"
    archive="$work/$ASSET_NAME"
    extracted="$work/bc250memcfg"
    fetch_release_metadata "$metadata"
    read -r tag asset_id expected_sha asset_size url < <(parse_release_metadata "$metadata") \
        || die "Could not validate the latest bc250_memcfg release metadata."
    curl --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors \
        --max-filesize "$asset_size" -fsSL \
        "$url" -o "$archive" || die "Could not download $url"
    actual_sha=$(sha256_file "$archive")
    [[ "$actual_sha" == "$expected_sha" ]] \
        || die "Checksum mismatch for $ASSET_NAME"
    extract_release_binary "$archive" "$extracted"
    binary_sha=$(sha256_file "$extracted")

    install -d -o root -g root -m 0755 "$BIN_DIR" "$STATE_DIR"
    staged_bin="$STATE_DIR/.bc250memcfg.new.$$"
    staged_manifest="$STATE_DIR/.install.conf.new.$$"
    install -o root -g root -m 0755 "$extracted" "$staged_bin"
    printf '%s\n' "1 $tag $asset_id $expected_sha $binary_sha $url" \
        > "$staged_manifest"
    chown root:root "$staged_manifest"
    chmod 0644 "$staged_manifest"
    if [[ -f "$MEMCFG_BIN" ]]; then cp -p "$MEMCFG_BIN" "$work/old.bin"; had_bin=1; fi
    if [[ -f "$MANIFEST" ]]; then cp -p "$MANIFEST" "$work/old.manifest"; had_manifest=1; fi
    if ! mv -f "$staged_bin" "$MEMCFG_BIN" \
        || ! mv -f "$staged_manifest" "$MANIFEST" \
        || ! verify_installed_tool; then
        if [[ $had_bin -eq 1 ]]; then cp -p "$work/old.bin" "$MEMCFG_BIN"; else rm -f "$MEMCFG_BIN"; fi
        if [[ $had_manifest -eq 1 ]]; then cp -p "$work/old.manifest" "$MANIFEST"; else rm -f "$MANIFEST"; fi
        die "bc250memcfg installation failed; the prior verified install was restored."
    fi
    log "Installed bc250memcfg $tag from its verified upstream release."
}

require_bc250() {
    command -v lspci >/dev/null 2>&1 || die "lspci is required for the BC-250 safety check."
    lspci -Dn 2>/dev/null | grep -qi '1002:13fe' \
        || die "BC-250 GPU PCI ID 1002:13fe was not detected; refusing the CMOS write."
}

validate_uma_size() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "UMA size must be a whole number of MiB."
    ((10#$1 >= 256 && 10#$1 <= 12288)) \
        || die "UMA size must be between 256 and the documented 12288 MiB maximum."
    ((10#$1 % 16 == 0)) || die "UMA size must be aligned to 16 MiB."
    ((10#$1 != 2048)) \
        || die "The BC-250 documentation warns that Linux does not boot with a 2048 MiB split."
}

profile_uma_size() {
    local value
    [[ -f "$PROFILE" && ! -L "$PROFILE" ]] || return 1
    value=$(awk -F= '$1 == "UMA_MB" {print $2}' "$PROFILE")
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

write_profile() {
    local size="$1"
    install -d -o root -g root -m 0755 "$STATE_DIR"
    printf '%s\n' '# Last CMOS UMA size requested by bc250-ram-split.sh.' \
        "UMA_MB=$size" > "$PROFILE.new.$$"
    chown root:root "$PROFILE.new.$$"
    chmod 0644 "$PROFILE.new.$$"
    mv -f "$PROFILE.new.$$" "$PROFILE"
}

cmd_show() {
    require_root
    require_bc250
    verify_installed_tool || die "bc250memcfg is not installed or failed verification; run '$0 install'."
    "$MEMCFG_BIN"
}

read_current_uma() {
    local output value
    output=$("$MEMCFG_BIN") || return 1
    value=$(awk -F= '$1 == "UMA_SIZE" {print $2}' <<< "$output")
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$((10#$value))"
}

cmd_set() {
    require_root
    local size="${1:-}" consent="${2:-}"
    [[ -n "$size" && "$consent" == --yes && $# -eq 2 ]] \
        || die "Usage: $0 set UMA_MB --yes"
    validate_uma_size "$size"
    require_bc250
    if ! verify_installed_tool; then
        tool_has_artifacts \
            && die "Existing bc250memcfg payload failed verification."
        cmd_install
    fi
    local output readback
    output=$("$MEMCFG_BIN" UMA_SIZE "$size") \
        || die "bc250memcfg failed while writing UMA_SIZE."
    printf '%s\n' "$output"
    [[ "$output" == "setting UMA_SIZE to $size" ]] \
        || die "bc250memcfg did not confirm the requested UMA_SIZE write."
    readback=$(read_current_uma) \
        || die "CMOS write could not be verified by reading UMA_SIZE back."
    [[ "$readback" == "$size" ]] \
        || die "CMOS readback is $readback MiB, not the requested $size MiB."
    write_profile "$size"
    log "CMOS minimum VRAM set to $size MiB. Reboot to apply it."
    log "Clearing CMOS is the recovery path if the system does not boot."
}

render_ttm_config() {
    local pages="$1"
    cat << EOF
# BC-250 TTM limit managed by bc250-ram-split.sh.
# Remove with: bc250-ram-split.sh ttm-remove
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT:-} ttm.pages_limit=$pages"
EOF
}

configured_ttm_pages() {
    local line pages
    [[ -f "$TTM_CONFIG" && ! -L "$TTM_CONFIG" ]] || return 1
    IFS= read -r line < "$TTM_CONFIG" || return 1
    [[ "$line" == '# BC-250 TTM limit managed by bc250-ram-split.sh.' ]] || return 1
    line=$(sed -n '3p' "$TTM_CONFIG")
    [[ "$line" =~ ^GRUB_CMDLINE_LINUX_DEFAULT=\"\$\{GRUB_CMDLINE_LINUX_DEFAULT:-\}\ ttm\.pages_limit=([0-9]+)\"$ ]] \
        || return 1
    pages="${BASH_REMATCH[1]}"
    cmp -s "$TTM_CONFIG" <(render_ttm_config "$pages") || return 1
    printf '%s\n' "$pages"
}

ttm_config_exists() { [[ -e "$TTM_CONFIG" || -L "$TTM_CONFIG" ]]; }

preflight_ttm_ownership() {
    if ttm_config_exists; then
        configured_ttm_pages >/dev/null \
            || die "Existing TTM configuration is not toolkit-owned: $TTM_CONFIG"
    fi
}

foreign_ttm_source() {
    local candidate
    for candidate in "$GRUB_DEFAULT" "${TTM_CONFIG%/*}"/*; do
        [[ "$candidate" != "$TTM_CONFIG" && -f "$candidate" && ! -L "$candidate" ]] \
            || continue
        if grep -Eq "(^|[[:space:]\"'])ttm\\.pages_limit=" "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

preflight_no_foreign_ttm() {
    local source
    if source=$(foreign_ttm_source); then
        die "Another GRUB source already sets ttm.pages_limit: $source"
    fi
}

active_boot_ttm_pages() {
    local token
    [[ -r "$PROC_CMDLINE" ]] || return 1
    for token in $(< "$PROC_CMDLINE"); do
        [[ "$token" =~ ^ttm\.pages_limit=([0-9]+)$ ]] || continue
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    done
    return 1
}

active_module_ttm_pages() {
    local value
    [[ -r "$TTM_SYS_PARAM" ]] || return 1
    IFS= read -r value < "$TTM_SYS_PARAM" || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

pages_to_gib() {
    awk -v pages="$1" 'BEGIN { printf "%.2f", pages * 4096 / 1073741824 }'
}

validate_generated_grub() {
    local path="$1" expected="$2"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    awk -v expected="$expected" '
        $1 ~ /^linux/ || ($1 == "steamenv_boot" && $2 ~ /^linux/) {
            on_line = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^ttm\.pages_limit=/) {
                    count++
                    on_line++
                    if (expected == "" || $i != "ttm.pages_limit=" expected)
                        bad = 1
                }
            }
            if (on_line > 1)
                bad = 1
        }
        END {
            if (expected == "")
                exit(count == 0 ? 0 : 1)
            exit(count > 0 && !bad ? 0 : 1)
        }
    ' "$path"
}

preflight_grub_target() {
    command -v grub-mkconfig >/dev/null 2>&1 \
        || command -v update-grub >/dev/null 2>&1 \
        || die "Neither update-grub nor grub-mkconfig is available."
    if [[ -e "$GRUB_CFG" || -L "$GRUB_CFG" ]]; then
        [[ -f "$GRUB_CFG" && ! -L "$GRUB_CFG" ]] \
            || die "Refusing unsafe generated GRUB path: $GRUB_CFG"
    fi
}

regenerate_grub() {
    local expected="$1" tmp
    mkdir -p "${GRUB_CFG%/*}"
    if command -v grub-mkconfig >/dev/null 2>&1; then
        tmp=$(mktemp "${GRUB_CFG%/*}/.bc250-grub.XXXXXX") || return 1
        if ! grub-mkconfig -o "$tmp" \
            || ! validate_generated_grub "$tmp" "$expected"; then
            rm -f "$tmp"
            return 1
        fi
        chmod 0644 "$tmp"
        mv -f "$tmp" "$GRUB_CFG"
    else
        update-grub || return 1
        validate_generated_grub "$GRUB_CFG" "$expected"
    fi
}

validate_ttm_pages() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "ttm.pages_limit must be a whole page count."
    ((10#$1 >= 65536 && 10#$1 <= 3145728)) \
        || die "ttm.pages_limit must be between 65536 pages (256 MiB) and 3145728 pages (12 GiB)."
}

restore_ttm_state() {
    local config_backup="$1" had_config="$2" grub_backup="$3" had_grub="$4"
    if [[ "$had_config" == 1 ]]; then
        atomic_restore_file "$config_backup" "$TTM_CONFIG"
    else
        rm -f "$TTM_CONFIG"
    fi
    if [[ "$had_grub" == 1 ]]; then
        atomic_restore_file "$grub_backup" "$GRUB_CFG"
    else
        rm -f "$GRUB_CFG"
    fi
}

lock_grub_config() {
    command -v flock >/dev/null 2>&1 \
        || die "flock is required for safe GRUB changes."
    exec 6> "$GRUB_CONFIG_LOCK" || die "Could not open $GRUB_CONFIG_LOCK"
    flock 6 || die "Could not lock $GRUB_CONFIG_LOCK"
    GRUB_LOCK_HELD=1
}

unlock_grub_config() {
    [[ $GRUB_LOCK_HELD -eq 1 ]] || return 0
    flock -u 6 2>/dev/null || true
    exec 6>&-
    GRUB_LOCK_HELD=0
}

atomic_restore_file() {
    local source="$1" target="$2" tmp
    mkdir -p "${target%/*}"
    tmp=$(mktemp "${target%/*}/.bc250-restore.XXXXXX") || return 1
    if ! cp -p "$source" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$target"
}

cmd_ttm_set() {
    require_root
    local pages="${1:-}" consent="${2:-}" work config_backup grub_backup
    local had_config=0 had_grub=0
    [[ -n "$pages" && "$consent" == --yes && $# -eq 2 ]] \
        || die "Usage: $0 ttm-set PAGES --yes"
    validate_ttm_pages "$pages"
    lock_grub_config
    preflight_ttm_ownership
    preflight_no_foreign_ttm
    preflight_grub_target
    install_storage
    work=$(mktemp -d /tmp/bc250-ttm.XXXXXX)
    TEMP_DIRS+=("$work")
    config_backup="$work/previous.cfg"
    grub_backup="$work/grub.cfg"
    if [[ -f "$TTM_CONFIG" ]]; then cp -p "$TTM_CONFIG" "$config_backup"; had_config=1; fi
    if [[ -f "$GRUB_CFG" ]]; then cp -p "$GRUB_CFG" "$grub_backup"; had_grub=1; fi
    mkdir -p "${TTM_CONFIG%/*}"
    render_ttm_config "$pages" > "$TTM_CONFIG.new.$$"
    chown root:root "$TTM_CONFIG.new.$$"
    chmod 0644 "$TTM_CONFIG.new.$$"
    mv -f "$TTM_CONFIG.new.$$" "$TTM_CONFIG"
    if ! regenerate_grub "$pages"; then
        restore_ttm_state "$config_backup" "$had_config" "$grub_backup" "$had_grub"
        die "GRUB regeneration failed; the prior TTM configuration was restored."
    fi
    if ! install_update_persistence; then
        restore_ttm_state "$config_backup" "$had_config" "$grub_backup" "$had_grub"
        die "Update persistence failed; the prior TTM configuration was restored."
    fi
    unlock_grub_config
    log "Configured ttm.pages_limit=$pages ($(pages_to_gib "$pages") GiB dynamic limit)."
    log "Reboot is required before the new TTM limit is active."
}

cmd_ttm_remove() {
    require_root
    local work config_backup grub_backup had_grub=0
    if ! ttm_config_exists; then
        log "No toolkit-managed TTM override is installed."
        remove_update_persistence
        return 0
    fi
    lock_grub_config
    preflight_ttm_ownership
    preflight_no_foreign_ttm
    preflight_grub_target
    work=$(mktemp -d /tmp/bc250-ttm-remove.XXXXXX)
    TEMP_DIRS+=("$work")
    config_backup="$work/previous.cfg"
    grub_backup="$work/grub.cfg"
    cp -p "$TTM_CONFIG" "$config_backup"
    if [[ -f "$GRUB_CFG" ]]; then cp -p "$GRUB_CFG" "$grub_backup"; had_grub=1; fi
    rm -f "$TTM_CONFIG"
    if ! regenerate_grub ""; then
        restore_ttm_state "$config_backup" 1 "$grub_backup" "$had_grub"
        die "GRUB regeneration failed; the TTM configuration was restored."
    fi
    if ! remove_update_persistence; then
        restore_ttm_state "$config_backup" 1 "$grub_backup" "$had_grub"
        die "Update persistence cleanup failed; the TTM configuration was restored."
    fi
    unlock_grub_config
    log "Removed the toolkit-managed TTM override. Reboot to return to the default limit."
}

ram_is_installed() {
    tool_has_artifacts || ttm_config_exists || [[ -e "$KEEP_FILE" || -L "$KEEP_FILE" ]]
}

cmd_installed() {
    if ram_is_installed; then
        printf '%s\n' installed
        return 0
    fi
    printf '%s\n' not-installed
    return 1
}

cmd_status() {
    local configured="" boot="" module="" uma=""
    echo "BC-250 RAM / VRAM split:"
    if verify_installed_tool; then
        printf '  %-22s installed %s\n' "bc250memcfg:" "$STORED_TAG"
    elif tool_has_artifacts; then
        printf '  %-22s partial or unverified\n' "bc250memcfg:"
    else
        printf '  %-22s not installed\n' "bc250memcfg:"
    fi
    if uma=$(profile_uma_size); then
        printf '  %-22s %s MiB (last requested; reboot applies changes)\n' "CMOS minimum VRAM:" "$uma"
    else
        printf '  %-22s unknown (use sudo %s show)\n' "CMOS minimum VRAM:" "$SELF"
    fi
    if configured=$(configured_ttm_pages); then
        printf '  %-22s %s pages (%s GiB dynamic)\n' "TTM configured:" "$configured" "$(pages_to_gib "$configured")"
    elif ttm_config_exists; then
        printf '  %-22s foreign or unsafe configuration\n' "TTM configured:"
    else
        printf '  %-22s default\n' "TTM configured:"
    fi
    if boot=$(active_boot_ttm_pages); then
        printf '  %-22s %s pages%s\n' "TTM boot argument:" "$boot" \
            "$([[ -n "$configured" && "$configured" != "$boot" ]] && printf ' (reboot needed)' || true)"
    else
        printf '  %-22s default%s\n' "TTM boot argument:" \
            "$([[ -n "$configured" ]] && printf ' (reboot needed)' || true)"
    fi
    if module=$(active_module_ttm_pages); then
        printf '  %-22s %s pages\n' "TTM live parameter:" "$module"
    fi
}

cmd_status_json() {
    local tool_state=not-installed tool_version="" uma="" ttm_state=default
    local configured="" boot="" module="" reboot_required=false protected=false
    if verify_installed_tool; then
        tool_state=verified
        tool_version=$STORED_TAG
    elif tool_has_artifacts; then
        tool_state=invalid
    fi
    uma=$(profile_uma_size || true)
    if configured=$(configured_ttm_pages); then
        ttm_state=configured
    elif ttm_config_exists; then
        ttm_state=foreign
    fi
    boot=$(active_boot_ttm_pages || true)
    module=$(active_module_ttm_pages || true)
    if [[ "$ttm_state" != foreign && "$configured" != "$boot" ]]; then
        reboot_required=true
    fi
    if [[ -f "$KEEP_FILE" && ! -L "$KEEP_FILE" ]]; then
        protected=true
    fi

    printf '{"schemaVersion":1,"available":true,"toolState":"%s","toolVersion":' "$tool_state"
    if [[ -n "$tool_version" ]]; then printf '"%s"' "$tool_version"; else printf 'null'; fi
    printf ',"umaLastRequestedMiB":'
    if [[ -n "$uma" ]]; then printf '%s' "$uma"; else printf 'null'; fi
    printf ',"ttmState":"%s","ttmConfiguredPages":' "$ttm_state"
    if [[ -n "$configured" ]]; then printf '%s' "$configured"; else printf 'null'; fi
    printf ',"ttmBootPages":'
    if [[ -n "$boot" ]]; then printf '%s' "$boot"; else printf 'null'; fi
    printf ',"ttmLivePages":'
    if [[ -n "$module" ]]; then printf '%s' "$module"; else printf 'null'; fi
    printf ',"rebootRequired":%s,"protected":%s}\n' "$reboot_required" "$protected"
}

cmd_uninstall() {
    require_root
    preflight_tool_ownership
    preflight_ttm_ownership
    if ttm_config_exists; then
        cmd_ttm_remove
    else
        remove_update_persistence
    fi
    rm -f "$MEMCFG_BIN" "$MANIFEST"
    rmdir "$BIN_DIR" 2>/dev/null || true
    log "Removed the memory utility and toolkit-managed TTM override."
    log "The saved profile was preserved at $PROFILE."
    log "The CMOS UMA split is unchanged; clear CMOS to restore firmware defaults."
}

b_ok() { printf '%s' "${CG}[$1]${C0}"; }
b_mid() { printf '%s' "${CY}[$1]${C0}"; }
b_off() { printf '%s' "${CD}[$1]${C0}"; }

tool_badge() {
    if verify_installed_tool; then b_ok "installed $STORED_TAG"
    elif tool_has_artifacts; then b_mid "repair needed"
    else b_off "not installed"; fi
}

uma_badge() {
    local value
    if value=$(profile_uma_size); then b_mid "$value MiB last set"
    else b_off "unknown"; fi
}

ttm_badge() {
    local configured boot
    if configured=$(configured_ttm_pages); then
        if boot=$(active_boot_ttm_pages) && [[ "$boot" == "$configured" ]]; then
            b_ok "$(pages_to_gib "$configured") GiB active"
        else
            b_mid "reboot needed"
        fi
    elif ttm_config_exists; then b_mid "foreign config"
    else b_off "default"; fi
}

uma_preset_badge() {
    local selected
    if selected=$(profile_uma_size) && [[ "$selected" == "$1" ]]; then
        b_mid "last set"
    fi
}

ttm_preset_badge() {
    local configured boot
    if configured=$(configured_ttm_pages) && [[ "$configured" == "$1" ]]; then
        if boot=$(active_boot_ttm_pages) && [[ "$boot" == "$configured" ]]; then
            b_ok active
        else
            b_mid "reboot needed"
        fi
    fi
}

menu_select() {
    local title="$1"; shift
    local items=("$@") n=$# cur=0 key rest i label badge hint label_width=0
    for i in "${!items[@]}"; do
        IFS='|' read -r label badge hint <<< "${items[$i]}"
        if ((${#label} > label_width)); then label_width=${#label}; fi
    done
    printf '\033[?25l'; TUI_CURSOR_HIDDEN=1
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
            rest=""; IFS= read -rsn2 -t 0.05 rest || true; key+="$rest"
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
    printf '%s' "${CD}-- press any key to return to RAM / VRAM settings --${C0}"
    IFS= read -rsn1 || true
    printf '\r\033[K'
}

ask() {
    local prompt="$1" def="${2:-}"
    REPLY=""
    read -rp "  $prompt${def:+ [$def]}: " REPLY || true
    [[ -n "$REPLY" ]] || REPLY="$def"
}

run_action() {
    local rc=0
    echo
    "$@" || rc=$?
    [[ $rc -eq 0 ]] || printf '%s\n' "${CR}${CB}[bc250-ram]${C0} action failed (exit $rc)"
    pause_key
}

run_privileged() {
    local rc=0
    echo
    sudo bash "$SELF" "$@" || rc=$?
    [[ $rc -eq 0 ]] || printf '%s\n' "${CR}${CB}[bc250-ram]${C0} action failed (exit $rc)"
    pause_key
}

confirm_uma() {
    local size="$1" answer
    echo
    printf '%s\n' "${CR}${CB}This writes the battery-backed CMOS memory configuration.${C0}"
    printf '%s\n' "The change applies after reboot. A bad setting may require clearing CMOS."
    printf 'Type SET VRAM to set the minimum VRAM allocation to %s MiB: ' "$size"
    IFS= read -r answer
    if [[ "$answer" == "SET VRAM" ]]; then
        run_privileged set "$size" --yes
    else
        log "Cancelled."
        pause_key
    fi
}

confirm_ttm() {
    local pages="$1" answer
    echo
    printf 'Set ttm.pages_limit=%s (%s GiB dynamic) and regenerate GRUB? [y/N] ' \
        "$pages" "$(pages_to_gib "$pages")"
    IFS= read -r answer
    case "$answer" in
        y|Y|yes|YES) run_privileged ttm-set "$pages" --yes ;;
        *) log "Cancelled."; pause_key ;;
    esac
}

menu_uma() {
    while true; do
        local items=(
            "Read current CMOS configuration||Requires administrator access; read-only."
            "256 MiB minimum|$(uma_preset_badge 256)|Smallest documented split; maximizes CPU RAM."
            "512 MiB minimum|$(uma_preset_badge 512)|Documentation recommendation with a raised TTM limit."
            "1 GiB minimum|$(uma_preset_badge 1024)|Set UMA_SIZE to 1024 MiB."
            "3 GiB minimum|$(uma_preset_badge 3072)|Set UMA_SIZE to 3072 MiB."
            "4 GiB minimum|$(uma_preset_badge 4096)|Set UMA_SIZE to 4096 MiB."
            "6 GiB minimum|$(uma_preset_badge 6144)|Set UMA_SIZE to 6144 MiB."
            "8 GiB minimum|$(uma_preset_badge 8192)|Factory-style equal RAM/VRAM split."
            "10 GiB minimum|$(uma_preset_badge 10240)|Leaves substantially less memory for the CPU."
            "12 GiB minimum|$(uma_preset_badge 12288)|Leaves only about 4 GiB for CPU memory."
            "Custom aligned size||256-12288 MiB in 16 MiB increments; 2048 MiB is blocked."
        )
        menu_select "CMOS minimum VRAM allocation" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) run_privileged show ;;
            1) confirm_uma 256 ;;
            2) confirm_uma 512 ;;
            3) confirm_uma 1024 ;;
            4) confirm_uma 3072 ;;
            5) confirm_uma 4096 ;;
            6) confirm_uma 6144 ;;
            7) confirm_uma 8192 ;;
            8) confirm_uma 10240 ;;
            9) confirm_uma 12288 ;;
            10) ask "UMA size in MiB" "512"; confirm_uma "$REPLY" ;;
        esac
    done
}

menu_ttm() {
    while true; do
        local items=(
            "Show TTM status|$(ttm_badge)|Compare configured, boot, and live page limits."
            "8 GiB dynamic limit|$(ttm_preset_badge 2097152)|Set ttm.pages_limit=2097152."
            "10 GiB dynamic limit|$(ttm_preset_badge 2621440)|Set ttm.pages_limit=2621440."
            "BC-250 guide 12 GB preset|$(ttm_preset_badge 3014656)|Published guide value: 11.50 GiB dynamic, about 12 GB total with 512 MiB UMA."
            "12 GiB dynamic limit|$(ttm_preset_badge 3145728)|Exact 12 GiB dynamic page count."
            "Custom pages_limit||Enter the raw 4 KiB page count."
            "Remove TTM override||Return to the kernel default after reboot."
        )
        menu_select "Dynamic VRAM / TTM limit" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) run_action cmd_status ;;
            1) confirm_ttm 2097152 ;;
            2) confirm_ttm 2621440 ;;
            3) confirm_ttm 3014656 ;;
            4) confirm_ttm 3145728 ;;
            5) ask "ttm.pages_limit page count" "3014656"; confirm_ttm "$REPLY" ;;
            6) run_privileged ttm-remove ;;
        esac
    done
}

cmd_menu() {
    require_normal_user
    [[ -t 0 && -t 1 ]] || die "The menu needs an interactive terminal. Use '$0 help' for CLI commands."
    while true; do
        local items=(
            "Status overview||Read-only local status; does not contact GitHub."
            "Install / update bc250_memcfg|$(tool_badge)|Fetch and verify the latest upstream release."
            "Minimum VRAM (CMOS UMA split)|$(uma_badge)|Set the persistent minimum GPU allocation; reboot required."
            "Dynamic VRAM limit (TTM)|$(ttm_badge)|Manage ttm.pages_limit in a dedicated SteamOS GRUB drop-in."
            "Full help||Safety notes, commands, and recovery guidance."
        )
        menu_select "BC-250 RAM / VRAM split" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_action cmd_status ;;
            1) run_privileged install ;;
            2) menu_uma ;;
            3) menu_ttm ;;
            4) cmd_help; pause_key ;;
        esac
    done
}

cmd_help() {
    cat << EOF
bc250-ram-split.sh -- BC-250 RAM / VRAM split configuration

Usage: $0 {menu|status|status-json|installed|install|show|set UMA_MB --yes|
           ttm-set PAGES --yes|ttm-remove|uninstall|help}

  install              Download the latest fanoush/bc250_memcfg release,
                       verify GitHub's SHA-256 digest and x86-64 ELF payload,
                       then install it in trusted persistent storage.
  show                 Read the current CMOS memory configuration (root).
  set UMA_MB --yes     Set only UMA_SIZE. Valid values are 256-12288 MiB in
                       16 MiB increments; 2048 MiB is blocked because the
                       BC-250 guide warns that Linux does not boot with it.
  ttm-set PAGES --yes  Set ttm.pages_limit using a dedicated GRUB drop-in.
                       Pages are 4 KiB: GiB * 262144 = PAGES.
  ttm-remove           Remove the toolkit-owned TTM override and regenerate GRUB.
  status               Show installed release, last requested UMA size, and
                       configured/active TTM values without network access.
  installed            Machine-readable lifecycle probe.
  uninstall            Remove the tool and TTM override, preserving the profile.

UMA_SIZE is the minimum reserved VRAM, not a fixed maximum. The CMOS write
persists across operating systems and toolkit uninstall. It applies after a
reboot and has no software reset; clear CMOS with the board jumper or battery
if a selected split prevents boot. The wrapper intentionally exposes no memory
timing controls from the upstream utility.

ttm.pages_limit caps dynamic system-memory-backed GPU allocations. The BC-250
guide's 3014656-page preset is 11.50 GiB dynamic, approximately 12 GB total
when paired with a 512 MiB UMA minimum. Reboot after changing or removing it.
EOF
}

if [[ $# -eq 0 ]]; then
    if [[ -t 0 && -t 1 ]]; then cmd_menu; exit 0; fi
    cmd_help >&2
    exit 1
fi

case "$1" in
    menu) (($# == 1)) || die "Usage: $0 menu"; cmd_menu ;;
    status) (($# == 1)) || die "Usage: $0 status"; cmd_status ;;
    status-json) (($# == 1)) || die "Usage: $0 status-json"; cmd_status_json ;;
    installed) (($# == 1)) || die "Usage: $0 installed"; cmd_installed ;;
    install) (($# == 1)) || die "Usage: $0 install"; cmd_install ;;
    show) (($# == 1)) || die "Usage: $0 show"; cmd_show ;;
    set) shift; cmd_set "$@" ;;
    ttm-set) shift; cmd_ttm_set "$@" ;;
    ttm-remove) (($# == 1)) || die "Usage: $0 ttm-remove"; cmd_ttm_remove ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; cmd_uninstall ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; cmd_help ;;
    *) cmd_help >&2; exit 1 ;;
esac
