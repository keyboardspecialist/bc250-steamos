#!/usr/bin/env bash
# Offline SteamOS repair for the pinned morrownr/rtw89 Wi-Fi modules.
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
DATA=/home/.steamos/offload/var/lib/rtw89-steamos
SOURCE=$DATA/source
MODULES=$DATA/modules
MODULE_TXN=$MODULES/install-transaction
FIRMWARE=$DATA/firmware
FIRMWARE_INITRAMFS_PENDING=$FIRMWARE/initramfs-pending
INSTALL_BASE=/usr/lib/modules
EXPECTED_COMMIT=08b8d326937a200a706ec9c501374eec15835b5a
EXPECTED_MAKEFILE_SHA=9e7157c446201a85990b0652b29e79a31d5602cbe3f128b876e612cd14b11a3e
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
FIRMWARE_CHANGED=0
MATCH_ENDPOINTS=()

log() { printf '[rtw89] %s\n' "$*"; }
die() { printf '[rtw89] %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "boot repair must run as root"
command -v flock >/dev/null || die "flock is required"
exec 9>/run/lock/rtw89-steamos.lock
flock 9

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
trap relock_rootfs EXIT

secure_tree() {
    local path=$1 bad current owner mode
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
    [[ -z $bad ]]
}

secure_kbuild_tree() {
    local path=$1 bad link target
    secure_tree_metadata "$path" || return 1
    bad=$(find "$path" -xdev -mindepth 1 \
        ! \( -type f -o -type d -o -type l \) -print -quit)
    [[ -z $bad ]] || return 1
    bad=$(find "$path" -xdev ! -type l \( ! -uid 0 -o -perm /022 \) -print -quit)
    [[ -z $bad ]] || return 1
    while IFS= read -r -d '' link; do
        [[ $(stat -c '%u' "$link") == 0 ]] || return 1
        target=$(readlink -f -- "$link") || return 1
        case "$target" in "$path"/*) ;; *) return 1 ;; esac
    done < <(find "$path" -xdev -type l -print0)
}

secure_tree_metadata() {
    local current=$1 owner mode
    while :; do
        [[ -d $current && ! -L $current ]] || return 1
        read -r owner mode < <(stat -Lc '%u %a' "$current")
        [[ $owner == 0 && $((8#$mode & 8#022)) -eq 0 ]] || return 1
        [[ $current == / ]] && break
        current=${current%/*}; [[ -n $current ]] || current=/
    done
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

secure_file() {
    local path=$1 owner mode
    [[ -f $path && ! -L $path ]] || return 1
    read -r owner mode < <(stat -Lc '%u %a' "$path")
    [[ $owner == 0 && $((8#$mode & 8#022)) -eq 0 ]]
}

manifest_paths() {
    sed -n 's/^[0-9a-f]\{64\}  //p' "$1"
}

validate_source_inventory() {
    local difference bad
    bad=$(find "$SOURCE" -xdev -mindepth 1 ! \( -type f -o -type d \) -print -quit)
    [[ -z $bad ]] || return 1
    difference=$(comm -3 \
        <({ manifest_paths "$SOURCE/SOURCE_MANIFEST.sha256"; echo SOURCE_MANIFEST.sha256; } \
            | LC_ALL=C sort -u) \
        <(cd "$SOURCE" && find . -type f -printf '%P\n' | LC_ALL=C sort))
    [[ -z $difference ]]
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

find_matching_endpoints() {
    local dir=$1 modalias_file modalias module alias existing
    local -a aliases=(/sys/bus/pci/devices/*/modalias /sys/bus/usb/devices/*/modalias)
    MATCH_ENDPOINTS=()
    for modalias_file in "${aliases[@]}"; do
        [[ -r $modalias_file ]] || continue
        IFS= read -r modalias < "$modalias_file"
        case "$modalias" in pci:*|usb:*) ;; *) continue ;; esac
        for module in "${EXPECTED_MODULES[@]}"; do
            [[ -f $dir/$module.ko ]] || continue
            while IFS= read -r alias; do
                case "$alias" in pci:*|usb:*) ;; *) continue ;; esac
                [[ $modalias == $alias ]] || continue
                existing=0
                for endpoint in "${MATCH_ENDPOINTS[@]}"; do
                    [[ $endpoint != "$module" ]] || existing=1
                done
                [[ $existing -eq 1 ]] || MATCH_ENDPOINTS+=("$module")
            done < <(modinfo -F alias "$dir/$module.ko" 2>/dev/null)
        done
    done
    ((${#MATCH_ENDPOINTS[@]} > 0))
}

render_module_manifest() {
    local dir=$1 release=$2 endpoint=$3 module file
    printf 'format rtw89-steamos-modules-v1\nrelease %s\nendpoint %s\n' \
        "$release" "$endpoint"
    for module in "${EXPECTED_MODULES[@]}"; do
        file=$dir/$module.ko
        printf 'module %s %s.ko\n' "$(sha256sum "$file" | cut -d' ' -f1)" "$module"
    done
}

validate_module_files() {
    local dir=$1 release=$2 endpoint=$3 module file count
    [[ -d $dir && ! -L $dir ]] || return 1
    for module in "${EXPECTED_MODULES[@]}"; do
        file=$dir/$module.ko
        [[ -f $file && ! -L $file ]] || return 1
        [[ $(modinfo -F name "$file" 2>/dev/null) == "$module" ]] || return 1
        [[ $(module_release "$file") == "$release" ]] || return 1
    done
    count=$(find "$dir" -maxdepth 1 -type f -name '*.ko' -print | wc -l)
    [[ $count -eq ${#EXPECTED_MODULES[@]} ]] || return 1
    [[ $endpoint == *_git ]] || return 1
    [[ -f $dir/$endpoint.ko && ! -L $dir/$endpoint.ko ]] || return 1
    endpoint_has_aliases "$dir/$endpoint.ko"
}

manifest_endpoint() {
    local manifest=$1 key endpoint
    read -r key endpoint < <(sed -n '3p' "$manifest")
    [[ $key == endpoint && $endpoint == *_git ]] || return 1
    printf '%s\n' "$endpoint"
}

validate_stage() {
    local stage=$1 release=$2 endpoint
    secure_tree "$stage" || return 1
    secure_file "$stage/manifest" || return 1
    endpoint=$(manifest_endpoint "$stage/manifest") || return 1
    validate_module_files "$stage" "$release" "$endpoint" || return 1
    cmp -s "$stage/manifest" <(render_module_manifest "$stage" "$release" "$endpoint")
}

validate_installed() {
    local installed=$1 stage=$2 module count
    secure_tree "$installed" || return 1
    for module in "${EXPECTED_MODULES[@]}"; do
        [[ -f $installed/$module.ko && ! -L $installed/$module.ko ]] || return 1
        [[ $(sha256sum "$installed/$module.ko" | cut -d' ' -f1) == \
            $(sha256sum "$stage/$module.ko" | cut -d' ' -f1) ]] || return 1
    done
    count=$(find "$installed" -mindepth 1 -maxdepth 1 -print | wc -l)
    [[ $count -eq ${#EXPECTED_MODULES[@]} ]]
}

module_transaction_release() {
    local marker=$1 format release_key release extra
    secure_file "$marker" || return 1
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
        orphan=$MODULES/.${KREL}.rtw89-new
        if [[ -e $orphan || -L $orphan ]]; then
            secure_tree "$orphan" || die "orphaned module staging path is unsafe: $orphan"
            rm -rf "$orphan"
            log "removed incomplete module stage left before transaction commit"
        fi
        return 0
    fi
    release=$(module_transaction_release "$MODULE_TXN") \
        || die "module transaction marker is unsafe or corrupt"
    canonical=$MODULES/$release
    new_stage=$MODULES/.${release}.rtw89-new
    old_stage=$MODULES/.${release}.rtw89-old
    destination=$INSTALL_BASE/$release/updates/rtw89
    root_new=$INSTALL_BASE/$release/updates/.rtw89.steamos-new
    root_old=$INSTALL_BASE/$release/updates/.rtw89.steamos-old
    if [[ -e $INSTALL_BASE/$release || -L $INSTALL_BASE/$release ]]; then
        safe_root_directory "$INSTALL_BASE/$release" || die "unsafe module transaction parent for $release"
    fi
    if [[ -e $INSTALL_BASE/$release/updates || -L $INSTALL_BASE/$release/updates ]]; then
        safe_root_directory "$INSTALL_BASE/$release/updates" \
            || die "unsafe module updates transaction parent for $release"
    fi
    if [[ -e $canonical || -L $canonical ]]; then
        validate_stage "$canonical" "$release" || die "canonical module transaction stage is unsafe"
        canonical_valid=1
    fi
    if [[ -e $old_stage || -L $old_stage ]]; then
        secure_tree "$old_stage" || die "old persistent module transaction stage is unsafe"
        validate_stage "$old_stage" "$release" && old_valid=1
    fi
    if [[ -e $new_stage || -L $new_stage ]]; then
        secure_tree "$new_stage" || die "new persistent module transaction stage is unsafe"
        validate_stage "$new_stage" "$release" && new_valid=1
    fi
    [[ ! -e $root_new && ! -L $root_new ]] || secure_tree "$root_new" \
        || die "new rootfs module transaction directory is unsafe"
    [[ ! -e $root_old && ! -L $root_old ]] || secure_tree "$root_old" \
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
    if [[ $mode == commit ]]; then rm -rf "$old_stage"; else rm -rf "$new_stage" "$old_stage"; fi
    rm -f "$MODULE_TXN"
    log "recovered interrupted module transaction for $release ($mode)"
}

validate_source() {
    secure_tree "$SOURCE" || die "persistent source is not root-owned, immutable data"
    secure_file "$SOURCE/UPSTREAM_COMMIT" || die "persistent source commit marker is unsafe"
    [[ $(<"$SOURCE/UPSTREAM_COMMIT") == "$EXPECTED_COMMIT" ]] \
        || die "persistent source is not pinned to $EXPECTED_COMMIT"
    [[ $(sha256sum "$SOURCE/Makefile" | cut -d' ' -f1) == "$EXPECTED_MAKEFILE_SHA" ]] \
        || die "persistent source Makefile is not the pinned patched Makefile"
    [[ $(sha256sum "$SOURCE/SOURCE_MANIFEST.sha256" | cut -d' ' -f1) == "$EXPECTED_SOURCE_MANIFEST_SHA" ]] \
        || die "persistent source manifest is unrecognized"
    validate_source_inventory || die "persistent source contains unpinned build input"
    (cd "$SOURCE" && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null) \
        || die "persistent source differs from pinned commit $EXPECTED_COMMIT"
}

validate_firmware_manifest_file() {
    local manifest=$1 line kind hash destination copy extra seen_cache='' seen_owned='' difference
    [[ -e $manifest || -L $manifest ]] || return 1
    secure_tree "$FIRMWARE" || return 1
    secure_file "$manifest" || return 1
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
                [[ -f $FIRMWARE/$copy && ! -L $FIRMWARE/$copy ]] || return 1
                [[ $(sha256sum "$FIRMWARE/$copy" | cut -d' ' -f1) == "$hash" ]] || return 1
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
        <(for source in "$SOURCE"/firmware/*.bin; do printf '/usr/lib/firmware/rtw89/%s\n' "${source##*/}"; done | LC_ALL=C sort) \
        <(sed -n 's/^cache [0-9a-f]\{64\} \([^ ]*\) files\/[^ ]*$/\1/p' "$manifest" | LC_ALL=C sort))
    [[ -z $difference ]]
}

