#!/usr/bin/env bash
# Shared privileged-service lifecycle for the Plasma and cracktro frontends.

SHARED_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_REPO_DIR="$(cd "$SHARED_SOURCE_DIR/.." && pwd)"
SHARED_PAYLOAD_DIR=/var/lib/bc250-control/desktop
SHARED_CLIENT_DIR=/var/lib/bc250-control/service-clients
SHARED_SERVICE_UNIT=/etc/systemd/system/bc250-control.service
SHARED_REPAIR_UNIT=/etc/systemd/system/bc250-desktop-control-repair.service
SHARED_DBUS_POLICY=/etc/dbus-1/system.d/io.github.keyboardspecialist.BC250Control1.conf
SHARED_POLKIT_POLICY=/usr/share/polkit-1/actions/io.github.keyboardspecialist.bc250-control.policy
SHARED_KEEP_FILE=/etc/atomic-update.conf.d/bc250-desktop.conf
SHARED_INSTALL_LOCK=/run/lock/bc250-service-install.lock
SHARED_CORE_UNLOCK_LIFECYCLE_LOCK=/run/lock/bc250-core-unlock-lifecycle.lock
SHARED_ROOT_UID=0
SHARED_STAGE=""
SHARED_OLD_PAYLOAD=""
SHARED_PAYLOAD_SWAPPED=0
SHARED_PAYLOAD_COMMITTED=0
SHARED_UNLOCK_LOCKED=0
SHARED_READONLY_CHANGED=0
SHARED_CLIENT_COUNT=0

shared_log() { echo "[bc250-service] $*"; }
shared_die() { echo "[bc250-service] $*" >&2; exit 1; }
shared_require_root() { [[ $EUID -eq 0 ]] || shared_die "Internal service installation requires root."; }

shared_validate_client() {
    [[ "$1" == plasma || "$1" == cracktro || "$1" == legacy ]] \
        || shared_die "Unrecognized service client: $1"
    [[ "$2" =~ ^[0-9]+$ ]] || shared_die "Invalid service client UID: $2"
    if [[ "$1" == legacy ]]; then
        [[ "$2" == 0 ]] || shared_die "The legacy preservation marker must use UID 0."
    else
        [[ "$2" -gt 0 ]] || shared_die "Frontend service clients require a non-root UID."
    fi
}

shared_validate_sources() {
    local path
    for path in \
        "$SHARED_SOURCE_DIR/service/bc250-control-service" \
        "$SHARED_SOURCE_DIR/service/bc250_control_service" \
        "$SHARED_SOURCE_DIR/service/io.github.keyboardspecialist.bc250-control.policy" \
        "$SHARED_SOURCE_DIR/vendor/dbus_next" \
        "$SHARED_REPO_DIR/backend/bc250_control" \
        "$SHARED_REPO_DIR/backend/vendor/tomli" \
        "$SHARED_SOURCE_DIR/bc250-desktop-control-repair" \
        "$SHARED_SOURCE_DIR/templates" \
        "$SHARED_REPO_DIR/bc250-power.sh" \
        "$SHARED_REPO_DIR/bc250-ram-split.sh" \
        "$SHARED_REPO_DIR/bc250-storage.sh" \
        "$SHARED_REPO_DIR/bc250-update-persistence.sh" \
        "$SHARED_REPO_DIR/topology.sh" \
        "$SHARED_REPO_DIR/core-unlock/bc250-unlock-cores.py" \
        "$SHARED_REPO_DIR/core-unlock/LICENSE"; do
        [[ -e "$path" && ! -L "$path" ]] \
            || shared_die "Required shared-service source is missing or unsafe: $path"
    done
    if find "$SHARED_SOURCE_DIR/service/bc250_control_service" \
        "$SHARED_SOURCE_DIR/vendor" "$SHARED_REPO_DIR/backend/bc250_control" \
        "$SHARED_REPO_DIR/backend/vendor" "$SHARED_SOURCE_DIR/templates" \
        -type l -print -quit | grep -q .; then
        shared_die "Refusing to stage service trees containing symlinks."
    fi
}

shared_copy_tree() {
    local source="$1" target="$2"
    install -d -o root -g root -m 0755 "$target"
    cp -a "$source"/. "$target"/
}

