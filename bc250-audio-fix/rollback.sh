#!/bin/bash
# Remove the patched amdgpu override and restore the stock module.
# Run as: sudo ./rollback.sh [kernel-release]
#
# IMPORTANT if running from a recovery-USB chroot: uname -r reports the
# USB's kernel, not the installed one, so the release is auto-detected
# from /usr/lib/modules instead. Pass it explicitly if detection fails.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

REL="${1:-$(uname -r)}"
if [ ! -d "/usr/lib/modules/$REL/kernel" ]; then
    # uname -r doesn't match this system (recovery chroot) — detect instead
    mapfile -t CANDIDATES < <(cd /usr/lib/modules && ls -d */ 2>/dev/null | tr -d /)
    if [ "${#CANDIDATES[@]}" = 1 ]; then
        REL="${CANDIDATES[0]}"
        echo "note: using detected kernel '$REL' (uname -r reports a different kernel)"
    else
        echo "ERROR: cannot determine kernel release. Available in /usr/lib/modules:"
        printf '  %s\n' "${CANDIDATES[@]:-none}"
        echo "Re-run as: sudo ./rollback.sh <kernel-release>"
        exit 1
    fi
fi

# tolerate failure in recovery chroots where / is already mounted rw
steamos-readonly disable || echo "warn: steamos-readonly disable failed (already rw?) — continuing"
trap 'steamos-readonly enable || true' EXIT

rm -f /usr/lib/modules/$REL/updates/amdgpu.ko.zst
depmod "$REL"
echo "amdgpu now resolves to: $(modinfo -F filename amdgpu)"
mkinitcpio -p linux-neptune-616
echo "OK — stock amdgpu restored. Reboot to apply."
