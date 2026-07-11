#!/bin/bash
# Build the patched amdgpu.ko against the RUNNING kernel — README runbook
# ("Rebuilding after a SteamOS update") steps 3-8 as code, with every step's
# postcondition asserted. Steps 1-2 stay manual (fetch Valve's source for the
# running kernel, extract the dep packages into deps/); this script verifies
# their results and refuses to continue on any mismatch.
#
#   ./build.sh [--cg] [kernel-tree]      (default: ./valve-kernel)
#
# --cg additionally applies the EXPERIMENTAL clock-gating patch
# (bc250-cg-flags.patch, idle power) — off by default until validated.
#
# Run on the BC-250 itself, as the normal user: the running kernel's
# /proc/config.gz and `uname -r` are the ground truth everything is checked
# against. On success amdgpu.ko.zst here is replaced — but only after the
# fresh module passes the same guards install.sh runs (check-module.sh).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REL=$(uname -r)

die()  { echo "FATAL: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

WITH_CG=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --cg) WITH_CG=1 ;;
        *)    ARGS+=("$a") ;;
    esac
done
TREE_ARG=${ARGS[0]:-$HERE/valve-kernel}
TREE=$(cd "$TREE_ARG" 2>/dev/null && pwd) || die "kernel tree not found: $TREE_ARG"

step "preflight"
[ -r /proc/config.gz ] || die "no /proc/config.gz — run this on the BC-250, not a dev machine"
[ "$(id -u)" != 0 ] || die "build as the normal user, not root (only install.sh needs sudo)"
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
source "$HERE/build-env.sh"
unset LOCALVERSION   # would silently append to vermagic

step "park .git so setlocalversion can't append -dirty (runbook step 5b)"
if [ -d "$TREE/.git" ]; then
    mv "$TREE/.git" "$PARKED"
    echo "parked $TREE/.git -> $PARKED"
else
    echo "already parked: $PARKED"
fi
echo "-g$SHA" > "$TREE/localversion.30-scm"

step "configure from the running kernel (runbook step 4)"
cd "$TREE"
zcat /proc/config.gz > .config
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
[ -s Module.symvers ] || die "Module.symvers missing from tree root — copy it from Valve's headers package (modules_prepare cannot generate it; without it modpost drowns in 'undefined!' errors)"
echo "Module.symvers present ($(wc -l < Module.symvers | tr -d ' ') symbols)"

step "apply DP-audio patch (runbook step 7)"
# SteamOS 3.8.x (6.16) needs both hunks; 3.9.x (6.18) already carries the
# clk_mgr DCN 2.01 reorder upstream (was hunk 2), leaving only the
# ignore_dpref_ss hunk. New kernel major: check which hunks are upstream
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

step "clock-gating patch (BC-250 idle power) — EXPERIMENTAL, opt-in via --cg"
# Enables the CG features AMD never wired up for cyan skillfish (cg_flags=0
# upstream). Unvalidated on this silicon, so default builds must NOT carry
# it: without --cg an applied copy left over from a previous --cg build is
# actively reversed, not tolerated. Version-independent code (nv.c switch
# cases); if a kernel bump makes it fail, the hunks are small — refresh
# against the new tree.
CGPATCH=$HERE/bc250-cg-flags.patch
if [ "$WITH_CG" = 1 ]; then
    if patch -p1 -R --dry-run -s -f < "$CGPATCH" >/dev/null 2>&1; then
        echo "cg-flags patch already applied"
    elif patch -p1 --dry-run -s -f < "$CGPATCH" >/dev/null 2>&1; then
        patch -p1 -s < "$CGPATCH"
        echo "cg-flags patch applied"
    else
        die "cg-flags patch neither applies nor reverses cleanly — tree has drifted; inspect by hand"
    fi
else
    if patch -p1 -R --dry-run -s -f < "$CGPATCH" >/dev/null 2>&1; then
        patch -p1 -R -s < "$CGPATCH"
        echo "cg-flags patch REVERSED (leftover from a previous --cg build)"
    elif patch -p1 --dry-run -s -f < "$CGPATCH" >/dev/null 2>&1; then
        echo "skipped (opt in with: ./build.sh --cg)"
    else
        die "tree in unknown state w.r.t. cg-flags patch (neither applied nor pristine) — inspect by hand"
    fi
fi

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

mv -f "$OUT/amdgpu.ko.zst" "$HERE/amdgpu.ko.zst"
echo
echo "OK — $HERE/amdgpu.ko.zst built and verified for $REL."
echo "Next: sudo $HERE/install.sh"