validate_firmware_manifest() {
    [[ -e $FIRMWARE/manifest || -L $FIRMWARE/manifest ]] || return 0
    validate_firmware_manifest_file "$FIRMWARE/manifest"
}

firmware_owned_hash() {
    local destination=$1 kind hash saved copy extra
    [[ -f $FIRMWARE/manifest && ! -L $FIRMWARE/manifest ]] || return 1
    while read -r kind hash saved copy extra; do
        if [[ $kind == owned && $saved == "$destination" ]]; then
            printf '%s\n' "$hash"
            return 0
        fi
    done < <(sed -n '2,$p' "$FIRMWARE/manifest")
    return 1
}

validate_firmware_variants() {
    local destination=$1 variant
    for variant in "$destination" "$destination.zst" "$destination.xz" "$destination.gz"; do
        [[ ! -e $variant && ! -L $variant ]] || secure_file "$variant" || return 1
    done
}

atomic_firmware_copy() {
    local source=$1 destination=$2 dir tmp
    dir=$(dirname "$destination")
    install -d -o root -g root -m 0755 "$dir"
    tmp=$(mktemp "$dir/.rtw89.firmware.XXXXXX")
    install -o root -g root -m 0644 "$source" "$tmp"
    mv -f "$tmp" "$destination"
}

