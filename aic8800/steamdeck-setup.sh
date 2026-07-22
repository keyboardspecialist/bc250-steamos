#!/bin/bash
# One-shot (re)setup of the AIC8800D80 USB WiFi dongle on the Steam Deck.
# Run:  sudo bash steamdeck-setup.sh [install|uninstall]
#       bash steamdeck-setup.sh status
#
# SteamOS updates/reinstalls wipe /usr (build tools + installed modules).
# This script restores everything:
#   1. unlock the read-only rootfs
#   2. install build tools (make/gcc/...)
#   3. fetch kernel headers matching the running kernel (into the repo, no rootfs pollution)
#   4. build aic_load_fw.ko + aic8800_fdrv.ko
#   5. install them to /usr/lib/modules/$(uname -r)/updates/aic8800 + depmod
#   6. write /etc configs (usb_modeswitch, udev rule, modprobe firmware path)
#   7. relock the rootfs and switch the dongle to WiFi mode
#
# The setup registers its /etc files in SteamOS's atomic-update keep list.
# Run setup after a kernel update; the boot service can rebuild from published
# headers but deliberately leaves the expensive source fallback interactive.
set -euo pipefail

ROOT_DATA_DIR=/var/lib/bc250-control
AIC_DATA_DIR=$ROOT_DATA_DIR/aic8800
ROOT_SOURCE=$AIC_DATA_DIR/source
ROOT_HELPER=$ROOT_DATA_DIR/helper/aic8800-ensure-modules
UNINSTALL_PENDING=$AIC_DATA_DIR/uninstall-pending
SERVICE_UNIT=/etc/systemd/system/aic8800-modules.service
KEEP_FILE=/etc/atomic-update.conf.d/bc250-aic.conf
KREL=$(uname -r)

log() { echo "[aic8800] $*"; }

runtime_artifact_present() {
    local path
    for path in \
        /usr/lib/modules/*/updates/aic8800/aic_load_fw.ko \
        /usr/lib/modules/*/updates/aic8800/aic8800_fdrv.ko \
        "$AIC_DATA_DIR/firmware" "$AIC_DATA_DIR/modules" "$ROOT_HELPER" \
        "$UNINSTALL_PENDING" \
        /etc/modprobe.d/aic8800.conf \
        /etc/udev/rules.d/40-aic8800-modeswitch.rules \
        /etc/usb_modeswitch.d/1111:1111 "$SERVICE_UNIT"; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || return 0
    done
    return 1
}

show_status() {
    local failed=0 state module_dir

    if ! runtime_artifact_present; then
        log "state: not-installed"
        if [ -d "$ROOT_SOURCE" ]; then
            log "persistent source: preserved ($ROOT_SOURCE)"
        fi
        return 1
    fi

    module_dir="/usr/lib/modules/$KREL/updates/aic8800"
    if [ -f "$module_dir/aic_load_fw.ko" ] \
       && [ -f "$module_dir/aic8800_fdrv.ko" ]; then
        state=installed
    elif [ -f "$AIC_DATA_DIR/modules/$KREL/aic_load_fw.ko" ] \
         && [ -f "$AIC_DATA_DIR/modules/$KREL/aic8800_fdrv.ko" ]; then
        state=staged
    else
        state=missing
        failed=1
    fi
    log "modules for $KREL: $state"

    if [ -d /sys/module/aic_load_fw ] && [ -d /sys/module/aic8800_fdrv ]; then
        state=loaded
    else
        state=not-loaded
    fi
    log "module runtime: $state"

    if [ -f "$SERVICE_UNIT" ] && [ -x "$ROOT_HELPER" ] \
       && [ -f "$ROOT_SOURCE/Makefile" ] \
       && command -v systemctl >/dev/null 2>&1 \
       && systemctl is-enabled aic8800-modules.service >/dev/null 2>&1; then
        state=enabled
    else
        state=disabled
        failed=1
    fi
    log "repair service: $state"

    if [ -f /etc/modprobe.d/aic8800.conf ] \
       && [ -f /etc/udev/rules.d/40-aic8800-modeswitch.rules ] \
       && [ -f /etc/usb_modeswitch.d/1111:1111 ]; then
        state=installed
    else
        state=incomplete
        failed=1
    fi
    log "device configuration: $state"

    if [ -d "$AIC_DATA_DIR/firmware/aic8800D80" ]; then
        state=installed
    else
        state=missing
        failed=1
    fi
    log "runtime firmware: $state"
    [ "$failed" = 0 ] && log "state: installed" || log "state: incomplete"
    return "$failed"
}