shared_stage_payload() {
    shared_validate_sources
    install -d -o root -g root -m 0755 /var/lib/bc250-control
    [[ -d /var/lib/bc250-control && ! -L /var/lib/bc250-control ]] \
        || shared_die "Privileged storage is unsafe."
    SHARED_STAGE=$(mktemp -d /var/lib/bc250-control/.desktop-stage.XXXXXX)
    install -d -o root -g root -m 0755 \
        "$SHARED_STAGE/py_modules" "$SHARED_STAGE/templates" \
        "$SHARED_STAGE/core-unlock"
    install -o root -g root -m 0755 \
        "$SHARED_SOURCE_DIR/service/bc250-control-service" \
        "$SHARED_STAGE/bc250-control-service"
    install -o root -g root -m 0755 \
        "$SHARED_SOURCE_DIR/bc250-desktop-control-repair" \
        "$SHARED_STAGE/bc250-desktop-control-repair"
    shared_copy_tree "$SHARED_SOURCE_DIR/service/bc250_control_service" \
        "$SHARED_STAGE/py_modules/bc250_control_service"
    shared_copy_tree "$SHARED_REPO_DIR/backend/bc250_control" \
        "$SHARED_STAGE/py_modules/bc250_control"
    shared_copy_tree "$SHARED_REPO_DIR/backend/vendor/tomli" \
        "$SHARED_STAGE/py_modules/tomli"
    shared_copy_tree "$SHARED_SOURCE_DIR/vendor/dbus_next" \
        "$SHARED_STAGE/py_modules/dbus_next"
    if [[ -d "$SHARED_REPO_DIR/backend/vendor/tomli-2.0.1.dist-info" ]]; then
        shared_copy_tree "$SHARED_REPO_DIR/backend/vendor/tomli-2.0.1.dist-info" \
            "$SHARED_STAGE/py_modules/tomli-2.0.1.dist-info"
    fi
    if [[ -d "$SHARED_SOURCE_DIR/vendor/dbus_next-0.2.3.dist-info" ]]; then
        shared_copy_tree "$SHARED_SOURCE_DIR/vendor/dbus_next-0.2.3.dist-info" \
            "$SHARED_STAGE/py_modules/dbus_next-0.2.3.dist-info"
    fi
    shared_copy_tree "$SHARED_SOURCE_DIR/templates" "$SHARED_STAGE/templates"
    install -o root -g root -m 0644 \
        "$SHARED_SOURCE_DIR/service/io.github.keyboardspecialist.bc250-control.policy" \
        "$SHARED_STAGE/templates/io.github.keyboardspecialist.bc250-control.policy"
    install -o root -g root -m 0755 \
        "$SHARED_REPO_DIR/bc250-power.sh" "$SHARED_STAGE/bc250-power.sh"
    install -o root -g root -m 0755 \
        "$SHARED_REPO_DIR/bc250-ram-split.sh" "$SHARED_STAGE/bc250-ram-split.sh"
    install -o root -g root -m 0755 \
        "$SHARED_REPO_DIR/bc250-storage.sh" "$SHARED_STAGE/bc250-storage.sh"
    install -o root -g root -m 0755 \
        "$SHARED_REPO_DIR/bc250-update-persistence.sh" \
        "$SHARED_STAGE/bc250-update-persistence.sh"
    install -o root -g root -m 0755 \
        "$SHARED_REPO_DIR/topology.sh" "$SHARED_STAGE/topology.sh"
    install -o root -g root -m 0755 \
        "$SHARED_REPO_DIR/core-unlock/bc250-unlock-cores.py" \
        "$SHARED_STAGE/core-unlock/bc250-unlock-cores.py"
    install -o root -g root -m 0644 \
        "$SHARED_REPO_DIR/core-unlock/LICENSE" "$SHARED_STAGE/core-unlock/LICENSE"
    find "$SHARED_STAGE" -type d -name __pycache__ -prune -exec rm -rf {} +
    find "$SHARED_STAGE" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
    chown -R root:root "$SHARED_STAGE"
    chmod -R go-w "$SHARED_STAGE"
    [[ -x "$SHARED_STAGE/bc250-control-service" \
        && -x "$SHARED_STAGE/bc250-power.sh" \
        && -x "$SHARED_STAGE/bc250-ram-split.sh" \
        && -x "$SHARED_STAGE/bc250-storage.sh" \
        && -x "$SHARED_STAGE/bc250-update-persistence.sh" \
        && -x "$SHARED_STAGE/core-unlock/bc250-unlock-cores.py" \
        && -f "$SHARED_STAGE/core-unlock/LICENSE" \
        && -f "$SHARED_STAGE/py_modules/bc250_control_service/main.py" \
        && -f "$SHARED_STAGE/py_modules/bc250_control/backend.py" \
        && -f "$SHARED_STAGE/py_modules/tomli/__init__.py" \
        && -f "$SHARED_STAGE/py_modules/dbus_next/__init__.py" ]] \
        || shared_die "The staged shared-service payload is incomplete."
    /usr/bin/python3 -I -c \
        'import runpy; runpy.run_path("'"$SHARED_STAGE"'/bc250-control-service", run_name="bc250_install_check")'
    sync -f "$SHARED_STAGE"
}