mark_firmware_initramfs_pending() {
    local tmp
    tmp=$(mktemp "$FIRMWARE/.initramfs-pending.XXXXXX")
    chmod 0644 "$tmp"; chown root:root "$tmp"
    mv -f "$tmp" "$FIRMWARE_INITRAMFS_PENDING"
}

recover_firmware_transaction() {
    local pending=$FIRMWARE/manifest.pending kind hash destination copy extra old_hash current variant tmp
    [[ -e $pending || -L $pending ]] || return 0
    FIRMWARE_CHANGED=1
    validate_firmware_manifest_file "$pending" \
        || die "pending firmware transaction is unsafe or corrupt"
    validate_firmware_manifest || die "persistent firmware manifest is unsafe or corrupt"
    mark_firmware_initramfs_pending
    while read -r kind hash destination copy extra; do
        [[ $kind == owned ]] || continue
        validate_firmware_variants "$destination" || die "unsafe firmware variant for $destination"
        if [[ -f $destination ]]; then
            current=$(sha256sum "$destination" | cut -d' ' -f1)
            [[ $current == "$hash" ]] && continue
            old_hash=$(firmware_owned_hash "$destination" 2>/dev/null || true)
            if [[ -z $old_hash || $current != "$old_hash" ]]; then
                tmp=$(mktemp "$FIRMWARE/.manifest.reconcile.XXXXXX")
                grep -Fvx "owned $hash $destination" "$pending" > "$tmp"
                chmod 0644 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$pending"
                log "preserving distribution firmware that changed during transaction: $destination"
                continue
            fi
        else
            for variant in "$destination.zst" "$destination.xz" "$destination.gz"; do
                if [[ -e $variant || -L $variant ]]; then
                    tmp=$(mktemp "$FIRMWARE/.manifest.reconcile.XXXXXX")
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
        atomic_firmware_copy "$FIRMWARE/$copy" "$destination"
        FIRMWARE_CHANGED=1
        log "restored driver-owned firmware $destination"
    done < <(sed -n '2,$p' "$pending")
    mv -f "$pending" "$FIRMWARE/manifest"
}

