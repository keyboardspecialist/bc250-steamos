#!/usr/bin/env bash
# Install the BC250 Trainer Flatpak and its privileged host service.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SOURCE_DIR/.." && pwd)"
SHARED_INSTALLER="$REPO_DIR/desktop-control/shared-service-install.sh"
APP_ID=io.github.keyboardspecialist.bc250trainer
CLIENT=trainer-flatpak
BUNDLE="${BC250_TRAINER_FLATPAK_BUNDLE:-$SOURCE_DIR/$APP_ID.flatpak}"

log() { echo "[bc250-trainer-flatpak] $*"; }
die() { echo "[bc250-trainer-flatpak] $*" >&2; exit 1; }
require_normal_user() { [[ $EUID -ne 0 ]] || die "Run as the logged-in desktop user, not with sudo."; }

[[ "$HOME" == /* && "$HOME" != *[[:space:]]* ]] \
    || die "HOME must be an absolute path without whitespace."
[[ -f "$SHARED_INSTALLER" && ! -L "$SHARED_INSTALLER" ]] \
    || die "Shared service installer is missing or unsafe: $SHARED_INSTALLER"
# shellcheck source=../desktop-control/shared-service-install.sh
source "$SHARED_INSTALLER"

legacy_client() {
    if [[ -d "$HOME/.local/share/plasma/plasmoids/io.github.keyboardspecialist.bc250control" ]] \
        || { command -v kpackagetool6 >/dev/null 2>&1 \
            && kpackagetool6 --type Plasma/Applet --show \
                io.github.keyboardspecialist.bc250control >/dev/null 2>&1; }; then
        printf 'plasma %s\n' "$(id -u)"
    else
        printf 'legacy 0\n'
    fi
}

install_all() {
    require_normal_user
    command -v flatpak >/dev/null 2>&1 || die "flatpak is required."
    [[ -f "$BUNDLE" && ! -L "$BUNDLE" ]] \
        || die "Flatpak bundle is missing or unsafe: $BUNDLE"
    shared_validate_sources

    local uid migration_client migration_uid had_service=0
    uid=$(id -u)
    shared_client_registered "$CLIENT" "$uid" && had_service=1
    read -r migration_client migration_uid < <(legacy_client)

    log "Installing persistent storage and shared privileged service (sudo)"
    sudo bash "$REPO_DIR/bc250-storage.sh" install
    sudo bash "$SOURCE_DIR/install-flatpak.sh" _install-root \
        "$CLIENT" "$uid" "$migration_client" "$migration_uid"
    if ! sudo bash "$REPO_DIR/bc250-update-persistence.sh" install desktop; then
        [[ $had_service -eq 1 ]] \
            || sudo bash "$SOURCE_DIR/install-flatpak.sh" _uninstall-root "$CLIENT" "$uid" || true
        die "Could not protect the shared service across SteamOS updates."
    fi
    if ! flatpak install --user --noninteractive --or-update "$BUNDLE"; then
        [[ $had_service -eq 1 ]] \
            || sudo bash "$SOURCE_DIR/install-flatpak.sh" _uninstall-root "$CLIENT" "$uid" || true
        die "Could not install the BC250 Trainer Flatpak."
    fi
    log "BC250 Trainer installed as $APP_ID"
}

uninstall_all() {
    require_normal_user
    local uid
    uid=$(id -u)
    if flatpak info --user "$APP_ID" >/dev/null 2>&1; then
        flatpak uninstall --user --noninteractive "$APP_ID"
    fi
    sudo bash "$SOURCE_DIR/install-flatpak.sh" _uninstall-root "$CLIENT" "$uid"
    log "BC250 Trainer Flatpak and its service registration were removed."
}

show_status() {
    require_normal_user
    local failed=0 state uid
    uid=$(id -u)
    if flatpak info --user "$APP_ID" >/dev/null 2>&1; then state=installed; else state=missing; failed=1; fi
    log "Flatpak: $state ($APP_ID)"
    if shared_client_registered "$CLIENT" "$uid"; then state=registered; else state=missing; failed=1; fi
    log "shared service client: $state (UID $uid)"
    if systemctl is-active bc250-control.service >/dev/null 2>&1; then state=active; else state=inactive; failed=1; fi
    log "service runtime: $state"
    return "$failed"
}

usage() {
    cat << EOF
Usage: $0 {install|status|uninstall|help}

Run as the logged-in desktop user. This installs the bundled Flatpak for the
current user and requests sudo only for the privileged BC-250 host service.
EOF
}

case "${1:-}" in
    install) (($# == 1)) || die "Usage: $0 install"; install_all ;;
    status) (($# == 1)) || die "Usage: $0 status"; show_status ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; uninstall_all ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; usage ;;
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
