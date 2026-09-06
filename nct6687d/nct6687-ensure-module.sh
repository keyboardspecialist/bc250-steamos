#!/usr/bin/env bash
# BC-250 toolkit managed NCT6687 boot recovery helper.
set -euo pipefail

DATA_DIR=/var/lib/bc250-control/nct6687d
SOURCE=$DATA_DIR/source
STAGE=$DATA_DIR/modules/$(uname -r)
OPTIONS_FILE=$DATA_DIR/module-options
KVER=$(uname -r)
INSTALLED_DIR=/usr/lib/modules/$KVER/updates/bc250-nct6687
INSTALLED_KO=$INSTALLED_DIR/nct6687.ko
INSTALLED_MARKER=$INSTALLED_DIR/.bc250-managed
STAGED_KO=$STAGE/nct6687.ko
STAGED_MARKER=$STAGE/.bc250-managed

log() { echo "[nct6687] $*"; }
die() { log "$*" >&2; exit 1; }
ko_kver() { modinfo -F vermagic "$1" 2>/dev/null | cut -d' ' -f1; }

command -v flock >/dev/null 2>&1 || die "flock is required."
exec 9>/run/lock/bc250-nct6687.lock
flock 9
[[ "$KVER" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Unsafe kernel release: $KVER"

secure_root_file() {
    local path=$1 metadata owner mode current
    [[ -f "$path" && ! -L "$path" ]] || die "Missing or unsafe trusted file: $path"
    metadata=$(stat -Lc '%u %a' "$path")
    read -r owner mode <<< "$metadata"
    [[ "$owner" == 0 && $((8#$mode & 8#022)) -eq 0 ]] \
        || die "Trusted file is not root-owned and protected: $path"
    current=$(dirname "$path")
    while :; do
        [[ -d "$current" && ! -L "$current" ]] \
            || die "Unsafe trusted directory: $current"
        metadata=$(stat -Lc '%u %a' "$current")
        read -r owner mode <<< "$metadata"
        [[ "$owner" == 0 && $((8#$mode & 8#022)) -eq 0 ]] \
            || die "Trusted directory is not root-owned and protected: $current"
        [[ "$current" == / ]] && break
        current=${current%/*}; [[ -n "$current" ]] || current=/
    done
}

verify_source() {
    local file
    for file in Kbuild Makefile nct6687.c LICENSE README.md source.sha256 \
        .bc250-source; do
        secure_root_file "$SOURCE/$file"
    done
    [[ "$(<"$SOURCE/.bc250-source")" == a49a8abdfb6221772ecc836b3109e0cc338203cf ]] \
        || die "Trusted source revision does not match the pinned commit."
    (cd "$SOURCE" && sha256sum -c --quiet source.sha256) \
        || die "Trusted source integrity verification failed."
}

read_options() {
    secure_root_file "$OPTIONS_FILE"
    IFS= read -r MODULE_OPTIONS < "$OPTIONS_FILE"
    [[ "$MODULE_OPTIONS" =~ ^force=[01]$ ]] \
        || die "Invalid persisted module options."
}

installed_module_valid() {
    local expected actual selected
    [[ -f "$INSTALLED_KO" && ! -L "$INSTALLED_KO" \
        && -f "$INSTALLED_MARKER" && ! -L "$INSTALLED_MARKER" ]] || return 1
    secure_root_file "$INSTALLED_KO"
    secure_root_file "$INSTALLED_MARKER"
    grep -Fqx '# BC-250 toolkit managed NCT6687 installed module.' \
        "$INSTALLED_MARKER" || return 1
    expected=$(sed -n 's/^sha256=//p' "$INSTALLED_MARKER")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum "$INSTALLED_KO" | cut -d' ' -f1)
    [[ "$actual" == "$expected" && "$(ko_kver "$INSTALLED_KO")" == "$KVER" ]] \
        || return 1
    selected=$(modinfo -k "$KVER" -n nct6687 2>/dev/null) || return 1
    [[ "$selected" -ef "$INSTALLED_KO" ]]
}

staged_module_valid() {
    local expected actual
    secure_root_file "$STAGED_KO"
    secure_root_file "$STAGED_MARKER"
    grep -Fqx '# BC-250 toolkit managed NCT6687 staged module.' \
        "$STAGED_MARKER" || return 1
    expected=$(sed -n 's/^sha256=//p' "$STAGED_MARKER")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum "$STAGED_KO" | cut -d' ' -f1)
    [[ "$actual" == "$expected" && "$(ko_kver "$STAGED_KO")" == "$KVER" ]]
}

find_owned_hwmon() {
    local name module
    for name in /sys/class/hwmon/hwmon*/name; do
        [[ -r "$name" ]] || continue
        case "$(<"$name")" in nct6683|nct6686|nct6687) ;; *) continue ;; esac
        module=$(readlink -f "${name%/*}/device/driver/module" 2>/dev/null || true)
        [[ "$module" == /sys/module/nct6687 ]] || continue
        printf '%s\n' "$(<"$name")"
        return 0
    done
    return 1
}

verify_source
read_options

if [[ -d /sys/module/nct6687 ]]; then
    hwmon_name=$(find_owned_hwmon) \
        || die "Loaded nct6687 module did not register its own hwmon device."
    log "module already loaded for $KVER; hwmon=$hwmon_name"
    exit
fi

if installed_module_valid; then
    source_kind=installed
    load_kind=modprobe
else
    staged_module_valid \
        || die "No verified module is staged for $KVER; rerun the interactive fan-driver installer."
    source_kind=staged
    load_kind=insmod
fi

stock_loaded=0
if [[ -d /sys/module/nct6683 ]]; then
    stock_loaded=1
    modprobe -r nct6683 \
        || die "The stock nct6683 module is busy and blocks the enhanced driver."
fi
if [[ "$load_kind" == modprobe ]]; then
    modprobe nct6687 || {
        [[ $stock_loaded -eq 0 ]] || modprobe nct6683 2>/dev/null || true
        die "Could not load the installed enhanced driver."
    }
else
    insmod "$STAGED_KO" "$MODULE_OPTIONS" || {
        [[ $stock_loaded -eq 0 ]] || modprobe nct6683 2>/dev/null || true
        die "Could not load the staged enhanced driver."
    }
fi

hwmon_name=$(find_owned_hwmon) \
    || {
        rmmod nct6687 2>/dev/null || true
        [[ $stock_loaded -eq 0 ]] || modprobe nct6683 2>/dev/null || true
        die "Module loaded but did not register its own NCT6683/6686/6687 hwmon device."
    }
log "$source_kind module loaded for $KVER; hwmon=$hwmon_name"
