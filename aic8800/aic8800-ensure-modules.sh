#!/bin/bash
# Ensure the AIC8800 dongle's kernel modules are built for and loaded on the
# running kernel. SteamOS updates wipe /lib/modules extras and the pacman
# toolchain; this rebuilds from the repo checkout and loads with insmod so the
# rootfs can stay read-only (except while reinstalling the toolchain).
set -euo pipefail
KVER="$(uname -r)"
PATH_CONF=/etc/aic8800-paths.conf
[ -r "$PATH_CONF" ] || { echo "missing $PATH_CONF; rerun steamdeck-setup.sh"; exit 1; }
# shellcheck source=/dev/null
. "$PATH_CONF"
: "${AIC8800_REPO:?missing AIC8800_REPO in $PATH_CONF}"
: "${AIC8800_BUILD_USER:?missing AIC8800_BUILD_USER in $PATH_CONF}"
DRV="$AIC8800_REPO/src/USB/driver_fw/drivers/aic8800"
FWDIR="$AIC8800_REPO/src/USB/driver_fw/fw/aic8800D80"
LOADFW_KO="$DRV/aic_load_fw/aic_load_fw.ko"
FDRV_KO="$DRV/aic8800_fdrv/aic8800_fdrv.ko"

log() { echo "$*"; }

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

if modinfo -k "$KVER" aic_load_fw >/dev/null 2>&1 \
   && modinfo -k "$KVER" aic8800_fdrv >/dev/null 2>&1; then
    modprobe aic_load_fw
    modprobe aic8800_fdrv
    log "installed modules loaded for $KVER"
    exit 0
fi

ko_kver() { modinfo -F vermagic "$1" 2>/dev/null | cut -d' ' -f1; }

if [ "$(ko_kver "$LOADFW_KO")" != "$KVER" ] \
   || [ "$(ko_kver "$FDRV_KO")" != "$KVER" ]; then
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
        runuser -u "$AIC8800_BUILD_USER" -- make -C "$DRV" steamos-headers
    fi

    log "building modules for $KVER"
    runuser -u "$AIC8800_BUILD_USER" -- make -C "$DRV" clean || true
    runuser -u "$AIC8800_BUILD_USER" -- make -C "$DRV"
    [ "$(ko_kver "$LOADFW_KO")" = "$KVER" ] \
        || { log "built firmware-loader module does not match $KVER"; exit 1; }
    [ "$(ko_kver "$FDRV_KO")" = "$KVER" ] \
        || { log "built WiFi module does not match $KVER"; exit 1; }
fi

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
log "modules loaded for $KVER"
