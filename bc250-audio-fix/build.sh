#!/bin/bash
# Build the patched amdgpu.ko against the RUNNING kernel — README runbook
# ("Rebuilding after a SteamOS update") steps 3-8 as code, with every step's
# postcondition asserted. Steps 1-2 stay manual (fetch Valve's source for the
# running kernel, extract the dep packages into deps/); this script verifies
# their results and refuses to continue on any mismatch.
#
#   ./build.sh [--prepare-only] [--allow-missing-symvers] [kernel-tree]
#
# --prepare-only stops after producing an exact external-module Kbuild tree;
# AIC8800 uses this when Valve omitted the matching headers package.
# --allow-missing-symvers is the AIC8800-only fast path. It requires
# --prepare-only and is safe only when CONFIG_MODVERSIONS is disabled.
# Run on the BC-250 itself, as the normal user: the running kernel's
# /proc/config.gz and `uname -r` are the ground truth everything is checked
# against. On success amdgpu.ko.zst here is replaced — but only after the
# fresh module passes the same guards install.sh runs (check-module.sh).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REL=$(uname -r)

die()  { echo "FATAL: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

PREPARE_ONLY=0
ALLOW_MISSING_SYMVERS=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --prepare-only)   PREPARE_ONLY=1 ;;
        --allow-missing-symvers) ALLOW_MISSING_SYMVERS=1 ;;
        *)                ARGS+=("$a") ;;
    esac
done
[ "${#ARGS[@]}" -le 1 ] || die "usage: $0 [--prepare-only] [--allow-missing-symvers] [kernel-tree]"
[ "$ALLOW_MISSING_SYMVERS" = 0 ] || [ "$PREPARE_ONLY" = 1 ] \
    || die "--allow-missing-symvers requires --prepare-only"
TREE_ARG=${ARGS[0]:-$HERE/valve-kernel}
TREE=$(cd "$TREE_ARG" 2>/dev/null && pwd) || die "kernel tree not found: $TREE_ARG"

step "preflight"
[ -r /proc/config.gz ] || die "no /proc/config.gz — run this on the BC-250, not a dev machine"
[ "$(id -u)" != 0 ] || die "build as the normal user; privileged prerequisite and install steps use sudo"
"$HERE/ensure-build-prereqs.sh"
grep -q '^VERSION' "$TREE/Makefile" 2>/dev/null || die "$TREE is not a kernel tree"

# sha embedded in the running release, e.g. ...-g57ac0765fe0d
case "$REL" in
    *-g*) SHA=${REL##*-g} ;;
    *)    die "cannot find -g<sha> suffix in '$REL'" ;;
esac

# The tree's .git may be live or parked (README step 5b). Find it to verify
# the checked-out commit matches the running kernel — the benign-looking
# mismatch here is what turns into a vermagic reject at boot.
PARKED=$TREE-dot-git
[ -d "$TREE/.git" ] && [ -d "$PARKED" ] && die "both $TREE/.git and $PARKED exist — resolve by hand first"
if   [ -d "$TREE/.git" ]; then GITDIR=$TREE/.git
elif [ -d "$PARKED" ];    then GITDIR=$PARKED
else die "no .git for $TREE (live or parked at $PARKED) — need it to verify the checked-out commit"
fi
FULLSHA=$(git --git-dir="$GITDIR" rev-parse HEAD)
[[ "$FULLSHA" == "$SHA"* ]] || die "tree is at $FULLSHA but running kernel is -g$SHA — fetch and check out the matching source (runbook step 1)"
echo "tree commit matches running kernel: $SHA"

step "build environment (runbook step 3)"
# build-env.sh fails loudly if pahole/bc are missing — pahole invisible to
# Kconfig means BTF and with it CONFIG_SCHED_CLASS_EXT get dropped SILENTLY.
# shellcheck source=bc250-audio-fix/build-env.sh
source "$HERE/build-env.sh"
# Ambient cross-build or output-directory settings would silently prepare a
# tree that differs from the native running kernel.
unset LOCALVERSION KERNELRELEASE KBUILD_OUTPUT ARCH SRCARCH CROSS_COMPILE LLVM LLVM_IAS KCONFIG_CONFIG

