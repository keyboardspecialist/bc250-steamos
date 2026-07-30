#!/usr/bin/env bash
# Install the standalone BC-250 Cracktro and register its shared service use.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SOURCE_DIR/.." && pwd)"
SHARED_INSTALLER="$REPO_DIR/desktop-control/shared-service-install.sh"
APP_ID=io.github.keyboardspecialist.bc250cracktro
APP_DIR="$HOME/.local/libexec/bc250-cracktro"
APP_BIN="$APP_DIR/bc250-cracktro"
OWNER_FILE="$APP_DIR/.bc250-cracktro-owner"
DESKTOP_FILE="$HOME/.local/share/applications/$APP_ID.desktop"
ICON_FILE="$HOME/.local/share/icons/hicolor/scalable/apps/$APP_ID.svg"
DESKTOP_TEMPLATE="$SOURCE_DIR/packaging/$APP_ID.desktop.in"
ICON_SOURCE="$SOURCE_DIR/packaging/$APP_ID.svg"
OWNER_VALUE="schema=1;owner=$APP_ID"

log() { echo "[bc250-cracktro] $*"; }
die() { echo "[bc250-cracktro] $*" >&2; exit 1; }
require_normal_user() { [[ $EUID -ne 0 ]] || die "Run as the logged-in desktop user, not with sudo."; }

