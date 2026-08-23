#!/usr/bin/env bash
# Enable real-time HDMI AC-3 5.1 encoding through ALSA and WirePlumber.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
PERSISTENCE_SH="${PERSISTENCE_SH:-$HERE/../bc250-update-persistence.sh}"
UDEV_RULE="${UDEV_RULE:-/etc/udev/rules.d/91-bc250-hdmi-ac3.rules}"
WP_CONF="${WP_CONF:-$HOME/.config/wireplumber/wireplumber.conf.d/90-bc250-hdmi-ac3.conf}"
ACP_PROFILE_FILE="${ACP_PROFILE_FILE:-/usr/share/alsa-card-profile/mixer/profile-sets/hdmi-ac3.conf}"
A52_PLUGIN="${A52_PLUGIN:-/usr/lib/alsa-lib/libasound_module_pcm_a52.so}"
KEEP_FILE="${KEEP_FILE:-/etc/atomic-update.conf.d/bc250-ac3.conf}"
RO_WAS_ENABLED=0
INSTALL_TRANSACTION=0
HAD_UDEV_RULE=0
HAD_WP_CONF=0
HAD_KEEP_FILE=0
USER_INSTALL_TRANSACTION=0
USER_HAD_WP_CONF=0
USER_REVERT_TRANSACTION=0
USER_REVERT_HAD_WP_CONF=0
SYSTEM_TRANSACTION=""
SYSTEM_HAD_UDEV_RULE=0
SYSTEM_HAD_KEEP_FILE=0
USER_PREVIOUS_PROFILE=""
USER_PREVIOUS_SINK=""

log() { echo "[bc250-hdmi-ac3] $*"; }
die() { echo "[bc250-hdmi-ac3] $*" >&2; exit 1; }

udev_rule_content() {
    cat << 'EOF'
# BC-250 HDMI AC-3 profile selection managed by hdmi-ac3/hdmi-ac3.sh.
# Match the BC-250 Radeon HDMI audio function; card indices can change between boots.
SUBSYSTEM=="sound", KERNEL=="card*", ATTRS{vendor}=="0x1002", ATTRS{device}=="0x1640", ENV{ACP_PROFILE_SET}="hdmi-ac3.conf"
EOF
}

wireplumber_content() {
    cat << 'EOF'
# BC-250 HDMI AC-3 encoding managed by hdmi-ac3/hdmi-ac3.sh.
monitor.alsa.rules = [
  {
    matches = [
      {
        device.name = "~alsa_card.pci-.*"
        device.nick = "~HD-Audio Generic"
        device.vendor.id = "0x1002"
        device.product.id = "0x1640"
      }
    ]
    actions = {
      update-props = {
        device.description = "HDMI / DisplayPort"
        api.acp.disable-pro-audio = true
        device.profile-set = "hdmi-ac3.conf"
        device.routes.default-sink-volume = 1.0
      }
    }
  }
  {
    matches = [ { node.name = "~alsa_output.pci-.*hdmi.*" } ]
    actions = {
      update-props = { session.suspend-timeout-seconds = 3600 }
    }
  }
  {
    matches = [
      {
        node.name = "~alsa_output.pci-.*hdmi.*"
        alsa.name = "~a52.*"
      }
    ]
    actions = {
      update-props = { api.alsa.start-delay = 1536 }
    }
  }
]
EOF
}

managed_file_matches() {
    local target="$1" writer="$2"
    [[ -f "$target" && ! -L "$target" ]] || return 1
    cmp -s "$target" <("$writer")
}

preflight_managed_file() {
    local target="$1" writer="$2"
    [[ ! -e "$target" && ! -L "$target" ]] && return 0
    managed_file_matches "$target" "$writer" \
        || die "Refusing to replace or remove unrecognized file: $target"
}

write_managed_file() {
    local target="$1" writer="$2" tmp
    preflight_managed_file "$target" "$writer"
    mkdir -p "${target%/*}"
    tmp=$(mktemp "${target%/*}/.bc250-hdmi-ac3.XXXXXX")
    "$writer" > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$target"
}

unlock_rootfs() {
    if command -v steamos-readonly >/dev/null 2>&1 \
        && steamos-readonly status 2>/dev/null | grep -qi enabled; then
        steamos-readonly disable
        RO_WAS_ENABLED=1
    fi
}

