#!/bin/bash
# Ensure the AIC8800 dongle's kernel modules are built for and loaded on the
# running kernel. SteamOS updates wipe /lib/modules extras and the pacman
# toolchain; this rebuilds from the root-owned source snapshot and loads with
# insmod so the rootfs can stay read-only (except while reinstalling tools).
set -euo pipefail
command -v flock >/dev/null || { echo "flock is required" >&2; exit 1; }
exec 9>/run/lock/bc250-aic8800.lock
flock 9
KVER="$(uname -r)"
DRV=/var/lib/bc250-control/aic8800/source
FWDIR=/var/lib/bc250-control/aic8800/firmware
STAGE=/var/lib/bc250-control/aic8800/modules/$KVER
BUILD_LOADFW_KO="$DRV/aic_load_fw/aic_load_fw.ko"
BUILD_FDRV_KO="$DRV/aic8800_fdrv/aic8800_fdrv.ko"
BUILD_ZLP_KO="$DRV/aic_zlp_quirk/aic_zlp_quirk.ko"
LOADFW_KO="$STAGE/aic_load_fw.ko"
FDRV_KO="$STAGE/aic8800_fdrv.ko"
ZLP_KO="$STAGE/aic_zlp_quirk.ko"

log() { echo "$*"; }
ko_kver() { modinfo -F vermagic "$1" 2>/dev/null | cut -d' ' -f1; }
[ -f "$DRV/Makefile" ] || { log "trusted AIC8800 source is missing; rerun steamdeck-setup.sh"; exit 1; }

module_supports_usb_device() {
    local module="$1" vendor="$2" product="$3" alias target
    vendor=$(printf '%s' "$vendor" | tr '[:lower:]' '[:upper:]')
    product=$(printf '%s' "$product" | tr '[:lower:]' '[:upper:]')
    if modinfo -k "$KVER" "$module" >/dev/null 2>&1; then
        target=$module
    elif [ "$module" = aic_load_fw ] && [ -f "$LOADFW_KO" ]; then
        target=$LOADFW_KO
    elif [ "$module" = aic8800_fdrv ] && [ -f "$FDRV_KO" ]; then
        target=$FDRV_KO
    elif [ "$module" = aic_load_fw ] && [ -f "$BUILD_LOADFW_KO" ]; then
        target=$BUILD_LOADFW_KO
    elif [ "$module" = aic8800_fdrv ] && [ -f "$BUILD_FDRV_KO" ]; then
        target=$BUILD_FDRV_KO
    else
        return 1
    fi
    while IFS= read -r alias; do
        case "$alias" in
            "usb:v${vendor}p${product}"*) return 0 ;;
        esac
    done < <(modinfo -F alias "$target" 2>/dev/null)
    return 1
}

aic_loader_present() {
    local device vendor product
    for device in /sys/bus/usb/devices/*; do
        [ -f "$device/idVendor" ] && [ -f "$device/idProduct" ] || continue
        read -r vendor < "$device/idVendor"
        read -r product < "$device/idProduct"
        module_supports_usb_device aic_load_fw "$vendor" "$product" || continue
        module_supports_usb_device aic8800_fdrv "$vendor" "$product" || return 0
    done
    return 1
}

reprobe_aic_loader() {
    local device interface driver vendor product
    for device in /sys/bus/usb/devices/*; do
        [ -f "$device/idVendor" ] && [ -f "$device/idProduct" ] || continue
        read -r vendor < "$device/idVendor"
        read -r product < "$device/idProduct"
        module_supports_usb_device aic_load_fw "$vendor" "$product" || continue
        module_supports_usb_device aic8800_fdrv "$vendor" "$product" && continue
        for interface in "$device":*; do
            [ -d "$interface" ] || continue
            if [ -L "$interface/driver" ]; then
                driver=$(basename "$(readlink -f "$interface/driver")")
                [ "$driver" = aic_load_fw ] || continue
                printf '%s\n' "${interface##*/}" > "$interface/driver/unbind"
            fi
            printf '%s\n' "${interface##*/}" > /sys/bus/usb/drivers_probe
        done
    done
}