shared_acquire_install_lock() {
    command -v flock >/dev/null 2>&1 || shared_die "flock is required."
    exec 6> "$SHARED_INSTALL_LOCK" || shared_die "Could not open $SHARED_INSTALL_LOCK"
    flock 6 || shared_die "Could not lock $SHARED_INSTALL_LOCK"
}

shared_acquire_unlock_lifecycle() {
    exec 8> "$SHARED_CORE_UNLOCK_LIFECYCLE_LOCK" \
        || shared_die "Could not open $SHARED_CORE_UNLOCK_LIFECYCLE_LOCK"
    flock 8 || shared_die "Could not lock $SHARED_CORE_UNLOCK_LIFECYCLE_LOCK"
    SHARED_UNLOCK_LOCKED=1
}

shared_release_unlock_lifecycle() {
    if [[ $SHARED_UNLOCK_LOCKED -eq 1 ]]; then
        flock -u 8 2>/dev/null || true
        exec 8>&-
        SHARED_UNLOCK_LOCKED=0
    fi
}

shared_marker_path() { printf '%s/%s.%s\n' "$SHARED_CLIENT_DIR" "$1" "$2"; }

shared_validate_marker() {
    local marker="$1" name client uid metadata owner mode expected
    name=${marker##*/}
    [[ "$name" =~ ^(plasma|cracktro)\.([1-9][0-9]*)$ || "$name" == legacy.0 ]] \
        || shared_die "Unrecognized shared-service client marker: $marker"
    client=${name%%.*}
    uid=${name##*.}
    [[ -f "$marker" && ! -L "$marker" ]] \
        || shared_die "Unsafe shared-service client marker: $marker"
    metadata=$(stat -Lc '%u %a' "$marker")
    read -r owner mode <<< "$metadata"
    [[ "$owner" == "$SHARED_ROOT_UID" && $((8#$mode & 8#022)) -eq 0 ]] \
        || shared_die "Insecure shared-service client marker: $marker"
    expected=$(printf 'schema=1\nclient=%s\nuid=%s\n' "$client" "$uid")
    [[ "$(cat "$marker")" == "$expected" ]] \
        || shared_die "Unrecognized shared-service client marker contents: $marker"
}

shared_validate_client_registry() {
    local marker metadata owner mode
    SHARED_CLIENT_COUNT=0
    [[ -e "$SHARED_CLIENT_DIR" ]] || return 0
    [[ -d "$SHARED_CLIENT_DIR" && ! -L "$SHARED_CLIENT_DIR" ]] \
        || shared_die "Unsafe shared-service client registry: $SHARED_CLIENT_DIR"
    metadata=$(stat -Lc '%u %a' "$SHARED_CLIENT_DIR")
    read -r owner mode <<< "$metadata"
    [[ "$owner" == "$SHARED_ROOT_UID" && $((8#$mode & 8#022)) -eq 0 ]] \
        || shared_die "Insecure shared-service client registry: $SHARED_CLIENT_DIR"
    while IFS= read -r -d '' marker; do
        shared_validate_marker "$marker"
        SHARED_CLIENT_COUNT=$((SHARED_CLIENT_COUNT + 1))
    done < <(find "$SHARED_CLIENT_DIR" -mindepth 1 -maxdepth 1 -print0)
}

shared_register_client() {
    local client="$1" uid="$2" marker tmp
    shared_validate_client "$client" "$uid"
    install -d -o root -g root -m 0755 "$SHARED_CLIENT_DIR"
    marker=$(shared_marker_path "$client" "$uid")
    [[ ! -L "$marker" && ( ! -e "$marker" || -f "$marker" ) ]] \
        || shared_die "Refusing unsafe service client marker: $marker"
    tmp=$(mktemp "$SHARED_CLIENT_DIR/.client.XXXXXX")
    printf 'schema=1\nclient=%s\nuid=%s\n' "$client" "$uid" > "$tmp"
    install -o root -g root -m 0644 "$tmp" "$marker"
    rm -f "$tmp"
}

shared_migrate_markerless_install() {
    local migration_client="$1" migration_uid="$2"
    shared_validate_client_registry
    if [[ $SHARED_CLIENT_COUNT -eq 0 && -d "$SHARED_PAYLOAD_DIR" ]]; then
        shared_register_client "$migration_client" "$migration_uid"
        shared_log "Claimed markerless service install as ${migration_client}.${migration_uid}."
    fi
}

shared_replace_payload() {
    local metadata owner mode
    if [[ -L "$SHARED_PAYLOAD_DIR" \
        || ( -e "$SHARED_PAYLOAD_DIR" && ! -d "$SHARED_PAYLOAD_DIR" ) ]]; then
        shared_die "Refusing to replace unsafe payload path: $SHARED_PAYLOAD_DIR"
    fi
    if [[ -d "$SHARED_PAYLOAD_DIR" ]]; then
        metadata=$(stat -Lc '%u %a' "$SHARED_PAYLOAD_DIR")
        read -r owner mode <<< "$metadata"
        [[ "$owner" == 0 && $((8#$mode & 8#022)) -eq 0 ]] \
            || shared_die "Refusing to replace an insecure payload directory."
        SHARED_OLD_PAYLOAD="/var/lib/bc250-control/.desktop-previous.$$"
        [[ ! -e "$SHARED_OLD_PAYLOAD" ]] \
            || shared_die "Temporary replacement path already exists."
        mv "$SHARED_PAYLOAD_DIR" "$SHARED_OLD_PAYLOAD"
    fi
    mv "$SHARED_STAGE" "$SHARED_PAYLOAD_DIR"
    SHARED_STAGE=""
    SHARED_PAYLOAD_SWAPPED=1
}

shared_root_cleanup() {
    local rc=$?
    trap - EXIT
    [[ -z "$SHARED_STAGE" || ! -e "$SHARED_STAGE" ]] || rm -rf "$SHARED_STAGE"
    if [[ $rc -ne 0 && $SHARED_PAYLOAD_SWAPPED -eq 1 \
        && $SHARED_PAYLOAD_COMMITTED -eq 0 ]]; then
        systemctl stop bc250-control.service >/dev/null 2>&1 || true
        if [[ -n "$SHARED_OLD_PAYLOAD" && -d "$SHARED_OLD_PAYLOAD" ]]; then
            rm -rf "$SHARED_PAYLOAD_DIR"
            mv "$SHARED_OLD_PAYLOAD" "$SHARED_PAYLOAD_DIR"
            "$SHARED_PAYLOAD_DIR/bc250-desktop-control-repair" repair \
                >/dev/null 2>&1 || true
            systemctl start bc250-control.service >/dev/null 2>&1 || true
        else
            shared_log "Installation failed; preserving the validated payload for repair."
        fi
    fi
    shared_release_unlock_lifecycle
    exit "$rc"
}

shared_service_install() {
    local client="$1" uid="$2" migration_client="$3" migration_uid="$4"
    shared_require_root
    shared_validate_client "$client" "$uid"
    shared_validate_client "$migration_client" "$migration_uid"
    shared_acquire_install_lock
    trap shared_root_cleanup EXIT
    shared_migrate_markerless_install "$migration_client" "$migration_uid"
    shared_stage_payload
    shared_acquire_unlock_lifecycle
    systemctl stop bc250-control.service >/dev/null 2>&1 || true
    shared_replace_payload
    "$SHARED_PAYLOAD_DIR/bc250-desktop-control-repair" repair
    systemctl restart bc250-desktop-control-repair.service
    systemctl restart bc250-control.service
    shared_register_client "$client" "$uid"
    if [[ "$client" == plasma && -e "$SHARED_CLIENT_DIR/legacy.0" ]]; then
        shared_validate_marker "$SHARED_CLIENT_DIR/legacy.0"
        rm -f "$SHARED_CLIENT_DIR/legacy.0"
        shared_log "Replaced the legacy preservation marker with plasma.${uid}."
    fi
    SHARED_PAYLOAD_COMMITTED=1
    [[ -z "$SHARED_OLD_PAYLOAD" || ! -e "$SHARED_OLD_PAYLOAD" ]] \
        || rm -rf "$SHARED_OLD_PAYLOAD"
    shared_release_unlock_lifecycle
    shared_log "Root service payload installed for ${client}.${uid}."
}

shared_restore_uninstall_readonly() {
    local rc=$?
    trap - EXIT
    if [[ $SHARED_READONLY_CHANGED -eq 1 ]]; then
        if ! /usr/bin/steamos-readonly enable; then
            echo "[bc250-service] Failed to restore the readonly root filesystem." >&2
            rc=1
        fi
        SHARED_READONLY_CHANGED=0
    fi
    shared_release_unlock_lifecycle
    exit "$rc"
}

shared_remove_service() {
    systemctl disable --now bc250-control.service \
        bc250-desktop-control-repair.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet bc250-control.service \
        || systemctl is-active --quiet bc250-desktop-control-repair.service; then
        shared_die "Could not stop the desktop services; refusing to remove their files."
    fi
    rm -f "$SHARED_SERVICE_UNIT" "$SHARED_REPAIR_UNIT" \
        /etc/systemd/system/multi-user.target.wants/bc250-control.service \
        /etc/systemd/system/multi-user.target.wants/bc250-desktop-control-repair.service \
        "$SHARED_DBUS_POLICY"
    rm -f /etc/systemd/system/bc250-control.service.d/10-bc250-storage.conf \
        /etc/systemd/system/bc250-desktop-control-repair.service.d/10-bc250-storage.conf
    rmdir /etc/systemd/system/bc250-control.service.d \
        /etc/systemd/system/bc250-desktop-control-repair.service.d 2>/dev/null || true
    if [[ -e "$SHARED_POLKIT_POLICY" ]]; then
        local state
        [[ -f "$SHARED_POLKIT_POLICY" && ! -L "$SHARED_POLKIT_POLICY" ]] \
            || shared_die "Refusing to remove unsafe polkit path: $SHARED_POLKIT_POLICY"
        state=$(/usr/bin/steamos-readonly status 2>&1) || true
        case "${state,,}" in
            *enabled*)
                SHARED_READONLY_CHANGED=1
                /usr/bin/steamos-readonly disable
                ;;
            *disabled*) ;;
            *) shared_die "Unrecognized SteamOS readonly state: $state" ;;
        esac
        rm -f "$SHARED_POLKIT_POLICY"
        if [[ $SHARED_READONLY_CHANGED -eq 1 ]]; then
            /usr/bin/steamos-readonly enable
            SHARED_READONLY_CHANGED=0
        fi
    fi
    [[ ! -L "$SHARED_PAYLOAD_DIR" ]] \
        || shared_die "Refusing to remove symlink payload: $SHARED_PAYLOAD_DIR"
    rm -rf "$SHARED_PAYLOAD_DIR"
    systemctl daemon-reload
    systemctl reload dbus.service >/dev/null 2>&1 || true
    bash "$SHARED_REPO_DIR/bc250-update-persistence.sh" remove desktop
}

shared_service_release() {
    local client="$1" uid="$2" marker remaining
    shared_require_root
    shared_validate_client "$client" "$uid"
    shared_acquire_install_lock
    trap shared_restore_uninstall_readonly EXIT
    shared_validate_client_registry
    marker=$(shared_marker_path "$client" "$uid")
    if [[ ! -e "$marker" ]]; then
        if [[ $SHARED_CLIENT_COUNT -eq 0 && -d "$SHARED_PAYLOAD_DIR" ]]; then
            if [[ "$client" == cracktro ]]; then
                shared_register_client legacy 0
                shared_log "Preserved markerless service install as legacy.0."
                shared_log "No service registration exists for ${client}.${uid}."
                return 0
            fi
            shared_register_client plasma "$uid"
            SHARED_CLIENT_COUNT=1
            shared_log "Claimed markerless Plasma service install before release."
        else
            shared_log "No service registration exists for ${client}.${uid}."
            return 0
        fi
    fi
    shared_validate_marker "$marker"
    remaining=$((SHARED_CLIENT_COUNT - 1))
    if [[ $remaining -gt 0 ]]; then
        rm -f "$marker"
        shared_log "Released ${client}.${uid}; shared service retained for $remaining client(s)."
        return 0
    fi
    shared_acquire_unlock_lifecycle
    shared_remove_service
    rm -f "$marker"
    rmdir "$SHARED_CLIENT_DIR" 2>/dev/null || true
    shared_release_unlock_lifecycle
    shared_log "Released ${client}.${uid}; no clients remain, so the shared service was removed."
}

shared_client_registered() {
    local client="$1" uid="$2" marker
    shared_validate_client "$client" "$uid"
    marker=$(shared_marker_path "$client" "$uid")
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    shared_validate_marker "$marker"
}