UNINSTALL_ROOTFS_WAS_READONLY=0
restore_uninstall_rootfs() {
    local rc=$?
    trap - EXIT
    if [ "$UNINSTALL_ROOTFS_WAS_READONLY" = 1 ]; then
        steamos-readonly enable || rc=1
        UNINSTALL_ROOTFS_WAS_READONLY=0
    fi
    exit "$rc"
}

uninstall_aic8800() {
    local module path rel existing reboot_required=0 modules_removed=0
    local update_persist
    local affected_releases=()

    [ "$(id -u)" = 0 ] || { log "uninstall requires root; run: sudo bash $0 uninstall" >&2; return 1; }

    # Stop and disable automatic repair before removing any of its inputs.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now aic8800-modules.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet aic8800-modules.service \
           || systemctl is-enabled --quiet aic8800-modules.service; then
            log "could not disable the repair service; refusing uninstall" >&2
            return 1
        fi
    fi
    command -v flock >/dev/null || { log "flock is required" >&2; return 1; }
    exec 9>/run/lock/bc250-aic8800.lock
    flock 9
    trap restore_uninstall_rootfs EXIT
    update_persist="$(cd "$(dirname "$0")/.." && pwd)/bc250-update-persistence.sh"
    [ -f "$update_persist" ] && [ ! -L "$update_persist" ] \
        || { log "update persistence helper is missing or unsafe: $update_persist" >&2; return 1; }

    if [ -e "$UNINSTALL_PENDING" ] || [ -L "$UNINSTALL_PENDING" ]; then
        [ -f "$UNINSTALL_PENDING" ] && [ ! -L "$UNINSTALL_PENDING" ] \
            || { log "unsafe pending rollback state: $UNINSTALL_PENDING" >&2; return 1; }
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            [[ "$rel" =~ ^[A-Za-z0-9._+-]+$ ]] \
                || { log "unsafe pending kernel release: $rel" >&2; return 1; }
            affected_releases+=("$rel")
        done < "$UNINSTALL_PENDING"
        modules_removed=1
    fi

    for module in aic8800_fdrv aic_load_fw; do
        if [ -d "/sys/module/$module" ]; then
            if ! modprobe -r "$module"; then
                log "could not unload $module; removal will finish after reboot"
                reboot_required=1
            fi
        fi
    done

    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        steamos-readonly disable
        UNINSTALL_ROOTFS_WAS_READONLY=1
    fi

    for path in /usr/lib/modules/*/updates/aic8800/aic_load_fw.ko \
                /usr/lib/modules/*/updates/aic8800/aic8800_fdrv.ko; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        [ -f "$path" ] && [ ! -L "$path" ] \
            || { log "refusing unsafe module path: $path" >&2; return 1; }
        rel=${path#/usr/lib/modules/}
        rel=${rel%%/*}
        if [[ ! "$rel" =~ ^[A-Za-z0-9._+-]+$ ]]; then
            log "refusing module under unsafe kernel release: $rel"
            return 1
        fi
        existing=0
        for module in "${affected_releases[@]}"; do
            [ "$module" != "$rel" ] || existing=1
        done
        if [ "$existing" = 0 ]; then
            affected_releases+=("$rel")
        fi
        modules_removed=1
    done
    if [ "${#affected_releases[@]}" -gt 0 ]; then
        command -v depmod >/dev/null \
            || { log "depmod is required to finish module removal" >&2; return 1; }
        command -v mkinitcpio >/dev/null \
            || { log "mkinitcpio is required to rebuild boot images" >&2; return 1; }
        install -d -o root -g root -m 0755 "$AIC_DATA_DIR"
        printf '%s\n' "${affected_releases[@]}" > "$UNINSTALL_PENDING"
        chmod 0644 "$UNINSTALL_PENDING"
    fi
    for path in /usr/lib/modules/*/updates/aic8800/aic_load_fw.ko \
                /usr/lib/modules/*/updates/aic8800/aic8800_fdrv.ko; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        rm -f "$path"
    done
    for rel in "${affected_releases[@]}"; do
        rmdir "/usr/lib/modules/$rel/updates/aic8800" 2>/dev/null || true
        depmod "$rel"
    done

    rm -f /etc/modprobe.d/aic8800.conf \
        /etc/udev/rules.d/40-aic8800-modeswitch.rules \
        /etc/usb_modeswitch.d/1111:1111 \
        "$SERVICE_UNIT" "$ROOT_HELPER" \
        /etc/aic8800-ensure-modules.sh /etc/aic8800-paths.conf \
        /etc/systemd/system/multi-user.target.wants/aic8800-modules.service \
        /etc/systemd/system/aic8800-modules.service.d/10-bc250-storage.conf
    rmdir /etc/systemd/system/aic8800-modules.service.d 2>/dev/null || true
    rm -rf "$AIC_DATA_DIR/firmware" "$AIC_DATA_DIR/modules"

    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    fi
    if [ "$modules_removed" = 1 ]; then
        mkinitcpio -P
    fi
    rm -f "$UNINSTALL_PENDING"
    bash "$update_persist" remove aic

    log "runtime modules, firmware, configuration, and repair service removed"
    log "persistent source preserved at $ROOT_SOURCE"
    log "repository source and build caches were not removed"
    if [ "$reboot_required" = 1 ]; then
        log "reboot required: yes (a module is still loaded)"
    else
        log "reboot required: no"
    fi
}

usage() {
    cat <<EOF
Usage: $0 [install|status|uninstall|help]

Install and uninstall run as root: sudo bash $0 install|uninstall
Status is read-only and runs as the logged-in user: bash $0 status
Uninstall preserves the persistent source snapshot and downloaded build caches.
EOF
}

case "${1:-install}" in
    status)
        [ "$#" = 1 ] || { usage >&2; exit 2; }
        show_status
        exit
        ;;
    uninstall)
        [ "$#" = 1 ] || { usage >&2; exit 2; }
        uninstall_aic8800
        exit
        ;;
    install)
        [ "$#" -le 1 ] || { usage >&2; exit 2; }
        ;;
    help|-h|--help)
        usage
        exit
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

[ "$(id -u)" = 0 ] || { echo "Please run with sudo."; exit 1; }
command -v flock >/dev/null || { echo "flock is required" >&2; exit 1; }
exec 9>/run/lock/bc250-aic8800.lock
flock 9

REAL_USER="${SUDO_USER:-deck}"
REAL_HOME="${REAL_HOME:-$(getent passwd "$REAL_USER" | cut -d: -f6)}"
[ -n "$REAL_HOME" ] || { echo "Could not resolve home for $REAL_USER"; exit 1; }
FIXES_REPO_DIR="${FIXES_REPO_DIR:-$REAL_HOME/.local/share/bc250-fixes/bc250-steamos}"
[ "$FIXES_REPO_DIR" = "${FIXES_REPO_DIR%[[:space:]]*}" ] \
    && [ "${FIXES_REPO_DIR#/}" != "$FIXES_REPO_DIR" ] \
    || { echo "FIXES_REPO_DIR must be an absolute path without whitespace."; exit 1; }
SCRIPT_REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
UPDATE_PERSIST_SH="$SCRIPT_REPO_DIR/bc250-update-persistence.sh"
STORAGE_SH="$SCRIPT_REPO_DIR/bc250-storage.sh"
HEADER_FETCHER="$SCRIPT_REPO_DIR/fetch-steamos-package.sh"
[ -f "$UPDATE_PERSIST_SH" ] \
    || { echo "Update persistence helper missing: $UPDATE_PERSIST_SH"; exit 1; }
[ -f "$HEADER_FETCHER" ] \
    || { echo "SteamOS package fetcher missing: $HEADER_FETCHER"; exit 1; }
if [ -d "$FIXES_REPO_DIR/aic8800" ]; then
    REPO="$FIXES_REPO_DIR/aic8800"
else
    REPO="$SCRIPT_REPO_DIR/aic8800"
fi
[ "$REPO" = "${REPO%[[:space:]]*}" ] \
    || { echo "The AIC8800 source path cannot contain whitespace."; exit 1; }
DRV=$REPO/src/USB/driver_fw/drivers/aic8800
FW_SOURCE=$REPO/src/USB/driver_fw/fw/aic8800D80
TOOLKIT_ROOT=$(cd "$REPO/.." && pwd)
KERNEL_TREE=$TOOLKIT_ROOT/bc250-audio-fix/valve-kernel
FW=$ROOT_DATA_DIR/aic8800/firmware/aic8800D80
BUILD_USER=$REAL_USER
ROOT_MODULE_STAGE=$ROOT_DATA_DIR/aic8800/modules/$KREL

[ -d "$DRV" ] || { echo "Driver source not found at $DRV"; exit 1; }
[ -d "$FW_SOURCE" ] || { echo "Firmware source not found at $FW_SOURCE"; exit 1; }
[ -f "$STORAGE_SH" ] || { echo "Storage helper missing: $STORAGE_SH"; exit 1; }
if [ -L "$DRV/steamos-headers" ]; then
    DRIVER_LINK=$DRV/steamos-headers
else
    DRIVER_LINK=$(find "$DRV" -path "$DRV/steamos-headers" -prune \
        -o -type l -print -quit)
fi
FIRMWARE_LINK=$(find "$FW_SOURCE" -type l -print -quit)
if [ -n "$DRIVER_LINK" ] || [ -n "$FIRMWARE_LINK" ]; then
    echo "Refusing to install AIC8800 source containing symlinks."
    exit 1
fi
bash "$STORAGE_SH" install

ROOTFS_WAS_READONLY=0
unlock_rootfs() {
    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        steamos-readonly disable
        ROOTFS_WAS_READONLY=1
    fi
}
relock_rootfs() {
    if [ "$ROOTFS_WAS_READONLY" = 1 ]; then
        steamos-readonly enable
        ROOTFS_WAS_READONLY=0
    fi
}
trap relock_rootfs EXIT

repair_kernel_cache_ownership() {
    local path probe owner needs_repair
    local build_uid build_group
    build_uid=$(id -u "$BUILD_USER")
    build_group=$(id -gn "$BUILD_USER")

    for path in "$KERNEL_TREE" "$KERNEL_TREE-dot-git"; do
        [ -e "$path" ] || continue
        [ ! -L "$path" ] || { echo "Refusing symlinked kernel cache: $path"; exit 1; }

        needs_repair=0
        for probe in "$path" "$path/.git"; do
            [ -e "$probe" ] || continue
            owner=$(stat -c '%u' "$probe") \
                || { echo "Could not determine ownership of $probe"; exit 1; }
            [ "$owner" = "$build_uid" ] || needs_repair=1
        done
        if [ "$needs_repair" = 1 ]; then
            echo "Repairing kernel cache ownership for $BUILD_USER: $path"
            chown -R "$BUILD_USER:$build_group" "$path"
        fi
    done
}

find_storage_device() {
    local device vendor product

    for device in /sys/bus/usb/devices/*; do
        [ -r "$device/idVendor" ] && [ -r "$device/idProduct" ] || continue
        vendor=$(<"$device/idVendor")
        product=$(<"$device/idProduct")
        if [ "$vendor:$product" = 1111:1111 ]; then
            printf '%s\n' "${device##*/}"
            return 0
        fi
    done
    return 1
}

find_wifi_device_id() {
    local expected_device="${1:-}" device vendor product vendor_upper product_upper alias

    for device in /sys/bus/usb/devices/*; do
        [ -r "$device/idVendor" ] && [ -r "$device/idProduct" ] || continue
        if [ -n "$expected_device" ] && [ "${device##*/}" != "$expected_device" ]; then
            continue
        fi

        vendor=$(<"$device/idVendor")
        product=$(<"$device/idProduct")
        vendor_upper=$(printf '%s' "$vendor" | tr '[:lower:]' '[:upper:]')
        product_upper=$(printf '%s' "$product" | tr '[:lower:]' '[:upper:]')
        while IFS= read -r alias; do
            case "$alias" in
                "usb:v${vendor_upper}p${product_upper}"*)
                    printf '%s:%s\n' "$vendor" "$product"
                    return 0
                    ;;
            esac
        done < <(modinfo -F alias aic8800_fdrv 2>/dev/null)
    done
    return 1
}

