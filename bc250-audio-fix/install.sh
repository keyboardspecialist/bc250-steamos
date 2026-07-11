#!/bin/bash
# Install the patched amdgpu.ko (BC-250 DP audio clock fix) via the
# modules updates/ override. Run as: sudo ./install.sh
set -euo pipefail

REL=$(uname -r)
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/amdgpu.ko.zst
DST=/usr/lib/modules/$REL/updates/amdgpu.ko.zst

[ -f "$SRC" ] || { echo "missing $SRC — the module is not shipped in the repo; build it against your running kernel first: ./fetch-sources.sh && ./build.sh"; exit 1; }
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

# Preset name follows the kernel package (linux-neptune-616 -> -618 across
# SteamOS 3.8 -> 3.9), so derive it from the running kernel release.
[[ "$REL" =~ neptune-[0-9]+ ]] && PRESET=linux-${BASH_REMATCH[0]} || PRESET=
[ -n "$PRESET" ] && [ -f "/etc/mkinitcpio.d/$PRESET.preset" ] || {
    echo "cannot find an mkinitcpio preset for '$REL' — available:"
    ls /etc/mkinitcpio.d/
    echo "module is installed and depmod done; rerun after fixing: mkinitcpio -p <preset>"
    exit 1
}
mkinitcpio -p "$PRESET"
echo "OK — patched amdgpu installed. Reboot to activate."
