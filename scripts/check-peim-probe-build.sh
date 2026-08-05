#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PACKAGE=$ROOT/bc250-pmfw-pei
EDK2_PIN=6951dfe7d59d144a3a980bd7eda699db2d8554ac
HOST_ONLY=0

unset C_INCLUDE_PATH CPLUS_INCLUDE_PATH CPATH LIBRARY_PATH

if [[ ${1:-} == --host-only ]]; then
    HOST_ONLY=1
    shift
fi
[[ $# -eq 0 ]] || { echo "Usage: $0 [--host-only]" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

clang -std=c11 -Wall -Wextra -Werror \
    -I "$PACKAGE/Tests/Include" -I "$PACKAGE/Include" \
    "$PACKAGE/Bc250Mailbox.c" "$PACKAGE/Tests/test_mailbox.c" \
    -o "$work/test-mailbox"
"$work/test-mailbox"

[[ $HOST_ONLY -eq 0 ]] || exit 0

git clone -q --filter=blob:none --no-checkout \
    https://github.com/tianocore/edk2.git "$work/edk2"
git -C "$work/edk2" checkout -q "$EDK2_PIN"
[[ $(git -C "$work/edk2" rev-parse HEAD) == "$EDK2_PIN" ]]
git -C "$work/edk2" submodule update -q --init --depth 1 \
    BaseTools/Source/C/BrotliCompress/brotli \
    MdePkg/Library/BaseFdtLib/libfdt \
    MdePkg/Library/MipiSysTLib/mipisyst

if [[ ! -r /usr/include/assert.h ]]; then
    command -v pacman >/dev/null \
        || { echo "FATAL: pacman is required to fetch stripped SteamOS headers" >&2; exit 1; }
    command -v curl >/dev/null \
        || { echo "FATAL: curl is required to fetch stripped SteamOS headers" >&2; exit 1; }
    command -v pacman-key >/dev/null \
        || { echo "FATAL: pacman-key is required to verify SteamOS packages" >&2; exit 1; }
    mkdir -p "$work/headers"
    mapfile -t header_urls < <(
        pacman -Sp --print-format '%l' \
            glibc linux-api-headers util-linux util-linux-libs
    )
    [[ ${#header_urls[@]} -eq 4 ]] \
        || { echo "FATAL: could not resolve SteamOS header packages" >&2; exit 1; }
    for url in "${header_urls[@]}"; do
        archive=$work/${url##*/}
        curl --retry 3 --retry-all-errors -fsSL -o "$archive" "$url"
        curl --retry 3 --retry-all-errors -fsSL -o "$archive.sig" "$url.sig"
        pacman-key --verify "$archive.sig" "$archive" >/dev/null
        tar --zstd -tf "$archive" >/dev/null
        tar --zstd -xf "$archive" -C "$work/headers" usr/include \
            2>/dev/null || true
    done
    export C_INCLUDE_PATH="$work/headers/usr/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
    export EXTRA_OPTFLAGS="${EXTRA_OPTFLAGS:-} -idirafter $work/headers/usr/include"
fi

if ! command -v nasm >/dev/null; then
    command -v pacman >/dev/null \
        || { echo "FATAL: nasm is required for the IA32 EDK2 build" >&2; exit 1; }
    nasm_url=$(pacman -Sp --print-format '%l' nasm)
    [[ -n $nasm_url ]] \
        || { echo "FATAL: could not resolve the SteamOS nasm package" >&2; exit 1; }
    nasm_archive=$work/${nasm_url##*/}
    curl --retry 3 --retry-all-errors -fsSL -o "$nasm_archive" "$nasm_url"
    curl --retry 3 --retry-all-errors -fsSL -o "$nasm_archive.sig" "$nasm_url.sig"
    pacman-key --verify "$nasm_archive.sig" "$nasm_archive" >/dev/null
    tar --zstd -tf "$nasm_archive" >/dev/null
    mkdir -p "$work/tools"
    tar --zstd -xf "$nasm_archive" -C "$work/tools" usr/bin/nasm
    export PATH=$work/tools/usr/bin:$PATH
fi

make -s -C "$work/edk2/BaseTools/Source/C"
export WORKSPACE=$work/edk2
export PACKAGES_PATH=$ROOT:$work/edk2
export EDK_TOOLS_PATH=$work/edk2/BaseTools
export PYTHON_COMMAND=python3
set +u
source "$work/edk2/edksetup.sh" BaseTools >/dev/null
set -u

build -a IA32 -t GCC5 -b RELEASE \
    -p bc250-pmfw-pei/Bc250Pkg.dsc \
    -m bc250-pmfw-pei/Bc250EarlyProbePeim.inf

image=$work/edk2/Build/Bc250Peim/RELEASE_GCC5/IA32/Bc250EarlyProbePeim.efi
description=$(LC_ALL=C file -b "$image")
[[ ( ${description,,} == *"intel 80386"* \
      || ${description,,} == *"intel i386"* ) \
    && ( ${description,,} == *"efi (boot service driver)"* \
        || ${description,,} == *"efi boot service driver"* ) ]] \
    || { printf 'Unexpected PEIM image: %s\n' "$description" >&2; exit 1; }

printf 'Built probe-only IA32 PEIM: %s\n' "$description"