step "park .git so setlocalversion can't append -dirty (runbook step 5b)"
if [ -d "$TREE/.git" ]; then
    mv "$TREE/.git" "$PARKED"
    echo "parked $TREE/.git -> $PARKED"
else
    echo "already parked: $PARKED"
fi
echo "-g$SHA" > "$TREE/localversion.30-scm"

FULL_BUILD_REQUIRED=$TREE/.bc250-full-build-required
FULL_BUILD_STAMP=$TREE/.bc250-full-build-stamp
FULL_BUILD_PROGRESS=$TREE/.bc250-full-build-in-progress
if [ -f "$FULL_BUILD_REQUIRED" ]; then
    if ! git --git-dir="$GITDIR" --work-tree="$TREE" diff --quiet HEAD -- . \
        && [ "$TREE" != "$HERE/valve-kernel" ] \
        && [ ! -f "$TREE/.bc250-managed-tree" ]; then
        die "$TREE has tracked changes and is not a toolkit-managed tree; refusing to discard them for the full build"
    fi
    git --git-dir="$GITDIR" --work-tree="$TREE" checkout -qf "$FULLSHA"
fi

step "configure from the running kernel (runbook step 4)"
cd "$TREE"
zcat /proc/config.gz > .config.running
cp .config.running .config
make olddefconfig
grep -q '^CONFIG_SCHED_CLASS_EXT=y' .config \
    || die "CONFIG_SCHED_CLASS_EXT lost in olddefconfig — pahole/BTF problem (see README): refusing to build an ABI-incompatible module"
echo "CONFIG_SCHED_CLASS_EXT=y survived olddefconfig"

