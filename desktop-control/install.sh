#!/usr/bin/env bash
# Install the Plasma desktop control and its privileged system service.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SOURCE_DIR/.." && pwd)"
PAYLOAD_DIR=/var/lib/bc250-control/desktop
PLASMOID_ID=io.github.keyboardspecialist.bc250control
PLASMOID_DIR="$SOURCE_DIR/plasmoid"
SERVICE_UNIT=/etc/systemd/system/bc250-control.service
REPAIR_UNIT=/etc/systemd/system/bc250-desktop-control-repair.service
DBUS_POLICY=/etc/dbus-1/system.d/io.github.keyboardspecialist.BC250Control1.conf
POLKIT_POLICY=/usr/share/polkit-1/actions/io.github.keyboardspecialist.bc250-control.policy
KEEP_FILE=/etc/atomic-update.conf.d/bc250-desktop.conf
STAGE=""
OLD_PAYLOAD=""
PAYLOAD_SWAPPED=0
PAYLOAD_COMMITTED=0
UNINSTALL_READONLY_CHANGED=0

log() { echo "[bc250-desktop] $*"; }
die() { echo "[bc250-desktop] $*" >&2; exit 1; }
require_normal_user() { [[ $EUID -ne 0 ]] || die "Run as the logged-in Deck user, not with sudo."; }
require_root() { [[ $EUID -eq 0 ]] || die "Internal installation step requires root."; }

validate_sources() {
    local path
    for path in \
        "$SOURCE_DIR/service/bc250-control-service" \
        "$SOURCE_DIR/service/bc250_control_service" \
        "$SOURCE_DIR/service/io.github.keyboardspecialist.bc250-control.policy" \
        "$SOURCE_DIR/vendor/dbus_next" \
        "$REPO_DIR/backend/bc250_control" \
        "$REPO_DIR/backend/vendor/tomli" \
        "$SOURCE_DIR/bc250-desktop-control-repair" \
        "$SOURCE_DIR/templates" \
        "$PLASMOID_DIR/metadata.json" \
        "$PLASMOID_DIR/contents/icons/bc250-control.svg" \
        "$PLASMOID_DIR/contents/ui/main.qml"; do
        [[ -e "$path" && ! -L "$path" ]] || die "Required source is missing or unsafe: $path"
    done
    if find "$SOURCE_DIR/service/bc250_control_service" \
        "$SOURCE_DIR/vendor" "$REPO_DIR/backend/bc250_control" \
        "$REPO_DIR/backend/vendor" "$SOURCE_DIR/templates" \
        -type l -print -quit | grep -q .; then
        die "Refusing to stage Python or template trees containing symlinks."
    fi
    if ! /usr/bin/python3 - "$PLASMOID_DIR/metadata.json" "$PLASMOID_ID" << 'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        metadata = json.load(stream)
    plugin = metadata.get("KPlugin", {})
    if plugin.get("Id") != sys.argv[2]:
        raise ValueError("the plugin ID does not match the installer")
    if metadata.get("X-Plasma-API-Minimum-Version") != "6.0":
        raise ValueError("the package does not declare the Plasma 6 API")
except (OSError, ValueError, TypeError) as error:
    print("Invalid plasmoid metadata: {}".format(error), file=sys.stderr)
    raise SystemExit(1)
PY
    then
        die "The Plasma applet package is invalid."
    fi
}

root_cleanup() {
    local rc=$?
    trap - EXIT
    [[ -z "$STAGE" || ! -e "$STAGE" ]] || rm -rf "$STAGE"
    if [[ $rc -ne 0 && $PAYLOAD_SWAPPED -eq 1 && $PAYLOAD_COMMITTED -eq 0 ]]; then
        systemctl stop bc250-control.service >/dev/null 2>&1 || true
        if [[ -n "$OLD_PAYLOAD" && -d "$OLD_PAYLOAD" ]]; then
            rm -rf "$PAYLOAD_DIR"
            mv "$OLD_PAYLOAD" "$PAYLOAD_DIR"
            "$PAYLOAD_DIR/bc250-desktop-control-repair" repair >/dev/null 2>&1 || true
            systemctl start bc250-control.service >/dev/null 2>&1 || true
        else
            log "Installation failed; preserving the validated payload for repair."
        fi
    fi
    exit "$rc"
}