echo "== [1/7] Unlocking rootfs =="
unlock_rootfs

echo "== [2/7] Installing build tools =="
pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate archlinux holo >/dev/null 2>&1 || true
pacman -Sy --noconfirm --needed base-devel git
relock_rootfs

echo "== [3/7] Kernel headers for $KREL =="
repair_kernel_cache_ownership
if [ ! -d "$DRV/steamos-headers/usr/lib/modules/$KREL/build" ]; then
    runuser -u "$BUILD_USER" -- make -C "$DRV" steamos-headers
else
    echo "already present, skipping download"
fi

echo "== [4/7] Building driver =="
runuser -u "$BUILD_USER" -- make -C "$DRV" clean
runuser -u "$BUILD_USER" -- make -C "$DRV"
for module in "$DRV/aic_load_fw/aic_load_fw.ko" "$DRV/aic8800_fdrv/aic8800_fdrv.ko"; do
    BUILT_REL=$(modinfo -F vermagic "$module" 2>/dev/null | cut -d' ' -f1)
    [ "$BUILT_REL" = "$KREL" ] \
        || { echo "Built module $module targets '$BUILT_REL', expected '$KREL'."; exit 1; }
done

echo "== [5/7] Installing modules =="
unlock_rootfs
make -C "$DRV" install

