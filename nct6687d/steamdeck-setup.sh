#!/usr/bin/env bash
# Install the pinned NCT6687D fan-control module on SteamOS.
set -euo pipefail

ROOT_DATA_DIR=/var/lib/bc250-control
DATA_DIR=$ROOT_DATA_DIR/nct6687d
ROOT_SOURCE=$DATA_DIR/source
ROOT_HELPER=$ROOT_DATA_DIR/helper/nct6687-ensure-module
OPTIONS_FILE=$DATA_DIR/module-options
SERVICE_UNIT=/etc/systemd/system/nct6687-modules.service
MODPROBE_CONFIG=/etc/modprobe.d/bc250-nct6687.conf
KREL=$(uname -r)
MODULE_DIR=/usr/lib/modules/$KREL/updates/bc250-nct6687
MODULE_KO=$MODULE_DIR/nct6687.ko
MODULE_MARKER=$MODULE_DIR/.bc250-managed
MANAGED_MARKER='# BC-250 toolkit managed NCT6687'

log() { echo "[nct6687] $*"; }
die() { log "$*" >&2; exit 1; }
ko_kver() { modinfo -F vermagic "$1" 2>/dev/null | cut -d' ' -f1; }

restore_automatic_fan_control() {
    local policy=${1:-required} name control found=0 value module
    for name in /sys/class/hwmon/hwmon*/name; do
        [[ -r "$name" ]] || continue
        case "$(<"$name")" in nct6683|nct6686|nct6687) ;; *) continue ;; esac
        module=$(readlink -f "${name%/*}/device/driver/module" 2>/dev/null || true)
        [[ "$module" == /sys/module/nct6687 ]] || continue
        for control in "${name%/*}"/pwm*_enable; do
            [[ -e "$control" ]] || continue
            found=1
            printf '2\n' > "$control" \
                || die "Could not restore firmware fan control through $control."
            IFS= read -r value < "$control"
            [[ "$value" == 2 ]] \
                || die "Firmware automatic mode was not confirmed through $control."
        done
    done
    if [[ $found -ne 1 && "$policy" == required ]]; then
        die "Loaded nct6687 module has no writable PWM controls to restore."
    fi
}