restore_rootfs() {
    if [[ $RO_WAS_ENABLED -eq 1 ]]; then
        if ! steamos-readonly enable; then
            echo "[bc250-hdmi-ac3] Failed to restore SteamOS read-only mode." >&2
            return 1
        fi
        RO_WAS_ENABLED=0
    fi
}

finish_rootfs() {
    restore_rootfs || die "SteamOS root filesystem remains writable; run 'sudo steamos-readonly enable'."
    trap - EXIT
}

system_transaction_cleanup() {
    [[ -n "$SYSTEM_TRANSACTION" ]] || return 0
    local failed=0
    set +e
    if [[ "$SYSTEM_TRANSACTION" == install ]]; then
        if [[ $SYSTEM_HAD_KEEP_FILE -eq 0 ]]; then
            bash "$PERSISTENCE_SH" remove ac3 || failed=1
        fi
        if [[ $SYSTEM_HAD_UDEV_RULE -eq 0 ]]; then
            rm -f -- "$UDEV_RULE" || failed=1
        fi
    elif [[ "$SYSTEM_TRANSACTION" == remove ]]; then
        if [[ $SYSTEM_HAD_UDEV_RULE -eq 1 ]]; then
            write_managed_file "$UDEV_RULE" udev_rule_content || failed=1
        fi
        if [[ $SYSTEM_HAD_KEEP_FILE -eq 1 ]]; then
            bash "$PERSISTENCE_SH" install ac3 || failed=1
        fi
    fi
    udevadm control --reload-rules || failed=1
    udevadm trigger --subsystem-match=sound || failed=1
    restore_rootfs || failed=1
    if [[ $failed -eq 0 ]]; then
        log "Failed system phase rolled back to its previous state."
    else
        echo "[bc250-hdmi-ac3] System rollback was incomplete; run status and repair from the toolkit." >&2
        return 1
    fi
}

require_root() { [[ $EUID -eq 0 ]] || die "Internal system action requires sudo."; }

install_system_config() {
    require_root
    local had_rule=0
    [[ -f "$PERSISTENCE_SH" && ! -L "$PERSISTENCE_SH" ]] \
        || die "Update persistence helper is missing or unsafe: $PERSISTENCE_SH"
    preflight_managed_file "$UDEV_RULE" udev_rule_content
    [[ -e "$UDEV_RULE" || -L "$UDEV_RULE" ]] && had_rule=1
    SYSTEM_HAD_UDEV_RULE=$had_rule
    [[ -e "$KEEP_FILE" || -L "$KEEP_FILE" ]] && SYSTEM_HAD_KEEP_FILE=1
    SYSTEM_TRANSACTION=install
    trap system_transaction_cleanup EXIT
    unlock_rootfs
    write_managed_file "$UDEV_RULE" udev_rule_content
    if ! bash "$PERSISTENCE_SH" install ac3; then
        die "Could not register the AC-3 udev rule for SteamOS updates."
    fi
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=sound || true
    finish_rootfs
    SYSTEM_TRANSACTION=""
}

rollback_system_config() {
    require_root
    local had_rule="${1:-}" had_keep="${2:-}"
    [[ "$had_rule" =~ ^[01]$ && "$had_keep" =~ ^[01]$ ]] || exit 2
    [[ -f "$PERSISTENCE_SH" && ! -L "$PERSISTENCE_SH" ]] || exit 1
    preflight_managed_file "$UDEV_RULE" udev_rule_content
    trap restore_rootfs EXIT
    unlock_rootfs
    if [[ $had_keep -eq 0 ]]; then
        bash "$PERSISTENCE_SH" remove ac3
    fi
    if [[ $had_rule -eq 0 ]]; then
        rm -f -- "$UDEV_RULE"
    fi
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=sound || true
    finish_rootfs
}

remove_system_config() {
    require_root
    [[ -f "$PERSISTENCE_SH" && ! -L "$PERSISTENCE_SH" ]] \
        || die "Update persistence helper is missing or unsafe: $PERSISTENCE_SH"
    preflight_managed_file "$UDEV_RULE" udev_rule_content
    [[ -e "$UDEV_RULE" || -L "$UDEV_RULE" ]] && SYSTEM_HAD_UDEV_RULE=1
    [[ -e "$KEEP_FILE" || -L "$KEEP_FILE" ]] && SYSTEM_HAD_KEEP_FILE=1
    SYSTEM_TRANSACTION=remove
    trap system_transaction_cleanup EXIT
    unlock_rootfs
    bash "$PERSISTENCE_SH" remove ac3
    rm -f -- "$UDEV_RULE"
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=sound || true
    finish_rootfs
    SYSTEM_TRANSACTION=""
}