step "pin the release string (runbook step 5a)"
BASE=$(make -s kernelversion)
[[ "$REL" == "$BASE"* ]] || die "running kernel '$REL' does not start with tree version '$BASE' — wrong source tree"
MIDDLE=${REL#"$BASE"}       # e.g. -1-neptune-616-g<sha>
MIDDLE=${MIDDLE%-g"$SHA"}   # e.g. -1-neptune-616
rm -f localversion.10-pkgrel localversion.20-pkgname
if [[ "$MIDDLE" == *-neptune-616 ]]; then
    # match the Arch packaging's file split (cosmetic — setlocalversion just
    # concatenates localversion* in lexical order)
    echo "${MIDDLE%-neptune-616}" > localversion.10-pkgrel
    echo "-neptune-616"           > localversion.20-pkgname
elif [ -n "$MIDDLE" ]; then
    echo "$MIDDLE" > localversion.10-pkgrel
fi
KREL=$(make -s kernelrelease)
[ "$KREL" = "$REL" ] || die "kernelrelease '$KREL' != running '$REL' — localversion pinning failed"
echo "kernelrelease matches: $KREL"

step "Module.symvers (runbook step 6)"
if [ -f "$FULL_BUILD_REQUIRED" ]; then
    CONFIG_DRIFT=$(scripts/diffconfig .config.running .config) \
        || die "could not compare the running and prepared kernel configs"
    [ -z "$CONFIG_DRIFT" ] \
        || die "olddefconfig changed the running kernel configuration; refusing an ABI-uncertain full build: $CONFIG_DRIFT"
fi
rm -f .config.running
CONFIG_HASH=$(sha256sum .config | awk '{print $1}')
FINGERPRINT=$(printf '%s\n%s\n%s\n' "$REL" "$FULLSHA" "$CONFIG_HASH")

verify_symvers() {
    [ -s Module.symvers ] || return 1
    awk -F '\t' '
        NF >= 4 && $3 == "vmlinux" { builtin=1 }
        NF >= 4 && $3 != "vmlinux" { modular=1 }
        END { exit !(builtin && modular) }
    ' Module.symvers
}

if [ -f "$FULL_BUILD_REQUIRED" ]; then
    CACHED=
    if [ -s "$FULL_BUILD_STAMP" ] \
        && [ "$(cat "$FULL_BUILD_STAMP")" = "$FINGERPRINT" ] \
        && verify_symvers; then
        CACHED=1
        echo "reusing full-build Module.symvers for $REL"
    fi

    if [ -z "$CACHED" ] \
        && [ "$PREPARE_ONLY" = 1 ] \
        && [ "$ALLOW_MISSING_SYMVERS" = 1 ] \
        && grep -qx '# CONFIG_MODVERSIONS is not set' .config; then
        rm -f Module.symvers "$FULL_BUILD_STAMP"
        SYMVERS_OPTIONAL=1
        echo "exact headers are unavailable; preparing the Wi-Fi Kbuild tree without Module.symvers"
        echo "AIC8800 will defer exported-symbol checks to the running kernel"
    elif [ -z "$CACHED" ]; then
        for tool in make gcc ld ar nm objcopy objdump strip perl python3 cpio flex bison msgfmt; do
            command -v "$tool" >/dev/null || die "$tool is required for the full kernel-build fallback"
        done

        MIN_GB=${FULL_BUILD_MIN_FREE_GB:-40}
        [[ "$MIN_GB" =~ ^[0-9]+$ ]] || die "FULL_BUILD_MIN_FREE_GB must be a non-negative integer"
        FREE_KB=$(df -Pk "$TREE" | awk 'NR == 2 { print $4 }')
        [ -n "$FREE_KB" ] || die "could not determine free space for $TREE"
        [ "$FREE_KB" -ge "$((MIN_GB * 1024 * 1024))" ] \
            || die "full kernel build needs about ${MIN_GB} GiB free (override with FULL_BUILD_MIN_FREE_GB)"

        JOBS=${FULL_BUILD_JOBS:-$(nproc)}
        [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "FULL_BUILD_JOBS must be a positive integer"
        if [ -z "${FULL_BUILD_JOBS:-}" ] && [ "$JOBS" -gt 8 ]; then
            JOBS=8
        fi

        if [ -s "$FULL_BUILD_PROGRESS" ] \
            && [ "$(cat "$FULL_BUILD_PROGRESS")" = "$FINGERPRINT" ]; then
            echo "resuming the interrupted full kernel build"
        else
            make clean
            printf '%s' "$FINGERPRINT" > "$FULL_BUILD_PROGRESS"
        fi

        echo "WARNING: exact headers are unavailable; building the complete kernel."
        echo "         This can take hours and use tens of GiB (jobs: $JOBS)."
        make -j"$JOBS" all
        verify_symvers || die "full build did not produce a complete Module.symvers"
        [ "$(cat include/config/kernel.release)" = "$REL" ] \
            || die "full build generated the wrong kernel release"

        cp Module.symvers .bc250-Module.symvers.saved
        make clean
        mv .bc250-Module.symvers.saved Module.symvers
        printf '%s' "$FINGERPRINT" > "$FULL_BUILD_STAMP"
        rm -f "$FULL_BUILD_PROGRESS"
        echo "generated Module.symvers from the exact source"
    fi
fi

if [ -s Module.symvers ]; then
    echo "Module.symvers present ($(wc -l < Module.symvers | tr -d ' ') symbols)"
elif [ "${SYMVERS_OPTIONAL:-0}" = 1 ]; then
    echo "Module.symvers intentionally omitted for Wi-Fi"
else
    die "Module.symvers missing from tree root — the headers package is unavailable and no full-build fallback was requested"
fi

if [ "$PREPARE_ONLY" = 1 ]; then
    step "modules_prepare + config re-verify"
    make -j"$(nproc)" modules_prepare
    grep -q '^#define CONFIG_SCHED_CLASS_EXT 1' include/generated/autoconf.h \
        || die "CONFIG_SCHED_CLASS_EXT missing from autoconf.h after modules_prepare"
    grep -qF "\"$REL\"" include/generated/utsrelease.h \
        || die "utsrelease.h does not carry $REL"
    if [ "${SYMVERS_OPTIONAL:-0}" = 1 ]; then
        grep -qx '# CONFIG_MODVERSIONS is not set' .config \
            || die "CONFIG_MODVERSIONS changed during modules_prepare"
        ! grep -q '^CONFIG_MODVERSIONS=' include/config/auto.conf \
            || die "CONFIG_MODVERSIONS unexpectedly enabled during modules_prepare"
    fi
    echo "prepared exact Kbuild tree: $TREE"
    exit 0
fi

step "apply DP-audio patch (runbook step 7)"
# SteamOS 3.8.x (6.16) needs both hunks; 3.9.x (6.18) already carries the
# clk_mgr DCN 2.01 reorder upstream, leaving only the dcn201
# spread-spectrum-state hunk. New kernel major: check which hunks are upstream
# before adding a variant here.
case "$BASE" in
    6.16.*) PATCH=$HERE/bc250-dp-audio-clock-6.16.patch ;;
    6.18.*) PATCH=$HERE/bc250-dp-audio-clock-6.18.patch ;;
    *)      die "no DP-audio patch variant for kernel $BASE — check which hunks are already upstream, then add a case above" ;;
