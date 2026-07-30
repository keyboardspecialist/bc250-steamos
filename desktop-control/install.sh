#!/usr/bin/env bash
# Install the Plasma desktop control and register it with the shared service.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SOURCE_DIR/.." && pwd)"
PLASMOID_ID=io.github.keyboardspecialist.bc250control
PLASMOID_DIR="$SOURCE_DIR/plasmoid"
SHARED_INSTALLER="$SOURCE_DIR/shared-service-install.sh"

log() { echo "[bc250-desktop] $*"; }
die() { echo "[bc250-desktop] $*" >&2; exit 1; }
require_normal_user() { [[ $EUID -ne 0 ]] || die "Run as the logged-in Deck user, not with sudo."; }

[[ -f "$SHARED_INSTALLER" && ! -L "$SHARED_INSTALLER" ]] \
    || die "Shared service installer is missing or unsafe: $SHARED_INSTALLER"
# shellcheck source=shared-service-install.sh
source "$SHARED_INSTALLER"

validate_sources() {
    local path
    shared_validate_sources
    for path in "$PLASMOID_DIR/metadata.json" \
        "$PLASMOID_DIR/contents/icons/bc250-control.svg" \
        "$PLASMOID_DIR/contents/ui/main.qml"; do
        [[ -e "$path" && ! -L "$path" ]] \
            || die "Required Plasma source is missing or unsafe: $path"
    done
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

plasmoid_installed() {
    kpackagetool6 --type Plasma/Applet --show "$PLASMOID_ID" >/dev/null 2>&1
}

install_all() {
    require_normal_user
    validate_sources
    command -v kpackagetool6 >/dev/null 2>&1 || die "kpackagetool6 is required."
    local uid had_plasmoid=0
    uid=$(id -u)
    plasmoid_installed && had_plasmoid=1
    log "Installing persistent storage and shared privileged service (sudo)"
    sudo bash "$REPO_DIR/bc250-storage.sh" install
    sudo bash "$SOURCE_DIR/install.sh" _install-root plasma "$uid" plasma "$uid"
    if ! sudo bash "$REPO_DIR/bc250-update-persistence.sh" install desktop; then
        [[ $had_plasmoid -eq 1 ]] \
            || sudo bash "$SOURCE_DIR/install.sh" _uninstall-root plasma "$uid" || true
        die "Could not protect the shared service across SteamOS updates."
    fi
    if [[ $had_plasmoid -eq 1 ]]; then
        kpackagetool6 --type Plasma/Applet --upgrade "$PLASMOID_DIR" \
            || die "Could not upgrade the Plasma applet; its service registration was retained."
    else
        if ! kpackagetool6 --type Plasma/Applet --install "$PLASMOID_DIR"; then
            sudo bash "$SOURCE_DIR/install.sh" _uninstall-root plasma "$uid" || true
            die "Could not install the Plasma applet."
        fi
    fi
    log "Desktop control installed for ${USER:-$(id -un)}."
    log "Log out and back in if an existing tray instance still shows the previous version."
}

uninstall_all() {
    require_normal_user
    local uid
    uid=$(id -u)
    if command -v kpackagetool6 >/dev/null 2>&1 && plasmoid_installed; then
        kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID"
    fi
    sudo bash "$SOURCE_DIR/install.sh" _uninstall-root plasma "$uid"
    log "Plasma control uninstalled; the service remains if another frontend uses it."
}

show_status() {
    require_normal_user
    local failed=0 state uid
    uid=$(id -u)
    if [[ -d "$SHARED_PAYLOAD_DIR" && ! -L "$SHARED_PAYLOAD_DIR" ]]; then state=installed; else state=missing; failed=1; fi
    log "shared root payload: $state ($SHARED_PAYLOAD_DIR)"
    if systemctl is-enabled bc250-control.service >/dev/null 2>&1; then state=enabled; else state=disabled; failed=1; fi
    log "system service: $state"
    if systemctl is-active bc250-control.service >/dev/null 2>&1; then state=active; else state=inactive; failed=1; fi
    log "service runtime: $state"
    if [[ -f "$SHARED_DBUS_POLICY" && -f "$SHARED_POLKIT_POLICY" ]]; then state=installed; else state=incomplete; failed=1; fi
    log "D-Bus/polkit integration: $state"
    if [[ -f "$SHARED_KEEP_FILE" ]]; then state=protected; else state=unprotected; failed=1; fi
    log "SteamOS update persistence: $state"
    if shared_client_registered plasma "$uid"; then state=registered; else state=missing; failed=1; fi
    log "Plasma service client: $state (UID $uid)"
    if command -v kpackagetool6 >/dev/null 2>&1 && plasmoid_installed; then state=installed; else state=missing; failed=1; fi
    log "user plasmoid: $state ($PLASMOID_ID)"
    return "$failed"
}

usage() {
    cat << EOF
Usage: $0 {install|uninstall|status|help}

Run as the logged-in Deck user, not with sudo. Installation requests sudo for
the shared root service and then installs or upgrades the Plasma applet.
EOF
}

case "${1:-}" in
    install) (($# == 1)) || die "Usage: $0 install"; install_all ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; uninstall_all ;;
    status) (($# == 1)) || die "Usage: $0 status"; show_status ;;
    help|-h|--help) usage ;;
    _install-root)
        (($# == 5)) || die "Invalid internal invocation."
        shared_service_install "$2" "$3" "$4" "$5"
        ;;
    _uninstall-root)
        (($# == 3)) || die "Invalid internal invocation."
        shared_service_release "$2" "$3"
        ;;
    *) usage >&2; exit 1 ;;
esac