restore_firmware() {
    local kind hash destination copy extra old_hash current variant has_variant owned tmp
    validate_firmware_manifest || die "persistent firmware manifest is unsafe or corrupt"
    safe_root_directory /usr/lib/firmware \
        || die "firmware parent path is symlinked, writable, or not root-owned"
    if [[ -e /usr/lib/firmware/rtw89 || -L /usr/lib/firmware/rtw89 ]]; then
        safe_root_directory /usr/lib/firmware/rtw89 || die "unsafe RTW89 firmware directory"
    fi
    [[ -f $FIRMWARE/manifest || -f $FIRMWARE/manifest.pending ]] || return 0
    recover_firmware_transaction
    tmp=$(mktemp "$FIRMWARE/.manifest.new.XXXXXX")
    printf 'format rtw89-steamos-firmware-v2\n' > "$tmp"
    while read -r kind hash destination copy extra; do
        [[ $kind == cache ]] || continue
        printf 'cache %s %s %s\n' "$hash" "$destination" "$copy" >> "$tmp"
        validate_firmware_variants "$destination" || die "unsafe firmware variant for $destination"
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
            if [[ $current == "$hash" ]]; then
                owned=1
            else
                log "using distribution firmware at $destination"
            fi
        fi
        [[ $owned -eq 0 ]] || printf 'owned %s %s\n' "$hash" "$destination" >> "$tmp"
    done < <(sed -n '2,$p' "$FIRMWARE/manifest")
    chmod 0644 "$tmp"; chown root:root "$tmp"
    if cmp -s "$tmp" "$FIRMWARE/manifest"; then
        rm -f "$tmp"
    else
        mv -f "$tmp" "$FIRMWARE/manifest.pending"
        recover_firmware_transaction
    fi
}