echo "== [6/7] Writing /etc configuration =="
mkdir -p /etc/usb_modeswitch.d /etc/udev/rules.d /etc/modprobe.d

# Dongle enumerates as fake USB mass-storage 1111:1111 (removable disk, so
# the standard CD-ROM eject doesn't work). This vendor SCSI message switches
# it to its actual firmware-loader and WiFi device IDs.
cat > '/etc/usb_modeswitch.d/1111:1111' <<'EOF'
# AIC8800D80 WiFi dongle: fake mass-storage -> WiFi mode
MessageContent="555342431234567800000000000010fd0000000000000000000000000000f2"
ResetUSB=1
EOF

cat > /etc/udev/rules.d/40-aic8800-modeswitch.rules <<'EOF'
# AIC8800D80 WiFi dongle: auto-switch from fake mass-storage to WiFi mode
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="1111", ATTR{idProduct}=="1111", RUN+="/usr/lib/udev/usb_modeswitch '%b/%k'"
EOF

cat > /etc/modprobe.d/aic8800.conf <<EOF
options aic_load_fw aic_fw_path=$FW
EOF

rm -rf "$FW" "$ROOT_SOURCE"
install -d -o root -g root -m 0755 "$FW" "$ROOT_SOURCE" \
    "$(dirname "$ROOT_HELPER")"