[[ "$HOME" == /* && "$HOME" != *[[:space:]]* ]] \
    || die "HOME must be an absolute path without whitespace."

[[ -f "$SHARED_INSTALLER" && ! -L "$SHARED_INSTALLER" ]] \
    || die "Shared service installer is missing or unsafe: $SHARED_INSTALLER"
# shellcheck source=../desktop-control/shared-service-install.sh
source "$SHARED_INSTALLER"

find_binary() {
    local candidate
    if [[ -n "${BC250_CRACKTRO_BINARY:-}" ]]; then
        candidate=$BC250_CRACKTRO_BINARY
        [[ "$candidate" == /* ]] || die "BC250_CRACKTRO_BINARY must be an absolute path."
        [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] \
            || die "BC250_CRACKTRO_BINARY is missing, unsafe, or not executable: $candidate"
        printf '%s\n' "$candidate"
        return
    fi
    for candidate in \
        "$SOURCE_DIR/bc250-cracktro" \
        "$SOURCE_DIR/build/bc250-cracktro" \
        "$SOURCE_DIR/build-ubuntu2404/bc250-cracktro" \
        "$REPO_DIR/.build/cracktro/bc250-cracktro"; do
        if [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    die "No built bc250-cracktro executable was found. Build it first or set BC250_CRACKTRO_BINARY."
}

desktop_owned() {
    [[ -f "$DESKTOP_FILE" && ! -L "$DESKTOP_FILE" ]] || return 1
    grep -Fxq "X-BC250-Installer-Owner=$APP_ID" "$DESKTOP_FILE" \
        && grep -Fxq "Exec=$APP_BIN" "$DESKTOP_FILE"
}

user_install_owned() {
    local path uid
    uid=$(id -u)
    [[ -d "$APP_DIR" && ! -L "$APP_DIR" \
        && -f "$OWNER_FILE" && ! -L "$OWNER_FILE" \
        && -f "$APP_BIN" && ! -L "$APP_BIN" \
        && -f "$ICON_FILE" && ! -L "$ICON_FILE" ]] || return 1
    for path in "$APP_DIR" "$OWNER_FILE" "$APP_BIN" "$DESKTOP_FILE" "$ICON_FILE"; do
        [[ "$(stat -Lc '%u' "$path")" == "$uid" ]] || return 1
    done
    [[ "$(cat "$OWNER_FILE")" == "$OWNER_VALUE" ]] && desktop_owned
}

validate_user_targets() {
    if user_install_owned; then
        return 0
    fi
    if [[ -e "$APP_DIR" || -L "$APP_DIR" \
        || -e "$DESKTOP_FILE" || -L "$DESKTOP_FILE" \
        || -e "$ICON_FILE" || -L "$ICON_FILE" ]]; then
        die "Refusing to replace files not recognized as a $APP_ID installation."
    fi
}

render_desktop() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "${line//@EXEC@/$APP_BIN}"
    done < "$DESKTOP_TEMPLATE"
}

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

install_user_files() {
    local binary="$1" stage old_app="" desktop_tmp icon_tmp
    install -d -m 0755 "${APP_DIR%/*}" "${DESKTOP_FILE%/*}" "${ICON_FILE%/*}"
    [[ ! -L "${APP_DIR%/*}" && ! -L "${DESKTOP_FILE%/*}" \
        && ! -L "${ICON_FILE%/*}" ]] || die "Refusing symlinked user installation directories."
    stage=$(mktemp -d "${APP_DIR%/*}/.bc250-cracktro.XXXXXX")
    desktop_tmp=$(mktemp "${DESKTOP_FILE%/*}/.bc250-cracktro.XXXXXX")
    icon_tmp=$(mktemp "${ICON_FILE%/*}/.bc250-cracktro.XXXXXX")
    trap 'rm -rf "$stage"; rm -f "$desktop_tmp" "$icon_tmp"' RETURN
    install -m 0755 "$binary" "$stage/bc250-cracktro"
    printf '%s\n' "$OWNER_VALUE" > "$stage/.bc250-cracktro-owner"
    chmod 0644 "$stage/.bc250-cracktro-owner"
    chmod 0755 "$stage"
    render_desktop > "$desktop_tmp"
    chmod 0644 "$desktop_tmp"
    install -m 0644 "$ICON_SOURCE" "$icon_tmp"
    if [[ -d "$APP_DIR" ]]; then
        old_app="${APP_DIR}.previous.$$"
        [[ ! -e "$old_app" ]] || die "Temporary application backup already exists: $old_app"
        mv "$APP_DIR" "$old_app"
    fi
    if ! mv "$stage" "$APP_DIR"; then
        [[ -z "$old_app" ]] || mv "$old_app" "$APP_DIR"
        return 1
    fi
    if ! mv -f "$desktop_tmp" "$DESKTOP_FILE" || ! mv -f "$icon_tmp" "$ICON_FILE"; then
        rm -rf "$APP_DIR"
        [[ -z "$old_app" ]] || mv "$old_app" "$APP_DIR"
        return 1
    fi
    [[ -z "$old_app" ]] || rm -rf "$old_app"
    trap - RETURN
}

install_all() {
    require_normal_user
    shared_validate_sources
    local binary uid migration_client migration_uid had_user=0
    binary=$(find_binary)
    uid=$(id -u)
    [[ -f "$DESKTOP_TEMPLATE" && ! -L "$DESKTOP_TEMPLATE" \
        && -f "$ICON_SOURCE" && ! -L "$ICON_SOURCE" ]] \
        || die "Cracktro packaging resources are missing or unsafe."
    user_install_owned && had_user=1
    validate_user_targets
    read -r migration_client migration_uid < <(legacy_client)
    log "Installing persistent storage and shared privileged service (sudo)"
    sudo bash "$REPO_DIR/bc250-storage.sh" install
    sudo bash "$SOURCE_DIR/install.sh" _install-root \
        cracktro "$uid" "$migration_client" "$migration_uid"
    if ! sudo bash "$REPO_DIR/bc250-update-persistence.sh" install desktop; then
        [[ $had_user -eq 1 ]] \
            || sudo bash "$SOURCE_DIR/install.sh" _uninstall-root cracktro "$uid" || true
        die "Could not protect the shared service across SteamOS updates."
    fi
    if ! install_user_files "$binary"; then
        [[ $had_user -eq 1 ]] \
            || sudo bash "$SOURCE_DIR/install.sh" _uninstall-root cracktro "$uid" || true
        die "Could not install the Cracktro user files."
    fi
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "${DESKTOP_FILE%/*}" >/dev/null 2>&1 || true
    log "Cracktro installed at $APP_BIN"
}

uninstall_all() {
    require_normal_user
    local uid
    uid=$(id -u)
    if [[ -e "$APP_DIR" || -L "$APP_DIR" \
        || -e "$DESKTOP_FILE" || -L "$DESKTOP_FILE" \
        || -e "$ICON_FILE" || -L "$ICON_FILE" ]]; then
        user_install_owned \
            || die "Refusing to remove files not recognized as a $APP_ID installation."
        rm -rf "$APP_DIR"
        rm -f "$DESKTOP_FILE" "$ICON_FILE"
    fi
    sudo bash "$SOURCE_DIR/install.sh" _uninstall-root cracktro "$uid"
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "${DESKTOP_FILE%/*}" >/dev/null 2>&1 || true
    log "Cracktro uninstalled; shared tuning state and other frontend registrations were preserved."
}

show_status() {
    require_normal_user
    local failed=0 state uid
    uid=$(id -u)
    if user_install_owned; then state=installed; else state=missing-or-unrecognized; failed=1; fi
    log "user application: $state ($APP_BIN)"
    if desktop_owned; then state="absolute Exec recognized"; else state="missing-or-unrecognized"; failed=1; fi
    log "desktop launcher: $state ($DESKTOP_FILE)"
    if shared_client_registered cracktro "$uid"; then state=registered; else state=missing; failed=1; fi
    log "shared service client: $state (UID $uid)"
    if [[ -d "$SHARED_PAYLOAD_DIR" && ! -L "$SHARED_PAYLOAD_DIR" ]]; then state=installed; else state=missing; failed=1; fi
    log "shared root payload: $state ($SHARED_PAYLOAD_DIR)"
    if systemctl is-active bc250-control.service >/dev/null 2>&1; then state=active; else state=inactive; failed=1; fi
    log "service runtime: $state"
    return "$failed"
}

usage() {
    cat << EOF
Usage: $0 {install|status|uninstall|help}

Run as the logged-in desktop user. The installer requests sudo only for the
shared privileged service and installs the application under ~/.local.
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
