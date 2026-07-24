#!/usr/bin/env bash
# Hardened SteamOS lifecycle for the pinned morrownr/rtw89 Wi-Fi driver.
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
SOURCE_LOGICAL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -L)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PREPARE_KBUILD=$SCRIPT_DIR/prepare-kbuild.sh
DATA=/home/.steamos/offload/var/lib/rtw89-steamos
ROOT_SOURCE=$DATA/source
ROOT_MODULES=$DATA/modules
ROOT_FIRMWARE=$DATA/firmware
FIRMWARE_INITRAMFS_PENDING=$ROOT_FIRMWARE/initramfs-pending
ROOT_HELPER=$DATA/helper/rtw89-ensure-modules
MODULE_BASE=/usr/lib/modules
CONFIG=/etc/modprobe.d/rtw89-steamos.conf
UNIT=/etc/systemd/system/rtw89-modules.service
ENABLEMENT=/etc/systemd/system/multi-user.target.wants/rtw89-modules.service
KEEP_FILE=/etc/atomic-update.conf.d/rtw89-steamos.conf
PENDING=$DATA/uninstall-pending
MODULE_TXN=$ROOT_MODULES/install-transaction
LEGACY_DATA=/var/lib/bc250-control/rtw89
LEGACY_HELPER=/var/lib/bc250-control/helper/rtw89-ensure-modules
LEGACY_CONFIG=/etc/modprobe.d/bc250-rtw89.conf
LEGACY_KEEP_FILE=/etc/atomic-update.conf.d/bc250-rtw89.conf
LEGACY_DROPIN=/etc/systemd/system/rtw89-modules.service.d/10-bc250-storage.conf
LEGACY_HELPER_SHA=6979edebc9933789ec03ae72f984554cb74982e8d106050af8f852ea09a8d8e2
LEGACY_UNIT_SHA=5548af3e04fc17459a35b2cd9da9afc4271d04d8fa9a264305f9b5330ac9ffe1
LEGACY_CONFIG_SHA=d7f1b894e7448c50e82bc8f13b4265f6321b27137a1115ca3ec55997a262aedc
LEGACY_KEEP_SHA=84b8654145db82683eb14bc4ebf6dfb7af38f1b62064243d5f0044220e493b94
LEGACY_DROPIN_SHA=05e8bb4210fc5b7b69ca5b69bcf1a12cec07e039d06c1dea875451345d36a8fb
EXPECTED_COMMIT=08b8d326937a200a706ec9c501374eec15835b5a
EXPECTED_MAKEFILE_SHA=9e7157c446201a85990b0652b29e79a31d5602cbe3f128b876e612cd14b11a3e
EXPECTED_CONFIG_SHA=59333c2a0312c11bc3a7ecc574f89881380d3c4c1946be1713d476ef62c2c2ee
EXPECTED_SOURCE_MANIFEST_SHA=cc2a6dbf477e27b993dc13d3f2b746563cbee3b847295eef6f448d83facce229
KREL=$(uname -r)
EXPECTED_MODULES=(
    rtw89_core_git rtw89_8851b_git rtw89_8851be_git rtw89_8851bu_git
    rtw89_8852a_git rtw89_8852ae_git rtw89_8852au_git
    rtw89_8852b_common_git rtw89_8852b_git rtw89_8852be_git
    rtw89_8852bu_git rtw89_8852bt_git rtw89_8852bte_git
    rtw89_8852c_git rtw89_8852ce_git rtw89_8852cu_git
    rtw89_8922a_git rtw89_8922ae_git rtw89_8922au_git
    rtw89_pci_git rtw89_usb_git
)
ROOTFS_WAS_READONLY=0
BUILD_DIR=''
MATCH_ENDPOINT=''
MATCH_DEVICE=''
LEGACY_MIGRATED=0

log() { printf '[rtw89] %s\n' "$*"; }
die() { printf '[rtw89] %s\n' "$*" >&2; exit 1; }

usage() {
    cat << EOF
Usage: $0 [install]
       $0 status
       $0 uninstall
       $0 help

Install (the default) and uninstall require root. Status is read-only and may
be run by a normal user. Uninstall preserves the root-owned source snapshot
and per-kernel module build caches.
EOF
}

render_config() {
    printf '%s\n' '# Managed by rtw89/steamdeck-setup.sh.' \
        '# Based on pinned morrownr/rtw89 configuration; local edits are not supported.'
    cat "$SCRIPT_DIR/rtw89.conf"
    printf '\n'
    cat "$SCRIPT_DIR/usb_storage.conf"
}

render_keep_file() {
    cat << EOF
# Managed by rtw89/steamdeck-setup.sh.
# Standalone RTW89 state preserved across SteamOS atomic updates.
$CONFIG
$UNIT
$ENABLEMENT
EOF
}

keep_file_owned() {
    local first
    [[ -f $KEEP_FILE && ! -L $KEEP_FILE ]] || return 1
    IFS= read -r first < "$KEEP_FILE" || return 1
    [[ $first == '# Managed by rtw89/steamdeck-setup.sh.' ]]
}

module_release() {
    modinfo -F vermagic "$1" 2>/dev/null | cut -d' ' -f1
}

endpoint_has_aliases() {
    local file=$1 alias found=0
    while IFS= read -r alias; do
        case "$alias" in pci:*|usb:*) found=1 ;; esac
    done < <(modinfo -F alias "$file" 2>/dev/null)
    [[ $found -eq 1 ]]
}

render_module_manifest() {
    local dir=$1 release=$2 endpoint=$3 module
    printf 'format rtw89-steamos-modules-v1\nrelease %s\nendpoint %s\n' \
        "$release" "$endpoint"
    for module in "${EXPECTED_MODULES[@]}"; do
        printf 'module %s %s.ko\n' \
            "$(sha256sum "$dir/$module.ko" | cut -d' ' -f1)" "$module"
    done
}

manifest_endpoint() {
    local manifest=$1 key endpoint
    read -r key endpoint < <(sed -n '3p' "$manifest")
    [[ $key == endpoint && $endpoint == *_git ]] || return 1
    printf '%s\n' "$endpoint"
}

