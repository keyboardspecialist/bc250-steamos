#!/usr/bin/env bash
# Put privileged BC-250 assets on SteamOS's large shared partition while
# retaining the conventional /var/lib/bc250-control path.
set -euo pipefail

ROOT_DIR=/var/lib/bc250-control
BACKING_DIR=/home/.steamos/offload/var/lib/bc250-control
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
LEGACY_UMR_DIR=/etc/bc250-control/umr
LEGACY_ROOT_DIR=/var/lib/bc250-40cu
UNIT_NAME='var-lib-bc250\x2dcontrol.mount'
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
UNIT_WANTS="/etc/systemd/system/local-fs.target.wants/$UNIT_NAME"
RECOVERY_NAME=bc250-persistence-recovery.service
RECOVERY_PATH="/etc/systemd/system/$RECOVERY_NAME"
RECOVERY_WANTS="/etc/systemd/system/local-fs.target.wants/$RECOVERY_NAME"
RECOVERY_HELPER="$BACKING_DIR/helper/bc250-storage.sh"
KEEP_PATH=/etc/atomic-update.conf.d/bc250-storage.conf
ROOT_BACKED_SERVICES=(
    bc250-cu-live-manager.service
    bc250-acpi-heal.service
    bc250-gpu-freq-restore.service
    bc250-smu-oc.service
    cyan-skillfish-governor-smu.service
    bc250-cec-poweroff-standby.service
    aic8800-modules.service
)
MIGRATION_OLD=""
BACKING_CREATED=0
BACKING_COMMITTED=0
LEGACY_UMR_INSTALLED=0
LEGACY_UMR_CLEANUP=0

log() { echo "[bc250-storage] $*"; }
die() { echo "[bc250-storage] $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run with sudo."; }

restore_failed_migration() {
    local rc=$?
    if [[ $rc -ne 0 && $BACKING_COMMITTED -eq 0 ]]; then
        if mountpoint -q "$ROOT_DIR"; then
            echo "[bc250-storage] Migration failed after $ROOT_DIR became mounted; preserving all data for manual recovery." >&2
            exit "$rc"
        fi
        if [[ $BACKING_CREATED -eq 1 ]]; then
            rm -rf "$BACKING_DIR"
        elif [[ $LEGACY_UMR_INSTALLED -eq 1 ]]; then
            rm -rf "$BACKING_DIR/umr"
        fi
        if [[ -n "$MIGRATION_OLD" && -d "$MIGRATION_OLD" ]]; then
            rm -rf "$ROOT_DIR"
            mv "$MIGRATION_OLD" "$ROOT_DIR"
        fi
    fi
    exit "$rc"
}
trap restore_failed_migration EXIT

