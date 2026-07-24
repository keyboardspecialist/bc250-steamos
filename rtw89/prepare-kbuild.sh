#!/usr/bin/env bash
# Prepare exact SteamOS Kbuild headers for an external RTW89 module build.
# A kernel image and vmlinux are intentionally not required.
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FETCHER=$HERE/fetch-steamos-package.sh
REL=${KERNEL_RELEASE:-$(uname -r)}
CACHE_ROOT=${RTW89_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/rtw89-steamos}
KDIR=$CACHE_ROOT/kbuild/$REL
SOURCE_KDIR=${RTW89_KBUILD_SOURCE:-}

die() { echo "[rtw89-kbuild] $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "run as the normal build user, not root"
[[ -f $FETCHER && ! -L $FETCHER ]] || die "standalone package fetcher is missing or unsafe"
for command in curl make readlink tar zstd; do
    command -v "$command" >/dev/null || die "required command is absent: $command"
done

case "$REL" in
    *-neptune-*-g*) ;;
    *) die "running release is not a SteamOS Neptune kernel: $REL" ;;
esac
SHA=${REL##*-g}
REST=${REL%-g"$SHA"}
FLAVOR=${REST##*-neptune-}
MID=${REST%-neptune-"$FLAVOR"}
PKGREL=${MID##*-}
KVER=${MID%-"$PKGREL"}
PKGVER=${KVER//-/.}
PACKAGE=linux-neptune-$FLAVOR-headers-$PKGVER-$PKGREL-x86_64.pkg.tar.zst
ARCHIVE=$CACHE_ROOT/packages/$PACKAGE

valid_kbuild() {
    local configured
    [[ -d $KDIR && ! -L $KDIR && -f $KDIR/.rtw89-steamos-kbuild ]] || return 1
    [[ $(<"$KDIR/.rtw89-steamos-kbuild") == "$REL" ]] || return 1
    [[ ! -e $KDIR/vmlinux && ! -L $KDIR/vmlinux ]] || return 1
    [[ -f $KDIR/include/config/kernel.release \
        && ! -L $KDIR/include/config/kernel.release ]] || return 1
    configured=$(<"$KDIR/include/config/kernel.release")
    [[ $configured == "$REL" ]] || return 1
    make -s -C "$KDIR" kernelrelease >/dev/null 2>&1 || return 1
    [[ -s $KDIR/Module.symvers ]] || return 1
}

validate_kbuild_or_die() {
    local configured release
    [[ -d $KDIR && ! -L $KDIR ]] || die "prepared Kbuild directory is missing"
    [[ -f $KDIR/.rtw89-steamos-kbuild && ! -L $KDIR/.rtw89-steamos-kbuild \
        && $(<"$KDIR/.rtw89-steamos-kbuild") == "$REL" ]] \
        || die "prepared Kbuild ownership marker is missing or mismatched"
    [[ ! -e $KDIR/vmlinux && ! -L $KDIR/vmlinux ]] \
        || die "prepared Kbuild still contains vmlinux"
    [[ -f $KDIR/include/config/kernel.release \
        && ! -L $KDIR/include/config/kernel.release ]] \
        || die "prepared Kbuild lacks include/config/kernel.release"
    configured=$(<"$KDIR/include/config/kernel.release")
    [[ $configured == "$REL" ]] \
        || die "headers contain Kbuild release '$configured', running kernel is '$REL'"
    release=$(make -s -C "$KDIR" kernelrelease 2>/dev/null) \
        || die "make could not evaluate the prepared Kbuild tree"
    [[ -n $release ]] || die "make returned an empty Kbuild release"
    [[ -s $KDIR/Module.symvers ]] || die "prepared Kbuild lacks a nonempty Module.symvers"
}

if valid_kbuild; then
    printf '%s\n' "$KDIR"
    exit 0
fi
if [[ -e $KDIR || -L $KDIR ]]; then
    [[ -f $KDIR/.rtw89-steamos-kbuild && ! -L $KDIR/.rtw89-steamos-kbuild ]] \
        || die "refusing to replace unrecognized cache path: $KDIR"
    rm -rf "$KDIR"
fi

mkdir -p "$CACHE_ROOT/packages" "$CACHE_ROOT/kbuild"
STAGE=$(mktemp -d "$CACHE_ROOT/.kbuild.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
if [[ -n $SOURCE_KDIR ]]; then
    SOURCE_KDIR=$(readlink -f "$SOURCE_KDIR") || die "cannot resolve local Kbuild tree"
    [[ -d $SOURCE_KDIR && ! -L $SOURCE_KDIR ]] || die "local Kbuild tree is unsafe"
    [[ -f $SOURCE_KDIR/include/config/kernel.release \
        && ! -L $SOURCE_KDIR/include/config/kernel.release \
        && $(<"$SOURCE_KDIR/include/config/kernel.release") == "$REL" ]] \
        || die "local Kbuild tree does not match exact release $REL"
    make -s -C "$SOURCE_KDIR" kernelrelease >/dev/null 2>&1 \
        || die "make could not evaluate the local Kbuild tree"
    [[ -s $SOURCE_KDIR/Module.symvers ]] || die "local Kbuild tree lacks Module.symvers"
    EXTRACTED=$STAGE/build
    mkdir "$EXTRACTED"
    cp -a "$SOURCE_KDIR"/. "$EXTRACTED"/
else
    EXPECTED_MEMBER="usr/lib/modules/$REL/build/include/config/kernel.release" \
        "$FETCHER" "$PACKAGE" "$ARCHIVE" >&2 \
        || die "exact SteamOS headers package is unavailable: $PACKAGE"
    tar --zstd -xf "$ARCHIVE" -C "$STAGE" "usr/lib/modules/$REL/build" \
        || die "headers package does not contain the exact Kbuild tree"
    EXTRACTED=$STAGE/usr/lib/modules/$REL/build
fi
[[ -d $EXTRACTED && ! -L $EXTRACTED ]] || die "extracted Kbuild tree is unsafe"
if [[ -e $EXTRACTED/vmlinux || -L $EXTRACTED/vmlinux ]]; then
    [[ -f $EXTRACTED/vmlinux && ! -L $EXTRACTED/vmlinux ]] \
        || die "packaged vmlinux path is unsafe"
    rm -f "$EXTRACTED/vmlinux"
fi
printf '%s\n' "$REL" > "$EXTRACTED/.rtw89-steamos-kbuild"
mv "$EXTRACTED" "$KDIR"
trap - EXIT
rm -rf "$STAGE"
validate_kbuild_or_die
printf '%s\n' "$KDIR"
