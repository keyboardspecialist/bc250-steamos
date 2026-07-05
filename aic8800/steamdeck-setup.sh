#!/bin/bash
# One-shot (re)setup of the AIC8800D80 USB WiFi dongle on the Steam Deck.
# Run:  sudo bash steamdeck-setup.sh
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
# The /etc files survive updates; steps 1-5 must be re-run after each SteamOS update.
set -euo pipefail

REPO=/home/deck/tools/bc250/aic8800
DRV=$REPO/src/USB/driver_fw/drivers/aic8800
FW=$REPO/src/USB/driver_fw/fw/aic8800D80
BUILD_USER=deck
KREL=$(uname -r)

[ "$(id -u)" = 0 ] || { echo "Please run with sudo."; exit 1; }
[ -d "$DRV" ] || { echo "Driver source not found at $DRV"; exit 1; }

echo "== [1/7] Unlocking rootfs =="
steamos-readonly disable

echo "== [2/7] Installing build tools =="
pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate archlinux holo >/dev/null 2>&1 || true
pacman -Sy --noconfirm --needed base-devel

echo "== [3/7] Kernel headers for $KREL =="
if [ ! -d "$DRV/steamos-headers/usr/lib/modules/$KREL/build" ]; then
    runuser -u "$BUILD_USER" -- make -C "$DRV" steamos-headers
else
    echo "already present, skipping download"
fi

echo "== [4/7] Building driver =="
runuser -u "$BUILD_USER" -- make -C "$DRV" clean
runuser -u "$BUILD_USER" -- make -C "$DRV"

echo "== [5/7] Installing modules =="
make -C "$DRV" install

echo "== [6/7] Writing /etc configuration =="
mkdir -p /etc/usb_modeswitch.d /etc/udev/rules.d /etc/modprobe.d

# Dongle enumerates as fake USB mass-storage 1111:1111 (removable disk, so
# the standard CD-ROM eject doesn't work). This vendor SCSI message makes it
# re-enumerate as a69c:8d80 (firmware loader mode).
cat > '/etc/usb_modeswitch.d/1111:1111' <<'EOF'
# AIC8800D80 WiFi dongle: fake mass-storage -> WiFi mode
TargetVendor=0xa69c
TargetProduct=0x8d80
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

udevadm control --reload

echo "== [7/7] Relocking rootfs =="
steamos-readonly enable

if lsusb -d 1111:1111 >/dev/null 2>&1; then
    echo "Switching dongle to WiFi mode..."
    usb_modeswitch -v 1111 -p 1111 \
        -M "555342431234567800000000000010fd0000000000000000000000000000f2" -R || true
    echo "Firmware upload + driver bind takes ~10s; watch: ip link"
elif lsusb -d a69c:8d81 >/dev/null 2>&1; then
    echo "Dongle already in WiFi mode; reloading driver..."
    modprobe -r aic8800_fdrv aic_load_fw 2>/dev/null || true
    modprobe aic8800_fdrv
else
    echo "Dongle not detected - plug it in and it will switch automatically."
fi

echo "Done."
