#!/usr/bin/env bash
# Install the pinned CoolerControl daemon AppImage and local Web UI launcher.
set -euo pipefail

VERSION=5.0.0
APPIMAGE_NAME=CoolerControlD-x86_64.AppImage
APPIMAGE_SHA256=15c17f7a3990c21f2cc8cbbda5cde8ea6c8ecb63a79f982aa9fbedc308d3440b
APPIMAGE_URL=${COOLERCONTROL_DOWNLOAD_URL:-https://gitlab.com/coolercontrol/coolercontrol/-/releases/$VERSION/downloads/packages/$APPIMAGE_NAME}
SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SOURCE_DIR/.." && pwd)
SELF=$SOURCE_DIR/$(basename "${BASH_SOURCE[0]}")
SERVICE_SOURCE=$SOURCE_DIR/bc250-coolercontrold.service
STORAGE_SH=$REPO_DIR/bc250-storage.sh
PERSISTENCE_SH=$REPO_DIR/bc250-update-persistence.sh
ROOT_DIR=/var/lib/bc250-control/coolercontrol
RUNTIME_DIR=$ROOT_DIR/runtime
APPIMAGE=$RUNTIME_DIR/$APPIMAGE_NAME
MARKER=$RUNTIME_DIR/.bc250-managed
SERVICE_NAME=bc250-coolercontrold.service
SERVICE_UNIT=/etc/systemd/system/$SERVICE_NAME
SERVICE_WANTS=/etc/systemd/system/multi-user.target.wants/$SERVICE_NAME
SERVICE_DROPIN=/etc/systemd/system/$SERVICE_NAME.d/10-bc250-storage.conf
KEEP_FILE=/etc/atomic-update.conf.d/bc250-coolercontrol.conf
DESKTOP_FILE=$HOME/.local/share/applications/org.coolercontrol.CoolerControl.bc250.desktop
MANAGED_MARKER='# BC-250 toolkit managed CoolerControl daemon.'
DOWNLOAD_PATH=

log() { echo "[coolercontrol] $*"; }
die() { log "$*" >&2; exit 1; }
require_normal_user() { [[ $EUID -ne 0 ]] || die "Run as the logged-in Deck user, not with sudo."; }
require_root() { [[ $EUID -eq 0 ]] || die "Internal operation requires root."; }

protected_root_file() {
    local path=$1 metadata owner mode
    [[ -f "$path" && ! -L "$path" ]] || return 1
    metadata=$(stat -Lc '%u %a' "$path") || return 1
    read -r owner mode <<< "$metadata"
    [[ "$owner" == 0 && $((8#$mode & 8#022)) -eq 0 ]]
}

protected_root_directory() {
    local path=$1 metadata owner mode
    [[ -d "$path" && ! -L "$path" ]] || return 1
    metadata=$(stat -Lc '%u %a' "$path") || return 1
    read -r owner mode <<< "$metadata"
    [[ "$owner" == 0 && $((8#$mode & 8#022)) -eq 0 ]]
}

payload_owned() {
    protected_root_file "$APPIMAGE" && protected_root_file "$MARKER" \
        && grep -Fqx "$MANAGED_MARKER" "$MARKER" \
        && grep -Fqx "version=$VERSION" "$MARKER" \
        && grep -Fqx "sha256=$APPIMAGE_SHA256" "$MARKER"
}

payload_integrity_valid() {
    local actual
    payload_owned || return 1
    actual=$(sha256sum "$APPIMAGE" | cut -d' ' -f1)
    [[ "$actual" == "$APPIMAGE_SHA256" ]]
}

service_owned() {
    protected_root_file "$SERVICE_UNIT" \
        && grep -Fqx '# BC-250 toolkit managed CoolerControl service.' "$SERVICE_UNIT"
}

desktop_owned() {
    [[ -f "$DESKTOP_FILE" && ! -L "$DESKTOP_FILE" ]] \
        && grep -Fqx '# BC-250 toolkit managed CoolerControl launcher.' "$DESKTOP_FILE"
}

runtime_artifact_present() {
    [[ -e "$APPIMAGE" || -L "$APPIMAGE" || -e "$MARKER" || -L "$MARKER" \
        || -e "$SERVICE_UNIT" || -L "$SERVICE_UNIT" \
        || -e "$SERVICE_WANTS" || -L "$SERVICE_WANTS" \
        || -e "$SERVICE_DROPIN" || -L "$SERVICE_DROPIN" \
        || -e "$KEEP_FILE" || -L "$KEEP_FILE" \
        || -e "$DESKTOP_FILE" || -L "$DESKTOP_FILE" ]]
}

nct6687_hwmon_present() {
    local name module
    for name in /sys/class/hwmon/hwmon*/name; do
        [[ -r "$name" ]] || continue
        case "$(<"$name")" in nct6683|nct6686|nct6687) ;; *) continue ;; esac
        module=$(readlink -f "${name%/*}/device/driver/module" 2>/dev/null || true)
        [[ "$module" == /sys/module/nct6687 ]] && return 0
    done
    return 1
}

restore_automatic_fan_control() {
    local name module control
    for name in /sys/class/hwmon/hwmon*/name; do
        [[ -r "$name" ]] || continue
        case "$(<"$name")" in nct6683|nct6686|nct6687) ;; *) continue ;; esac
        module=$(readlink -f "${name%/*}/device/driver/module" 2>/dev/null || true)
        [[ "$module" == /sys/module/nct6687 ]] || continue
        for control in "${name%/*}"/pwm*_enable; do
            [[ -w "$control" ]] || continue
            printf '2\n' > "$control" \
                || die "Could not restore firmware fan control through $control."
            [[ "$(<"$control")" == 2 ]] \
                || die "Firmware automatic mode was not confirmed through $control."
        done
    done
}

show_status() {
    require_normal_user
    local failed=0 state
    if ! runtime_artifact_present; then
        log "state: not-installed"
        [[ ! -d "$ROOT_DIR/config" && ! -d "$ROOT_DIR/data" ]] \
            || log "saved configuration: preserved ($ROOT_DIR)"
        return 1
    fi
    if payload_integrity_valid; then state="installed ($VERSION)"; else state=incomplete; failed=1; fi
    log "daemon payload: $state"
    if service_owned && systemctl is-enabled --quiet "$SERVICE_NAME"; then state=enabled; else state=incomplete; failed=1; fi
    log "system service: $state"
    if systemctl is-active --quiet "$SERVICE_NAME"; then state=active; else state=inactive; failed=1; fi
    log "daemon runtime: $state"
    if [[ -f "$KEEP_FILE" && ! -L "$KEEP_FILE" ]]; then state=protected; else state=missing; failed=1; fi
    log "SteamOS update persistence: $state"
    if desktop_owned; then state=installed; else state=missing; failed=1; fi
    log "Web UI launcher: $state"
    if nct6687_hwmon_present; then state=available; else state=missing; failed=1; fi
    log "BC-250 fan controller: $state"
    [[ $failed -eq 0 ]] && log "state: installed" || log "state: incomplete"
    return "$failed"
}

download_appimage() {
    local cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/bc250-coolercontrol destination tmp actual version
    [[ "$cache_dir" == /* && ! -L "$cache_dir" ]] || die "Unsafe download cache path: $cache_dir"
    mkdir -p "$cache_dir"
    destination=$cache_dir/$APPIMAGE_NAME-$VERSION
    if [[ -f "$destination" && ! -L "$destination" ]]; then
        actual=$(sha256sum "$destination" | cut -d' ' -f1)
        if [[ "$actual" == "$APPIMAGE_SHA256" ]]; then
            chmod 0755 "$destination"
            log "Using verified cached CoolerControl $VERSION"
            DOWNLOAD_PATH=$destination
            return
        fi
        rm -f "$destination"
    fi
    [[ ! -e "$destination" && ! -L "$destination" ]] \
        || die "Refusing unsafe cache destination: $destination"
    command -v curl >/dev/null 2>&1 || die "curl is required."
    tmp=$(mktemp "$cache_dir/.coolercontrol.XXXXXX")
    if ! curl --retry 2 --connect-timeout 10 -fL "$APPIMAGE_URL" -o "$tmp"; then
        rm -f "$tmp"
        die "Could not download CoolerControl $VERSION."
    fi
    actual=$(sha256sum "$tmp" | cut -d' ' -f1)
    [[ "$actual" == "$APPIMAGE_SHA256" ]] \
        || { rm -f "$tmp"; die "Downloaded CoolerControl AppImage failed SHA-256 verification."; }
    chmod 0755 "$tmp"
    version=$("$tmp" --version 2>/dev/null || true)
    [[ "$version" == "coolercontrold $VERSION" ]] \
        || { rm -f "$tmp"; die "Downloaded AppImage reported an unexpected version."; }
    mv "$tmp" "$destination"
    log "Downloaded and verified CoolerControl $VERSION"
    DOWNLOAD_PATH=$destination
}

install_desktop_launcher() {
    local dir tmp
    dir=$(dirname "$DESKTOP_FILE")
    [[ ! -L "$dir" ]] || die "Refusing symlinked applications directory: $dir"
    if [[ -e "$DESKTOP_FILE" || -L "$DESKTOP_FILE" ]]; then
        desktop_owned || die "Refusing to replace unrecognized desktop launcher: $DESKTOP_FILE"
    fi
    mkdir -p "$dir"
    tmp=$(mktemp "$dir/.coolercontrol.XXXXXX")
    cat > "$tmp" << 'EOF'
# BC-250 toolkit managed CoolerControl launcher.
[Desktop Entry]
Type=Application
Name=CoolerControl
Comment=Monitor and control the BC-250 fan controller
Exec=/usr/bin/xdg-open http://localhost:11987
TryExec=/usr/bin/xdg-open
Icon=utilities-system-monitor
Categories=System;Monitor;
Terminal=false
EOF
    chmod 0644 "$tmp"
    mv "$tmp" "$DESKTOP_FILE"
}

atomic_install_root() {
    local source=$1 target=$2 mode=$3 dir tmp
    dir=$(dirname "$target")
    install -d -o root -g root -m 0755 "$dir"
    tmp=$(mktemp "$dir/.coolercontrol.XXXXXX")
    install -o root -g root -m "$mode" "$source" "$tmp"
    mv -f "$tmp" "$target"
}

install_root() {
    require_root
    local source=$1 actual marker_tmp app_tmp version
    [[ -f "$source" && ! -L "$source" ]] || die "Downloaded AppImage is missing or unsafe."
    actual=$(sha256sum "$source" | cut -d' ' -f1)
    [[ "$actual" == "$APPIMAGE_SHA256" ]] || die "AppImage changed before root installation."
    for path in "$SERVICE_SOURCE" "$STORAGE_SH" "$PERSISTENCE_SH"; do
        [[ -f "$path" && ! -L "$path" ]] || die "Installer payload is missing or unsafe: $path"
    done
    for path in "$ROOT_DIR" "$RUNTIME_DIR" "$ROOT_DIR/config" "$ROOT_DIR/data"; do
        if [[ -e "$path" || -L "$path" ]]; then
            protected_root_directory "$path" || die "Refusing unsafe persistent directory: $path"
        fi
    done
    if [[ -e "$SERVICE_UNIT" || -L "$SERVICE_UNIT" ]]; then
        service_owned || die "Refusing to replace unrecognized service: $SERVICE_UNIT"
    fi
    if [[ -e "$APPIMAGE" || -L "$APPIMAGE" || -e "$MARKER" || -L "$MARKER" ]]; then
        payload_integrity_valid \
            || die "Refusing to replace an unrecognized or damaged daemon payload."
    fi
    if systemctl is-active --quiet coolercontrold.service 2>/dev/null; then
        die "The distribution coolercontrold.service is active; uninstall it before using the BC-250 managed service."
    fi

    bash "$STORAGE_SH" install
    install -d -o root -g root -m 0755 "$ROOT_DIR" "$RUNTIME_DIR"
    install -d -o root -g root -m 0700 "$ROOT_DIR/config" "$ROOT_DIR/data"
    app_tmp=$(mktemp "$RUNTIME_DIR/.coolercontrol.XXXXXX")
    install -o root -g root -m 0755 "$source" "$app_tmp"
    actual=$(sha256sum "$app_tmp" | cut -d' ' -f1)
    version=$("$app_tmp" --version 2>/dev/null || true)
    if [[ "$actual" != "$APPIMAGE_SHA256" || "$version" != "coolercontrold $VERSION" ]]; then
        rm -f "$app_tmp"
        die "Root-staged AppImage failed integrity or version verification."
    fi
    mv -f "$app_tmp" "$APPIMAGE"
    marker_tmp=$(mktemp)
    printf '%s\nversion=%s\nsha256=%s\n' "$MANAGED_MARKER" "$VERSION" "$APPIMAGE_SHA256" > "$marker_tmp"
    atomic_install_root "$marker_tmp" "$MARKER" 0644
    rm -f "$marker_tmp"
    atomic_install_root "$SERVICE_SOURCE" "$SERVICE_UNIT" 0644
    bash "$STORAGE_SH" install
    bash "$PERSISTENCE_SH" install coolercontrol
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
    systemctl restart "$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME" \
        || die "CoolerControl service did not become active."
}

safe_dropin() {
    [[ -f "$SERVICE_DROPIN" && ! -L "$SERVICE_DROPIN" ]] \
        && grep -Fqx 'Requires=bc250-persistence-recovery.service' "$SERVICE_DROPIN" \
        && grep -Fqx 'RequiresMountsFor=/var/lib/bc250-control' "$SERVICE_DROPIN"
}

uninstall_root() {
    require_root
    if [[ -e "$SERVICE_UNIT" || -L "$SERVICE_UNIT" ]]; then
        service_owned || die "Refusing to remove unrecognized service: $SERVICE_UNIT"
    fi
    if [[ -e "$APPIMAGE" || -L "$APPIMAGE" || -e "$MARKER" || -L "$MARKER" ]]; then
        payload_integrity_valid \
            || die "Refusing to remove an unrecognized or damaged daemon payload."
    fi
    if [[ -e "$SERVICE_WANTS" && ! -L "$SERVICE_WANTS" ]]; then
        die "Refusing non-symlink service enablement path: $SERVICE_WANTS"
    fi
    if [[ -L "$SERVICE_WANTS" ]]; then
        [[ "$(readlink "$SERVICE_WANTS")" == "../$SERVICE_NAME" ]] \
            || die "Refusing unrecognized service enablement link: $SERVICE_WANTS"
    fi
    if [[ -e "$SERVICE_DROPIN" || -L "$SERVICE_DROPIN" ]]; then
        safe_dropin || die "Refusing to remove unrecognized service drop-in: $SERVICE_DROPIN"
    fi
    if [[ -f "$SERVICE_UNIT" ]] || systemctl is-active --quiet "$SERVICE_NAME" \
        || systemctl is-enabled --quiet "$SERVICE_NAME"; then
        systemctl disable --now "$SERVICE_NAME" \
            || die "Could not stop and disable the CoolerControl service."
    fi
    if systemctl is-active --quiet "$SERVICE_NAME" \
        || systemctl is-enabled --quiet "$SERVICE_NAME"; then
        die "CoolerControl remained active or enabled; refusing removal."
    fi
    restore_automatic_fan_control
    rm -f "$SERVICE_WANTS" "$SERVICE_UNIT" "$SERVICE_DROPIN" "$APPIMAGE" "$MARKER"
    rmdir "$(dirname "$SERVICE_DROPIN")" "$RUNTIME_DIR" 2>/dev/null || true
    systemctl daemon-reload
    bash "$PERSISTENCE_SH" remove coolercontrol
    log "CoolerControl removed; saved profiles remain in $ROOT_DIR."
}

install_all() {
    require_normal_user
    local desktop_dir
    [[ "$HOME" == /* ]] || die "HOME must be an absolute path."
    desktop_dir=$(dirname "$DESKTOP_FILE")
    if [[ -e "$DESKTOP_FILE" || -L "$DESKTOP_FILE" ]]; then
        desktop_owned || die "Refusing to replace unrecognized desktop launcher: $DESKTOP_FILE"
    fi
    [[ ! -e "$desktop_dir" || ( -d "$desktop_dir" && ! -L "$desktop_dir" ) ]] \
        || die "Refusing unsafe applications directory: $desktop_dir"
    nct6687_hwmon_present \
        || die "Install and load the toolkit NCT6687 fan-control driver first."
    download_appimage
    sudo bash "$SELF" _install-root "$DOWNLOAD_PATH"
    install_desktop_launcher
    log "CoolerControl $VERSION installed. Open it from the application menu or http://localhost:11987"
}

uninstall_all() {
    require_normal_user
    if [[ -e "$DESKTOP_FILE" || -L "$DESKTOP_FILE" ]]; then
        desktop_owned || die "Refusing to remove unrecognized desktop launcher: $DESKTOP_FILE"
    fi
    sudo bash "$SELF" _uninstall-root
    rm -f "$DESKTOP_FILE"
}

usage() {
    cat << EOF
Usage: $0 {install|status|uninstall|help}

Installs the pinned, verified official CoolerControl daemon AppImage and a
desktop launcher for its local Web UI. Run as the logged-in Deck user; install
and uninstall request sudo for the system service.
EOF
}

case "${1:-}" in
    install) (($# == 1)) || die "Usage: $0 install"; install_all ;;
    status) (($# == 1)) || die "Usage: $0 status"; show_status ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; uninstall_all ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; usage ;;
    _install-root) (($# == 2)) || die "Invalid internal invocation."; install_root "$2" ;;
    _uninstall-root) (($# == 1)) || die "Invalid internal invocation."; uninstall_root ;;
    *) usage >&2; exit 1 ;;
esac