esac
echo "kernel $BASE -> $(basename "$PATCH")"
if patch -p1 -R --dry-run -s -f < "$PATCH" >/dev/null 2>&1; then
    echo "patch already applied"
elif patch -p1 --dry-run -s -f < "$PATCH" >/dev/null 2>&1; then
    patch -p1 -s < "$PATCH"
    echo "patch applied"
else
    die "patch neither applies nor reverses cleanly — tree has drifted; inspect by hand"
fi

step "apply Cyan Skillfish GPU metrics patches"
METRICS_PATCH=$HERE/bc250-cyan-skillfish-gpu-telemetry.patch
GFXCLK_PATCH=$HERE/bc250-cyan-skillfish-gfxclk.patch

METRICS_SOURCE=drivers/gpu/drm/amd/pm/swsmu/smu11/cyan_skillfish_ppt.c

TELEMETRY_SOURCE_SHA=ab86a4598bf907c6963c0a9b4c43f7a50727ce11993833a0b307d9ae0ae0e017
GFXCLK_SOURCE_SHA=572014e03cff22fb57f21121e8e8722f11d3d99822ee86e60fbfe50ed6e76f30

METRICS_SOURCE_SHA=$(sha256sum "$METRICS_SOURCE" | cut -d' ' -f1)
if [ "$METRICS_SOURCE_SHA" = "$TELEMETRY_SOURCE_SHA" ] \
   || [ "$METRICS_SOURCE_SHA" = "$GFXCLK_SOURCE_SHA" ]; then
    echo "GPU telemetry patch already applied"
elif patch -p1 --dry-run -s -f < "$METRICS_PATCH" >/dev/null 2>&1; then
    patch -p1 -s < "$METRICS_PATCH"
    echo "GPU telemetry patch applied"
else
    die "GPU telemetry patch neither applies nor reverses cleanly — tree has drifted; inspect by hand"
fi

METRICS_SOURCE_SHA=$(sha256sum "$METRICS_SOURCE" | cut -d' ' -f1)
if [ "$METRICS_SOURCE_SHA" = "$GFXCLK_SOURCE_SHA" ]; then
    echo "GPU clock query patch already applied"
elif patch -p1 --dry-run -s -f < "$GFXCLK_PATCH" >/dev/null 2>&1; then
    patch -p1 -s < "$GFXCLK_PATCH"
    echo "GPU clock query patch applied"
