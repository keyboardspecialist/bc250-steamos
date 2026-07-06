#!/bin/bash
# Remove the patched amdgpu override from the OTHER SteamOS slot (the one
# that black-screened on 2026-07-03) and regenerate its initramfs.
#
# Background: install.sh was run while booted into the other slot, so the
# patched module + initramfs live there. After the black screen the system
# failed over to this slot, so rollback.sh here was a no-op. This script
# chroots into the other slot and does the rollback where it's needed.
#
# Run as: sudo ./cleanup-other-slot.sh
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

REL=$(uname -r)

echo "== current slot: $(findmnt -no SOURCE /) =="
if [ -e "/usr/lib/modules/$REL/updates/amdgpu.ko.zst" ]; then
    echo "NOTE: current slot also has the override — cleaning it first via rollback.sh"
    "$(dirname "$0")/rollback.sh"
fi

echo "== entering other slot chroot =="
steamos-chroot --partset other -- /bin/bash -euo pipefail -c "
    echo \"other slot OS: \$(grep -E 'VERSION_ID|BUILD_ID' /etc/os-release | tr '\n' ' ')\"
    steamos-readonly disable
    rm -fv /usr/lib/modules/*/updates/amdgpu.ko.zst
    rm -fv /usr/lib/depmod.d/10-updates.conf
    # the other slot's kernel may differ from the booted one — depmod what's there
    for d in /usr/lib/modules/*/; do depmod \"\$(basename \"\$d\")\"; done
    RESOLVED=\$(modinfo -F filename amdgpu)
    echo \"other slot: amdgpu now resolves to \$RESOLVED\"
    case \"\$RESOLVED\" in
        */updates/*) echo 'ERROR: override still winning on other slot'; exit 1;;
    esac
    mkinitcpio -p linux-neptune-616
    steamos-readonly enable
"

echo "== verifying other slot initramfs is fresh =="
OTHER_ROOT=$(readlink -f /dev/disk/by-partsets/other/rootfs)
MNT=$(mktemp -d)
mount -o ro "$OTHER_ROOT" "$MNT"
ls -la "$MNT/boot/" | grep -E 'initramfs|vmlinuz' || true
umount "$MNT" && rmdir "$MNT"

echo "OK — other slot cleaned. It should now boot with the stock amdgpu."