cp -RL "$FW_SOURCE"/. "$FW"/
cp -a "$DRV"/. "$ROOT_SOURCE"/
# Headers and source trees are downloaded build input, not trusted source. The
# boot helper fetches exact packaged headers but never prepares kernel source.
rm -rf "$ROOT_SOURCE/steamos-headers"
install -o root -g root -m 0755 "$HEADER_FETCHER" "$ROOT_SOURCE/fetch-steamos-package.sh"
rm -rf "$ROOT_MODULE_STAGE"
install -d -o root -g root -m 0755 "$ROOT_MODULE_STAGE"
install -o root -g root -m 0644 "$DRV/aic_load_fw/aic_load_fw.ko" \
    "$ROOT_MODULE_STAGE/aic_load_fw.ko"
install -o root -g root -m 0644 "$DRV/aic8800_fdrv/aic8800_fdrv.ko" \
    "$ROOT_MODULE_STAGE/aic8800_fdrv.ko"
chown -R root:root "$ROOT_DATA_DIR/aic8800"
chmod -R go-w "$ROOT_DATA_DIR/aic8800"
install -o root -g root -m 0755 "$REPO/aic8800-ensure-modules.sh" "$ROOT_HELPER"
install -m 644 "$REPO/aic8800-modules.service" /etc/systemd/system/aic8800-modules.service
sed -i "/^RequiresMountsFor=/c RequiresMountsFor=$ROOT_DATA_DIR" /etc/systemd/system/aic8800-modules.service
rm -f /etc/aic8800-ensure-modules.sh
rm -f /etc/aic8800-paths.conf

udevadm control --reload
systemctl daemon-reload
systemctl enable aic8800-modules.service >/dev/null
bash "$UPDATE_PERSIST_SH" install aic

echo "== [7/7] Relocking rootfs =="
relock_rootfs

# Source-only preparation can omit Module.symvers, so make the runtime WiFi
# dependency explicit instead of relying solely on generated module metadata.
modprobe cfg80211

if storage_device=$(find_storage_device); then
    echo "Switching dongle to WiFi mode..."
    usb_modeswitch -v 1111 -p 1111 \
        -M "555342431234567800000000000010fd0000000000000000000000000000f2" -R || true

    wifi_id=
    for _ in {1..15}; do
        if wifi_id=$(find_wifi_device_id "$storage_device"); then
            break
        fi
        sleep 1
    done
    if [ -n "$wifi_id" ]; then
        echo "Dongle switched to WiFi mode as $wifi_id."
    else
        echo "WiFi device did not appear; check: journalctl -k -u systemd-udevd"
    fi
elif wifi_id=$(find_wifi_device_id); then
    echo "Dongle already in WiFi mode as $wifi_id; reloading driver..."
    modprobe -r aic8800_fdrv aic_load_fw 2>/dev/null || true
    modprobe aic8800_fdrv
else
    echo "Dongle not detected - plug it in and it will switch automatically."
fi

echo "Done."