else
    die "GPU clock query patch neither applies nor reverses cleanly — tree has drifted; inspect by hand"
fi

step "apply GFX1013 compute-queue lifecycle patches"
GFX1013_UPSTREAM=https://raw.githubusercontent.com/DryhoppedIPA/bc250-gfx1013-fix
GFX1013_COMMIT=d3e6dc062c34d2523db0abe5741d1f5b0dea00d9
GFX1013_CACHE=$HERE/downloads/gfx1013-$GFX1013_COMMIT
mkdir -p "$GFX1013_CACHE"
[ ! -L "$GFX1013_CACHE" ] || die "refusing symlinked GFX1013 patch cache: $GFX1013_CACHE"

fetch_gfx1013_patch() {
    local name=$1 expected=$2 remote=${3:-patches/kernel/v33/$1}
    local target=$GFX1013_CACHE/$1 actual tmp
    if [ -f "$target" ] && [ ! -L "$target" ]; then
        actual=$(sha256sum "$target" | awk '{print $1}')
        [ "$actual" = "$expected" ] && return
    fi
    tmp=$(mktemp "$GFX1013_CACHE/.${name}.XXXXXX")
    curl --retry 3 --retry-all-errors -fsSL \
        "$GFX1013_UPSTREAM/$GFX1013_COMMIT/$remote" -o "$tmp" \
        || { rm -f "$tmp"; die "could not fetch GFX1013 patch $name"; }
    actual=$(sha256sum "$tmp" | awk '{print $1}')
    [ "$actual" = "$expected" ] \
        || { rm -f "$tmp"; die "checksum mismatch for GFX1013 patch $name"; }
    chmod 0644 "$tmp"
    mv -f "$tmp" "$target"
}

apply_gfx1013_patch() {
    local name=$1 label=$2 marker=$3 source_file=$4 patch_file=$GFX1013_CACHE/$1
    if grep -qF "$marker" "$source_file"; then
        echo "$label already applied"
    elif patch -p1 --dry-run -s -f < "$patch_file" >/dev/null 2>&1; then
        patch -p1 -s < "$patch_file"
        rm -f "$source_file.orig"
        echo "$label applied"
    else
        die "$label neither applies nor reverses cleanly — tree has drifted; inspect by hand"
    fi
}

fetch_gfx1013_patch upstream-MIT-LICENSE \
    ddf5d9be5c762bcc5237e36235a1c5f00be521cfc92d8c264dfcce392e2c1313 LICENSE
fetch_gfx1013_patch GPL-2.0-only.txt \
    8780e78a1a737e127f25a65f6d95269bffd36158dc261114de7859b490bfc5aa \
    LICENSES/GPL-2.0-only.txt
fetch_gfx1013_patch upstream-NOTICE.md \
    ccf962b0b8aca2b9a67a2e2081d4edf6a66f8403fdf66a54d08a1ef10367f3eb NOTICE.md
fetch_gfx1013_patch 0001-gfx1013-mmio-pasid-route.patch \
    0f1103241c38c0e81eb453e3c8eecf5b2a60d82ce2b128eef14edff93c3c463b
fetch_gfx1013_patch 0002-gfx1013-compute-gfxoff-guard.patch \
    f44fa410667531a346abc4f45f2886c268b06136b351a10d1cf4581090878bc1
fetch_gfx1013_patch 0003-gfx1013-scoped-pasid-type0.patch \
    64751ed16e09ae4e4248bfbf7a59c3219be26411faea210e53129dc2df7830e3
apply_gfx1013_patch 0001-gfx1013-mmio-pasid-route.patch \
    "GFX1013 MMIO PASID routing" "using MMIO PASID TLB flushes" \
    drivers/gpu/drm/amd/amdgpu/gmc_v10_0.c
