#!/bin/bash
# Ensure the AIC8800 dongle's kernel modules are built for and loaded on the
# running kernel. SteamOS updates wipe /lib/modules extras and the pacman
# toolchain; this rebuilds from the repo checkout and loads with insmod so the
# rootfs can stay read-only (except while reinstalling the toolchain).
set -u
KVER="$(uname -r)"
REPO=/home/deck/code/aic8800/src/USB/driver_fw/drivers/aic8800
FWDIR=/home/deck/code/aic8800/src/USB/driver_fw/fw/aic8800D80
LOADFW_KO="$REPO/aic_load_fw/aic_load_fw.ko"
FDRV_KO="$REPO/aic8800_fdrv/aic8800_fdrv.ko"

log() { echo "$*"; }

# Modules installed in /lib/modules for this kernel: udev autoload handles
# everything, nothing to do.
if modinfo -k "$KVER" aic8800_fdrv >/dev/null 2>&1; then
    log "modules present in /lib/modules for $KVER; nothing to do"
    exit 0
fi

ko_kver() { modinfo -F vermagic "$1" 2>/dev/null | cut -d' ' -f1; }

if [ "$(ko_kver "$FDRV_KO")" != "$KVER" ]; then
    if ! command -v gcc >/dev/null || ! command -v make >/dev/null; then
        log "toolchain missing (wiped by OS update); reinstalling base-devel"
        steamos-readonly disable || exit 1
        trap 'steamos-readonly enable' EXIT
        pacman-key --init >/dev/null 2>&1 || true
        pacman-key --populate archlinux >/dev/null 2>&1 || true
        pacman-key --populate holo >/dev/null 2>&1 || true
        pacman -Sy --noconfirm --needed base-devel || { log "pacman failed"; exit 1; }
        steamos-readonly enable
        trap - EXIT
    fi

    if [ ! -d "$REPO/steamos-headers/usr/lib/modules/$KVER/build" ] \
       && [ ! -d "/lib/modules/$KVER/build" ]; then
        log "fetching kernel headers for $KVER"
        runuser -u deck -- make -C "$REPO" steamos-headers \
            || { log "header fetch failed (is the network up?)"; exit 1; }
    fi

    log "building modules for $KVER"
    runuser -u deck -- make -C "$REPO" clean || true
    runuser -u deck -- make -C "$REPO" || { log "build failed"; exit 1; }
    [ "$(ko_kver "$FDRV_KO")" = "$KVER" ] \
        || { log "built modules do not match $KVER"; exit 1; }
fi

# insmod does not read /etc/modprobe.d, so pass the firmware path explicitly.
[ -d /sys/module/aic_load_fw ]  || insmod "$LOADFW_KO" aic_fw_path="$FWDIR" || exit 1
[ -d /sys/module/aic8800_fdrv ] || insmod "$FDRV_KO" || exit 1
log "modules loaded for $KVER"