find_nct6687_hwmon() {
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

runtime_artifact_present() {
    local path
    for path in /usr/lib/modules/*/updates/bc250-nct6687/nct6687.ko \
        "$DATA_DIR/modules" "$OPTIONS_FILE" "$ROOT_HELPER" "$SERVICE_UNIT" \
        "$MODPROBE_CONFIG" \
        /etc/atomic-update.conf.d/bc250-fan.conf \
        /etc/systemd/system/multi-user.target.wants/nct6687-modules.service; do
        [[ ! -e "$path" && ! -L "$path" ]] || return 0
    done
    return 1
}

module_copy_valid() {
    local module=$1 marker=$2 kind=${3:-installed} expected actual metadata owner mode selected
    [[ -f "$module" && ! -L "$module" ]] || return 1
    metadata=$(stat -Lc '%u %a' "$module") || return 1
    read -r owner mode <<< "$metadata"
    [[ "$owner" == 0 && $((8#$mode & 8#022)) -eq 0 ]] || return 1
    if [[ -n "$marker" ]]; then
        [[ -f "$marker" && ! -L "$marker" ]] || return 1
        metadata=$(stat -Lc '%u %a' "$marker") || return 1
        read -r owner mode <<< "$metadata"
        [[ "$owner" == 0 && $((8#$mode & 8#022)) -eq 0 ]] || return 1
        grep -Fqx "$MANAGED_MARKER $kind module." "$marker" || return 1
        expected=$(sed -n 's/^sha256=//p' "$marker")
        [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
        actual=$(sha256sum "$module" | cut -d' ' -f1)
        [[ "$actual" == "$expected" ]] || return 1
    fi
    [[ "$(ko_kver "$module")" == "$KREL" ]] || return 1
    if [[ "$kind" == installed ]]; then
        selected=$(modinfo -k "$KREL" -n nct6687 2>/dev/null) || return 1
        [[ "$selected" -ef "$module" ]]
    fi
}

show_status() {
    local failed=0 state hwmon=- options=- keep_file=/etc/atomic-update.conf.d/bc250-fan.conf
    if ! runtime_artifact_present; then
        log "state: not-installed"
        [[ ! -d "$ROOT_SOURCE" ]] || log "persistent source: preserved ($ROOT_SOURCE)"
        return 1
    fi

    if module_copy_valid "$MODULE_KO" "$MODULE_MARKER"; then
        state=installed
    elif module_copy_valid "$DATA_DIR/modules/$KREL/nct6687.ko" \
        "$DATA_DIR/modules/$KREL/.bc250-managed" staged; then
        state=staged
    else
        state=missing; failed=1
    fi
    log "module for $KREL: $state"

    if [[ -d /sys/module/nct6687 ]]; then state=loaded; else state=not-loaded; failed=1; fi
    log "module runtime: $state"
    hwmon=$(find_nct6687_hwmon || true)
    if [[ -z "$hwmon" ]]; then failed=1; hwmon=-; fi
    log "hwmon: $hwmon"

    if [[ -f "$OPTIONS_FILE" && ! -L "$OPTIONS_FILE" ]]; then
        IFS= read -r options < "$OPTIONS_FILE"
    fi
    if [[ ! "$options" =~ ^force=[01]$ ]] \
        || [[ ! -f "$MODPROBE_CONFIG" || -L "$MODPROBE_CONFIG" ]] \
        || ! grep -Fxq "$MANAGED_MARKER driver options." "$MODPROBE_CONFIG" \
        || ! grep -Fxq 'blacklist nct6683' "$MODPROBE_CONFIG" \
        || ! grep -Fxq "options nct6687 $options" "$MODPROBE_CONFIG"; then
        failed=1
    fi
    log "load option: $options"

    if [[ -f "$SERVICE_UNIT" && ! -L "$SERVICE_UNIT" \
        && -x "$ROOT_HELPER" && ! -L "$ROOT_HELPER" \
        && -f "$ROOT_SOURCE/Kbuild" && ! -L "$ROOT_SOURCE/Kbuild" ]] \
        && systemctl is-enabled nct6687-modules.service >/dev/null 2>&1; then
        state=enabled
    else
        state=incomplete; failed=1
    fi
    log "repair service: $state"

    if [[ -f "$keep_file" && ! -L "$keep_file" \
        && "$(sed -n '1p' "$keep_file")" == '# Toolkit state preserved by SteamOS atomic updates.' \
        && "$(sed -n '2p' "$keep_file")" == '# Generated by bc250-update-persistence.sh.' ]] \
        && grep -Fxq "$MODPROBE_CONFIG" "$keep_file" \
        && grep -Fxq "$SERVICE_UNIT" "$keep_file"; then
        state=protected
    else
        state=missing; failed=1
    fi
    log "update persistence: $state"
    if [[ $failed -eq 0 ]]; then log "state: installed"; else log "state: incomplete"; fi
    return "$failed"
}

usage() {
    cat << EOF
Usage: $0 install [--force-unknown]
       $0 {status|uninstall|help}

Install and uninstall require root. Status is read-only.
--force-unknown permits only unknown 0xdxxx chip IDs and can be unsafe when the
controller does not use the NCT6687 register map.
EOF
}

command_name=${1:-install}
shift || true
FORCE_UNKNOWN=0
case "$command_name" in
    status) (($# == 0)) || { usage >&2; exit 2; }; show_status; exit ;;
    uninstall) (($# == 0)) || { usage >&2; exit 2; } ;;
    install)
        if (($# == 1)) && [[ $1 == --force-unknown ]]; then
            FORCE_UNKNOWN=1
        elif (($# != 0)); then
            usage >&2; exit 2
        fi
        ;;
    help|-h|--help) (($# == 0)) || { usage >&2; exit 2; }; usage; exit ;;
    *) usage >&2; exit 2 ;;
esac

[[ $EUID -eq 0 ]] || die "Run with sudo."
command -v flock >/dev/null 2>&1 || die "flock is required."

ROOTFS_WAS_READONLY=0
TEMP_DIRS=()
TEMP_FILES=()
INSTALL_COMPLETE=0
PREVIOUS_NCT6687=0
PREVIOUS_NCT6683=0
PREVIOUS_NCT6687_KO=
PREVIOUS_MODULE_OPTIONS=force=0
PRIOR_INSTALLED_VALID=0
PRIOR_STAGED_VALID=0
NEW_STAGE_PROBED=0
STAGED_KO=
restore_rootfs() {
    local rc=$? path
    trap - EXIT
    if [[ $rc -ne 0 && "$command_name" == install && $INSTALL_COMPLETE -eq 0 ]]; then
        if [[ -d /sys/module/nct6687 ]] \
            && ! find_nct6687_hwmon >/dev/null 2>&1; then
            rmmod nct6687 2>/dev/null || true
        fi
        if [[ ! -d /sys/module/nct6687 && $NEW_STAGE_PROBED -eq 1 \
            && -f "$STAGED_KO" && ! -L "$STAGED_KO" ]]; then
            insmod "$STAGED_KO" "force=$FORCE_UNKNOWN" 2>/dev/null || true
        fi
        if [[ -d /sys/module/nct6687 ]] \
            && ! find_nct6687_hwmon >/dev/null 2>&1; then
            rmmod nct6687 2>/dev/null || true
        fi
        if ! find_nct6687_hwmon >/dev/null 2>&1 \
            && [[ $PREVIOUS_NCT6687 -eq 1 ]]; then
            if [[ -n "$PREVIOUS_NCT6687_KO" && -f "$PREVIOUS_NCT6687_KO" \
                && ! -L "$PREVIOUS_NCT6687_KO" ]]; then
                insmod "$PREVIOUS_NCT6687_KO" "$PREVIOUS_MODULE_OPTIONS" \
                    2>/dev/null || true
            else
                modprobe nct6687 2>/dev/null || true
            fi
        fi
        if [[ -d /sys/module/nct6687 ]] \
            && ! find_nct6687_hwmon >/dev/null 2>&1; then
            rmmod nct6687 2>/dev/null || true
        fi
        if ! find_nct6687_hwmon >/dev/null 2>&1 \
            && [[ $PREVIOUS_NCT6683 -eq 1 ]]; then
            modprobe nct6683 2>/dev/null || true
        fi
    fi
    for path in "${TEMP_FILES[@]}"; do
        [[ -n "$path" ]] && rm -f -- "$path"
    done
    for path in "${TEMP_DIRS[@]}"; do
        [[ -n "$path" ]] && rm -rf -- "$path"
    done
    if [[ $ROOTFS_WAS_READONLY -eq 1 ]]; then
        steamos-readonly enable || rc=1
    fi
    exit "$rc"
}
unlock_rootfs() {
    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        steamos-readonly disable
        ROOTFS_WAS_READONLY=1
    fi
}
relock_rootfs() {
    if [[ $ROOTFS_WAS_READONLY -eq 1 ]]; then
        steamos-readonly enable
        ROOTFS_WAS_READONLY=0
    fi
}
trap restore_rootfs EXIT

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOOLKIT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
UPDATE_PERSIST_SH=$TOOLKIT_DIR/bc250-update-persistence.sh
STORAGE_SH=$TOOLKIT_DIR/bc250-storage.sh

safe_managed_file() {
    local path=$1
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    [[ -f "$path" && ! -L "$path" ]] || die "Refusing unsafe managed path: $path"
    grep -Fqx "$MANAGED_MARKER${2:-}" "$path" \
        || die "Refusing to replace unrecognized file: $path"
}

atomic_install() {
    local source=$1 target=$2 mode=$3 dir tmp
    dir=$(dirname "$target")
    install -d -o root -g root -m 0755 "$dir"
    tmp=$(mktemp "$dir/.nct6687.XXXXXX")
    install -o root -g root -m "$mode" "$source" "$tmp"
    sync -d "$tmp"
    mv -f "$tmp" "$target"
    sync -f "$dir"
}

if [[ $command_name == uninstall ]]; then
    if ! runtime_artifact_present; then
        log "Driver is not installed."
        [[ ! -d "$ROOT_SOURCE" ]] || log "Pinned GPL source remains at $ROOT_SOURCE"
        exit 0
    fi
    safe_managed_file "$SERVICE_UNIT" ' module recovery service.'
    safe_managed_file "$MODPROBE_CONFIG" ' driver options.'
    if [[ -e "$ROOT_HELPER" || -L "$ROOT_HELPER" ]]; then
        [[ -f "$ROOT_HELPER" && ! -L "$ROOT_HELPER" ]] \
            || die "Refusing unsafe helper: $ROOT_HELPER"
        grep -Fqx '# BC-250 toolkit managed NCT6687 boot recovery helper.' "$ROOT_HELPER" \
            || die "Refusing to remove unrecognized helper: $ROOT_HELPER"
    fi
    [[ -f "$UPDATE_PERSIST_SH" && ! -L "$UPDATE_PERSIST_SH" ]] \
        || die "Update persistence helper is missing or unsafe."
    KEEP_FILE=/etc/atomic-update.conf.d/bc250-fan.conf
    if [[ -e "$KEEP_FILE" || -L "$KEEP_FILE" ]]; then
        [[ -f "$KEEP_FILE" && ! -L "$KEEP_FILE" \
            && "$(sed -n '1p' "$KEEP_FILE")" == '# Toolkit state preserved by SteamOS atomic updates.' \
            && "$(sed -n '2p' "$KEEP_FILE")" == '# Generated by bc250-update-persistence.sh.' ]] \
            || die "Refusing to remove an unrecognized fan keep list."
    fi
    if [[ -e "$OPTIONS_FILE" || -L "$OPTIONS_FILE" ]]; then
        [[ -f "$OPTIONS_FILE" && ! -L "$OPTIONS_FILE" ]] \
            || die "Refusing unsafe module options: $OPTIONS_FILE"
        IFS= read -r stored_options < "$OPTIONS_FILE"
        [[ "$stored_options" =~ ^force=[01]$ ]] \
            || die "Refusing to remove unrecognized module options."
    fi
    declare -a releases=() module_paths=() marker_paths=()
    for path in /usr/lib/modules/*/updates/bc250-nct6687/nct6687.ko; do
        [[ -e "$path" || -L "$path" ]] || continue
        rel=${path#/usr/lib/modules/}; rel=${rel%%/*}
        [[ "$rel" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Unsafe kernel release: $rel"
        marker=${path%/*}/.bc250-managed
        [[ -f "$path" && ! -L "$path" && -f "$marker" && ! -L "$marker" ]] \
            || die "Refusing to remove an unrecognized module: $path"
        grep -Fqx "$MANAGED_MARKER installed module." "$marker" \
            || die "Refusing to remove an unrecognized module marker: $marker"
        expected=$(sed -n 's/^sha256=//p' "$marker")
        actual=$(sha256sum "$path" | cut -d' ' -f1)
        [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] \
            || die "Installed module integrity check failed: $path"
        releases+=("$rel"); module_paths+=("$path"); marker_paths+=("$marker")
    done
    for stage_dir in "$DATA_DIR"/modules/*; do
        [[ -e "$stage_dir" || -L "$stage_dir" ]] || continue
        [[ -d "$stage_dir" && ! -L "$stage_dir" ]] \
            || die "Refusing unsafe staged-module directory: $stage_dir"
        rel=${stage_dir##*/}
        [[ "$rel" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Unsafe staged kernel release: $rel"
        staged_path=$stage_dir/nct6687.ko
        staged_marker=$stage_dir/.bc250-managed
        [[ -f "$staged_path" && ! -L "$staged_path" \
            && -f "$staged_marker" && ! -L "$staged_marker" ]] \
            || die "Refusing to remove an unrecognized staged module: $stage_dir"
        grep -Fqx "$MANAGED_MARKER staged module." "$staged_marker" \
            || die "Refusing an unrecognized staged-module marker: $staged_marker"
        expected=$(sed -n 's/^sha256=//p' "$staged_marker")
        actual=$(sha256sum "$staged_path" | cut -d' ' -f1)
        [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" \
            && "$(ko_kver "$staged_path")" == "$rel" ]] \
            || die "Staged module integrity check failed: $staged_path"
    done
    if command -v systemctl >/dev/null 2>&1; then
        if [[ ! -f "$SERVICE_UNIT" ]] \
            && systemctl is-enabled --quiet nct6687-modules.service; then
            die "Refusing to disable a service not installed by this toolkit."
        fi
        systemctl disable --now nct6687-modules.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet nct6687-modules.service \
            || systemctl is-enabled --quiet nct6687-modules.service; then
            die "Could not disable the repair service; refusing uninstall."
        fi
    fi
    exec 9>/run/lock/bc250-nct6687.lock
    flock 9
    if [[ -d /sys/module/nct6687 ]]; then
        restore_automatic_fan_control
        modprobe -r nct6687 \
            || die "Could not unload nct6687; stop fan-control software first."
    fi

    unlock_rootfs
    for i in "${!module_paths[@]}"; do
        rm -f "${module_paths[$i]}" "${marker_paths[$i]}"
        rmdir "$(dirname "${module_paths[$i]}")" 2>/dev/null || true
        depmod "${releases[$i]}"
    done
    rm -f "$SERVICE_UNIT" "$MODPROBE_CONFIG" "$ROOT_HELPER" \
        /etc/systemd/system/multi-user.target.wants/nct6687-modules.service \
        /etc/systemd/system/nct6687-modules.service.d/10-bc250-storage.conf
    rmdir /etc/systemd/system/nct6687-modules.service.d 2>/dev/null || true
    rm -rf "$DATA_DIR/modules" "$DATA_DIR/headers"
    rm -f "$OPTIONS_FILE"
    relock_rootfs
    systemctl daemon-reload
    bash "$UPDATE_PERSIST_SH" remove fan
    log "Driver, staged modules, configuration, and repair service removed."
    log "Pinned GPL source preserved at $ROOT_SOURCE"
    exit 0
fi

exec 9>/run/lock/bc250-nct6687.lock
flock 9
[[ "$KREL" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Unsafe kernel release: $KREL"
[[ -f "$UPDATE_PERSIST_SH" && ! -L "$UPDATE_PERSIST_SH" \
    && -f "$STORAGE_SH" && ! -L "$STORAGE_SH" \
    && -f "$SCRIPT_DIR/fetch-source.sh" && ! -L "$SCRIPT_DIR/fetch-source.sh" \
    && -f "$SCRIPT_DIR/nct6687-ensure-module.sh" && ! -L "$SCRIPT_DIR/nct6687-ensure-module.sh" \
    && -f "$SCRIPT_DIR/nct6687-modules.service" && ! -L "$SCRIPT_DIR/nct6687-modules.service" ]] \
    || die "Installer payload is incomplete or unsafe."

REAL_USER=${SUDO_USER:-deck}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[[ -n "$REAL_HOME" ]] || die "Could not resolve home for $REAL_USER."
BUILD_USER=$REAL_USER
CACHE_ROOT=$TOOLKIT_DIR/.build/nct6687d
SOURCE_CACHE=$CACHE_ROOT/source
HEADER_ROOT=$CACHE_ROOT/headers/$KREL
KERNEL_PREPARER=$TOOLKIT_DIR/bc250-audio-fix/prepare-kernel.sh
KERNEL_TREE=$TOOLKIT_DIR/bc250-audio-fix/valve-kernel

bash "$STORAGE_SH" install

log "Installing build prerequisites"
unlock_rootfs
pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate archlinux holo >/dev/null 2>&1 || true
pacman -Sy --noconfirm --needed base-devel curl
relock_rootfs

[[ ! -L "$TOOLKIT_DIR/.build" && ! -L "$CACHE_ROOT" && ! -L "$SOURCE_CACHE" ]] \
    || die "Refusing symlinked build cache."
install -d -o "$BUILD_USER" -g "$(id -gn "$BUILD_USER")" -m 0755 \
    "$TOOLKIT_DIR/.build" "$CACHE_ROOT"
chown -R "$BUILD_USER:$(id -gn "$BUILD_USER")" "$CACHE_ROOT"
runuser -u "$BUILD_USER" -- bash "$SCRIPT_DIR/fetch-source.sh" "$SOURCE_CACHE"

verify_header_package() {
    local package_path=$1 package=$2 index discovered repo url verify_dir
    local mirror=${MIRROR:-https://steamdeck-packages.steamos.cloud/archlinux-mirror}
    local -a repos=()
    command -v pacman-key >/dev/null 2>&1 \
        || die "pacman-key is required to verify kernel headers."
    if [[ -n ${HDR_REPOS:-} ]]; then
        read -r -a repos <<< "$HDR_REPOS"
    else
        repos=(jupiter-main)
        index=$(curl --retry 2 --connect-timeout 10 -fsSL "$mirror/") \
            || die "Could not read the SteamOS package index for signature verification."
        discovered=$(grep -oE 'href="jupiter-[^"/]+/"' <<< "$index" \
            | sed 's|^href="||; s|/"$||' \
            | grep -vxE 'jupiter-(main|ci-test|staging.*)' \
            | sort -rV || true)
        while IFS= read -r repo; do
            [[ -n "$repo" ]] && repos+=("$repo")
        done <<< "$discovered"
    fi
    verify_dir=$(mktemp -d /tmp/nct6687-headers-verify.XXXXXX)
    TEMP_DIRS+=("$verify_dir")
    install -o root -g root -m 0644 "$package_path" "$verify_dir/$package"
    for repo in "${repos[@]}"; do
        [[ "$repo" =~ ^jupiter-[A-Za-z0-9._-]+$ ]] || continue
        url="$mirror/$repo/os/x86_64/$package.sig"
        if curl --retry 2 --connect-timeout 10 -fsSL "$url" \
            -o "$verify_dir/$package.sig" \
            && pacman-key --verify "$verify_dir/$package.sig" >/dev/null 2>&1; then
            log "Verified Valve package signature for $package"
            rm -rf "$verify_dir"
            return 0
        fi
    done
    die "No trusted Valve signature verified the downloaded kernel headers."
}

prepare_headers() {
    local pkgbase flavor pkgver package status prepared_release=
    if [[ -d /lib/modules/$KREL/build ]]; then
        KDIR=/lib/modules/$KREL/build
        return
    fi
    KDIR=$HEADER_ROOT/usr/lib/modules/$KREL/build
    [[ -r /usr/lib/modules/$KREL/pkgbase ]] || die "Kernel pkgbase is unavailable for $KREL."
    pkgbase=$(</usr/lib/modules/$KREL/pkgbase)
    [[ "$pkgbase" =~ ^linux-[A-Za-z0-9._+-]+$ ]] || die "Unsafe kernel pkgbase: $pkgbase"
    flavor=${pkgbase#linux-}
    pkgver=$(sed -e "s/-$flavor-g[0-9a-f]*$//" -e 's/-/./' <<< "$KREL")
    package=$pkgbase-headers-$pkgver-x86_64.pkg.tar.zst
    runuser -u "$BUILD_USER" -- mkdir -p "$HEADER_ROOT"
    set +e
    runuser -u "$BUILD_USER" -- bash "$TOOLKIT_DIR/fetch-steamos-package.sh" \
        "$package" "$HEADER_ROOT/$package"
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        verify_header_package "$HEADER_ROOT/$package" "$package"
        # Never trust an old extracted tree merely because kernel.release
        # matches; regenerate it from the package whose signature just passed.
        runuser -u "$BUILD_USER" -- rm -rf "$HEADER_ROOT/usr"
        runuser -u "$BUILD_USER" -- tar --zstd -xf "$HEADER_ROOT/$package" -C "$HEADER_ROOT"
        KDIR=$HEADER_ROOT/usr/lib/modules/$KREL/build
    elif [[ $status -eq 3 ]]; then
        [[ -f "$KERNEL_PREPARER" && ! -L "$KERNEL_PREPARER" ]] \
            || die "Exact headers are unpublished and the kernel preparer is unavailable."
        runuser -u "$BUILD_USER" -- bash "$KERNEL_PREPARER" --wifi "$KERNEL_TREE"
        KDIR=$KERNEL_TREE
    else
        die "Could not reliably retrieve matching kernel headers."
    fi
    if [[ -r "$KDIR/include/config/kernel.release" ]]; then
        IFS= read -r prepared_release < "$KDIR/include/config/kernel.release"
    fi
    [[ -d "$KDIR" && "$prepared_release" == "$KREL" ]] \
        || die "Prepared headers do not match $KREL."
}

prepare_headers
runuser -u "$BUILD_USER" -- bash -c \
    'cd "$1" && sha256sum -c --quiet source.sha256' _ "$SOURCE_CACHE" \
    || die "Pinned source changed before the build."
build_args=()
if grep -q '^CONFIG_CC_IS_CLANG=y' "$KDIR/include/config/auto.conf" "$KDIR/.config" 2>/dev/null; then
    build_args+=(LLVM=1)
fi
if [[ ! -s "$KDIR/Module.symvers" ]]; then
    grep -qx '# CONFIG_MODVERSIONS is not set' "$KDIR/.config" \
        || die "Module.symvers is required when CONFIG_MODVERSIONS is enabled or unknown."
    build_args+=(KBUILD_MODPOST_WARN=1)
fi
log "Building nct6687.ko for $KREL"
runuser -u "$BUILD_USER" -- make -C "$KDIR" M="$SOURCE_CACHE" \
    "${build_args[@]}" CONFIG_DEBUG_INFO_BTF_MODULES= clean
runuser -u "$BUILD_USER" -- make -C "$KDIR" M="$SOURCE_CACHE" \
    "${build_args[@]}" CONFIG_DEBUG_INFO_BTF_MODULES= modules
runuser -u "$BUILD_USER" -- bash -c \
    'cd "$1" && sha256sum -c --quiet source.sha256' _ "$SOURCE_CACHE" \
    || die "Pinned source changed during the build."
BUILT_KO=$SOURCE_CACHE/nct6687.ko
[[ -f "$BUILT_KO" && ! -L "$BUILT_KO" && "$(ko_kver "$BUILT_KO")" == "$KREL" ]] \
    || die "Built module does not target $KREL."
[[ "$(modinfo -F name "$BUILT_KO")" == nct6687 ]] || die "Unexpected built module name."
[[ "$(modinfo -F license "$BUILT_KO")" == GPL ]] || die "Unexpected built module license."

if [[ -e "$DATA_DIR" || -L "$DATA_DIR" ]]; then
    [[ -d "$DATA_DIR" && ! -L "$DATA_DIR" ]] \
        || die "Refusing unsafe persistent data path: $DATA_DIR"
    read -r data_owner data_mode < <(stat -Lc '%u %a' "$DATA_DIR")
    [[ "$data_owner" == 0 && $((8#$data_mode & 8#022)) -eq 0 ]] \
        || die "Persistent data path is not root-owned and protected: $DATA_DIR"
fi
install -d -o root -g root -m 0755 "$DATA_DIR/modules"
STAGE_DIR=$DATA_DIR/modules/$KREL
if [[ -e "$STAGE_DIR" || -L "$STAGE_DIR" ]]; then
    [[ -d "$STAGE_DIR" && ! -L "$STAGE_DIR" ]] \
        || die "Refusing unsafe staged-module path: $STAGE_DIR"
    module_copy_valid "$STAGE_DIR/nct6687.ko" "$STAGE_DIR/.bc250-managed" staged \
        || die "Refusing to replace an unrecognized staged module."
    PRIOR_STAGED_VALID=1
fi
stage_dir_tmp=$(mktemp -d "$DATA_DIR/.module-stage-$KREL.XXXXXX")
TEMP_DIRS+=("$stage_dir_tmp")
install -o root -g root -m 0644 "$BUILT_KO" "$stage_dir_tmp/nct6687.ko"
[[ "$(ko_kver "$stage_dir_tmp/nct6687.ko")" == "$KREL" ]] \
    || die "Root-staged module does not target $KREL."
[[ "$(modinfo -F name "$stage_dir_tmp/nct6687.ko")" == nct6687 ]] \
    || die "Root-staged module has an unexpected name."
[[ "$(modinfo -F license "$stage_dir_tmp/nct6687.ko")" == GPL ]] \
    || die "Root-staged module has an unexpected license."
STAGED_KO=$stage_dir_tmp/nct6687.ko
staged_sha=$(sha256sum "$STAGED_KO" | cut -d' ' -f1)
printf '%s\nkernel=%s\nsha256=%s\n' "$MANAGED_MARKER staged module." \
    "$KREL" "$staged_sha" > "$stage_dir_tmp/.bc250-managed"
chmod 0644 "$stage_dir_tmp/.bc250-managed"
chown -R root:root "$stage_dir_tmp"

safe_managed_file "$SERVICE_UNIT" ' module recovery service.'
safe_managed_file "$MODPROBE_CONFIG" ' driver options.'
if [[ -e "$ROOT_HELPER" || -L "$ROOT_HELPER" ]]; then
    [[ -f "$ROOT_HELPER" && ! -L "$ROOT_HELPER" ]] \
        || die "Refusing unsafe helper: $ROOT_HELPER"
    grep -Fqx '# BC-250 toolkit managed NCT6687 boot recovery helper.' "$ROOT_HELPER" \
        || die "Refusing to replace unrecognized helper: $ROOT_HELPER"
fi
if [[ -e "$MODULE_KO" || -L "$MODULE_KO" || -e "$MODULE_MARKER" || -L "$MODULE_MARKER" ]]; then
    module_copy_valid "$MODULE_KO" "$MODULE_MARKER" \
        || die "Refusing to replace an unrecognized installed module."
    PRIOR_INSTALLED_VALID=1
fi

if [[ -e "$OPTIONS_FILE" || -L "$OPTIONS_FILE" ]]; then
    [[ -f "$OPTIONS_FILE" && ! -L "$OPTIONS_FILE" ]] \
        || die "Refusing unsafe persisted module options: $OPTIONS_FILE"
    IFS= read -r PREVIOUS_MODULE_OPTIONS < "$OPTIONS_FILE"
    [[ "$PREVIOUS_MODULE_OPTIONS" =~ ^force=[01]$ ]] \
        || die "Refusing to replace unrecognized persisted module options."
fi

if [[ -e "$ROOT_SOURCE" || -L "$ROOT_SOURCE" ]]; then
    [[ -d "$ROOT_SOURCE" && ! -L "$ROOT_SOURCE" \
        && -f "$ROOT_SOURCE/.bc250-source" && ! -L "$ROOT_SOURCE/.bc250-source" \
        && "$(<"$ROOT_SOURCE/.bc250-source")" == a49a8abdfb6221772ecc836b3109e0cc338203cf \
        && -f "$ROOT_SOURCE/source.sha256" && ! -L "$ROOT_SOURCE/source.sha256" ]] \
        || die "Refusing to replace unrecognized persistent source: $ROOT_SOURCE"
    (cd "$ROOT_SOURCE" && sha256sum -c --quiet source.sha256) \
        || die "Existing persistent source integrity check failed."
fi
source_stage=$(mktemp -d "$DATA_DIR/.source-stage.XXXXXX")
TEMP_DIRS+=("$source_stage")
for file in Kbuild Makefile nct6687.c LICENSE README.md source.sha256 .bc250-source; do
    install -o root -g root -m 0644 "$SOURCE_CACHE/$file" "$source_stage/$file"
done
(cd "$source_stage" && sha256sum -c --quiet source.sha256) \
    || die "Staged source integrity verification failed."

config_tmp=$(mktemp)
TEMP_FILES+=("$config_tmp")
printf '%s\nblacklist nct6683\noptions nct6687 force=%s\n' \
    "$MANAGED_MARKER driver options." "$FORCE_UNKNOWN" > "$config_tmp"
service_tmp=$(mktemp)
TEMP_FILES+=("$service_tmp")
cp "$SCRIPT_DIR/nct6687-modules.service" "$service_tmp"

if [[ -d /sys/module/nct6687 ]]; then
    PREVIOUS_NCT6687=1
    if [[ $PRIOR_INSTALLED_VALID -eq 1 ]]; then
        previous_module_source=$MODULE_KO
    elif [[ $PRIOR_STAGED_VALID -eq 1 ]]; then
        previous_module_source=$STAGE_DIR/nct6687.ko
    else
        previous_module_source=
    fi
    if [[ -n "$previous_module_source" ]]; then
        runtime_rollback_dir=$(mktemp -d "$DATA_DIR/.runtime-rollback.XXXXXX")
        TEMP_DIRS+=("$runtime_rollback_dir")
        install -o root -g root -m 0644 "$previous_module_source" \
            "$runtime_rollback_dir/nct6687.ko"
        PREVIOUS_NCT6687_KO=$runtime_rollback_dir/nct6687.ko
    fi
    restore_automatic_fan_control optional
    rmmod nct6687 \
        || die "Could not unload the existing nct6687 module; stop fan-control software first."
fi
if [[ -d /sys/module/nct6683 ]]; then
    PREVIOUS_NCT6683=1
    modprobe -r nct6683 \
        || die "The stock nct6683 module is busy and blocks the enhanced driver."
fi

if ! insmod "$STAGED_KO" "force=$FORCE_UNKNOWN"; then
    if [[ $PREVIOUS_NCT6687 -eq 1 ]]; then modprobe nct6687 || true; fi
    if [[ $PREVIOUS_NCT6683 -eq 1 ]]; then modprobe nct6683 || true; fi
    die "The staged NCT6687 module did not load; the prior module was restored when possible."
fi
if ! hwmon_name=$(find_nct6687_hwmon); then
    rmmod nct6687 2>/dev/null || true
    if [[ $PREVIOUS_NCT6687 -eq 1 ]]; then modprobe nct6687 || true; fi
    if [[ $PREVIOUS_NCT6683 -eq 1 ]]; then modprobe nct6683 || true; fi
    die "The staged module did not register its own NCT6683/6686/6687 hwmon device."
fi
restore_automatic_fan_control
rmmod nct6687 \
    || die "The staged module could not be unloaded after its safety probe."
NEW_STAGE_PROBED=1

rm -rf "$STAGE_DIR"
mv "$stage_dir_tmp" "$STAGE_DIR"
STAGED_KO=$STAGE_DIR/nct6687.ko
rm -rf "$ROOT_SOURCE"
mv "$source_stage" "$ROOT_SOURCE"
chown -R root:root "$ROOT_SOURCE"
chmod -R go-w "$ROOT_SOURCE"
install -d -o root -g root -m 0755 "$(dirname "$ROOT_HELPER")"
printf 'force=%s\n' "$FORCE_UNKNOWN" > "$OPTIONS_FILE"
chown root:root "$OPTIONS_FILE"; chmod 0644 "$OPTIONS_FILE"
atomic_install "$SCRIPT_DIR/nct6687-ensure-module.sh" "$ROOT_HELPER" 0755

unlock_rootfs
install -d -o root -g root -m 0755 "$MODULE_DIR"
atomic_install "$STAGED_KO" "$MODULE_KO" 0644
module_sha=$(sha256sum "$MODULE_KO" | cut -d' ' -f1)
marker_tmp=$(mktemp)
TEMP_FILES+=("$marker_tmp")
printf '%s\nkernel=%s\nsha256=%s\n' "$MANAGED_MARKER installed module." "$KREL" "$module_sha" > "$marker_tmp"
atomic_install "$marker_tmp" "$MODULE_MARKER" 0644
atomic_install "$config_tmp" "$MODPROBE_CONFIG" 0644
atomic_install "$service_tmp" "$SERVICE_UNIT" 0644
rm -f "$config_tmp" "$service_tmp" "$marker_tmp"
depmod "$KREL"
selected_module=$(modinfo -k "$KREL" -n nct6687 2>/dev/null) || selected_module=
[[ -n "$selected_module" && "$selected_module" -ef "$MODULE_KO" ]] \
    || die "depmod did not select the toolkit-installed nct6687 module."
systemctl daemon-reload
systemctl enable nct6687-modules.service >/dev/null
bash "$UPDATE_PERSIST_SH" install fan
relock_rootfs

modprobe nct6687
hwmon_name=$(find_nct6687_hwmon) \
    || die "Module loaded but did not register its own NCT6683/6686/6687 hwmon device."
INSTALL_COMPLETE=1
log "Installed pinned nct6687d source and module for $KREL."
log "Registered hwmon device: $hwmon_name"
log "Use pwmN_enable=2 to restore firmware automatic fan control."