require_normal_user() {
    [[ $EUID -ne 0 ]] \
        || die "Run as the logged-in Deck user, not with sudo. The script requests administrator access when needed."
}

require_user_runtime() {
    local executable linker_cache
    for executable in pactl systemctl; do
        command -v "$executable" >/dev/null 2>&1 || die "Required command is missing: $executable"
    done
    [[ -f "$ACP_PROFILE_FILE" ]] \
        || die "SteamOS AC-3 profile is missing: $ACP_PROFILE_FILE"
    [[ -f "$A52_PLUGIN" ]] \
        || die "ALSA a52 encoder is missing. Install the SteamOS alsa-plugins package."
    linker_cache=$(ldconfig -p 2>/dev/null || true)
    grep -q libavcodec <<< "$linker_cache" \
        || die "FFmpeg libavcodec is missing. Install the SteamOS ffmpeg package."
}

require_sudo() {
    command -v sudo >/dev/null 2>&1 || die "Required command is missing: sudo"
}

find_hdmi_card() {
    local cards card
    cards=$(pactl list cards 2>/dev/null) || return 1
    card=$(awk '
        /^Card #[0-9]+/ { name = "" }
        /^[[:space:]]+Name:/ { name = $2 }
        /alsa.mixer_name = "ATI R6xx HDMI"/ && name != "" { print name; exit }
    ' <<< "$cards")
    [[ -n "$card" ]] || return 1
    printf '%s\n' "$card"
}

wait_for_hdmi_card() {
    local card _
    for _ in {1..15}; do
        card=$(find_hdmi_card || true)
        if [[ -n "$card" ]]; then
            printf '%s\n' "$card"
            return 0
        fi
        sleep 1
    done
    return 1
}

active_profile_for_card() {
    local card="$1"
    pactl list cards 2>/dev/null | awk -v target="$card" '
        /^Card #[0-9]+/ { selected = 0 }
        /^[[:space:]]+Name:/ { selected = ($2 == target) }
        selected && /^[[:space:]]+Active Profile:/ {
            sub(/^[^:]+:[[:space:]]*/, "")
            print
            exit
        }
    '
}

restart_wireplumber() {
    systemctl --user restart wireplumber
    local _
    for _ in {1..15}; do
        systemctl --user is-active --quiet wireplumber && return 0
        sleep 1
    done
    die "WirePlumber did not become active after restart."
}

select_default_sink() {
    local profile="$1" match="$2" card card_path sink
    card=$(wait_for_hdmi_card) || die "No AMD HDMI/DisplayPort audio card was found after WirePlumber restarted."
    pactl set-card-profile "$card" "$profile"
    sleep 1
    card_path=${card#alsa_card.}
    sink=$(pactl list sinks short \
        | awk -v card_path="$card_path" -v pattern="$match" \
            'index($2, card_path) && $2 ~ pattern { print $2; exit }')
    [[ -n "$sink" ]] || die "Profile $profile did not create an audio sink."
    pactl set-default-sink "$sink"
    log "Default sink: $sink"
}

restore_stereo_sink() {
    local strict="${1:-0}" card card_path sink
    card=$(find_hdmi_card || true)
    if [[ -z "$card" ]]; then
        log "No active AMD HDMI card was found; stereo will be selected when WirePlumber discovers it."
        return 0
    fi
    if ! pactl set-card-profile "$card" output:hdmi-stereo; then
        log "Could not select HDMI stereo now; the AC-3 override has still been removed."
        [[ "$strict" == 0 ]] || return 1
        return 0
    fi
    sleep 1
    card_path=${card#alsa_card.}
    sink=$(pactl list sinks short \
        | awk -v card_path="$card_path" \
            'index($2, card_path) && $2 ~ /hdmi-stereo/ { print $2; exit }')
    if [[ -n "$sink" ]]; then
        pactl set-default-sink "$sink"
        log "Default sink: $sink"
    fi
}

rollback_install() {
    [[ $INSTALL_TRANSACTION -eq 1 ]] || return 0
    set +e
    if [[ $HAD_WP_CONF -eq 0 ]] && managed_file_matches "$WP_CONF" wireplumber_content; then
        rm -f -- "$WP_CONF"
    fi
    sudo bash "$SELF" rollback-system "$HAD_UDEV_RULE" "$HAD_KEEP_FILE"
    systemctl --user restart wireplumber
    log "Installation failed; previous HDMI audio configuration was restored."
}

rollback_user_install() {
    [[ $USER_INSTALL_TRANSACTION -eq 1 ]] || return 0
    local failed=0 card=""
    set +e
    if [[ $USER_HAD_WP_CONF -eq 0 ]] && managed_file_matches "$WP_CONF" wireplumber_content; then
        rm -f -- "$WP_CONF" || failed=1
    fi
    systemctl --user restart wireplumber || failed=1
    card=$(find_hdmi_card || true)
    if [[ -n "$card" && -n "$USER_PREVIOUS_PROFILE" \
        && "$USER_PREVIOUS_PROFILE" != unknown ]]; then
        pactl set-card-profile "$card" "$USER_PREVIOUS_PROFILE" || failed=1
    fi
    if [[ -n "$USER_PREVIOUS_SINK" ]]; then
        pactl set-default-sink "$USER_PREVIOUS_SINK" || failed=1
    fi
    if [[ $failed -eq 0 ]]; then
        log "User audio activation failed; previous profile and sink were restored."
    else
        echo "[bc250-hdmi-ac3] User audio rollback was incomplete; restart WirePlumber and select the previous output." >&2
        return 1
    fi
}

rollback_user_revert() {
    [[ $USER_REVERT_TRANSACTION -eq 1 ]] || return 0
    local failed=0
    set +e
    if [[ $USER_REVERT_HAD_WP_CONF -eq 1 ]]; then
        write_managed_file "$WP_CONF" wireplumber_content || failed=1
        systemctl --user restart wireplumber || failed=1
        select_default_sink output:hdmi-ac3-surround hdmi-ac3-surround || failed=1
    fi
    if [[ $failed -eq 0 ]]; then
        log "User stereo activation failed; previous WirePlumber configuration was restored."
    else
        echo "[bc250-hdmi-ac3] User stereo rollback was incomplete; run status and repair from the toolkit." >&2
        return 1
    fi
}

install_user_config() {
    require_normal_user
    local card
    require_user_runtime
    find_hdmi_card >/dev/null \
        || die "No AMD HDMI/DisplayPort audio card was found."
    preflight_managed_file "$WP_CONF" wireplumber_content
    managed_file_matches "$WP_CONF" wireplumber_content && USER_HAD_WP_CONF=1
    card=$(find_hdmi_card)
    USER_PREVIOUS_PROFILE=$(active_profile_for_card "$card" || true)
    USER_PREVIOUS_SINK=$(pactl get-default-sink 2>/dev/null || true)
    USER_INSTALL_TRANSACTION=1
    trap rollback_user_install EXIT
    write_managed_file "$WP_CONF" wireplumber_content
    restart_wireplumber
    select_default_sink output:hdmi-ac3-surround hdmi-ac3-surround
    USER_INSTALL_TRANSACTION=0
    trap - EXIT
    log "User audio state: active"
}

revert_user_config() {
    require_normal_user
    local executable
    for executable in pactl systemctl; do
        command -v "$executable" >/dev/null 2>&1 || die "Required command is missing: $executable"
    done
    preflight_managed_file "$WP_CONF" wireplumber_content
    managed_file_matches "$WP_CONF" wireplumber_content && USER_REVERT_HAD_WP_CONF=1
    USER_REVERT_TRANSACTION=1
    trap rollback_user_revert EXIT
    rm -f -- "$WP_CONF"
    rmdir "${WP_CONF%/*}" 2>/dev/null || true
    restart_wireplumber
    restore_stereo_sink 1
    USER_REVERT_TRANSACTION=0
    trap - EXIT
    log "User audio state: stereo"
}

install_ac3() {
    require_normal_user
    require_user_runtime
    require_sudo
    find_hdmi_card >/dev/null \
        || die "No AMD HDMI/DisplayPort audio card was found."
    preflight_managed_file "$WP_CONF" wireplumber_content
    managed_file_matches "$UDEV_RULE" udev_rule_content && HAD_UDEV_RULE=1
    managed_file_matches "$WP_CONF" wireplumber_content && HAD_WP_CONF=1
    [[ -e "$KEEP_FILE" || -L "$KEEP_FILE" ]] && HAD_KEEP_FILE=1
    INSTALL_TRANSACTION=1
    trap rollback_install EXIT
    sudo bash "$SELF" install-system
    write_managed_file "$WP_CONF" wireplumber_content
    restart_wireplumber
    select_default_sink output:hdmi-ac3-surround hdmi-ac3-surround
    INSTALL_TRANSACTION=0
    trap - EXIT
    log "state: active"
    log "Dolby Digital 5.1 encoding is active."
}

revert_ac3() {
    require_normal_user
    local executable
    for executable in sudo pactl systemctl; do
        command -v "$executable" >/dev/null 2>&1 || die "Required command is missing: $executable"
    done
    preflight_managed_file "$WP_CONF" wireplumber_content
    sudo bash "$SELF" remove-system
    rm -f -- "$WP_CONF"
    rmdir "${WP_CONF%/*}" 2>/dev/null || true
    restart_wireplumber
    restore_stereo_sink
    log "state: not-installed"
    log "Default HDMI stereo is active."
}

show_status() {
    require_normal_user
    local udev_state=missing wp_state=missing keep_state=missing active_profile=unknown card=""
    if managed_file_matches "$UDEV_RULE" udev_rule_content; then
        udev_state=installed
    elif [[ -e "$UDEV_RULE" || -L "$UDEV_RULE" ]]; then
        udev_state=foreign
    fi
    if managed_file_matches "$WP_CONF" wireplumber_content; then
        wp_state=installed
    elif [[ -e "$WP_CONF" || -L "$WP_CONF" ]]; then
        wp_state=foreign
    fi
    if [[ -f "$KEEP_FILE" && ! -L "$KEEP_FILE" ]]; then
        if grep -Fxq '# Toolkit state preserved by SteamOS atomic updates.' "$KEEP_FILE" \
            && grep -Fxq '# Generated by bc250-update-persistence.sh.' "$KEEP_FILE" \
            && grep -Fxq "$UDEV_RULE" "$KEEP_FILE"; then
            keep_state=installed
        else
            keep_state=foreign
        fi
    elif [[ -e "$KEEP_FILE" || -L "$KEEP_FILE" ]]; then
        keep_state=foreign
    fi
    if command -v pactl >/dev/null 2>&1; then
        card=$(find_hdmi_card || true)
        if [[ -n "$card" ]]; then
            active_profile=$(active_profile_for_card "$card")
            active_profile=${active_profile:-unknown}
        fi
    fi
    log "udev rule: $udev_state"
    log "WirePlumber config: $wp_state"
    log "update persistence: $keep_state"
    log "active profile: $active_profile"
    if [[ "$udev_state" == installed && "$wp_state" == installed \
        && "$keep_state" == installed ]]; then
        if [[ "$active_profile" == output:hdmi-ac3-surround* ]]; then
            log "state: active"
        else
            log "state: configured"
        fi
        return 0
    fi
    if [[ "$udev_state" == missing && "$wp_state" == missing \
        && "$keep_state" == missing \
        && "$active_profile" != output:hdmi-ac3-surround* ]]; then
        log "state: not-installed"
        return 1
    fi
    log "state: incomplete"
    return 1
}

show_help() {
    cat << EOF
Usage: $0 {install|revert|uninstall|status|help}

  install      Enable real-time Dolby Digital 5.1 encoding over HDMI/DP.
  revert       Remove toolkit AC-3 configuration and restore HDMI stereo.
  uninstall    Alias for revert, used by component maintenance.
  status       Show managed configuration and the active HDMI profile.

Run as the logged-in Deck user, not with sudo.
EOF
}

case "${1:-help}" in
    install) (($# == 1)) || die "Usage: $0 install"; install_ac3 ;;
    revert|uninstall) (($# == 1)) || die "Usage: $0 revert"; revert_ac3 ;;
    status) (($# == 1)) || die "Usage: $0 status"; show_status ;;
    install-system) (($# == 1)) || exit 2; install_system_config ;;
    remove-system) (($# == 1)) || exit 2; remove_system_config ;;
    rollback-system) (($# == 3)) || exit 2; rollback_system_config "$2" "$3" ;;
    install-user) (($# == 1)) || exit 2; install_user_config ;;
    revert-user) (($# == 1)) || exit 2; revert_user_config ;;
    help|-h|--help) (($# == 1)) || die "Usage: $0 help"; show_help ;;
    *) show_help >&2; exit 1 ;;
esac