copy_tree() {
    local source="$1" target="$2"
    install -d -o root -g root -m 0755 "$target"
    cp -a "$source"/. "$target"/
}

stage_payload() {
    validate_sources
    install -d -o root -g root -m 0755 /var/lib/bc250-control
    [[ -d /var/lib/bc250-control && ! -L /var/lib/bc250-control ]] \
        || die "Privileged storage is unsafe."
    STAGE=$(mktemp -d /var/lib/bc250-control/.desktop-stage.XXXXXX)
    install -d -o root -g root -m 0755 "$STAGE/py_modules" "$STAGE/templates"
    install -o root -g root -m 0755 \
        "$SOURCE_DIR/service/bc250-control-service" "$STAGE/bc250-control-service"
    install -o root -g root -m 0755 \
        "$SOURCE_DIR/bc250-desktop-control-repair" "$STAGE/bc250-desktop-control-repair"
    # Isolated mode omits the entrypoint directory, so all imports live here.
    copy_tree "$SOURCE_DIR/service/bc250_control_service" \
        "$STAGE/py_modules/bc250_control_service"
    copy_tree "$REPO_DIR/backend/bc250_control" "$STAGE/py_modules/bc250_control"
    copy_tree "$REPO_DIR/backend/vendor/tomli" "$STAGE/py_modules/tomli"
    copy_tree "$SOURCE_DIR/vendor/dbus_next" "$STAGE/py_modules/dbus_next"
    if [[ -d "$REPO_DIR/backend/vendor/tomli-2.0.1.dist-info" ]]; then
        copy_tree "$REPO_DIR/backend/vendor/tomli-2.0.1.dist-info" \
            "$STAGE/py_modules/tomli-2.0.1.dist-info"
    fi
    if [[ -d "$SOURCE_DIR/vendor/dbus_next-0.2.3.dist-info" ]]; then
        copy_tree "$SOURCE_DIR/vendor/dbus_next-0.2.3.dist-info" \
            "$STAGE/py_modules/dbus_next-0.2.3.dist-info"
    fi
    copy_tree "$SOURCE_DIR/templates" "$STAGE/templates"
    install -o root -g root -m 0644 \
        "$SOURCE_DIR/service/io.github.keyboardspecialist.bc250-control.policy" \
        "$STAGE/templates/io.github.keyboardspecialist.bc250-control.policy"
    find "$STAGE" -type d -name __pycache__ -prune -exec rm -rf {} +
    find "$STAGE" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
    chown -R root:root "$STAGE"
    chmod -R go-w "$STAGE"
    [[ -x "$STAGE/bc250-control-service" \
        && -f "$STAGE/py_modules/bc250_control_service/main.py" \
        && -f "$STAGE/py_modules/bc250_control/backend.py" \
        && -f "$STAGE/py_modules/tomli/__init__.py" \
        && -f "$STAGE/py_modules/dbus_next/__init__.py" ]] \
        || die "The staged desktop payload is incomplete."
    /usr/bin/python3 -I -c \
        'import runpy; runpy.run_path("'"$STAGE"'/bc250-control-service", run_name="bc250_install_check")'
    sync -f "$STAGE"
}