secure_directory() {
    local current="$1" metadata owner mode
    while :; do
        [[ -d "$current" && ! -L "$current" ]] \
            || die "Unsafe storage path (not a real directory): $current"
        metadata=$(stat -Lc '%u %a' "$current")
        read -r owner mode <<< "$metadata"
        [[ "$owner" == 0 && $((8#$mode & 8#022)) -eq 0 ]] \
            || die "Unsafe storage path (must be root-owned and not group/world-writable): $current"
        [[ "$current" == / ]] && break
        current=${current%/*}
        [[ -n "$current" ]] || current=/
    done
}

secure_file() {
    local path="$1" metadata owner mode
    [[ -f "$path" && ! -L "$path" ]] || die "Unsafe recovery helper: $path"
    metadata=$(stat -Lc '%u %a' "$path")
    read -r owner mode <<< "$metadata"
    [[ "$owner" == 0 && $((8#$mode & 8#022)) -eq 0 ]] \
        || die "Unsafe recovery helper (must be root-owned and not group/world-writable): $path"
    secure_directory "$(dirname "$path")"
}

directory_empty() (
    local -a entries
    shopt -s nullglob dotglob
    entries=("$1"/*)
    ((${#entries[@]} == 0))
)

expected_mount_active() {
    mountpoint -q "$ROOT_DIR" \
        && [[ "$(findmnt -rn -M "$ROOT_DIR" -o FSROOT)" \
            == "/.steamos/offload/var/lib/bc250-control" ]]
}

render_mount_unit() {
    cat << EOF
[Unit]
Description=BC-250 persistent privileged storage
Requires=$RECOVERY_NAME
After=home.mount $RECOVERY_NAME
RequiresMountsFor=/home
Before=local-fs.target

[Mount]
What=$BACKING_DIR
Where=$ROOT_DIR
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF
}

render_recovery_unit() {
    cat << EOF
[Unit]
Description=BC-250 persistence infrastructure recovery
DefaultDependencies=no
RequiresMountsFor=/home
After=home.mount
Before=$UNIT_NAME local-fs.target

[Service]
Type=oneshot
ExecStart=$RECOVERY_HELPER repair-infrastructure
RemainAfterExit=yes
UMask=0022
NoNewPrivileges=yes
RestrictAddressFamilies=AF_UNIX
LockPersonality=yes

[Install]
WantedBy=local-fs.target
EOF
}

render_keep_file() {
    cat << EOF
# BC-250 persistence infrastructure retained across SteamOS atomic updates.
$RECOVERY_PATH
$RECOVERY_WANTS
$UNIT_PATH
$UNIT_WANTS
EOF
}

atomic_write() {
    local target="$1" mode="$2" dir tmp
    dir=$(dirname "$target")
    [[ ! -L "$target" ]] || die "Refusing to replace symlink: $target"
    [[ ! -e "$target" || -f "$target" ]] \
        || die "Refusing to replace non-file: $target"
    install -d -o root -g root -m 0755 "$dir"
    tmp=$(mktemp "$dir/.bc250-storage.XXXXXX")
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
    chown root:root "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        chmod "$mode" "$target"
        chown root:root "$target"
    else
        sync -d "$tmp"
        mv -f "$tmp" "$target"
        sync -f "$dir"
        log "Repaired $target"
    fi
}

install_enablement() {
    local link="$1" unit="$2" expected="../$unit"
    install -d -o root -g root -m 0755 "$(dirname "$link")"
    if [[ -L "$link" ]]; then
        [[ "$(readlink "$link")" == "$expected" ]] && return 0
        rm -f "$link"
    elif [[ -e "$link" ]]; then
        die "Refusing to replace non-symlink enablement path: $link"
    fi
    ln -s "$expected" "$link"
    log "Repaired $link"
}

write_infrastructure_files() {
    render_mount_unit | atomic_write "$UNIT_PATH" 0644
    render_recovery_unit | atomic_write "$RECOVERY_PATH" 0644
    render_keep_file | atomic_write "$KEEP_PATH" 0644
    install_enablement "$UNIT_WANTS" "$UNIT_NAME"
    install_enablement "$RECOVERY_WANTS" "$RECOVERY_NAME"
}

write_component_dropins() {
    local unit base dropin
    for unit in "${ROOT_BACKED_SERVICES[@]}"; do
        base="/etc/systemd/system/$unit"
        [[ -f "$base" && ! -L "$base" ]] || continue
        dropin="/etc/systemd/system/$unit.d/10-bc250-storage.conf"
        case "$unit" in
            cyan-skillfish-governor-smu.service)
                atomic_write "$dropin" 0644 << EOF
[Unit]
Requires=$RECOVERY_NAME
After=
After=$RECOVERY_NAME bc250-cu-live-manager.service
RequiresMountsFor=$ROOT_DIR
EOF
                ;;
            bc250-cec-poweroff-standby.service)
                atomic_write "$dropin" 0644 << EOF
[Unit]
Requires=$RECOVERY_NAME
After=
After=$RECOVERY_NAME
RequiresMountsFor=$ROOT_DIR
EOF
                ;;
            *)
                atomic_write "$dropin" 0644 << EOF
[Unit]
Requires=$RECOVERY_NAME
After=$RECOVERY_NAME
RequiresMountsFor=$ROOT_DIR
EOF
                ;;
        esac
    done
}

install_recovery_helper() {
    local source="$SELF"
    if [[ ! -f "$source" && -n "$MIGRATION_OLD" \
        && "$SELF" == "$ROOT_DIR/"* ]]; then
        source="$MIGRATION_OLD/${SELF#"$ROOT_DIR/"}"
    fi
    [[ -f "$source" && ! -L "$source" ]] \
        || die "Recovery helper source is missing or unsafe: $source"
    install -d -o root -g root -m 0755 "$(dirname "$RECOVERY_HELPER")"
    atomic_write "$RECOVERY_HELPER" 0755 < "$source"
    secure_file "$RECOVERY_HELPER"
}

repair_infrastructure() {
    require_root
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin

    [[ -d "$BACKING_DIR" && ! -L "$BACKING_DIR" ]] \
        || die "Persistent backing storage is missing or unsafe: $BACKING_DIR"
    secure_directory "$BACKING_DIR"
    secure_file "$RECOVERY_HELPER"

    if mountpoint -q "$ROOT_DIR"; then
        expected_mount_active \
            || die "$ROOT_DIR is already an unexpected mount point."
    else
        if [[ -e "$ROOT_DIR" ]]; then
            [[ -d "$ROOT_DIR" && ! -L "$ROOT_DIR" ]] \
                || die "Unsafe storage mount point: $ROOT_DIR"
            secure_directory "$ROOT_DIR"
            directory_empty "$ROOT_DIR" \
                || die "Refusing to hide files in unmounted $ROOT_DIR"
        else
            install -d -o root -g root -m 0755 "$ROOT_DIR"
        fi
    fi

    write_infrastructure_files
    write_component_dropins
    systemctl daemon-reload

    if ! mountpoint -q "$ROOT_DIR"; then
        mount --bind "$BACKING_DIR" "$ROOT_DIR"
        log "Restored bind mount at $ROOT_DIR"
    fi
    expected_mount_active || die "Failed to establish the expected $ROOT_DIR bind mount."
    secure_directory "$ROOT_DIR"
}

migrate_helper() {
    local source="$1" target="$2" unit="$3"
    [[ -f "$source" && ! -L "$source" ]] || return 0
    if [[ ! -e "$target" ]]; then
        install -D -o root -g root -m 0755 "$source" "$target"
    fi
    if [[ -f "$unit" && ! -L "$unit" ]]; then
        sed -i "s|$source|$target|g" "$unit"
    fi
    rm -f "$source"
    log "Migrated legacy helper $source."
}

migrate_aic_helper() {
    local old=/etc/aic8800-ensure-modules.sh
    local source="$SCRIPT_DIR/aic8800/src/USB/driver_fw/drivers/aic8800"
    local firmware="$SCRIPT_DIR/aic8800/src/USB/driver_fw/fw/aic8800D80"
    local helper="$SCRIPT_DIR/aic8800/aic8800-ensure-modules.sh"
    local unit=/etc/systemd/system/aic8800-modules.service
    local stage repo_line repo
    [[ -f "$old" && ! -L "$old" ]] || return 0
    if [[ ! -f "$source/Makefile" && -f /etc/aic8800-paths.conf \
        && ! -L /etc/aic8800-paths.conf ]]; then
        repo_line=$(grep -m1 '^AIC8800_REPO=' /etc/aic8800-paths.conf || true)
        repo=${repo_line#AIC8800_REPO=}
        if [[ "$repo" =~ ^/[A-Za-z0-9_./-]+$ ]]; then
            source="$repo/src/USB/driver_fw/drivers/aic8800"
            firmware="$repo/src/USB/driver_fw/fw/aic8800D80"
            helper="$repo/aic8800-ensure-modules.sh"
        fi
    fi
    if [[ ! -f "$source/Makefile" || ! -d "$firmware" || ! -f "$helper" ]]; then
        systemctl disable --now aic8800-modules.service >/dev/null 2>&1 || true
        rm -f "$old" /etc/aic8800-paths.conf "$unit"
        log "Disabled unsafe legacy AIC8800 boot helper; rerun aic8800/steamdeck-setup.sh."
        return 0
    fi
    if find "$source" "$firmware" -type l -print -quit | grep -q .; then
        die "Refusing to snapshot AIC8800 source containing symlinks."
    fi
    install -d -o root -g root -m 0755 "$ROOT_DIR/aic8800"
    stage=$(mktemp -d "$ROOT_DIR/aic8800/.source-migrate.XXXXXX")
    cp -a "$source"/. "$stage"/
    chown -R root:root "$stage"
    chmod -R go-w "$stage"
    rm -rf "$ROOT_DIR/aic8800/source"
    mv "$stage" "$ROOT_DIR/aic8800/source"
    rm -rf "$ROOT_DIR/aic8800/firmware/aic8800D80"
    install -d -o root -g root -m 0755 "$ROOT_DIR/aic8800/firmware/aic8800D80"
    cp -a "$firmware"/. "$ROOT_DIR/aic8800/firmware/aic8800D80"/
    chown -R root:root "$ROOT_DIR/aic8800"
    chmod -R go-w "$ROOT_DIR/aic8800"
    install -D -o root -g root -m 0755 "$helper" \
        "$ROOT_DIR/helper/aic8800-ensure-modules"
    if [[ -f "$unit" && ! -L "$unit" ]]; then
        sed -i "s|$old|$ROOT_DIR/helper/aic8800-ensure-modules|g" "$unit"
        if grep -q '^ConditionPathExists=' "$unit"; then
            sed -i "s|^ConditionPathExists=.*|ConditionPathExists=$ROOT_DIR/aic8800/source/Makefile|" "$unit"
        fi
    fi
    rm -f "$old" /etc/aic8800-paths.conf
    log "Migrated legacy AIC8800 helper and trusted source snapshot."
}

install_storage() {
    require_root
    local parent old="" backing_existed=0

    for parent in /home/.steamos /home/.steamos/offload \
        /home/.steamos/offload/var /home/.steamos/offload/var/lib; do
        if [[ ! -e "$parent" ]]; then
            install -d -o root -g root -m 0755 "$parent"
        fi
        secure_directory "$parent"
    done
    if [[ -e "$BACKING_DIR" ]]; then
        backing_existed=1
    else
        install -d -o root -g root -m 0755 "$BACKING_DIR"
        BACKING_CREATED=1
    fi
    secure_directory "$BACKING_DIR"

    # The legacy UMR payload can fill the /etc overlay so completely that the
    # mount unit cannot be written. Stage it in secure backing storage, but do
    # not remove the source or update its environment file until mount commit.
    if [[ -d "$LEGACY_UMR_DIR" && ! -L "$LEGACY_UMR_DIR" ]]; then
        local umr_stage
        if [[ -e "$BACKING_DIR/umr" ]]; then
            [[ -d "$BACKING_DIR/umr" && ! -L "$BACKING_DIR/umr" \
                && -x "$BACKING_DIR/umr/bin/umr" \
                && -f "$BACKING_DIR/umr/share/umr/database/cyan_skillfish.asic" \
                && -f "$BACKING_DIR/umr/share/umr/database/cyan_skillfish.soc15" ]] \
                || die "Persistent UMR conflicts with legacy $LEGACY_UMR_DIR"
        else
            umr_stage=$(mktemp -d "$BACKING_DIR/.umr-migrate.XXXXXX")
            cp -a "$LEGACY_UMR_DIR"/. "$umr_stage"/
            [[ -x "$umr_stage/bin/umr" \
                && -f "$umr_stage/share/umr/database/cyan_skillfish.asic" \
                && -f "$umr_stage/share/umr/database/cyan_skillfish.soc15" ]] \
                || die "Refusing to remove incomplete legacy UMR data."
            chown -R root:root "$umr_stage"
            chmod -R go-w "$umr_stage"
            mv "$umr_stage" "$BACKING_DIR/umr"
            LEGACY_UMR_INSTALLED=1
        fi
        LEGACY_UMR_CLEANUP=1
    fi

    if mountpoint -q "$ROOT_DIR"; then
        [[ "$(findmnt -rn -M "$ROOT_DIR" -o FSROOT)" == "/.steamos/offload/var/lib/bc250-control" ]] \
            || die "$ROOT_DIR is already an unexpected mount point."
    else
        if [[ -e "$ROOT_DIR" ]]; then
            [[ -d "$ROOT_DIR" && ! -L "$ROOT_DIR" ]] \
                || die "Refusing to replace unsafe path: $ROOT_DIR"
            secure_directory "$ROOT_DIR"
            if ! directory_empty "$ROOT_DIR"; then
                [[ $backing_existed -eq 0 ]] \
                    || die "Refusing to merge unmounted $ROOT_DIR into existing $BACKING_DIR"
                old="/var/lib/.bc250-control.migrate.$$"
                MIGRATION_OLD="$old"
                mv "$ROOT_DIR" "$old"
            fi
        fi
        if [[ -n "$old" ]]; then
            if find "$old" -type l -print -quit | grep -q .; then
                die "Refusing to migrate privileged storage containing symlinks."
            fi
            [[ $LEGACY_UMR_INSTALLED -eq 0 || ! -e "$old/umr" ]] \
                || die "Conflicting legacy UMR trees require manual resolution."
            cp -a "$old"/. "$BACKING_DIR"/
            chown -R root:root "$BACKING_DIR"
            chmod -R go-w "$BACKING_DIR"
        fi
        install -d -o root -g root -m 0755 "$ROOT_DIR"
    fi

    install_recovery_helper
    write_infrastructure_files
    write_component_dropins
    systemctl daemon-reload
    systemctl restart "$RECOVERY_NAME"
    mountpoint -q "$ROOT_DIR" || die "Failed to mount $ROOT_DIR"
    secure_directory "$ROOT_DIR"
    BACKING_COMMITTED=1
    if [[ -n "$old" ]]; then
        rm -rf "$old"
        MIGRATION_OLD=""
        old=""
    fi
    if [[ $LEGACY_UMR_CLEANUP -eq 1 ]]; then
        rm -rf "$LEGACY_UMR_DIR"
        rmdir /etc/bc250-control 2>/dev/null || true
        if [[ -f /etc/bc250-cu-live-manager.conf \
            && ! -L /etc/bc250-cu-live-manager.conf ]]; then
            sed -i "s|^UMR=.*|UMR=$ROOT_DIR/umr/bin/umr|" \
                /etc/bc250-cu-live-manager.conf
            sed -i "s|^UMR_DATABASE_PATH=.*|UMR_DATABASE_PATH=$ROOT_DIR/umr/share/umr/database|" \
                /etc/bc250-cu-live-manager.conf
        fi
        log "Migrated legacy UMR out of the /etc overlay."
    fi

    # Preserve old service paths without retaining 100+ MB on the tiny /var
    # partition. This compatibility link stays entirely inside root-owned
    # /var/lib and is removed after component units have been rewritten.
    if [[ -d "$LEGACY_ROOT_DIR" && ! -L "$LEGACY_ROOT_DIR" ]]; then
        rm -rf "$ROOT_DIR/legacy-bc250-40cu"
        cp -a "$LEGACY_ROOT_DIR" "$ROOT_DIR/legacy-bc250-40cu"
        chown -R root:root "$ROOT_DIR/legacy-bc250-40cu"
        chmod -R go-w "$ROOT_DIR/legacy-bc250-40cu"
        rm -rf "$LEGACY_ROOT_DIR"
        ln -s "$ROOT_DIR/legacy-bc250-40cu" "$LEGACY_ROOT_DIR"
        log "Offloaded legacy $LEGACY_ROOT_DIR data."
    fi

    migrate_helper /etc/bc250-acpi-heal.sh \
        "$ROOT_DIR/helper/bc250-acpi-heal" \
        /etc/systemd/system/bc250-acpi-heal.service
    migrate_helper /etc/bc250-cec-poweroff-standby.sh \
        "$ROOT_DIR/helper/bc250-cec-poweroff-standby" \
        /etc/systemd/system/bc250-cec-poweroff-standby.service
    migrate_aic_helper
    if [[ -f /etc/cyan-skillfish-governor-smu/freq-state \
        && ! -L /etc/cyan-skillfish-governor-smu/freq-state ]]; then
        if [[ ! -e "$ROOT_DIR/governor/freq-state" ]]; then
            install -D -o root -g root -m 0644 \
                /etc/cyan-skillfish-governor-smu/freq-state \
                "$ROOT_DIR/governor/freq-state"
        fi
        rm -f /etc/cyan-skillfish-governor-smu/freq-state
        log "Migrated legacy GPU frequency state."
    fi
    systemctl daemon-reload
    log "$ROOT_DIR is backed by $BACKING_DIR"
}

show_status() {
    local state=missing source=- recovery=- mount_enabled=-
    if mountpoint -q "$ROOT_DIR"; then
        if expected_mount_active; then state=mounted; else state=unexpected; fi
        source=$(findmnt -rn -M "$ROOT_DIR" -o SOURCE)
    elif [[ -f "$UNIT_PATH" ]]; then
        state=unmounted
    fi
    [[ -L "$RECOVERY_WANTS" && "$(readlink "$RECOVERY_WANTS")" == "../$RECOVERY_NAME" ]] \
        && recovery=enabled
    [[ -L "$UNIT_WANTS" && "$(readlink "$UNIT_WANTS")" == "../$UNIT_NAME" ]] \
        && mount_enabled=enabled
    log "storage: $state"
    log "path: $ROOT_DIR"
    log "source: $source"
    log "mount unit: $UNIT_PATH ($mount_enabled)"
    log "recovery: $RECOVERY_PATH ($recovery)"
    log "recovery helper: $RECOVERY_HELPER"
    log "atomic-update list: $KEEP_PATH"
}

case "${1:-install}" in
    install|repair) install_storage ;;
    repair-infrastructure) repair_infrastructure ;;
    status) show_status ;;
    render)
        case "${2:-}" in
            mount) render_mount_unit ;;
            recovery) render_recovery_unit ;;
            keep) render_keep_file ;;
            *) die "Usage: $0 render {mount|recovery|keep}" ;;
        esac
        ;;
    *) die "Usage: $0 {install|repair|repair-infrastructure|status|render}" ;;
esac
