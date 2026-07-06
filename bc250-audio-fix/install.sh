#!/bin/bash
# Install the patched amdgpu.ko (BC-250 DP audio clock fix) via the
# modules updates/ override. Run as: sudo ./install.sh
set -euo pipefail

REL=$(uname -r)
SRC="$(cd "$(dirname "$0")" && pwd)/amdgpu.ko.zst"
DST=/usr/lib/modules/$REL/updates/amdgpu.ko.zst

[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

# Guard: refuse to install a module whose vermagic does not match the
# running kernel — modprobe would reject it at boot and, with the
# updates/ override baked into the initramfs, leave the system with no
# GPU driver (this is what forced the 2026-07-02 recovery).
VERMAGIC=$(modinfo -F vermagic "$SRC" | awk '{print $1}')
if [ "$VERMAGIC" != "$REL" ]; then
    echo "ERROR: vermagic mismatch — module is for '$VERMAGIC', kernel is '$REL'"
    echo "Refusing to install. Rebuild against the running kernel first."
    exit 1
fi
echo "vermagic OK: $VERMAGIC"

# Guard 2: vermagic is only a version-string compare and CONFIG_MODVERSIONS
# is off in this kernel, so nothing else validates ABI. A module built with
# a config missing CONFIG_SCHED_CLASS_EXT (happens silently when pahole is
# absent) has every task_struct offset shifted by 256 bytes — it loads fine
# and then hangs with no log output (the 2026-07-05 black screen). Compare
# compiled task_struct offsets in a known function against the stock module.
STOCK=/usr/lib/modules/$REL/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst
if [ -f "$STOCK" ] && command -v objdump >/dev/null; then
    TMPD=$(mktemp -d)
    trap 'rm -rf "$TMPD"' EXIT
    zstd -dq "$STOCK" -o "$TMPD/stock.ko"
    zstd -dq "$SRC"   -o "$TMPD/new.ko"
    for m in stock new; do
        objdump -d --no-show-raw-insn --disassemble=amdgpu_vm_set_task_info \
            "$TMPD/$m.ko" | grep -oE '0x[0-9a-f]+\(%r' > "$TMPD/$m.offsets"
    done
    [ -s "$TMPD/stock.offsets" ] || { echo "ERROR: could not extract reference offsets"; exit 1; }
    if ! cmp -s "$TMPD/stock.offsets" "$TMPD/new.offsets"; then
        echo "ERROR: task_struct field offsets differ from the stock module —"
        echo "the module was built against a mismatched config (check pahole/sched_ext)."
        diff "$TMPD/stock.offsets" "$TMPD/new.offsets" | head
        exit 1
    fi
    echo "ABI OK: task_struct offsets match stock module"
else
    echo "WARNING: skipping ABI check (stock module or objdump unavailable)"
fi

steamos-readonly disable
trap 'rm -rf "${TMPD:-}"; steamos-readonly enable' EXIT

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