apply_gfx1013_patch 0002-gfx1013-compute-gfxoff-guard.patch \
    "GFX1013 compute GFXOFF guard" "GFX1013 COMPUTE_GFXOFF_GUARD" \
    drivers/gpu/drm/amd/amdgpu/amdgpu_amdkfd.c
apply_gfx1013_patch 0003-gfx1013-scoped-pasid-type0.patch \
    "GFX1013 scoped PASID invalidation" "PASID-only CPU type-0 invalidation" \
    drivers/gpu/drm/amd/amdgpu/gmc_v10_0.c
if grep -qF "bc250_gfx1013_fix" drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c; then
    echo "GFX1013 loaded-module attestation already applied"
elif patch -p1 --dry-run -s -f < "$HERE/bc250-gfx1013-attestation.patch" >/dev/null 2>&1; then
    patch -p1 -s < "$HERE/bc250-gfx1013-attestation.patch"
    rm -f drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c.orig
    echo "GFX1013 loaded-module attestation applied"
else
    die "GFX1013 loaded-module attestation neither applies nor is present — tree has drifted"
fi
grep -qF "using MMIO PASID TLB flushes" drivers/gpu/drm/amd/amdgpu/gmc_v10_0.c \
    && grep -qF "GFX1013 COMPUTE_GFXOFF_GUARD" drivers/gpu/drm/amd/amdgpu/amdgpu_amdkfd.c \
    && grep -qF "PASID-only CPU type-0 invalidation" drivers/gpu/drm/amd/amdgpu/gmc_v10_0.c \
    && grep -qF "bc250_gfx1013_fix" drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c \
    || die "GFX1013 compute-queue patch postcondition failed"

step "modules_prepare + config re-verify (runbook step 7)"
make -j"$(nproc)" modules_prepare
grep -q '^#define CONFIG_SCHED_CLASS_EXT 1' include/generated/autoconf.h \
    || die "CONFIG_SCHED_CLASS_EXT missing from autoconf.h after modules_prepare — syncconfig rewrote the config behind your back; check pahole"
grep -qF "\"$REL\"" include/generated/utsrelease.h \
    || die "utsrelease.h does not carry $REL — vermagic would be wrong"
echo "autoconf.h and utsrelease.h verified"

step "build amdgpu (runbook step 7)"
# unconditional clean: syncconfig can regenerate auto.conf without touching
# the include/config/ stamp files, so stale objects would NOT rebuild (README)
make M=drivers/gpu/drm/amd/amdgpu clean
make -j"$(nproc)" M=drivers/gpu/drm/amd/amdgpu modules
KO=drivers/gpu/drm/amd/amdgpu/amdgpu.ko
[ -f "$KO" ] || die "build produced no $KO"

step "package + verify (runbook step 8)"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp "$KO" "$OUT/amdgpu.ko"
strip --strip-debug "$OUT/amdgpu.ko"
zstd -19 -q -f "$OUT/amdgpu.ko" -o "$OUT/amdgpu.ko.zst"

# Same guards install.sh runs — fail HERE, at build time, not standing at the
# console with steamos-readonly disabled. Build-time is strict: exit 2
# ("could not check") is also fatal.
"$HERE/check-module.sh" "$OUT/amdgpu.ko.zst" "$REL" \
    || die "module failed guard checks — NOT replacing $HERE/amdgpu.ko.zst"

MODULE_SHA=$(sha256sum "$OUT/amdgpu.ko.zst" | awk '{print $1}')
printf '%s %s\n' "$GFX1013_COMMIT" "$MODULE_SHA" > "$OUT/amdgpu.gfx1013.attestation"
mv -f "$OUT/amdgpu.ko.zst" "$HERE/amdgpu.ko.zst"
mv -f "$OUT/amdgpu.gfx1013.attestation" "$HERE/amdgpu.gfx1013.attestation"
echo
echo "OK — $HERE/amdgpu.ko.zst built and verified for $REL."
echo "Next: sudo $HERE/install.sh"