find_kdir() {
    local candidate=/usr/lib/modules/$KREL/build resolved release
    [[ -d $candidate ]] || return 1
    resolved=$(readlink -f "$candidate") || return 1
    [[ -n $resolved && -d $resolved ]] || return 1
    # The boot service runs as root, so never execute Kbuild input writable by
    # another user or containing links outside the validated tree.
    secure_kbuild_tree "$resolved" || return 1
    [[ -f $resolved/include/config/kernel.release \
        && ! -L $resolved/include/config/kernel.release ]] || return 1
    release=$(<"$resolved/include/config/kernel.release")
    [[ $release == "$KREL" ]] || return 1
    make -s -C "$resolved" kernelrelease >/dev/null 2>&1 || return 1
    printf '%s\n' "$resolved"
}

build_external_modules() {
    local build=$1 kdir=$2
    if [[ ! -e $kdir/vmlinux && ! -L $kdir/vmlinux ]]; then
        log "vmlinux is absent; optional module BTF will be skipped"
    fi
    make -C "$build" KDIR="$kdir" clean modules 2>&1 \
        | sed '/Skipping BTF generation for .* due to unavailability of vmlinux/d'
}

build_stage() {
    local kdir build stage endpoint module kbuild_copy=''
    for module in make gcc ld modinfo sha256sum readlink; do
        command -v "$module" >/dev/null || \
            die "build prerequisite '$module' is absent; rerun interactive steamdeck-setup.sh"
    done
    kdir=$(find_kdir) || \
        die "exact Kbuild for $KREL is absent; rerun interactive steamdeck-setup.sh"
    validate_source

    if [[ -e $kdir/vmlinux || -L $kdir/vmlinux ]]; then
        [[ -f $kdir/vmlinux && ! -L $kdir/vmlinux ]] \
            || die "local vmlinux path is unsafe"
        kbuild_copy=$(mktemp -d /var/tmp/rtw89-steamos-kbuild.XXXXXX)
        cp -a "$kdir"/. "$kbuild_copy"/
        rm -f "$kbuild_copy/vmlinux"
        secure_kbuild_tree "$kbuild_copy" || die "sanitized Kbuild copy is unsafe"
        kdir=$kbuild_copy
    fi

    build=$(mktemp -d /var/tmp/rtw89-steamos-build.XXXXXX)
    trap 'rm -rf "${build:-}" "${kbuild_copy:-}"; relock_rootfs' EXIT
    cp -a "$SOURCE"/. "$build"/
    build_external_modules "$build" "$kdir"
    find_matching_endpoints "$build" \
        || die "no attached supported RTW89 device matches rebuilt module aliases"
    endpoint=${MATCH_ENDPOINTS[0]}
    validate_module_files "$build" "$KREL" "$endpoint" \
        || die "boot rebuild did not produce the validated $KREL module set"

    install -d -o root -g root -m 0755 "$MODULES"
    stage=$(mktemp -d "$MODULES/.${KREL}.new.XXXXXX")
    for module in "${EXPECTED_MODULES[@]}"; do
        install -o root -g root -m 0644 "$build/$module.ko" "$stage/$module.ko"
    done
    render_module_manifest "$stage" "$KREL" "$endpoint" > "$stage/manifest"
    chmod 0644 "$stage/manifest"
    chown -R root:root "$stage"
    chmod -R go-w "$stage"
    validate_stage "$stage" "$KREL" || die "new persistent module stage failed validation"
    [[ ! -e $MODULES/$KREL && ! -L $MODULES/$KREL ]] \
        || die "refusing to replace an unrecognized stage for $KREL"
    mv "$stage" "$MODULES/$KREL"
    rm -rf "$build" "$kbuild_copy"
    trap relock_rootfs EXIT
    log "built and staged modules for $KREL"
}