aic_runtime_ready() {
    local device interface driver vendor product
    for device in /sys/bus/usb/devices/*; do
        [ -f "$device/idVendor" ] && [ -f "$device/idProduct" ] || continue
        read -r vendor < "$device/idVendor"
        read -r product < "$device/idProduct"
        module_supports_usb_device aic8800_fdrv "$vendor" "$product" || continue
        for interface in "$device":*; do
            [ -L "$interface/driver" ] || continue
            driver=$(basename "$(readlink -f "$interface/driver")")
            [ "$driver" = aic8800_fdrv ] && return 0
        done
    done
    return 1
}

zlp_target_present() {
    local device vendor product
    for device in /sys/bus/usb/devices/*; do
        [ -f "$device/idVendor" ] && [ -f "$device/idProduct" ] || continue
        read -r vendor < "$device/idVendor"
        read -r product < "$device/idProduct"
        [ "${vendor,,}:${product,,}" = 368b:8d81 ] && return 0
    done
    return 1
}

wait_for_aic_runtime() {
    local _
    for _ in {1..15}; do
        aic_runtime_ready && return 0
        sleep 1
    done
    return 1
}

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

loader_present=0
aic_loader_present && loader_present=1

if modinfo -k "$KVER" aic_load_fw >/dev/null 2>&1 \
   && modinfo -k "$KVER" aic8800_fdrv >/dev/null 2>&1 \
   && modinfo -k "$KVER" aic_zlp_quirk >/dev/null 2>&1; then
    modprobe aic_load_fw
    modprobe aic8800_fdrv
    module_source=installed
else
    if [ "$(ko_kver "$LOADFW_KO")" = "$KVER" ] \
       && [ "$(ko_kver "$FDRV_KO")" = "$KVER" ] \
       && [ "$(ko_kver "$ZLP_KO")" = "$KVER" ]; then
        log "reusing staged modules for $KVER"
    else
        if [ "$(ko_kver "$BUILD_LOADFW_KO")" != "$KVER" ] \
           || [ "$(ko_kver "$BUILD_FDRV_KO")" != "$KVER" ] \
           || [ "$(ko_kver "$BUILD_ZLP_KO")" != "$KVER" ]; then
            if ! command -v gcc >/dev/null || ! command -v make >/dev/null; then
                log "toolchain missing (wiped by OS update); reinstalling base-devel"
                unlock_rootfs
                pacman-key --init >/dev/null 2>&1 || true
                pacman-key --populate archlinux >/dev/null 2>&1 || true
                pacman-key --populate holo >/dev/null 2>&1 || true
                pacman -Sy --noconfirm --needed base-devel
                relock_rootfs
            fi

            if [ ! -d "$DRV/steamos-headers/usr/lib/modules/$KVER/build" ] \
               && [ ! -d "/lib/modules/$KVER/build" ]; then
                log "fetching kernel headers for $KVER"
                make -C "$DRV" steamos-headers \
                    || { log "exact headers unavailable; rerun interactive steamdeck-setup.sh for source preparation"; exit 1; }
            fi

            log "building modules for $KVER"
            make -C "$DRV" clean || true
            make -C "$DRV"
            [ "$(ko_kver "$BUILD_LOADFW_KO")" = "$KVER" ] \
                || { log "built firmware-loader module does not match $KVER"; exit 1; }
            [ "$(ko_kver "$BUILD_FDRV_KO")" = "$KVER" ] \
                || { log "built WiFi module does not match $KVER"; exit 1; }
            [ "$(ko_kver "$BUILD_ZLP_KO")" = "$KVER" ] \
                || { log "built Bluetooth ZLP quirk does not match $KVER"; exit 1; }
        fi

        install -d -o root -g root -m 0755 "$STAGE"
        install -o root -g root -m 0644 "$BUILD_LOADFW_KO" "$LOADFW_KO"
        install -o root -g root -m 0644 "$BUILD_FDRV_KO" "$FDRV_KO"
        install -o root -g root -m 0644 "$BUILD_ZLP_KO" "$ZLP_KO"
        [ "$(ko_kver "$LOADFW_KO")" = "$KVER" ] \
            || { log "staged firmware-loader module does not match $KVER"; exit 1; }
        [ "$(ko_kver "$FDRV_KO")" = "$KVER" ] \
            || { log "staged WiFi module does not match $KVER"; exit 1; }
        [ "$(ko_kver "$ZLP_KO")" = "$KVER" ] \
            || { log "staged Bluetooth ZLP quirk does not match $KVER"; exit 1; }
    fi

    # A source-prepared WiFi build may not carry kernel dependency metadata when
    # Valve omitted Module.symvers. Load cfg80211 before validating via insmod.
    modprobe cfg80211

    # insmod does not read /etc/modprobe.d, so pass the firmware path explicitly.
    loaded_fw=0
    if [ ! -d /sys/module/aic_load_fw ]; then
        insmod "$LOADFW_KO" aic_fw_path="$FWDIR"
        loaded_fw=1
    fi
    if [ ! -d /sys/module/aic8800_fdrv ]; then
        insmod "$FDRV_KO" || {
            [ "$loaded_fw" = 0 ] || rmmod aic_load_fw 2>/dev/null || true
            exit 1
        }
    fi
    module_source=staged
fi

if [ "$loader_present" = 1 ] || aic_loader_present; then
    sleep 1
    if aic_loader_present; then
        log "reprobing AIC8800 firmware-loader device after persistent storage recovery"
        reprobe_aic_loader
    fi
    wait_for_aic_runtime \
        || { log "AIC8800 firmware loader did not transition to a runtime device bound to aic8800_fdrv"; exit 1; }
fi

if zlp_target_present && [ ! -d /sys/module/aic_zlp_quirk ]; then
    modprobe btusb
    if [ "$module_source" = installed ]; then
        modprobe aic_zlp_quirk
    else
        insmod "$ZLP_KO"
    fi
fi

log "$module_source modules loaded for $KVER"