replace_payload() {
    systemctl stop bc250-control.service >/dev/null 2>&1 || true
    if [[ -L "$PAYLOAD_DIR" || ( -e "$PAYLOAD_DIR" && ! -d "$PAYLOAD_DIR" ) ]]; then
        die "Refusing to replace unsafe payload path: $PAYLOAD_DIR"
    fi
    if [[ -d "$PAYLOAD_DIR" ]]; then
        local metadata owner mode
        metadata=$(stat -Lc '%u %a' "$PAYLOAD_DIR")
        read -r owner mode <<< "$metadata"
        [[ "$owner" == 0 && $((8#$mode & 8#022)) -eq 0 ]] \
            || die "Refusing to replace an insecure payload directory."
        OLD_PAYLOAD="/var/lib/bc250-control/.desktop-previous.$$"
        [[ ! -e "$OLD_PAYLOAD" ]] || die "Temporary replacement path already exists."
        mv "$PAYLOAD_DIR" "$OLD_PAYLOAD"
    fi
    mv "$STAGE" "$PAYLOAD_DIR"
    STAGE=""
    PAYLOAD_SWAPPED=1
}

root_install() {
    require_root
    trap root_cleanup EXIT
    stage_payload
    replace_payload
    "$PAYLOAD_DIR/bc250-desktop-control-repair" repair
    systemctl restart bc250-desktop-control-repair.service
    systemctl restart bc250-control.service
    PAYLOAD_COMMITTED=1
    [[ -z "$OLD_PAYLOAD" || ! -e "$OLD_PAYLOAD" ]] || rm -rf "$OLD_PAYLOAD"
    log "Root service payload installed at $PAYLOAD_DIR"
}

restore_uninstall_readonly() {
    local rc=$?
    trap - EXIT
    if [[ $UNINSTALL_READONLY_CHANGED -eq 1 ]]; then
        if ! /usr/bin/steamos-readonly enable; then
            echo "[bc250-desktop] Failed to restore the readonly root filesystem." >&2
            rc=1
        fi
        UNINSTALL_READONLY_CHANGED=0
    fi
    exit "$rc"
}

root_uninstall() {
    require_root
    trap restore_uninstall_readonly EXIT
    systemctl disable --now bc250-control.service \
        bc250-desktop-control-repair.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet bc250-control.service \
        || systemctl is-active --quiet bc250-desktop-control-repair.service; then
        die "Could not stop the desktop services; refusing to remove their files."
    fi
    rm -f "$SERVICE_UNIT" "$REPAIR_UNIT" \
        /etc/systemd/system/multi-user.target.wants/bc250-control.service \
        /etc/systemd/system/multi-user.target.wants/bc250-desktop-control-repair.service \
        "$DBUS_POLICY"
    rm -f /etc/systemd/system/bc250-control.service.d/10-bc250-storage.conf \
        /etc/systemd/system/bc250-desktop-control-repair.service.d/10-bc250-storage.conf
    rmdir /etc/systemd/system/bc250-control.service.d \
        /etc/systemd/system/bc250-desktop-control-repair.service.d 2>/dev/null || true
    if [[ -e "$POLKIT_POLICY" ]]; then
        [[ -f "$POLKIT_POLICY" && ! -L "$POLKIT_POLICY" ]] \
            || die "Refusing to remove unsafe polkit path: $POLKIT_POLICY"
        local state
        state=$(/usr/bin/steamos-readonly status 2>&1) \
            || die "Could not determine the SteamOS readonly state."
        case "${state,,}" in
            *enabled*)
                UNINSTALL_READONLY_CHANGED=1
                /usr/bin/steamos-readonly disable
                ;;
            *disabled*) ;;
            *) die "Unrecognized SteamOS readonly state: $state" ;;
        esac
        rm -f "$POLKIT_POLICY"
        if [[ $UNINSTALL_READONLY_CHANGED -eq 1 ]]; then
            /usr/bin/steamos-readonly enable
            UNINSTALL_READONLY_CHANGED=0
        fi
    fi
    [[ ! -L "$PAYLOAD_DIR" ]] || die "Refusing to remove symlink payload: $PAYLOAD_DIR"
    rm -rf "$PAYLOAD_DIR"
    systemctl daemon-reload
    systemctl reload dbus.service >/dev/null 2>&1 || true
    bash "$REPO_DIR/bc250-update-persistence.sh" remove desktop
    log "Desktop service removed; shared BC-250 toolkit assets were preserved."
}

plasmoid_installed() {
    kpackagetool6 --type Plasma/Applet --show "$PLASMOID_ID" >/dev/null 2>&1
}

install_all() {
    require_normal_user
    validate_sources
    command -v kpackagetool6 >/dev/null 2>&1 || die "kpackagetool6 is required."
    local new_root_install=0
    [[ -d "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]] || new_root_install=1
    log "Installing persistent storage and privileged desktop service (sudo)"
    sudo bash "$REPO_DIR/bc250-storage.sh" install
    sudo bash "$SOURCE_DIR/install.sh" _install-root
    if ! sudo bash "$REPO_DIR/bc250-update-persistence.sh" install desktop; then
        ((new_root_install == 0)) || sudo bash "$SOURCE_DIR/install.sh" _uninstall-root || true
        die "Could not protect the desktop service across SteamOS updates."
    fi
    if plasmoid_installed; then
        if ! kpackagetool6 --type Plasma/Applet --upgrade "$PLASMOID_DIR"; then
            ((new_root_install == 0)) || sudo bash "$SOURCE_DIR/install.sh" _uninstall-root || true
            die "Could not upgrade the Plasma applet."
        fi
    else
        if ! kpackagetool6 --type Plasma/Applet --install "$PLASMOID_DIR"; then
            ((new_root_install == 0)) || sudo bash "$SOURCE_DIR/install.sh" _uninstall-root || true
            die "Could not install the Plasma applet."
        fi
    fi
    log "Desktop control installed for ${USER:-$(id -un)}."
    log "Log out and back in if an existing tray instance still shows the previous version."
}

uninstall_all() {
    require_normal_user
    sudo bash "$SOURCE_DIR/install.sh" _uninstall-root
    if command -v kpackagetool6 >/dev/null 2>&1 && plasmoid_installed; then
        kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID"
    fi
    log "Desktop control uninstalled."
}

show_status() {
    require_normal_user
    local failed=0 state
    if [[ -d "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]]; then state=installed; else state=missing; failed=1; fi
    log "root payload: $state ($PAYLOAD_DIR)"
    if systemctl is-enabled bc250-control.service >/dev/null 2>&1; then state=enabled; else state=disabled; failed=1; fi
    log "system service: $state"
    if systemctl is-active bc250-control.service >/dev/null 2>&1; then state=active; else state=inactive; failed=1; fi
    log "service runtime: $state"
    if [[ -f "$DBUS_POLICY" && -f "$POLKIT_POLICY" ]]; then state=installed; else state=incomplete; failed=1; fi
    log "D-Bus/polkit integration: $state"
    if [[ -f "$KEEP_FILE" ]]; then state=protected; else state=unprotected; failed=1; fi
    log "SteamOS update persistence: $state"
    if command -v kpackagetool6 >/dev/null 2>&1 && plasmoid_installed; then state=installed; else state=missing; failed=1; fi
    log "user plasmoid: $state ($PLASMOID_ID)"
    return "$failed"
}

usage() {
    cat << EOF
Usage: $0 {install|uninstall|status|help}

Run as the logged-in Deck user, not with sudo. Installation requests sudo for
the root service and then installs or upgrades the Plasma applet for this user.
EOF
}

case "${1:-}" in
    install) (($# == 1)) || die "Usage: $0 install"; install_all ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; uninstall_all ;;
    status) (($# == 1)) || die "Usage: $0 status"; show_status ;;
    help|-h|--help) usage ;;
    _install-root) (($# == 1)) || die "Invalid internal invocation."; root_install ;;
    _uninstall-root) (($# == 1)) || die "Invalid internal invocation."; root_uninstall ;;
    *) usage >&2; exit 1 ;;
esac