validate_module_files() {
    local dir=$1 release=$2 endpoint=$3 module count
    [[ -d $dir && ! -L $dir ]] || return 1
    for module in "${EXPECTED_MODULES[@]}"; do
        [[ -f $dir/$module.ko && ! -L $dir/$module.ko ]] || return 1
        [[ $(modinfo -F name "$dir/$module.ko" 2>/dev/null) == "$module" ]] || return 1
        [[ $(module_release "$dir/$module.ko") == "$release" ]] || return 1
    done
    count=$(find "$dir" -maxdepth 1 -type f -name '*.ko' -print | wc -l)
    [[ $count -eq ${#EXPECTED_MODULES[@]} ]] || return 1
    [[ -f $dir/$endpoint.ko && ! -L $dir/$endpoint.ko ]] || return 1
    endpoint_has_aliases "$dir/$endpoint.ko"
}

validate_stage() {
    local stage=$1 release=$2 endpoint
    [[ -d $stage && ! -L $stage && -f $stage/manifest && ! -L $stage/manifest ]] || return 1
    endpoint=$(manifest_endpoint "$stage/manifest") || return 1
    validate_module_files "$stage" "$release" "$endpoint" || return 1
    cmp -s "$stage/manifest" <(render_module_manifest "$stage" "$release" "$endpoint")
}

validate_installed() {
    local installed=$1 stage=$2 module count
    secure_root_tree "$installed" || return 1
    for module in "${EXPECTED_MODULES[@]}"; do
        [[ -f $installed/$module.ko && ! -L $installed/$module.ko ]] || return 1
        [[ $(sha256sum "$installed/$module.ko" | cut -d' ' -f1) == \
            $(sha256sum "$stage/$module.ko" | cut -d' ' -f1) ]] || return 1
    done
    count=$(find "$installed" -mindepth 1 -maxdepth 1 -print | wc -l)
    [[ $count -eq ${#EXPECTED_MODULES[@]} ]]
}

validate_firmware_manifest_file() {
    local manifest=$1 line kind hash destination copy extra seen_cache='' seen_owned='' difference
    [[ -e $manifest || -L $manifest ]] || return 1
    [[ -d $ROOT_FIRMWARE && ! -L $ROOT_FIRMWARE \
        && -f $manifest && ! -L $manifest ]] || return 1
    IFS= read -r line < "$manifest"
    [[ $line == 'format rtw89-steamos-firmware-v2' ]] || return 1
    while read -r kind hash destination copy extra; do
        [[ -z ${kind:-} ]] && continue
        [[ $hash =~ ^[0-9a-f]{64}$ ]] || return 1
        [[ $destination =~ ^/usr/lib/firmware/rtw89/[A-Za-z0-9._+-]+\.bin$ ]] || return 1
        case "$kind" in
            cache)
                [[ -z ${extra:-} && $copy =~ ^files/[0-9a-f]{64}-[A-Za-z0-9._+-]+\.bin$ ]] || return 1
                [[ ${copy#files/$hash-} == "${destination##*/}" ]] || return 1
                [[ $seen_cache != *$'\n'"$destination"$'\n'* ]] || return 1
                seen_cache+=$'\n'"$destination"$'\n'
                [[ -f $ROOT_FIRMWARE/$copy && ! -L $ROOT_FIRMWARE/$copy ]] || return 1
                [[ $(sha256sum "$ROOT_FIRMWARE/$copy" | cut -d' ' -f1) == "$hash" ]] || return 1
                ;;
            owned)
                [[ -z ${copy:-} && -z ${extra:-} ]] || return 1
                [[ $seen_owned != *$'\n'"$destination"$'\n'* ]] || return 1
                seen_owned+=$'\n'"$destination"$'\n'
                grep -Fqx "cache $hash $destination files/$hash-${destination##*/}" "$manifest" || return 1
                ;;
            *) return 1 ;;
        esac
    done < <(sed -n '2,$p' "$manifest")
    difference=$(comm -3 \
        <(for source in "$SCRIPT_DIR"/firmware/*.bin; do printf '/usr/lib/firmware/rtw89/%s\n' "${source##*/}"; done | LC_ALL=C sort) \
        <(sed -n 's/^cache [0-9a-f]\{64\} \([^ ]*\) files\/[^ ]*$/\1/p' "$manifest" | LC_ALL=C sort))
    [[ -z $difference ]]
}

validate_firmware_manifest() {
    [[ -e $ROOT_FIRMWARE/manifest || -L $ROOT_FIRMWARE/manifest ]] || return 0
    validate_firmware_manifest_file "$ROOT_FIRMWARE/manifest"
}

firmware_targets_valid() {
    local kind hash destination copy extra
    [[ ! -e $ROOT_FIRMWARE/manifest.pending && ! -L $ROOT_FIRMWARE/manifest.pending \
        && ! -e $FIRMWARE_INITRAMFS_PENDING && ! -L $FIRMWARE_INITRAMFS_PENDING ]] || return 1
    validate_firmware_manifest || return 1
    [[ -f $ROOT_FIRMWARE/manifest && ! -L $ROOT_FIRMWARE/manifest ]] || return 1
    while read -r kind hash destination copy extra; do
        [[ $kind == owned ]] || continue
        secure_root_file "$destination" || return 1
        [[ $(sha256sum "$destination" | cut -d' ' -f1) == "$hash" ]] || return 1
    done < <(sed -n '2,$p' "$ROOT_FIRMWARE/manifest")
}

firmware_owned_hash() {
    local destination=$1 kind saved_hash saved_destination copy extra
    [[ -f $ROOT_FIRMWARE/manifest && ! -L $ROOT_FIRMWARE/manifest ]] || return 1
    while read -r kind saved_hash saved_destination copy extra; do
        if [[ $kind == owned && $saved_destination == "$destination" ]]; then
            printf '%s\n' "$saved_hash"
            return 0
        fi
    done < <(sed -n '2,$p' "$ROOT_FIRMWARE/manifest")
    return 1
}

validate_firmware_variants() {
    local destination=$1 variant
    for variant in "$destination" "$destination.zst" "$destination.xz" "$destination.gz"; do
        [[ ! -e $variant && ! -L $variant ]] || secure_root_file "$variant" || return 1
    done
}

secure_root_tree() {
    local path=$1 bad owner mode current
    [[ -d $path && ! -L $path ]] || return 1
    current=$path
    while :; do
        [[ -d $current && ! -L $current ]] || return 1
        read -r owner mode < <(stat -Lc '%u %a' "$current")
        [[ $owner == 0 && $((8#$mode & 8#022)) -eq 0 ]] || return 1
        [[ $current == / ]] && break
        current=${current%/*}; [[ -n $current ]] || current=/
    done
    bad=$(find "$path" -xdev \( -type l -o ! -uid 0 -o -perm /022 \) -print -quit)
    [[ -z $bad ]] || return 1
    read -r owner mode < <(stat -Lc '%u %a' "$path")
    [[ $owner == 0 && $((8#$mode & 8#022)) -eq 0 ]]
}

safe_root_directory() {
    local current=$1 owner mode
    while :; do
        [[ -d $current && ! -L $current ]] || return 1
        read -r owner mode < <(stat -Lc '%u %a' "$current")
        [[ $owner == 0 && $((8#$mode & 8#022)) -eq 0 ]] || return 1
        [[ $current == / ]] && break
        current=${current%/*}; [[ -n $current ]] || current=/
    done
}

install_standalone_storage() {
    local path
    for path in /home/.steamos /home/.steamos/offload /home/.steamos/offload/var \
        /home/.steamos/offload/var/lib "$DATA"; do
        if [[ ! -e $path && ! -L $path ]]; then
            install -d -o root -g root -m 0755 "$path"
        fi
        safe_root_directory "$path" \
            || die "standalone persistent storage is unsafe: $path"
    done
}

directory_empty() (
    local -a entries
    shopt -s nullglob dotglob
    entries=("$1"/*)
    ((${#entries[@]} == 0))
)

validate_legacy_file() {
    local path=$1 hash=$2 description=$3
    [[ -e $path || -L $path ]] || return 0
    secure_root_file "$path" || die "unsafe legacy $description: $path"
    [[ $(sha256sum "$path" | cut -d' ' -f1) == "$hash" ]] \
        || die "refusing unrecognized legacy $description: $path"
}

rewrite_manifest_header() {
    local path=$1 old=$2 new=$3 tmp first
    secure_root_file "$path" || die "unsafe legacy manifest: $path"
    IFS= read -r first < "$path"
    [[ $first == "$old" ]] || die "unrecognized legacy manifest: $path"
    tmp=$(mktemp "$(dirname "$path")/.manifest-migrate.XXXXXX")
    { printf '%s\n' "$new"; sed -n '2,$p' "$path"; } > "$tmp"
    chmod 0644 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$path"
}

migrate_legacy_install() {
    local stage path release unit_hash
    [[ -e $LEGACY_DATA || -L $LEGACY_DATA \
        || -e $LEGACY_HELPER || -L $LEGACY_HELPER \
        || -e $LEGACY_CONFIG || -L $LEGACY_CONFIG \
        || -e $LEGACY_KEEP_FILE || -L $LEGACY_KEEP_FILE \
        || -e $LEGACY_DROPIN || -L $LEGACY_DROPIN ]] || return 0
    [[ -d $LEGACY_DATA && ! -L $LEGACY_DATA ]] \
        || die "legacy RTW89 integration exists without recognized persistent data"
    secure_root_tree "$LEGACY_DATA" || die "legacy RTW89 persistent data is unsafe"
    [[ -f $LEGACY_DATA/source/UPSTREAM_COMMIT \
        && $(<"$LEGACY_DATA/source/UPSTREAM_COMMIT") == "$EXPECTED_COMMIT" ]] \
        || die "legacy RTW89 source is unrecognized"
    [[ ! -e $LEGACY_DATA/modules/install-transaction \
        && ! -e $LEGACY_DATA/firmware/manifest.pending \
        && ! -e $LEGACY_DATA/uninstall-pending ]] \
        || die "finish the existing RTW89 transaction before standalone migration"
    validate_legacy_file "$LEGACY_HELPER" "$LEGACY_HELPER_SHA" "boot helper"
    validate_legacy_file "$LEGACY_CONFIG" "$LEGACY_CONFIG_SHA" "module configuration"
    validate_legacy_file "$LEGACY_KEEP_FILE" "$LEGACY_KEEP_SHA" "keep file"
    validate_legacy_file "$LEGACY_DROPIN" "$LEGACY_DROPIN_SHA" "storage drop-in"
    if [[ -e $UNIT || -L $UNIT ]]; then
        secure_root_file "$UNIT" || die "unsafe legacy service unit"
        unit_hash=$(sha256sum "$UNIT" | cut -d' ' -f1)
        [[ $unit_hash == "$LEGACY_UNIT_SHA" \
            || $unit_hash == "$(sha256sum "$SCRIPT_DIR/rtw89-modules.service" | cut -d' ' -f1)" ]] \
            || die "refusing unrecognized RTW89 service unit"
    fi
    if [[ -e $ENABLEMENT || -L $ENABLEMENT ]]; then
        [[ -L $ENABLEMENT && $(readlink "$ENABLEMENT") == ../rtw89-modules.service ]] \
            || die "unsafe legacy service enablement"
    fi

    if directory_empty "$DATA"; then
        stage=$(mktemp -d "$(dirname "$DATA")/.rtw89-migrate.XXXXXX")
        cp -a "$LEGACY_DATA"/. "$stage"/
        chown -R root:root "$stage"; chmod -R go-w "$stage"
        for path in "$stage"/modules/*/manifest; do
            [[ -f $path ]] || continue
            rewrite_manifest_header "$path" 'format bc250-rtw89-modules-v1' \
                'format rtw89-steamos-modules-v1'
        done
        if [[ -f $stage/firmware/manifest ]]; then
            rewrite_manifest_header "$stage/firmware/manifest" \
                'format bc250-rtw89-firmware-v2' 'format rtw89-steamos-firmware-v2'
        fi
        rmdir "$DATA"
        mv "$stage" "$DATA"
    fi
    secure_root_tree "$DATA" || die "migrated standalone data is unsafe"
    secure_root_tree "$ROOT_SOURCE" && validate_pinned_source "$ROOT_SOURCE" \
        || die "migrated standalone source failed validation"
    for path in "$ROOT_MODULES"/*/manifest; do
        [[ -f $path ]] || continue
        release=${path#"$ROOT_MODULES"/}; release=${release%%/*}
        validate_stage "$ROOT_MODULES/$release" "$release" \
            || die "migrated module stage failed validation: $release"
    done
    validate_firmware_manifest || die "migrated firmware manifest failed validation"
    LEGACY_MIGRATED=1
    log "validated and copied the previous toolkit-managed RTW89 installation"
}

finalize_legacy_migration() {
    [[ $LEGACY_MIGRATED -eq 1 ]] || return 0
    rm -f "$LEGACY_HELPER" "$LEGACY_CONFIG" "$LEGACY_KEEP_FILE" "$LEGACY_DROPIN"
    rmdir "$(dirname "$LEGACY_DROPIN")" 2>/dev/null || true
    rm -rf "$LEGACY_DATA"
    log "removed superseded toolkit-managed RTW89 state"
}

write_keep_file() {
    local tmp
    if [[ -e $KEEP_FILE || -L $KEEP_FILE ]]; then
        keep_file_owned || die "refusing to replace unrecognized keep file: $KEEP_FILE"
    fi
    install -d -o root -g root -m 0755 "$(dirname "$KEEP_FILE")"
    tmp=$(mktemp "$(dirname "$KEEP_FILE")/.rtw89-steamos.XXXXXX")
    render_keep_file > "$tmp"
    chmod 0644 "$tmp"; chown root:root "$tmp"
    mv -f "$tmp" "$KEEP_FILE"
}

validate_module_destination_parent() {
    local release=$1
    safe_root_directory "$MODULE_BASE/$release" || return 1
    if [[ -e $MODULE_BASE/$release/updates || -L $MODULE_BASE/$release/updates ]]; then
        safe_root_directory "$MODULE_BASE/$release/updates" || return 1
    fi
}

validate_firmware_destination_parent() {
    safe_root_directory /usr/lib/firmware || return 1
    if [[ -e /usr/lib/firmware/rtw89 || -L /usr/lib/firmware/rtw89 ]]; then
        safe_root_directory /usr/lib/firmware/rtw89 || return 1
    fi
}

secure_root_file() {
    local path=$1 owner mode
    [[ -f $path && ! -L $path ]] || return 1
    read -r owner mode < <(stat -Lc '%u %a' "$path")
    [[ $owner == 0 && $((8#$mode & 8#022)) -eq 0 ]]
}

manifest_paths() {
    sed -n 's/^[0-9a-f]\{64\}  //p' "$1"
}

validate_source_inventory() {
    local tree=$1 checkout=${2:-0} difference bad
    bad=$(find "$tree" -xdev -mindepth 1 ! \( -type f -o -type d \) -print -quit)
    [[ -z $bad ]] || return 1
    difference=$(comm -3 \
        <({ manifest_paths "$tree/SOURCE_MANIFEST.sha256"; echo SOURCE_MANIFEST.sha256; \
            if [[ $checkout -eq 1 ]]; then
                printf '%s\n' STEAMOS.md steamdeck-setup.sh rtw89-ensure-modules.sh \
                    rtw89-modules.service prepare-kbuild.sh fetch-steamos-package.sh
            fi; } | LC_ALL=C sort -u) \
        <(cd "$tree" && find . -type f -printf '%P\n' | LC_ALL=C sort))
    [[ -z $difference ]]
}

validate_pinned_source() {
    local tree=$1 checkout=${2:-0}
    [[ -f $tree/UPSTREAM_COMMIT && ! -L $tree/UPSTREAM_COMMIT \
        && $(<"$tree/UPSTREAM_COMMIT") == "$EXPECTED_COMMIT" ]] || return 1
    [[ -f $tree/SOURCE_MANIFEST.sha256 && ! -L $tree/SOURCE_MANIFEST.sha256 \
        && $(sha256sum "$tree/SOURCE_MANIFEST.sha256" | cut -d' ' -f1) == "$EXPECTED_SOURCE_MANIFEST_SHA" ]] \
        || return 1
    validate_source_inventory "$tree" "$checkout" || return 1
    (cd "$tree" && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null)
}

validate_checkout() {
    local bad
    [[ $SOURCE_LOGICAL_DIR == "$SCRIPT_DIR" ]] \
        || die "rtw89 source directory must not be reached through a symlink"
    [[ -d $SCRIPT_DIR && ! -L $SCRIPT_DIR ]] || die "rtw89 source must be a real directory"
    bad=$(find "$SCRIPT_DIR" -type l -print -quit)
    [[ -z $bad ]] || die "vendored rtw89 source contains a symlink: $bad"
    [[ -f $SCRIPT_DIR/UPSTREAM_COMMIT && ! -L $SCRIPT_DIR/UPSTREAM_COMMIT ]] \
        || die "UPSTREAM_COMMIT is missing or unsafe"
    [[ $(<"$SCRIPT_DIR/UPSTREAM_COMMIT") == "$EXPECTED_COMMIT" ]] \
        || die "vendored source is not pinned to $EXPECTED_COMMIT"
    [[ $(sha256sum "$SCRIPT_DIR/Makefile" | cut -d' ' -f1) == "$EXPECTED_MAKEFILE_SHA" ]] \
        || die "Makefile is not the pinned no-git patched Makefile"
    [[ $(sha256sum "$SCRIPT_DIR/rtw89.conf" | cut -d' ' -f1) == "$EXPECTED_CONFIG_SHA" ]] \
        || die "rtw89.conf differs from the pinned configuration"
    [[ -f $SCRIPT_DIR/SOURCE_MANIFEST.sha256 && ! -L $SCRIPT_DIR/SOURCE_MANIFEST.sha256 \
        && $(sha256sum "$SCRIPT_DIR/SOURCE_MANIFEST.sha256" | cut -d' ' -f1) == "$EXPECTED_SOURCE_MANIFEST_SHA" ]] \
        || die "vendored source manifest is missing or unrecognized"
    validate_pinned_source "$SCRIPT_DIR" 1 \
        || die "vendored RTW89 source differs from pinned commit $EXPECTED_COMMIT"
    grep -Fqx 'ccflags-y += -DGIT_COMMIT=08b8d326937a200a706ec9c501374eec15835b5a' \
        "$SCRIPT_DIR/Makefile" || die "Makefile lacks the pinned commit definition"
    grep -Fqx 'blacklist rtw89_core' "$SCRIPT_DIR/rtw89.conf" \
        || die "rtw89.conf does not blacklist the stock driver"
    grep -Fqx 'blacklist rtw89core' "$SCRIPT_DIR/rtw89.conf" \
        || die "rtw89.conf does not blacklist Larry's driver"
    [[ -f $SCRIPT_DIR/rtw89-modules.service && ! -L $SCRIPT_DIR/rtw89-modules.service ]] \
        || die "service source is missing or unsafe"
    [[ -f $SCRIPT_DIR/rtw89-ensure-modules.sh && ! -L $SCRIPT_DIR/rtw89-ensure-modules.sh ]] \
        || die "boot helper source is missing or unsafe"
    [[ -f $PREPARE_KBUILD && ! -L $PREPARE_KBUILD \
        && -f $SCRIPT_DIR/fetch-steamos-package.sh \
        && ! -L $SCRIPT_DIR/fetch-steamos-package.sh ]] \
        || die "standalone Kbuild preparation scripts are missing or unsafe"
}

validate_kernel() {
    local base major minor
    base=${KREL%%-*}
    IFS=. read -r major minor _ <<< "$base"
    [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] \
        || die "cannot parse running kernel release $KREL"
    ((major > 6 || (major == 6 && minor >= 6))) \
        || die "RTW89 requires Linux 6.6 or newer; running $KREL"
}

find_matching_endpoint() {
    local dir=$1 modalias_file modalias module alias
    local -a aliases=(/sys/bus/pci/devices/*/modalias /sys/bus/usb/devices/*/modalias)
    for modalias_file in "${aliases[@]}"; do
        [[ -r $modalias_file ]] || continue
        IFS= read -r modalias < "$modalias_file"
        case "$modalias" in pci:*|usb:*) ;; *) continue ;; esac
        for module in "${EXPECTED_MODULES[@]}"; do
            [[ -f $dir/$module.ko ]] || continue
            while IFS= read -r alias; do
                case "$alias" in pci:*|usb:*) ;; *) continue ;; esac
                if [[ $modalias == $alias ]]; then
                    MATCH_ENDPOINT=$module
                    MATCH_DEVICE=${modalias_file%/modalias}
                    return 0
                fi
            done < <(modinfo -F alias "$dir/$module.ko" 2>/dev/null)
        done
    done
    return 1
}

diagnose_unsupported_device() {
    local device vendor product
    for device in /sys/bus/usb/devices/*; do
        [[ -r $device/idVendor && -r $device/idProduct ]] || continue
        IFS= read -r vendor < "$device/idVendor"
        IFS= read -r product < "$device/idProduct"
        if [[ ${vendor,,} == 0bda && ${product,,} =~ ^(1a2b|a192)$ ]]; then
            die "Realtek USB adapter $vendor:$product is still in CD-ROM mode; install/run usb_modeswitch, reconnect it, then retry"
        fi
    done
    for device in /sys/bus/pci/devices/*; do
        [[ -r $device/vendor && -r $device/device ]] || continue
        IFS= read -r vendor < "$device/vendor"
        IFS= read -r product < "$device/device"
        if [[ ${vendor,,} == 0x10ec && ${product,,} =~ ^0x(892d|882d|895d)$ ]]; then
            die "attached RTL8922DE device ${product#0x} is not enabled by this pinned driver build"
        fi
    done
}

unlock_rootfs() {
    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        steamos-readonly disable
        ROOTFS_WAS_READONLY=1
    fi
}

relock_rootfs() {
    if [[ $ROOTFS_WAS_READONLY -eq 1 ]]; then
        steamos-readonly enable
        ROOTFS_WAS_READONLY=0
    fi
}

cleanup_install() {
    local rc=$?
    recover_module_transaction || rc=1
    [[ -z $BUILD_DIR ]] || rm -rf "$BUILD_DIR"
    relock_rootfs || rc=1
    exit "$rc"
}

acquire_locks() {
    command -v flock >/dev/null || die "flock is required"
    exec 9>/run/lock/rtw89-steamos.lock
    flock 9
}

module_transaction_release() {
    local marker=$1 format release_key release extra
    secure_root_file "$marker" || return 1
    read -r format extra < "$marker"
    [[ $format == rtw89-steamos-module-transaction-v1 && -z ${extra:-} ]] || return 1
    read -r release_key release extra < <(sed -n '2p' "$marker")
    [[ $release_key == release && $release =~ ^[A-Za-z0-9._+-]+$ && -z ${extra:-} ]] || return 1
    [[ $(wc -l < "$marker") -eq 2 ]] || return 1
    printf '%s\n' "$release"
}

recover_module_transaction() {
    local release canonical new_stage old_stage destination root_new root_old mode='' orphan
    local canonical_valid=0 new_valid=0 old_valid=0
    if [[ ! -e $MODULE_TXN && ! -L $MODULE_TXN ]]; then
        orphan=$ROOT_MODULES/.${KREL}.rtw89-new
        if [[ -e $orphan || -L $orphan ]]; then
            secure_root_tree "$orphan" || die "orphaned module staging path is unsafe: $orphan"
            rm -rf "$orphan"
            log "removed incomplete module stage left before transaction commit"
        fi
        return 0
    fi
    release=$(module_transaction_release "$MODULE_TXN") \
        || die "module transaction marker is unsafe or corrupt"
    canonical=$ROOT_MODULES/$release
    new_stage=$ROOT_MODULES/.${release}.rtw89-new
    old_stage=$ROOT_MODULES/.${release}.rtw89-old
    destination=$MODULE_BASE/$release/updates/rtw89
    root_new=$MODULE_BASE/$release/updates/.rtw89.steamos-new
    root_old=$MODULE_BASE/$release/updates/.rtw89.steamos-old
    validate_module_destination_parent "$release" || die "unsafe module transaction parent for $release"
    if [[ -e $canonical || -L $canonical ]]; then
        secure_root_tree "$canonical" && validate_stage "$canonical" "$release" \
            || die "canonical module transaction stage is unsafe"
        canonical_valid=1
    fi
    if [[ -e $old_stage || -L $old_stage ]]; then
        secure_root_tree "$old_stage" || die "old persistent module transaction stage is unsafe"
        validate_stage "$old_stage" "$release" && old_valid=1
    fi
    if [[ -e $new_stage || -L $new_stage ]]; then
        secure_root_tree "$new_stage" || die "new persistent module transaction stage is unsafe"
        validate_stage "$new_stage" "$release" && new_valid=1
    fi
    [[ ! -e $root_new && ! -L $root_new ]] || secure_root_tree "$root_new" \
        || die "new rootfs module transaction directory is unsafe"
    [[ ! -e $root_old && ! -L $root_old ]] || secure_root_tree "$root_old" \
        || die "old rootfs module transaction directory is unsafe"

    if [[ -d $destination && $canonical_valid -eq 1 ]] && validate_installed "$destination" "$canonical"; then
        mode=rollback
    elif [[ -d $destination && $old_valid -eq 1 ]] && validate_installed "$destination" "$old_stage"; then
        mode=rollback
    elif [[ -d $destination && $new_valid -eq 1 ]] && validate_installed "$destination" "$new_stage"; then
        mode=commit
    elif [[ ! -e $destination && ! -L $destination && -d $root_old \
        && $canonical_valid -eq 1 ]] && validate_installed "$root_old" "$canonical"; then
        unlock_rootfs
        mv "$root_old" "$destination"
        mode=rollback
    elif [[ ! -e $destination && ! -L $destination && -d $root_old \
        && $old_valid -eq 1 ]] && validate_installed "$root_old" "$old_stage"; then
        unlock_rootfs
        mv "$root_old" "$destination"
        mode=rollback
    elif [[ ! -e $destination && ! -L $destination && -d $root_new \
        && $new_valid -eq 1 ]] && validate_installed "$root_new" "$new_stage"; then
        unlock_rootfs
        mv "$root_new" "$destination"
        mode=commit
    elif [[ ! -e $destination && ! -L $destination \
        && ($canonical_valid -eq 1 || $old_valid -eq 1 || -e $new_stage) ]]; then
        mode=rollback
    else
        die "cannot safely recover interrupted module transaction for $release"
    fi

    if [[ $mode == commit ]]; then
        if [[ -d $new_stage ]]; then
            if [[ -d $canonical ]]; then
                [[ ! -e $old_stage && ! -L $old_stage ]] \
                    || die "conflicting old module transaction stage"
                mv "$canonical" "$old_stage"
            fi
            mv "$new_stage" "$canonical"
        fi
    elif [[ ! -d $canonical && $old_valid -eq 1 ]]; then
        mv "$old_stage" "$canonical"
    fi
    unlock_rootfs
    rm -rf "$root_new" "$root_old"
    if [[ $mode == commit ]]; then
        rm -rf "$old_stage"
    else
        rm -rf "$new_stage" "$old_stage"
    fi
    rm -f "$MODULE_TXN"
    log "recovered interrupted module transaction for $release ($mode)"
}

atomic_copy_file() {
    local source=$1 target=$2 mode=$3 dir tmp
    dir=$(dirname "$target")
    [[ ! -L $target && (! -e $target || -f $target) ]] \
        || die "refusing unsafe file destination: $target"
    install -d -o root -g root -m 0755 "$dir"
    tmp=$(mktemp "$dir/.rtw89.file.XXXXXX")
    install -o root -g root -m "$mode" "$source" "$tmp"
    mv -f "$tmp" "$target"
}

replace_directory() {
    local staged=$1 target=$2 backup=${target}.old.$$
    [[ ! -e $backup && ! -L $backup ]] || die "stale replacement path: $backup"
    if [[ -e $target || -L $target ]]; then
        [[ -d $target && ! -L $target ]] || die "unsafe directory destination: $target"
        mv "$target" "$backup"
    fi
    if ! mv "$staged" "$target"; then
        [[ ! -e $backup ]] || mv "$backup" "$target"
        return 1
    fi
    rm -rf "$backup"
}

show_status() {
    local failed=0 present=0 stage=$ROOT_MODULES/$KREL installed endpoint state
    installed=$MODULE_BASE/$KREL/updates/rtw89
    for state in "$CONFIG" "$UNIT" "$ENABLEMENT" "$ROOT_HELPER" \
        "$KEEP_FILE" "$ROOT_FIRMWARE/manifest" "$ROOT_FIRMWARE/manifest.pending" \
        "$FIRMWARE_INITRAMFS_PENDING" "$MODULE_TXN" "$PENDING" "$installed" \
        "$LEGACY_DATA" "$LEGACY_HELPER" "$LEGACY_CONFIG" "$LEGACY_KEEP_FILE" \
        "$LEGACY_DROPIN"; do
        [[ ! -e $state && ! -L $state ]] || present=1
    done
    if [[ $present -eq 0 ]]; then
        log "state: absent"
        [[ -d $ROOT_SOURCE ]] && log "persistent source cache: preserved"
        return 1
    fi

    if secure_root_tree "$stage" && validate_stage "$stage" "$KREL" \
        && validate_installed "$installed" "$stage"; then
        endpoint=$(manifest_endpoint "$stage/manifest")
        log "modules for $KREL: installed and validated ($endpoint)"
    else
        log "modules for $KREL: absent or invalid"
        failed=1
    fi
    if secure_root_tree "$ROOT_SOURCE" && validate_pinned_source "$ROOT_SOURCE"; then
        log "persistent source: pinned and trusted"
    else
        log "persistent source: missing or untrusted"
        failed=1
    fi
    if secure_root_file "$CONFIG" && cmp -s "$CONFIG" <(render_config); then
        log "module configuration: installed"
    else
        log "module configuration: incomplete"
        failed=1
    fi
    if [[ -f $UNIT && ! -L $UNIT && -f $ROOT_HELPER && ! -L $ROOT_HELPER \
        && -L $ENABLEMENT && $(readlink "$ENABLEMENT") == ../rtw89-modules.service ]] \
        && secure_root_file "$UNIT" && secure_root_file "$ROOT_HELPER" \
        && cmp -s "$UNIT" "$SCRIPT_DIR/rtw89-modules.service" \
        && cmp -s "$ROOT_HELPER" "$SCRIPT_DIR/rtw89-ensure-modules.sh"; then
        log "repair service: enabled"
    else
        log "repair service: incomplete"
        failed=1
    fi
    if secure_root_file "$KEEP_FILE" && keep_file_owned \
        && cmp -s "$KEEP_FILE" <(render_keep_file); then
        log "atomic-update persistence: installed"
    else
        log "atomic-update persistence: incomplete"
        failed=1
    fi
    if firmware_targets_valid; then
        log "driver firmware: valid"
    else
        log "driver firmware: incomplete or invalid"
        failed=1
    fi
    [[ $failed -eq 0 ]] && log "state: complete" || log "state: partial"
    return "$failed"
}

prepare_kbuild() {
    local user=$1 source=/usr/lib/modules/$KREL/build kdir release
    [[ -f $PREPARE_KBUILD && ! -L $PREPARE_KBUILD ]] \
        || die "exact Kbuild is absent and standalone prepare-kbuild.sh is unavailable"
    if [[ -d $source ]]; then
        kdir=$(runuser -u "$user" -- env RTW89_KBUILD_SOURCE="$source" "$PREPARE_KBUILD") \
            || die "standalone local Kbuild sanitization failed"
    else
        kdir=$(runuser -u "$user" -- "$PREPARE_KBUILD") \
            || die "standalone kernel-header preparation failed"
    fi
    [[ -d $kdir ]] || die "prepare-kbuild.sh did not create $kdir"
    release=$(runuser -u "$user" -- make -s -C "$kdir" kernelrelease) \
        || die "prepared Kbuild is unusable"
    [[ $release == "$KREL" ]] \
        || die "prepared Kbuild release '$release' does not equal '$KREL'"
    printf '%s\n' "$kdir"
}

install_tools_if_needed() {
    local command missing=0
    for command in make gcc ld modinfo sha256sum runuser tar curl zstd; do
        command -v "$command" >/dev/null || missing=1
    done
    [[ $missing -eq 0 ]] && return
    log "installing base-devel while the SteamOS root is temporarily writable"
    unlock_rootfs
    pacman-key --init >/dev/null 2>&1 || true
    pacman-key --populate archlinux holo >/dev/null 2>&1 || true
    pacman -Sy --noconfirm --needed base-devel
    relock_rootfs
    for command in make gcc ld modinfo sha256sum runuser tar curl zstd; do
        command -v "$command" >/dev/null || die "required build command is still absent: $command"
    done
}

build_modules_as_user() {
    local user=$1 build=$2 kdir=$3
    if [[ ! -e $kdir/vmlinux && ! -L $kdir/vmlinux ]]; then
        log "vmlinux is absent; optional module BTF will be skipped"
    fi
    runuser -u "$user" -- bash -o pipefail -c '
        make -C "$1" KDIR="$2" clean modules 2>&1 \
            | sed "/Skipping BTF generation for .* due to unavailability of vmlinux/d"
    ' _ "$build" "$kdir"
}

snapshot_source() {
    local stage
    install -d -o root -g root -m 0755 "$DATA"
    if [[ -e $ROOT_SOURCE || -L $ROOT_SOURCE ]]; then
        secure_root_tree "$ROOT_SOURCE" \
            || die "refusing to replace an unsafe persistent source snapshot"
        [[ -f $ROOT_SOURCE/UPSTREAM_COMMIT && ! -L $ROOT_SOURCE/UPSTREAM_COMMIT \
            && $(<"$ROOT_SOURCE/UPSTREAM_COMMIT") == "$EXPECTED_COMMIT" ]] \
            || die "refusing to replace an unrecognized persistent source snapshot"
    fi
    stage=$(mktemp -d "$DATA/.source.new.XXXXXX")
    tar -C "$SCRIPT_DIR" \
        --exclude='.git' --exclude='*.ko' --exclude='*.o' \
        --exclude='*.mod' --exclude='*.mod.c' --exclude='*.mod.o' \
        --exclude='.*.cmd' --exclude='Module.symvers' --exclude='modules.order' \
        --exclude='./valve-kernel' --exclude='./steamos-headers' \
        --exclude='./steamdeck-setup.sh' --exclude='./rtw89-ensure-modules.sh' \
        --exclude='./rtw89-modules.service' --exclude='./prepare-kbuild.sh' \
        --exclude='./fetch-steamos-package.sh' --exclude='./STEAMOS.md' \
        -cf - . | tar -C "$stage" --no-same-owner -xf -
    chown -R root:root "$stage"
    chmod -R go-w "$stage"
    secure_root_tree "$stage" || die "source snapshot failed ownership validation"
    [[ $(<"$stage/UPSTREAM_COMMIT") == "$EXPECTED_COMMIT" \
        && $(sha256sum "$stage/Makefile" | cut -d' ' -f1) == "$EXPECTED_MAKEFILE_SHA" \
        && $(sha256sum "$stage/SOURCE_MANIFEST.sha256" | cut -d' ' -f1) == "$EXPECTED_SOURCE_MANIFEST_SHA" ]] \
        || die "source snapshot failed pin validation"
    (cd "$stage" && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null) \
        || die "source snapshot failed content validation"
    replace_directory "$stage" "$ROOT_SOURCE"
}

stage_modules() {
    local build=$1 endpoint=$2 stage=$ROOT_MODULES/.${KREL}.rtw89-new module
    local installed=$MODULE_BASE/$KREL/updates/rtw89 marker
    install -d -o root -g root -m 0755 "$ROOT_MODULES"
    [[ ! -e $MODULE_TXN && ! -L $MODULE_TXN ]] || die "module transaction recovery did not complete"
    [[ ! -e $stage && ! -L $stage ]] || die "stale new module transaction stage: $stage"
    [[ ! -e $ROOT_MODULES/.${KREL}.rtw89-old && ! -L $ROOT_MODULES/.${KREL}.rtw89-old ]] \
        || die "stale old module transaction stage for $KREL"
    if [[ -e $ROOT_MODULES/$KREL || -L $ROOT_MODULES/$KREL ]]; then
        secure_root_tree "$ROOT_MODULES/$KREL" \
            || die "persistent stage for $KREL is not root-owned immutable data"
        validate_stage "$ROOT_MODULES/$KREL" "$KREL" \
            || die "refusing to replace unsafe persistent stage for $KREL"
        if [[ -e $installed || -L $installed ]]; then
            validate_installed "$installed" "$ROOT_MODULES/$KREL" \
                || die "installed modules do not match the existing trusted stage"
        fi
    elif [[ -e $installed || -L $installed ]]; then
        die "installed modules have no existing trusted persistent stage"
    fi
    install -d -o root -g root -m 0755 "$stage"
    for module in "${EXPECTED_MODULES[@]}"; do
        install -o root -g root -m 0644 "$build/$module.ko" "$stage/$module.ko"
    done
    render_module_manifest "$stage" "$KREL" "$endpoint" > "$stage/manifest"
    chmod 0644 "$stage/manifest"
    chown -R root:root "$stage"
    chmod -R go-w "$stage"
    validate_stage "$stage" "$KREL" || die "persistent module stage failed validation"
    marker=$(mktemp "$ROOT_MODULES/.install-transaction.XXXXXX")
    printf 'rtw89-steamos-module-transaction-v1\nrelease %s\n' "$KREL" > "$marker"
    chmod 0644 "$marker"; chown root:root "$marker"
    mv "$marker" "$MODULE_TXN"
}

recover_firmware_transaction() {
    local pending=$ROOT_FIRMWARE/manifest.pending kind hash destination copy extra old_hash current variant tmp
    [[ -e $pending || -L $pending ]] || return 0
    validate_firmware_manifest_file "$pending" \
        || die "pending firmware transaction is unsafe or corrupt"
    validate_firmware_manifest || die "existing firmware manifest is unsafe or corrupt"
    atomic_copy_file /dev/null "$FIRMWARE_INITRAMFS_PENDING" 0644
    while read -r kind hash destination copy extra; do
        [[ $kind == owned ]] || continue
        validate_firmware_variants "$destination" \
            || die "unsafe firmware variant for $destination"
        if [[ -f $destination ]]; then
            current=$(sha256sum "$destination" | cut -d' ' -f1)
            [[ $current == "$hash" ]] && continue
            old_hash=$(firmware_owned_hash "$destination" 2>/dev/null || true)
            if [[ -z $old_hash || $current != "$old_hash" ]]; then
                tmp=$(mktemp "$ROOT_FIRMWARE/.manifest.reconcile.XXXXXX")
                grep -Fvx "owned $hash $destination" "$pending" > "$tmp"
                chmod 0644 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$pending"
                log "preserving distribution firmware that changed during transaction: $destination"
                continue
            fi
        else
            for variant in "$destination.zst" "$destination.xz" "$destination.gz"; do
                if [[ -e $variant || -L $variant ]]; then
                    tmp=$(mktemp "$ROOT_FIRMWARE/.manifest.reconcile.XXXXXX")
                    grep -Fvx "owned $hash $destination" "$pending" > "$tmp"
                    chmod 0644 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$pending"
                    log "preserving distribution firmware that appeared during transaction: $variant"
                    continue 2
                fi
            done
        fi
        unlock_rootfs
        copy=$(sed -n "s|^cache $hash $destination \([^ ]*\)$|\1|p" "$pending")
        [[ -n $copy ]] || die "pending firmware cache entry disappeared: $destination"
        atomic_copy_file "$ROOT_FIRMWARE/$copy" "$destination" 0644
    done < <(sed -n '2,$p' "$pending")
    mv -f "$pending" "$ROOT_FIRMWARE/manifest"
}

stage_and_install_firmware() {
    local source name hash destination old_hash current variant has_variant owned tmp
    validate_firmware_manifest || die "existing firmware manifest is unsafe or corrupt"
    validate_firmware_destination_parent \
        || die "firmware destination parent is symlinked, writable, or not root-owned"
    if [[ -e $ROOT_FIRMWARE || -L $ROOT_FIRMWARE ]]; then
        secure_root_tree "$ROOT_FIRMWARE" \
            || die "persistent firmware is not root-owned immutable data"
    fi
    recover_firmware_transaction
    install -d -o root -g root -m 0755 "$ROOT_FIRMWARE/files"
    tmp=$(mktemp "$ROOT_FIRMWARE/.manifest.new.XXXXXX")
    printf 'format rtw89-steamos-firmware-v2\n' > "$tmp"
    for source in "$SCRIPT_DIR"/firmware/*.bin; do
        [[ -f $source && ! -L $source ]] || die "unsafe bundled firmware: $source"
        name=${source##*/}
        hash=$(sha256sum "$source" | cut -d' ' -f1)
        destination=/usr/lib/firmware/rtw89/$name
        atomic_copy_file "$source" "$ROOT_FIRMWARE/files/$hash-$name" 0644
        printf 'cache %s %s files/%s-%s\n' "$hash" "$destination" "$hash" "$name" >> "$tmp"
    done
    for source in "$SCRIPT_DIR"/firmware/*.bin; do
        name=${source##*/}
        hash=$(sha256sum "$source" | cut -d' ' -f1)
        destination=/usr/lib/firmware/rtw89/$name
        validate_firmware_variants "$destination" \
            || die "firmware variant is symlinked, writable, or not root-owned: $destination"
        old_hash=$(firmware_owned_hash "$destination" 2>/dev/null || true)
        has_variant=0
        for variant in "$destination" "$destination.zst" "$destination.xz" "$destination.gz"; do
            [[ ! -e $variant && ! -L $variant ]] || has_variant=1
        done
        owned=0
        if [[ $has_variant -eq 0 ]]; then
            owned=1
        elif [[ -n $old_hash && -f $destination ]]; then
            current=$(sha256sum "$destination" | cut -d' ' -f1)
            [[ $current == "$old_hash" ]] && owned=1
        fi
        [[ $owned -eq 0 ]] || printf 'owned %s %s\n' "$hash" "$destination" >> "$tmp"
    done
    chmod 0644 "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" "$ROOT_FIRMWARE/manifest.pending"
    validate_firmware_manifest_file "$ROOT_FIRMWARE/manifest.pending" \
        || die "new firmware manifest failed validation"
    recover_firmware_transaction
}

install_rootfs_modules() {
    local stage=$ROOT_MODULES/.${KREL}.rtw89-new destination=$MODULE_BASE/$KREL/updates/rtw89
    local new=$MODULE_BASE/$KREL/updates/.rtw89.steamos-new
    local old=$MODULE_BASE/$KREL/updates/.rtw89.steamos-old module
    [[ -f $MODULE_TXN && ! -L $MODULE_TXN ]] || die "module transaction marker is missing"
    validate_module_destination_parent "$KREL" \
        || die "running-kernel module destination parent is unsafe"
    if [[ -e $destination || -L $destination ]]; then
        [[ -d $ROOT_MODULES/$KREL ]] \
            && validate_installed "$destination" "$ROOT_MODULES/$KREL" \
            || die "refusing to replace unrecognized installed RTW89 modules"
    fi
    [[ ! -e $new && ! -L $new && ! -e $old && ! -L $old ]] \
        || die "stale rootfs module transaction path"
    unlock_rootfs
    install -d -o root -g root -m 0755 "$(dirname "$destination")"
    install -d -o root -g root -m 0755 "$new"
    for module in "${EXPECTED_MODULES[@]}"; do
        install -o root -g root -m 0644 "$stage/$module.ko" "$new/$module.ko"
    done
    validate_installed "$new" "$stage" || die "rootfs module staging failed validation"
    [[ ! -e $destination && ! -L $destination ]] || mv "$destination" "$old"
    mv "$new" "$destination"
    recover_module_transaction
}

safe_load_endpoint() {
    local endpoint=$1 module ref unsafe=0
    local conflicts=(rtw89_8851bu rtw89_8851be rtw89_8851b rtw89_8852au rtw89_8852ae
        rtw89_8852a rtw89_8852b_common rtw89_8852bu rtw89_8852be rtw89_8852b
        rtw89_8852bte rtw89_8852bt rtw89_8852cu rtw89_8852ce rtw89_8852c
        rtw89_8922au rtw89_8922ae rtw89_8922a rtw89_core rtw89_usb rtw89_pci
        rtw89core rtw89pci rtw_8851b rtw_8851be rtw_8852a rtw_8852ae
        rtw_8852b rtw_8852be rtw_8852c rtw_8852ce rtw_8922a rtw_8922ae)
    for module in "${conflicts[@]}"; do
        [[ -d /sys/module/$module ]] || continue
        ref=$(<"/sys/module/$module/refcnt" 2>/dev/null || printf 1)
        [[ $ref == 0 ]] || unsafe=1
    done
    if [[ $unsafe -eq 1 ]]; then
        log "a conflicting Wi-Fi module is in use; reboot required to activate $endpoint"
        return 0
    fi
    for module in "${conflicts[@]}"; do
        [[ ! -d /sys/module/$module ]] || modprobe -r "$module" 2>/dev/null || {
            log "could not safely unload $module; reboot required to activate $endpoint"
            return 0
        }
    done
    if modprobe "$endpoint"; then
        log "loaded $endpoint for ${MATCH_DEVICE:-the attached adapter}"
    else
        log "module installation is complete, but loading failed; reboot required"
    fi
}

install_rtw89() {
    local build_user build_group kdir endpoint module source_stage
    [[ $EUID -eq 0 ]] || die "install requires root; run: sudo bash $0 install"
    [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] \
        || die "install must be invoked with sudo by the normal build user"
    id "$SUDO_USER" >/dev/null 2>&1 || die "SUDO_USER does not identify a local user"
    validate_checkout
    validate_kernel
    acquire_locks
    trap cleanup_install EXIT
    install_standalone_storage
    migrate_legacy_install
    recover_module_transaction
    install_tools_if_needed
    kdir=$(prepare_kbuild "$SUDO_USER")

    BUILD_DIR=$(mktemp -d /var/tmp/rtw89-steamos-user.XXXXXX)
    build_group=$(id -gn "$SUDO_USER")
    chown "$SUDO_USER:$build_group" "$BUILD_DIR"
    runuser -u "$SUDO_USER" -- cp -a "$SCRIPT_DIR"/. "$BUILD_DIR"/
    build_modules_as_user "$SUDO_USER" "$BUILD_DIR" "$kdir"
    # Discovering the endpoint from built aliases proves both source support and
    # that the selected _git module actually handles an attached PCIe/USB device.
    if ! find_matching_endpoint "$BUILD_DIR"; then
        diagnose_unsupported_device
        die "no attached supported Realtek RTW89 PCIe/USB Wi-Fi device matches the built aliases"
    fi
    endpoint=$MATCH_ENDPOINT
    validate_module_files "$BUILD_DIR" "$KREL" "$endpoint" \
        || die "build output failed module name, type, alias, or vermagic validation"

    snapshot_source
    stage_modules "$BUILD_DIR" "$endpoint"
    stage_and_install_firmware
    install_rootfs_modules

    unlock_rootfs
    atomic_copy_file "$SCRIPT_DIR/rtw89-ensure-modules.sh" "$ROOT_HELPER" 0755
    atomic_copy_file "$SCRIPT_DIR/rtw89-modules.service" "$UNIT" 0644
    local config_tmp
    config_tmp=$(mktemp /etc/modprobe.d/.rtw89-steamos.XXXXXX)
    render_config > "$config_tmp"
    chmod 0644 "$config_tmp"
    chown root:root "$config_tmp"
    [[ ! -L $CONFIG && (! -e $CONFIG || -f $CONFIG) ]] \
        || die "unsafe module configuration destination: $CONFIG"
    mv -f "$config_tmp" "$CONFIG"
    write_keep_file
    depmod "$KREL"
    mkinitcpio -P
    rm -f "$FIRMWARE_INITRAMFS_PENDING"
    finalize_legacy_migration
    relock_rootfs

    systemctl daemon-reload
    systemctl enable rtw89-modules.service >/dev/null
    safe_load_endpoint "$endpoint"
    log "installation complete for Realtek RTW89 Wi-Fi on $KREL"
    log "Bluetooth is separate and is not provided by this driver"
}

validate_owned_file() {
    local path=$1 expected=$2 description=$3
    [[ -e $path || -L $path ]] || return 0
    secure_root_file "$path" || die "unsafe $description: $path"
    cmp -s "$path" "$expected" || die "refusing to remove unrecognized $description: $path"
}

preflight_uninstall() {
    local path rel stage kind hash destination copy extra
    command -v systemctl >/dev/null || die "systemctl is required"
    command -v depmod >/dev/null || die "depmod is required"
    command -v mkinitcpio >/dev/null || die "mkinitcpio is required"
    if [[ -e $CONFIG || -L $CONFIG ]]; then
        secure_root_file "$CONFIG" || die "unsafe module configuration: $CONFIG"
        cmp -s "$CONFIG" <(render_config) \
            || die "refusing to remove modified module configuration: $CONFIG"
    fi
    if [[ $LEGACY_MIGRATED -eq 1 && -f $UNIT && ! -L $UNIT \
        && $(sha256sum "$UNIT" | cut -d' ' -f1) == "$LEGACY_UNIT_SHA" ]]; then
        secure_root_file "$UNIT" || die "unsafe legacy service unit"
    else
        validate_owned_file "$UNIT" "$SCRIPT_DIR/rtw89-modules.service" "service unit"
    fi
    validate_owned_file "$ROOT_HELPER" "$SCRIPT_DIR/rtw89-ensure-modules.sh" "boot helper"
    if [[ -e $ENABLEMENT || -L $ENABLEMENT ]]; then
        [[ -L $ENABLEMENT && $(readlink "$ENABLEMENT") == ../rtw89-modules.service ]] \
            || die "refusing unexpected service enablement path"
    fi
    if [[ -e $KEEP_FILE || -L $KEEP_FILE ]]; then
        secure_root_file "$KEEP_FILE" || die "unsafe atomic-update keep file"
        keep_file_owned || die "unrecognized atomic-update keep file"
        cmp -s "$KEEP_FILE" <(render_keep_file) \
            || die "modified atomic-update keep file"
    fi
    validate_firmware_manifest || die "firmware manifest is unsafe or corrupt"
    [[ ! -e $ROOT_FIRMWARE/manifest.pending && ! -L $ROOT_FIRMWARE/manifest.pending ]] \
        || die "firmware transaction is pending; rerun install before uninstalling"
    [[ ! -e $MODULE_TXN && ! -L $MODULE_TXN ]] \
        || die "module transaction is pending; rerun install before uninstalling"
    validate_firmware_destination_parent || die "firmware destination parent is unsafe"
    if [[ -e $ROOT_FIRMWARE || -L $ROOT_FIRMWARE ]]; then
        secure_root_tree "$ROOT_FIRMWARE" || die "persistent firmware storage is unsafe"
    fi
    for path in "$MODULE_BASE"/*/updates/rtw89; do
        [[ -e $path || -L $path ]] || continue
        rel=${path#"$MODULE_BASE"/}; rel=${rel%%/*}
        [[ $rel =~ ^[A-Za-z0-9._+-]+$ ]] || die "unsafe kernel release in $path"
        validate_module_destination_parent "$rel" || die "unsafe module parent for $rel"
        stage=$ROOT_MODULES/$rel
        secure_root_tree "$stage" || die "persistent module stage is unsafe: $stage"
        validate_stage "$stage" "$rel" || die "no recognized manifest for installed modules: $path"
        validate_installed "$path" "$stage" || die "installed modules are not manifest-owned: $path"
    done
    if [[ -e $PENDING || -L $PENDING ]]; then
        [[ -f $PENDING && ! -L $PENDING ]] || die "unsafe pending uninstall state"
        while IFS= read -r rel; do
            [[ $rel =~ ^[A-Za-z0-9._+-]+$ ]] || die "unsafe pending kernel release: $rel"
        done < "$PENDING"
    fi
    if [[ -f $ROOT_FIRMWARE/manifest ]]; then
        while read -r kind hash destination copy extra; do
            [[ $kind == owned ]] || continue
            [[ ! -L $destination && (! -e $destination || -f $destination) ]] \
                || die "unsafe driver firmware destination: $destination"
            [[ ! -f $destination ]] || secure_root_file "$destination" \
                || die "driver firmware destination is not root-owned immutable data"
        done < <(sed -n '2,$p' "$ROOT_FIRMWARE/manifest")
    fi
}

uninstall_rtw89() {
    local path rel endpoint kind hash destination copy extra reboot=0 tmp
    local -a releases=() loaded=()
    local -a unload_order=(
        rtw89_8851be_git rtw89_8851bu_git
        rtw89_8852ae_git rtw89_8852au_git rtw89_8852be_git rtw89_8852bu_git
        rtw89_8852bte_git rtw89_8852ce_git rtw89_8852cu_git
        rtw89_8922ae_git rtw89_8922au_git
        rtw89_8851b_git rtw89_8852a_git rtw89_8852bte_git rtw89_8852bt_git
        rtw89_8852b_git rtw89_8852b_common_git rtw89_8852c_git rtw89_8922a_git
        rtw89_usb_git rtw89_pci_git rtw89_core_git
    )
    [[ $EUID -eq 0 ]] || die "uninstall requires root; run: sudo bash $0 uninstall"
    validate_checkout
    acquire_locks
    install_standalone_storage
    migrate_legacy_install
    preflight_uninstall

    systemctl disable --now rtw89-modules.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet rtw89-modules.service \
        || systemctl is-enabled --quiet rtw89-modules.service; then
        die "could not disable the repair service; refusing uninstall"
    fi
    preflight_uninstall
    trap relock_rootfs EXIT

    if [[ -f $PENDING ]]; then
        mapfile -t releases < "$PENDING"
    fi
    for path in "$MODULE_BASE"/*/updates/rtw89; do
        [[ -e $path ]] || continue
        rel=${path#"$MODULE_BASE"/}; rel=${rel%%/*}
        if [[ ! " ${releases[*]} " =~ " $rel " ]]; then releases+=("$rel"); fi
    done
    [[ " ${releases[*]} " =~ " $KREL " ]] || releases+=("$KREL")

    for path in "$ROOT_MODULES"/*/manifest; do
        [[ -f $path ]] || continue
        endpoint=$(manifest_endpoint "$path" 2>/dev/null || true)
        [[ -z $endpoint || ! -d /sys/module/$endpoint ]] || modprobe -r "$endpoint" 2>/dev/null || reboot=1
    done
    for endpoint in "${unload_order[@]}"; do
        [[ ! -d /sys/module/$endpoint ]] || modprobe -r "$endpoint" 2>/dev/null || reboot=1
    done

    install -d -o root -g root -m 0755 "$DATA"
    tmp=$(mktemp "$DATA/.uninstall-pending.XXXXXX")
    printf '%s\n' "${releases[@]}" | sort -u > "$tmp"
    chmod 0644 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$PENDING"

    unlock_rootfs
    for path in "$MODULE_BASE"/*/updates/rtw89; do
        [[ -e $path ]] || continue
        rel=${path#"$MODULE_BASE"/}; rel=${rel%%/*}
        validate_installed "$path" "$ROOT_MODULES/$rel" \
            || die "module directory changed after preflight: $path"
        rm -rf "$path"
    done
    if [[ -f $ROOT_FIRMWARE/manifest ]]; then
        while read -r kind hash destination copy extra; do
            [[ $kind == owned ]] || continue
            [[ ! -L $destination && (! -e $destination || -f $destination) ]] \
                || die "firmware destination changed after preflight: $destination"
            if [[ -f $destination ]]; then
                if [[ $(sha256sum "$destination" | cut -d' ' -f1) == "$hash" ]]; then
                    rm -f "$destination"
                else
                    log "preserving changed firmware file: $destination"
                fi
            fi
        done < <(sed -n '2,$p' "$ROOT_FIRMWARE/manifest")
    fi
    rm -f "$CONFIG" "$UNIT" "$ROOT_HELPER" "$ENABLEMENT" "$KEEP_FILE"
    rm -rf "$ROOT_FIRMWARE"
    for rel in "${releases[@]}"; do
        [[ -d $MODULE_BASE/$rel ]] && depmod "$rel"
    done
    mkinitcpio -P
    finalize_legacy_migration
    systemctl daemon-reload
    rm -f "$PENDING"
    relock_rootfs
    trap - EXIT

    log "runtime modules, firmware, configuration, and repair service removed"
    log "persistent source and per-kernel module caches preserved under $DATA"
    if [[ $reboot -eq 1 ]]; then
        log "reboot required: yes; one or more _git modules remain loaded"
    else
        log "reboot required: yes; reboot to bind the restored stock driver cleanly"
    fi
}

case "${1:-install}" in
    install)
        [[ $# -le 1 ]] || { usage >&2; exit 2; }
        install_rtw89
        ;;
    status)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        show_status
        ;;
    uninstall)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        uninstall_rtw89
        ;;
    help|-h|--help)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        usage
        ;;
    *) usage >&2; exit 2 ;;
esac
