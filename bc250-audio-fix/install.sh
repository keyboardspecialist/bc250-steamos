#!/bin/bash
# Install the patched amdgpu.ko (BC-250 DP audio clock fix) via the
# modules updates/ override. Run as: sudo ./install.sh
set -euo pipefail

REL=$(uname -r)
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/amdgpu.ko.zst
DST=/usr/lib/modules/$REL/updates/amdgpu.ko.zst

[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

# Both guards (vermagic + task_struct ABI offsets) live in check-module.sh,
# shared with build.sh — see the comments there for why each exists.
# Exit 1 = a guard failed: refuse to install. Exit 2 = ABI check could not
# run (stock module or objdump unavailable): warn and continue.
rc=0
"$HERE/check-module.sh" "$SRC" "$REL" || rc=$?
if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then
    echo "Refusing to install. Rebuild against the running kernel first (./build.sh)."
    exit 1
fi

steamos-readonly disable
trap 'steamos-readonly enable' EXIT

install -D -m644 "$SRC" "$DST"
depmod "$REL"

RESOLVED=$(modinfo -F filename amdgpu)
echo "amdgpu now resolves to: $RESOLVED"
if [[ "$RESOLVED" != *"/updates/"* ]]; then
    echo "ERROR: updates/ override not winning; forcing depmod priority"
    mkdir -p /usr/lib/depmod.d
    echo "search updates built-in" > /usr/lib/depmod.d/10-updates.conf
    depmod "$REL"
    RESOLVED=$(modinfo -F filename amdgpu)
    echo "amdgpu now resolves to: $RESOLVED"
    [[ "$RESOLVED" == *"/updates/"* ]] || { echo "still losing — aborting before initramfs"; rm -f "$DST"; depmod "$REL"; exit 1; }
fi

mkinitcpio -p linux-neptune-616
echo "OK — patched amdgpu installed. Reboot to activate."
