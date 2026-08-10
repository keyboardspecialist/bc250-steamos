#!/bin/bash
# Install the patched amdgpu.ko (display, metrics, and compute-queue fixes) via the
# modules updates/ override. Run as: sudo ./install.sh
set -euo pipefail

REL=$(uname -r)
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/amdgpu.ko.zst
ATTESTATION=$HERE/amdgpu.gfx1013.attestation
DST=/usr/lib/modules/$REL/updates/amdgpu.ko.zst
MARKER=/usr/lib/modules/$REL/updates/.bc250-audio-fix
METRICS_MARKER=/usr/lib/modules/$REL/updates/.bc250-metrics-fix
GFX1013_MARKER=/usr/lib/modules/$REL/updates/.bc250-gfx1013-fix
BOOT_CONFIG=$HERE/boot-config.sh
SCHED_CONFIG=/etc/default/grub.d/bc250-amdgpu.cfg
AMDGPU_KEEP_FILE=/etc/atomic-update.conf.d/bc250-amdgpu.conf
GRUB_CFG=/efi/EFI/steamos/grub.cfg
GRUB_CONFIG_LOCK=/run/lock/bc250-grub-config.lock

[ -f "$SRC" ] || { echo "missing $SRC — the module is not shipped in the repo; build it against your running kernel first: ./fetch-sources.sh && ./build.sh"; exit 1; }
[ -f "$ATTESTATION" ] && [ ! -L "$ATTESTATION" ] \
    || { echo "missing GFX1013 build attestation — rebuild with ./build.sh"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

read -r ATTESTED_COMMIT ATTESTED_SHA < "$ATTESTATION" \
    || { echo "invalid GFX1013 build attestation — rebuild with ./build.sh"; exit 1; }
ACTUAL_SHA=$(sha256sum "$SRC" | awk '{print $1}')
[ "$ATTESTED_COMMIT" = d3e6dc062c34d2523db0abe5741d1f5b0dea00d9 ] \
    && [[ "$ATTESTED_SHA" =~ ^[0-9a-f]{64}$ ]] \
    && [ "$ATTESTED_SHA" = "$ACTUAL_SHA" ] \
    || { echo "GFX1013 build attestation does not match amdgpu.ko.zst — rebuild with ./build.sh"; exit 1; }

[[ "$REL" =~ neptune-[0-9]+ ]] && PRESET=linux-${BASH_REMATCH[0]} || PRESET=
[ -n "$PRESET" ] && [ -f "/etc/mkinitcpio.d/$PRESET.preset" ] || {
    echo "cannot find an mkinitcpio preset for '$REL' — available:"
    ls /etc/mkinitcpio.d/
    exit 1
}

# Both guards (vermagic + task_struct ABI offsets) live in check-module.sh,
# shared with build.sh — see the comments there for why each exists.
# Any nonzero result is fatal. Vermagic alone cannot detect the task_struct
# layout mismatch that previously produced a boot-time black screen.
rc=0
"$HERE/check-module.sh" "$SRC" "$REL" || rc=$?
if [ "$rc" != 0 ]; then
    echo "Refusing to install. Rebuild against the running kernel first (./build.sh)."
    exit 1
fi

ROOTFS_WAS_READONLY=0
INSTALL_STARTED=0
INSTALL_OK=0
BOOT_CONFIG_INSTALLED=0
TMPD=$(mktemp -d)
PRIORITY_FILE=/usr/lib/depmod.d/10-bc250-audio-fix.conf
restore_boot_file() {
    local backup=$1 target=$2 tmp
    if [ -f "$backup" ]; then
        tmp=$(mktemp "${target%/*}/.bc250-restore.XXXXXX") || return 1
        if ! cp -p "$backup" "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        mv -f "$tmp" "$target"
    else
        rm -f "$target"
    fi
}
cleanup() {
    local boot_restore_failed=0
    if [ "$INSTALL_STARTED" = 1 ] && [ "$INSTALL_OK" = 0 ]; then
        echo "install failed; restoring the previous module override" >&2
        if [ -f "$TMPD/original.ko.zst" ]; then
            install -D -m644 "$TMPD/original.ko.zst" "$DST"
        else
            rm -f "$DST"
        fi
        if [ -f "$TMPD/original-marker" ]; then
            install -D -m644 "$TMPD/original-marker" "$MARKER"
        else
            rm -f "$MARKER"
        fi
        if [ -f "$TMPD/original-metrics-marker" ]; then
            install -D -m644 "$TMPD/original-metrics-marker" "$METRICS_MARKER"
        else
            rm -f "$METRICS_MARKER"
        fi
        if [ -f "$TMPD/original-gfx1013-marker" ]; then
            install -D -m644 "$TMPD/original-gfx1013-marker" "$GFX1013_MARKER"
        else
            rm -f "$GFX1013_MARKER"
        fi
        if [ -f "$TMPD/original-priority.conf" ]; then
            install -D -m644 "$TMPD/original-priority.conf" "$PRIORITY_FILE"
        else
            rm -f "$PRIORITY_FILE"
        fi
        depmod "$REL" || true
        if mkinitcpio -p "$PRESET" >/dev/null 2>&1; then
            if [ "$BOOT_CONFIG_INSTALLED" = 1 ]; then
                restore_boot_file "$TMPD/original-amdgpu.cfg" "$SCHED_CONFIG" || boot_restore_failed=1
                restore_boot_file "$TMPD/original-amdgpu-keep.conf" "$AMDGPU_KEEP_FILE" || boot_restore_failed=1
                restore_boot_file "$TMPD/original-grub.cfg" "$GRUB_CFG" || boot_restore_failed=1
                if [ "$boot_restore_failed" = 1 ]; then
                    echo "warning: failed to restore part of the previous boot-policy state" >&2
                fi
            fi
        elif [ "$BOOT_CONFIG_INSTALLED" = 1 ]; then
            echo "stock initramfs regeneration failed; retaining amdgpu.sched_policy=2 for boot safety" >&2
        fi
    fi
    rm -rf "$TMPD"
    if [ "$ROOTFS_WAS_READONLY" = 1 ]; then steamos-readonly enable || true; fi
}
trap cleanup EXIT
command -v flock >/dev/null 2>&1 || { echo "flock is required for safe GRUB changes" >&2; exit 1; }
exec 8> "$GRUB_CONFIG_LOCK"
flock 8 || { echo "could not lock $GRUB_CONFIG_LOCK" >&2; exit 1; }
if [ -f "$DST" ]; then cp -a "$DST" "$TMPD/original.ko.zst"; fi
if [ -f "$MARKER" ]; then cp -a "$MARKER" "$TMPD/original-marker"; fi
if [ -f "$METRICS_MARKER" ]; then cp -a "$METRICS_MARKER" "$TMPD/original-metrics-marker"; fi
if [ -f "$GFX1013_MARKER" ]; then cp -a "$GFX1013_MARKER" "$TMPD/original-gfx1013-marker"; fi
if [ -f "$PRIORITY_FILE" ]; then cp -a "$PRIORITY_FILE" "$TMPD/original-priority.conf"; fi
if [ -f "$SCHED_CONFIG" ]; then cp -a "$SCHED_CONFIG" "$TMPD/original-amdgpu.cfg"; fi
if [ -f "$AMDGPU_KEEP_FILE" ]; then cp -a "$AMDGPU_KEEP_FILE" "$TMPD/original-amdgpu-keep.conf"; fi
if [ -f "$GRUB_CFG" ]; then cp -a "$GRUB_CFG" "$TMPD/original-grub.cfg"; fi
if steamos-readonly status 2>/dev/null | grep -qi enabled; then
    steamos-readonly disable
    ROOTFS_WAS_READONLY=1
fi

INSTALL_STARTED=1
install -D -m644 "$SRC" "$DST"
sha256sum "$DST" | awk '{print $1}' > "$MARKER"
chmod 644 "$MARKER"
install -m644 "$MARKER" "$METRICS_MARKER"
install -m644 "$MARKER" "$GFX1013_MARKER"
depmod "$REL"

RESOLVED=$(modinfo -k "$REL" -F filename amdgpu)
echo "amdgpu now resolves to: $RESOLVED"
if [[ "$RESOLVED" != *"/updates/"* ]]; then
    echo "ERROR: updates/ override not winning; forcing depmod priority"
    mkdir -p /usr/lib/depmod.d
    cat > "$PRIORITY_FILE" <<'EOF'
# Managed by bc250-audio-fix/install.sh
search updates built-in
EOF
    depmod "$REL"
    RESOLVED=$(modinfo -k "$REL" -F filename amdgpu)
    echo "amdgpu now resolves to: $RESOLVED"
    [[ "$RESOLVED" == *"/updates/"* ]] || { echo "still losing — aborting before initramfs"; rm -f "$DST"; depmod "$REL"; exit 1; }
fi

BC250_GRUB_LOCK_HELD=1 "$BOOT_CONFIG" install
BOOT_CONFIG_INSTALLED=1
mkinitcpio -p "$PRESET"
INSTALL_OK=1
echo "OK — display, GPU telemetry, and GFX1013 compute-queue corrections installed with amdgpu.sched_policy=2. Reboot to activate."