install_stage() {
    local stage=$1 destination=$INSTALL_BASE/$KREL/updates/rtw89 new module
    safe_root_directory "$INSTALL_BASE/$KREL" \
        || die "unsafe running-kernel module directory"
    if [[ -e $INSTALL_BASE/$KREL/updates || -L $INSTALL_BASE/$KREL/updates ]]; then
        safe_root_directory "$INSTALL_BASE/$KREL/updates" || die "unsafe module updates directory"
    fi
    if [[ -e $destination || -L $destination ]]; then
        die "installed RTW89 directory is not validated; rerun interactive steamdeck-setup.sh"
    fi
    unlock_rootfs
    install -d -o root -g root -m 0755 "$(dirname "$destination")"
    new=$(mktemp -d "$(dirname "$destination")/.rtw89.new.XXXXXX")
    for module in "${EXPECTED_MODULES[@]}"; do
        install -o root -g root -m 0644 "$stage/$module.ko" "$new/$module.ko"
    done
    validate_installed "$new" "$stage" || die "rootfs module staging failed validation"
    mv "$new" "$destination"
    depmod "$KREL"
    mkinitcpio -P
    relock_rootfs
    log "restored modules for $KREL"
}

recover_module_transaction
restore_firmware
stage=$MODULES/$KREL
installed=$INSTALL_BASE/$KREL/updates/rtw89

if [[ -e $stage || -L $stage ]]; then
    validate_stage "$stage" "$KREL" || die "persistent module stage for $KREL is unsafe or corrupt"
    if [[ -e $installed || -L $installed ]]; then
        validate_installed "$installed" "$stage" \
            || die "installed modules differ from the trusted stage; rerun interactive steamdeck-setup.sh"
    else
        install_stage "$stage"
    fi
else
    if [[ -e $installed || -L $installed ]]; then
        die "installed modules have no trusted stage; rerun interactive steamdeck-setup.sh"
    fi
    build_stage
    stage=$MODULES/$KREL
    install_stage "$stage"
fi

if [[ $FIRMWARE_CHANGED == 1 || -e $FIRMWARE_INITRAMFS_PENDING \
    || -L $FIRMWARE_INITRAMFS_PENDING ]]; then
    secure_file "$FIRMWARE_INITRAMFS_PENDING" \
        || die "firmware initramfs marker is unsafe"
    unlock_rootfs
    mkinitcpio -P
    rm -f "$FIRMWARE_INITRAMFS_PENDING"
    relock_rootfs
fi

metadata_endpoint=$(manifest_endpoint "$stage/manifest")
installed_name=$(modinfo -k "$KREL" -n "$metadata_endpoint" 2>/dev/null || true)
if [[ $installed_name != "$installed/$metadata_endpoint.ko" ]]; then
    unlock_rootfs
    depmod "$KREL"
    mkinitcpio -P
    relock_rootfs
    log "repaired module dependency metadata for $KREL"
fi
if find_matching_endpoints "$installed"; then
    for endpoint in "${MATCH_ENDPOINTS[@]}"; do
        modprobe "$endpoint" || die "could not load $endpoint; rerun interactive setup or reboot"
        log "validated $endpoint is loaded for $KREL"
    done
else
    log "modules are validated for $KREL; no attached supported adapter currently needs loading"
fi
