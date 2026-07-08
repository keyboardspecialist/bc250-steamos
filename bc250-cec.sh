#!/usr/bin/env bash
# bc250-cec.sh
#
# HDMI-CEC / TV control for the BC-250 on SteamOS, through a DP->HDMI
# adapter that tunnels CEC over the DisplayPort AUX channel.
#
# Discovery notes (July 2026, SteamOS 3.8 / kernel 6.16.12-valve24.2):
#   - The kernel side already works: CONFIG_DRM_DISPLAY_DP_AUX_CEC=y (the
#     modern name of CONFIG_DRM_DP_CEC), so amdgpu exposes /dev/cec0 on the
#     DP-1 AUX channel whenever a CEC-tunneling adapter is attached.
#   - Valve ships a full CEC daemon in the OS image: cecd (user service,
#     D-Bus name com.steampowered.CecDaemon1, config fragments merged from
#     ~/.config/cecd/config.d/*.toml). Out of the box it wakes the TV on
#     resume, suspends the console when the TV turns off, and relays the
#     TV remote as a uinput input device.
#   - Steam's own UI writes 99-steamos-manager.toml in that config dir and
#     rewrites it regularly -- never edit that file. Our overrides go in
#     99-zz-bc250.toml, which sorts after it and therefore wins.
#
# What this script adds on top of cecd:
#   - status/test/monitor tooling for the whole CEC stack
#   - OSD name ("BC-250" instead of "steamdeck" in the TV's device list)
#   - behavior toggles that outrank the Steam UI fragment
#   - TV standby on POWEROFF (cecd only covers suspend)
#   - wake TV + grab input at cold boot (cecd only covers resume)
#
# Root handling deviates from bc250-power.sh on purpose: everything here
# talks to cecd on the *user* D-Bus session, so the script must run as
# deck, NOT root. The one exception -- installing the poweroff standby
# system unit -- shells out to sudo for just that action.
#
# SteamOS persistence: user config + user unit live in $HOME, the system
# unit lives in /etc (writable overlay). Nothing touches /usr or /boot,
# so no steamos-readonly handling is needed and updates can't break it.
set -euo pipefail

CEC_DEV="/dev/cec0"
TV_LA=0                                      # CEC logical address of the TV

DBUS_NAME="com.steampowered.CecDaemon1"
DAEMON_PATH="/com/steampowered/CecDaemon1/Daemon"
DEV_PATH="/com/steampowered/CecDaemon1/Devices/Cec0"
IF_CONFIG="$DBUS_NAME.Config1"
IF_DEV="$DBUS_NAME.CecDevice1"
CECD_SVC="cecd.service"                      # Valve's daemon (user scope)

CONF_DIR="$HOME/.config/cecd/config.d"
NAME_CONF="$CONF_DIR/50-bc250.toml"          # our osd_name fragment
OVR_CONF="$CONF_DIR/99-zz-bc250.toml"        # toggle overrides (sorts last)

USER_UNIT_DIR="$HOME/.config/systemd/user"
WAKE_UNIT="$USER_UNIT_DIR/bc250-cec-boot-wake.service"
WAKE_SVC="bc250-cec-boot-wake.service"
STANDBY_UNIT="/etc/systemd/system/bc250-cec-poweroff-standby.service"
STANDBY_SVC="bc250-cec-poweroff-standby.service"

OSD_DEFAULT="BC-250"                         # CEC OSD name limit: 14 bytes

log()  { echo -e "\033[1;32m[cec]\033[0m $*"; }
warn() { echo -e "\033[1;33m[cec]\033[0m $*"; }
die()  { echo -e "\033[1;31m[cec]\033[0m $*" >&2; exit 1; }

require_user() {
    [[ $EUID -ne 0 ]] || die "Run as deck, not root -- cecd lives on deck's user D-Bus session.
      Only 'shutdown-standby install' needs sudo, and it asks by itself."
    [[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]] \
        || die "No user D-Bus session (\$XDG_RUNTIME_DIR/bus missing) -- run from a logged-in deck session."
}

# cecd is D-Bus activatable, so a Ping starts it if the unit isn't up yet.
require_daemon() {
    systemctl --user is-active -q "$CECD_SVC" 2>/dev/null && return 0
    busctl --user --timeout=5 call "$DBUS_NAME" "$DAEMON_PATH" \
        org.freedesktop.DBus.Peer Ping >/dev/null 2>&1 && return 0
    die "cecd is not running and could not be started -- try: systemctl --user start cecd"
}

cleanup() { tui_show_cursor; }
trap cleanup EXIT

# ========================= pure-bash TUI menu =============================
# Same skin as bc250-power.sh: zero dependencies, every menu action calls
# the same cmd_* function as the CLI, nothing is menu-only.
C0=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'; CI=$'\033[7m'
CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'; CC=$'\033[36m'

TUI_CURSOR_HIDDEN=0
tui_show_cursor() {
    if [[ $TUI_CURSOR_HIDDEN -eq 1 ]]; then printf '\033[?25h'; TUI_CURSOR_HIDDEN=0; fi
}

# menu_select "Title" "label|badge|hint" ...
# up/down or j/k to move, Enter selects (MENU_CHOICE=index), q/Esc backs out
# (returns 1). Redraws in place; hint line describes the highlighted item.
menu_select() {
    local title="$1"; shift
    local items=("$@") n=$# cur=0 drawn=0 key rest i label badge hint
    local lines=$((n + 4))
    printf '\033[?25l'; TUI_CURSOR_HIDDEN=1
    while true; do
        if [[ $drawn -eq 1 ]]; then printf '\033[%dA' "$lines"; fi
        printf '\r\033[K%s\n' "${CB}${CC}${title}${C0}"
        printf '\033[K%s\n' "${CD}  up/down move - Enter select - q back${C0}"
        for i in "${!items[@]}"; do
            IFS='|' read -r label badge hint <<< "${items[$i]}"
            if [[ $i -eq $cur ]]; then
                printf '\033[K%s\n' "  ${CI}${CB} > ${label} ${C0} ${badge}"
            else
                printf '\033[K%s\n' "     ${label}  ${badge}"
            fi
        done
        IFS='|' read -r label badge hint <<< "${items[$cur]}"
        printf '\033[K\n\033[K%s\n' "  ${CD}${hint}${C0}"
        drawn=1
        IFS= read -rsn1 key || { tui_show_cursor; return 1; }
        if [[ $key == $'\033' ]]; then
            rest=""
            IFS= read -rsn2 -t 0.05 rest || true
            key+="$rest"
        fi
        case "$key" in
            $'\033[A'|k) if (( cur > 0 ));   then cur=$((cur-1)); else cur=$((n-1)); fi ;;
            $'\033[B'|j) if (( cur < n-1 )); then cur=$((cur+1)); else cur=0; fi ;;
            "")          MENU_CHOICE=$cur; tui_show_cursor; return 0 ;;
            q|Q|$'\033') tui_show_cursor; return 1 ;;
        esac
    done
}

pause_key() {
    echo
    printf '%s' "${CD}-- press any key to return to the menu --${C0}"
    IFS= read -rsn1 || true
    printf '\r\033[K'
}

ask() {   # ask "Prompt" [default] -> REPLY
    local prompt="$1" def="${2:-}"
    REPLY=""
    if [[ -n "$def" ]]; then
        read -rp "  $prompt [$def]: " REPLY || true
        [[ -n "$REPLY" ]] || REPLY="$def"
    else
        read -rp "  $prompt: " REPLY || true
    fi
}

# run a cmd_* in a subshell with its own cleanup trap: a die() inside an
# action drops back to the menu instead of killing it
run_action() {
    local rc=0
    ( trap cleanup EXIT; "$@" ) || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo -e "${CR}${CB}[cec]${C0} action failed (exit $rc) -- see message above."
    fi
    pause_key
}

b_ok()   { printf '%s' "${CG}[$1]${C0}"; }
b_mid()  { printf '%s' "${CY}[$1]${C0}"; }
b_off()  { printf '%s' "${CD}[$1]${C0}"; }

c_state() {   # colorize systemctl is-enabled / is-active words
    case "$1" in
        enabled|active|running)          printf '%s' "${CG}$1${C0}" ;;
        failed|masked)                   printf '%s' "${CR}$1${C0}" ;;
        disabled|inactive|not-found|-)   printf '%s' "${CD}$1${C0}" ;;
        *)                               printf '%s' "${CY}$1${C0}" ;;
    esac
}

unit_state() {   # systemctl wrapper that never emits two lines / fails
    local out
    out=$(systemctl "$@" 2>/dev/null | head -1) || true
    echo "${out:--}"
}

# ========================= D-Bus / cecd plumbing ==========================

cecd_up() { systemctl --user is-active -q "$CECD_SVC" 2>/dev/null; }

dev_call() {   # dev_call METHOD [SIG ARGS...]
    local m="$1"; shift
    busctl --user --timeout=5 call "$DBUS_NAME" "$DEV_PATH" "$IF_DEV" "$m" "$@"
}

_prop() {   # _prop PATH IFACE NAME -> value with type letter and quotes stripped
    local out
    out=$(busctl --user --timeout=2 get-property "$DBUS_NAME" "$1" "$2" "$3" 2>/dev/null) \
        || { echo "?"; return 0; }
    out=${out#* }                       # strip the type letter
    out=${out%\"}; out=${out#\"}        # strip quotes on strings
    printf '%s\n' "$out"
}
cfg_prop() { _prop "$DAEMON_PATH" "$IF_CONFIG" "$1"; }
dev_prop() { _prop "$DEV_PATH" "$IF_DEV" "$1"; }

daemon_reload_config() {
    busctl --user --timeout=5 call "$DBUS_NAME" "$DAEMON_PATH" "$IF_CONFIG" Reload \
        || warn "Config1.Reload failed -- try: systemctl --user restart cecd"
}

pa_pretty() {   # decimal physical address -> a.b.c.d (13312 -> 3.4.0.0)
    local d="$1"
    [[ "$d" =~ ^[0-9]+$ ]] || { echo "?"; return 0; }
    printf '%x.%x.%x.%x' $(( (d>>12)&15 )) $(( (d>>8)&15 )) $(( (d>>4)&15 )) $(( d&15 ))
}

la_name() {
    case "$1" in
        0)  echo "TV" ;;
        4)  echo "Playback Device 1" ;;
        5)  echo "Audio System" ;;
        8)  echo "Playback Device 2" ;;
        11) echo "Playback Device 3" ;;
        1|2|9)    echo "Recording Device" ;;
        3|6|7|10) echo "Tuner" ;;
        *)  echo "LA $1" ;;
    esac
}

audio_la() {
    local v; v=$(dev_prop AudioLogicalAddress)
    if [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; else echo 5; fi
}

# Ask the TV for its power state: <Give Device Power Status> (0x8f = 143),
# expect <Report Power Status> (0x90 = 144). Reply includes the opcode, so
# the status byte is the LAST field (verified live: "ay 2 144 0").
tv_power_status() {
    local out
    out=$(busctl --user --timeout=3 call "$DBUS_NAME" "$DEV_PATH" "$IF_DEV" \
          SendReceiveRawMessage ayyyq 1 143 "$TV_LA" 144 1500 2>/dev/null) || { echo "no-reply"; return 0; }
    case "${out##* }" in
        0) echo "on" ;;
        1) echo "standby" ;;
        2) echo "standby->on" ;;
        3) echo "on->standby" ;;
        *) echo "unknown" ;;
    esac
}

# toml_set KEY VALUE FILE -- flat-key TOML edit, no /tmp round-trips
# (temp file lives next to the target, repo rule: fs.protected_regular)
toml_set() {
    local key="$1" val="$2" file="$3" tmp
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp "$(dirname "$file")/.bc250-cec.XXXXXX")
    if [[ -f "$file" ]]; then
        grep -v "^${key}[[:space:]]*=" "$file" > "$tmp" || true
    fi
    printf '%s = %s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$file"
}

ovr_has() { grep -q "^${1}[[:space:]]*=" "$OVR_CONF" 2>/dev/null; }

ovr_count() {
    grep -cE '^(wake_tv|suspend_tv|allow_standby|uinput)[[:space:]]*=' "$OVR_CONF" 2>/dev/null \
        || echo 0
}

prop_for() {   # toml key -> Config1 property name
    case "$1" in
        wake_tv)       echo WakeTv ;;
        suspend_tv)    echo SuspendTv ;;
        allow_standby) echo AllowStandby ;;
        uinput)        echo Uinput ;;
    esac
}

remote_dev_present() { grep -q 'Name="cecd' /proc/bus/input/devices 2>/dev/null; }

# ============================== badges ====================================

badge_osd() {
    cecd_up || { b_off "cecd not running"; return 0; }
    local name; name=$(cfg_prop OsdName)
    case "$name" in
        "?")        b_off "cecd not answering" ;;
        steamdeck)  b_off "steamdeck (default)" ;;
        *)          b_ok "$name" ;;
    esac
    return 0
}

badge_toggle() {   # badge_toggle <toml-key>
    cecd_up || { b_off "cecd not running"; return 0; }
    local val mark=""
    val=$(cfg_prop "$(prop_for "$1")")
    ovr_has "$1" && mark=" *override"
    case "$val" in
        true)  b_ok "on${mark}" ;;
        false) b_off "off${mark}" ;;
        *)     b_off "?" ;;
    esac
    return 0
}

badge_overrides() {
    local n; n=$(ovr_count)
    if [[ "$n" -gt 0 ]]; then b_mid "$n key(s) overridden"
    else b_off "Steam UI in control"; fi
    return 0
}

badge_standby() {
    if [[ "$(systemctl is-enabled "$STANDBY_SVC" 2>/dev/null)" == enabled ]]; then b_ok "installed"
    elif [[ -f "$STANDBY_UNIT" ]]; then b_mid "present - not enabled"
    else b_off "not installed"; fi
    return 0
}

badge_wake() {
    if [[ "$(systemctl --user is-enabled "$WAKE_SVC" 2>/dev/null)" == enabled ]]; then b_ok "installed"
    elif [[ -f "$WAKE_UNIT" ]]; then b_mid "present - not enabled"
    else b_off "not installed"; fi
    return 0
}

badge_remote() {
    cecd_up || { b_off "cecd not running"; return 0; }
    local val; val=$(cfg_prop Uinput)
    if [[ "$val" == true ]] && remote_dev_present; then b_ok "active"
    elif [[ "$val" == true ]]; then b_mid "enabled - no device"
    else b_off "off"; fi
    return 0
}

# ============================== status ====================================

cmd_status() {
    require_user
    echo -e "${CB}== CEC device ==${C0}"
    if [[ -e "$CEC_DEV" ]]; then
        echo "  $CEC_DEV: present ($(stat -c '%A %U:%G' "$CEC_DEV" 2>/dev/null || echo '?'))"
    else
        echo -e "  $CEC_DEV: ${CR}MISSING${C0} -- adapter unplugged, or it doesn't tunnel CEC over DP"
    fi

    echo -e "${CB}== cecd daemon (Valve, user service) ==${C0}"
    local act; act=$(systemctl --user is-active "$CECD_SVC" 2>/dev/null || true)
    echo "  cecd.service: $(c_state "${act:--}")  ${CD}(statically enabled via graphical-session.target)${C0}"
    if ! cecd_up; then
        warn "cecd is down -- the sections below will be empty. Try: systemctl --user start cecd"
    fi

    echo -e "${CB}== identity on the CEC bus ==${C0}"
    local osd la pa active ala
    osd=$(cfg_prop OsdName); pa=$(dev_prop PhysicalAddress); active=$(dev_prop Active)
    la=$(dev_prop LogicalAddresses)     # "count v1 v2..."
    ala=$(dev_prop AudioLogicalAddress)
    local la_disp="?"
    if [[ "$la" =~ ^[0-9]+[[:space:]] ]]; then
        la_disp=""
        local v
        for v in ${la#* }; do la_disp+="${la_disp:+, }$v ($(la_name "$v"))"; done
    fi
    echo "  OSD name:         $osd"
    echo "  logical address:  $la_disp"
    echo "  physical address: $(pa_pretty "$pa")"
    echo "  active source:    $active"
    if [[ "$ala" =~ ^[0-9]+$ && "$ala" -ne 255 ]]; then
        echo "  audio system:     LA $ala ($(la_name "$ala")) -- vol-up/vol-down/mute target"
    else
        echo "  audio system:     none on the bus (volume verbs will no-op)"
    fi

    echo -e "${CB}== behavior (effective cecd config) ==${C0}"
    local key
    for key in wake_tv suspend_tv allow_standby uinput; do
        local src="steam-ui"; ovr_has "$key" && src="override"
        printf '  %-15s %-6s (%s)\n' "$key" "$(cfg_prop "$(prop_for "$key")")" "$src"
    done

    echo -e "${CB}== TV ==${C0}"
    echo "  power status: $(tv_power_status)"

    echo -e "${CB}== installed extras ==${C0}"
    echo "  poweroff standby unit: $(c_state "$(unit_state is-enabled "$STANDBY_SVC")")"
    echo "  boot wake unit (user): $(c_state "$(unit_state --user is-enabled "$WAKE_SVC")")"
    [[ -f "$NAME_CONF" ]] && echo "  $NAME_CONF: present" || echo "  $NAME_CONF: not written"
    [[ -f "$OVR_CONF"  ]] && echo "  $OVR_CONF: present ($(ovr_count) key(s))" || echo "  $OVR_CONF: not written"

    echo -e "${CB}== TV remote ==${C0}"
    if remote_dev_present; then
        echo "  cecd uinput device present -- TV remote keys reach the system"
    else
        echo "  no cecd input device (uinput off, or no remote traffic yet)"
    fi
}

# ============================ OSD name ====================================

cmd_osd_name() {
    require_user; require_daemon
    local name="${1:-}"
    if [[ "$name" == "--reset" ]]; then
        rm -f "$NAME_CONF"
        daemon_reload_config >/dev/null
        log "OSD name fragment removed -- back to cecd's default after next restart."
        return 0
    fi
    if [[ -z "$name" ]]; then
        ask "TV OSD name (max 14 bytes)" "$OSD_DEFAULT"; name="$REPLY"
    fi
    local bytes; bytes=$(printf %s "$name" | wc -c)
    (( bytes >= 1 && bytes <= 14 )) || die "OSD name must be 1-14 bytes (got $bytes)."
    if [[ ! -f "$NAME_CONF" ]]; then
        mkdir -p "$CONF_DIR"
        printf '# Written by bc250-cec.sh -- OSD name shown in the TV device list.\n' > "$NAME_CONF"
    fi
    toml_set osd_name "\"$name\"" "$NAME_CONF"
    daemon_reload_config >/dev/null
    dev_call SetOsdName s "$name" >/dev/null 2>&1 \
        || warn "SetOsdName bus call failed (config still saved; takes effect on cecd restart)"
    local eff; eff=$(cfg_prop OsdName)
    if [[ "$eff" == "$name" ]]; then
        log "OSD name: $name (saved to $NAME_CONF, live on the bus)"
    else
        warn "Saved, but cecd still reports '$eff' -- config merge order may differ; check 'status'."
    fi
}

# ============================ toggles =====================================

cmd_toggle() {
    local arg="${1:-}" want="${2:-}" toml
    case "$arg" in
        wake-tv)       toml=wake_tv ;;
        suspend-tv)    toml=suspend_tv ;;
        allow-standby) toml=allow_standby ;;
        uinput)        toml=uinput ;;
        *) die "usage: $0 toggle {wake-tv|suspend-tv|allow-standby|uinput} [on|off]" ;;
    esac
    require_user; require_daemon
    local prop cur new
    prop=$(prop_for "$toml")
    cur=$(cfg_prop "$prop")
    case "$want" in
        on)  new=true ;;
        off) new=false ;;
        "")  if [[ "$cur" == true ]]; then new=false; else new=true; fi ;;
        *)   die "usage: $0 toggle $arg [on|off]" ;;
    esac
    if [[ ! -f "$OVR_CONF" ]]; then
        mkdir -p "$CONF_DIR"
        cat > "$OVR_CONF" << 'EOF'
# Written by bc250-cec.sh -- overrides Steam UI CEC toggles.
# Sorts after 99-steamos-manager.toml so these values win.
# Delete this file (or run 'bc250-cec.sh clear-overrides') to give
# control back to Steam's Settings UI.
EOF
        warn "First override: Steam UI toggles stop having effect for keys set here."
        warn "Undo any time with: $0 clear-overrides"
    fi
    toml_set "$toml" "$new" "$OVR_CONF"
    daemon_reload_config >/dev/null
    local eff; eff=$(cfg_prop "$prop")
    log "$arg: $cur -> $eff"
    if [[ "$eff" != "$new" ]]; then
        warn "Effective value did not follow the override -- cecd's config merge order"
        warn "may differ from expected. Reverting is safe: $0 clear-overrides"
        return 1
    fi
    # Reload updates the property, but uinput device plumbing may need a
    # real restart to appear/disappear.
    if [[ "$toml" == uinput ]]; then
        sleep 2
        local have=0; remote_dev_present && have=1
        if { [[ "$new" == true && $have -eq 0 ]] || [[ "$new" == false && $have -eq 1 ]]; } && [[ -t 0 ]]; then
            ask "uinput device state didn't change yet -- restart cecd now? [Y/n]" "Y"
            [[ "$REPLY" =~ ^[Yy] ]] && systemctl --user restart "$CECD_SVC" && log "cecd restarted."
        fi
    fi
}

cmd_clear_overrides() {
    require_user
    if [[ ! -f "$OVR_CONF" ]]; then
        log "No overrides file -- Steam UI already in control."
        return 0
    fi
    rm -f "$OVR_CONF"
    cecd_up && daemon_reload_config >/dev/null
    log "Overrides cleared. Effective toggles now:"
    local key
    for key in wake_tv suspend_tv allow_standby uinput; do
        printf '  %-15s %s\n' "$key" "$(cfg_prop "$(prop_for "$key")")"
    done
}

# ===================== TV standby on poweroff =============================
# cecd's suspend_tv covers suspend only. This system unit covers poweroff:
# it is inert at boot (ExecStart=true, RemainAfterExit) and does its work in
# ExecStop, which systemd runs early in shutdown while /dev/cec0, journald
# and systemctl are all still alive. The gate on the queued goal target
# excludes reboot; suspend never stops the unit at all. cec-ctl (v4l-utils)
# is used instead of cecd/D-Bus because the user session may already be
# tearing down -- and a second fd transmitting alongside cecd is verified
# to work.

cmd_shutdown_standby() {
    local action="${1:-status}"
    case "$action" in
        install)
            require_user
            log "Installing $STANDBY_SVC (sudo)..."
            sudo tee "$STANDBY_UNIT" >/dev/null << 'EOF'
[Unit]
Description=BC-250: send CEC standby to the TV on poweroff
# Inert at boot; the work happens in ExecStop during shutdown. Reboot is
# excluded by the goal-target gate, suspend never stops the unit.
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/true
ExecStop=/bin/bash -c 'if systemctl list-jobs | grep -qE "(poweroff|halt)\.target.*start"; then /usr/bin/cec-ctl -s -d /dev/cec0 --to 0 --standby || true; fi'
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable "$STANDBY_SVC" >/dev/null 2>&1
            sudo systemctl start "$STANDBY_SVC"
            log "Installed. TV goes to standby on poweroff (not reboot, not suspend)."
            ;;
        remove)
            require_user
            log "Removing $STANDBY_SVC (sudo)..."
            sudo systemctl disable --now "$STANDBY_SVC" >/dev/null 2>&1 || true
            sudo rm -f "$STANDBY_UNIT"
            sudo systemctl daemon-reload
            log "Removed."
            ;;
        status)
            echo "  unit file: $STANDBY_UNIT $([[ -f "$STANDBY_UNIT" ]] && echo present || echo absent)"
            echo "  enabled:   $(systemctl is-enabled "$STANDBY_SVC" 2>/dev/null || echo -)"
            echo "  active:    $(systemctl is-active "$STANDBY_SVC" 2>/dev/null || echo -)"
            ;;
        *) die "usage: $0 shutdown-standby {install|remove|status}" ;;
    esac
}

shutdown_standby_toggle() {   # menu helper: flip install state
    if [[ "$(systemctl is-enabled "$STANDBY_SVC" 2>/dev/null)" == enabled ]]; then
        cmd_shutdown_standby remove
    else
        cmd_shutdown_standby install
    fi
}

# ========================= wake TV at boot ================================
# cecd wakes the TV on resume-from-suspend (wake_tv) but does nothing at
# cold boot. This user unit fires once per session start; Wake() powers the
# TV on AND switches its input to us. cecd is D-Bus activatable, so the
# call also covers "cecd not started yet"; the retry loop covers the
# adapter still negotiating HPD / a logical address right after boot.

cmd_boot_wake() {
    local action="${1:-status}"
    case "$action" in
        install)
            require_user
            mkdir -p "$USER_UNIT_DIR"
            cat > "$WAKE_UNIT" << 'EOF'
[Unit]
Description=BC-250: wake the TV and take input at session start
After=cecd.service
Wants=cecd.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for i in 1 2 3 4 5; do busctl --user call com.steampowered.CecDaemon1 /com/steampowered/CecDaemon1/Devices/Cec0 com.steampowered.CecDaemon1.CecDevice1 Wake && exit 0; sleep 2; done; exit 1'

[Install]
WantedBy=graphical-session.target
EOF
            systemctl --user daemon-reload
            systemctl --user enable "$WAKE_SVC" >/dev/null 2>&1
            log "Installed. TV wakes + switches to the BC-250 at every session start."
            ;;
        remove)
            require_user
            systemctl --user disable "$WAKE_SVC" >/dev/null 2>&1 || true
            rm -f "$WAKE_UNIT"
            systemctl --user daemon-reload
            log "Removed."
            ;;
        status)
            echo "  unit file: $WAKE_UNIT $([[ -f "$WAKE_UNIT" ]] && echo present || echo absent)"
            echo "  enabled:   $(systemctl --user is-enabled "$WAKE_SVC" 2>/dev/null || echo -)"
            ;;
        *) die "usage: $0 boot-wake {install|remove|status}" ;;
    esac
}

boot_wake_toggle() {
    if [[ "$(systemctl --user is-enabled "$WAKE_SVC" 2>/dev/null)" == enabled ]]; then
        cmd_boot_wake remove
    else
        cmd_boot_wake install
    fi
}

# ======================== recommended setup ===============================

cmd_setup() {
    require_user; require_daemon
    log "Recommended setup: OSD name, TV standby on suspend + poweroff, wake at boot."
    echo
    log "[1/4] OSD name -> $OSD_DEFAULT"
    cmd_osd_name "$OSD_DEFAULT" || warn "OSD name step failed -- continuing."
    echo
    log "[2/4] Standby TV when the console suspends"
    cmd_toggle suspend-tv on || warn "suspend-tv toggle failed -- continuing."
    echo
    log "[3/4] Standby TV on poweroff (needs sudo)"
    cmd_shutdown_standby install || warn "poweroff unit install failed -- continuing."
    echo
    log "[4/4] Wake TV at boot"
    cmd_boot_wake install || warn "boot wake install failed -- continuing."
    echo
    log "Done. Already on out of the box: wake TV on resume, suspend console"
    log "when the TV turns off, TV remote as input. Check with: $0 status"
}

# ============================== tests =====================================

t_pass() { echo -e "  ${CG}${CB}PASS${C0} $*"; }
t_fail() { echo -e "  ${CR}${CB}FAIL${C0} $*"; }
t_skip() { echo -e "  ${CD}skip${C0} $*"; }

cmd_test() {
    require_user; require_daemon
    log "Guided TV-control test. Steps never abort the sequence."
    echo

    if dev_call Poll y "$TV_LA" >/dev/null 2>&1; then
        t_pass "TV answers polls at logical address $TV_LA"
    else
        t_fail "TV did not ACK a poll -- is it on this HDMI input / CEC enabled in its menu?"
    fi

    local st; st=$(tv_power_status)
    if [[ "$st" == no-reply ]]; then
        t_fail "TV power status: no reply"
    else
        t_pass "TV power status: $st"
    fi

    log "Waking the TV (Wake = power on + switch input to us)..."
    if dev_call Wake >/dev/null 2>&1; then
        sleep 3
        st=$(tv_power_status)
        case "$st" in
            on|"standby->on") t_pass "TV reports '$st' after Wake" ;;
            *)                t_fail "TV reports '$st' after Wake (some TVs are slow -- re-run status)" ;;
        esac
    else
        t_fail "Wake call failed"
    fi

    log "Claiming active source..."
    if dev_call SetActiveSource i -- -1 >/dev/null 2>&1; then
        sleep 2
        if [[ "$(dev_prop Active)" == true ]]; then
            t_pass "BC-250 is the active source"
        else
            t_fail "SetActiveSource sent but Active still false"
        fi
    else
        t_fail "SetActiveSource call failed"
    fi

    local ala; ala=$(dev_prop AudioLogicalAddress)
    if [[ "$ala" =~ ^[0-9]+$ && "$ala" -ne 255 ]]; then
        local astat
        if astat=$(dev_call GetAudioStatus y "$ala" 2>/dev/null); then
            t_pass "audio system LA $ala: volume $(echo "$astat" | awk '{print $2}')%, mute $(echo "$astat" | awk '{print $3}')"
            log "Volume blip (up, then back down)..."
            dev_call VolumeUp y "$ala" >/dev/null 2>&1 || true
            sleep 1
            dev_call VolumeDown y "$ala" >/dev/null 2>&1 || true
        else
            t_skip "audio system present (LA $ala) but no audio status reply -- soundbar off?"
        fi
    else
        t_skip "no audio system on the bus"
    fi

    if [[ -t 0 ]]; then
        echo
        ask "Send TV standby to test power-off? [y/N]" "N"
        if [[ "$REPLY" =~ ^[Yy] ]]; then
            dev_call Standby y "$TV_LA" >/dev/null 2>&1 || true
            sleep 3
            st=$(tv_power_status)
            case "$st" in
                standby|"on->standby"|no-reply) t_pass "TV standing by ('$st')" ;;
                *)                              t_fail "TV still reports '$st'" ;;
            esac
            # auto-wake: the terminal is usually ON the TV we just put to
            # sleep, so a prompt here would never be seen
            log "Waking the TV back up..."
            dev_call Wake >/dev/null 2>&1 || true
            sleep 3
            st=$(tv_power_status)
            case "$st" in
                on|"standby->on") t_pass "TV back on ('$st')" ;;
                *)                t_fail "TV reports '$st' after wake-back -- manual recovery: $0 tv-on" ;;
            esac
        fi
    fi
}

# ======================== monitor / remote ================================

cmd_monitor() {
    echo "Raw CEC bus traffic -- Ctrl-C to exit."
    echo -e "${CD}(rootless alternative: busctl --user monitor $DBUS_NAME)${C0}"
    if [[ $EUID -eq 0 ]]; then exec cectool monitor; fi
    # kernel CEC monitor mode needs CAP_NET_ADMIN (EPERM as plain user)
    exec sudo cectool monitor
}

cmd_remote() {
    require_user
    local val; val=$(cfg_prop Uinput)
    echo "  uinput relay (cecd config): $val"
    echo
    if remote_dev_present; then
        echo "  cecd input devices:"
        awk -v RS= '/Name="cecd/ { print "    " $0 "\n" }' /proc/bus/input/devices \
            | grep -E 'Name=|Handlers=' | sed 's/^[NH]: /    /'
        echo
        echo "  TV remote arrows / OK / back should drive gamescope directly."
    else
        echo "  No cecd input device found."
        [[ "$val" == true ]] && echo "  Toggle is on -- try: systemctl --user restart cecd"
        [[ "$val" == true ]] || echo "  Enable with: $0 toggle uinput on"
    fi
}

# ========================= one-shot CLI verbs =============================

cmd_tv_on()    { require_user; require_daemon; dev_call Wake >/dev/null; log "Wake sent (power on + switch input)."; }
cmd_tv_off()   { require_user; require_daemon; dev_call Standby y "$TV_LA" >/dev/null; log "Standby sent to the TV."; }
cmd_switch()   { require_user; require_daemon; dev_call SetActiveSource i -- -1 >/dev/null; log "Active-source claim sent."; }
cmd_vol_up()   { require_user; require_daemon; dev_call VolumeUp   y "$(audio_la)" >/dev/null; }
cmd_vol_down() { require_user; require_daemon; dev_call VolumeDown y "$(audio_la)" >/dev/null; }
cmd_mute()     { require_user; require_daemon; dev_call Mute       y "$(audio_la)" >/dev/null; }

# ============================== menus =====================================

menu_toggles() {
    while true; do
        local items=(
            "Wake TV on resume|$(badge_toggle wake_tv)|cecd wakes the TV when the console resumes from sleep. On by default."
            "Standby TV on suspend|$(badge_toggle suspend_tv)|TV turns off when the console goes to sleep."
            "Suspend when TV turns off|$(badge_toggle allow_standby)|TV standby puts the console to sleep too. On by default."
            "TV remote as input|$(badge_toggle uinput)|Relay remote keys as an input device -- drives gamescope."
            "Clear overrides|$(badge_overrides)|Delete our override file; Steam UI regains control of all four."
        )
        menu_select "CEC behavior toggles  ${CD}(override Steam UI)${C0}" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_action cmd_toggle wake-tv ;;
            1) run_action cmd_toggle suspend-tv ;;
            2) run_action cmd_toggle allow-standby ;;
            3) run_action cmd_toggle uinput ;;
            4) run_action cmd_clear_overrides ;;
        esac
    done
}

cmd_menu() {
    [[ -t 0 && -t 1 ]] || die "The menu needs an interactive terminal. See '$0 help' for CLI commands."
    # Opposite of bc250-power.sh: this script must NOT run as root, because
    # cecd only exists on deck's user D-Bus session.
    [[ $EUID -ne 0 ]] || die "Run as deck, not root. Only the poweroff unit asks for sudo itself."
    while true; do
        local items=(
            "Status overview||Full health dump: device, daemon, TV power, config. Always safe."
            "Recommended setup||One shot: OSD name + TV off on suspend/poweroff + wake at boot."
            "Set TV name (OSD)|$(badge_osd)|Name in the TV's device list. Default: $OSD_DEFAULT."
            "Behavior toggles|$(badge_overrides)|Wake/standby/remote toggles -- overrides Steam UI settings."
            "TV standby on power-off|$(badge_standby)|Sends CEC standby on poweroff only (not reboot/suspend). Uses sudo."
            "Wake TV at boot|$(badge_wake)|Wake the TV + grab its input when the session starts."
            "Test TV control|$(tv_badge_menu)|Guided sequence: poll, wake, switch input, audio, standby."
            "TV-remote input|$(badge_remote)|uinput relay state and the input devices cecd created."
            "Live CEC monitor||Raw bus traffic via cectool (needs sudo; Ctrl-C exits)."
            "Full help||The complete manual for every CLI command."
        )
        menu_select "BC-250 CEC / TV control  ${CD}(SteamOS cecd)${C0}" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_action cmd_status ;;
            1) run_action cmd_setup ;;
            2) run_action cmd_osd_name ;;
            3) menu_toggles ;;
            4) run_action shutdown_standby_toggle ;;
            5) run_action boot_wake_toggle ;;
            6) run_action cmd_test ;;
            7) run_action cmd_remote ;;
            8) cmd_monitor ;;
            9) cmd_help; pause_key ;;
        esac
    done
}

tv_badge_menu() {   # tiny live badge for the test row: is the TV reachable?
    cecd_up || { b_off "cecd not running"; return 0; }
    [[ -e "$CEC_DEV" ]] || { b_off "no /dev/cec0"; return 0; }
    b_ok "ready"
    return 0
}

cmd_help() {
    cat << 'EOF'
bc250-cec.sh -- HDMI-CEC / TV control for the BC-250 on SteamOS
================================================================
The kernel and Valve's cecd daemon already do the heavy lifting: CEC is
tunneled over the DP->HDMI adapter's AUX channel to /dev/cec0, and cecd
(user service, D-Bus com.steampowered.CecDaemon1) wakes the TV on resume,
suspends the console when the TV turns off, and relays the TV remote as
an input device. This script configures cecd and fills its gaps.

Run as deck (NOT root/sudo) -- cecd lives on the user D-Bus session.
Only 'shutdown-standby install' escalates, by itself, for one unit file.

GUIDED MENU
  Run with no arguments in a terminal: arrow keys / j k, Enter, q.
  Every menu action is one of the CLI commands below.

SETUP
  setup            Recommended one-shot: osd-name BC-250, TV standby on
                   suspend + poweroff, wake TV at boot.
  osd-name [NAME]  Name shown in the TV's device/input list (max 14
                   bytes, default BC-250). 'osd-name --reset' removes it.
  toggle KEY [on|off]
                   KEY: wake-tv | suspend-tv | allow-standby | uinput
                     wake-tv        wake TV when console resumes  (default on)
                     suspend-tv     TV standby when console sleeps (default off)
                     allow-standby  console sleeps when TV turns off (default on)
                     uinput         TV remote -> input events      (default on)
                   Written to ~/.config/cecd/config.d/99-zz-bc250.toml,
                   which outranks Steam UI's fragment. No arg = flip.
  clear-overrides  Delete the override file; Steam UI back in control.
  shutdown-standby install|remove|status
                   System unit: CEC standby to the TV on POWEROFF only
                   (reboot and suspend excluded). The one sudo action.
  boot-wake install|remove|status
                   User unit: wake TV + switch its input to the BC-250
                   at every session start.

EVERYDAY VERBS
  tv-on            Wake the TV and switch input to the BC-250.
  tv-off           Put the TV into standby.
  switch           Claim active source (switch TV input to us).
  vol-up|vol-down|mute
                   Volume on the CEC audio system (soundbar/AVR).

DIAGNOSTICS
  status           Full health dump -- device, daemon, bus identity,
                   effective config + source, TV power, installed units.
  test             Guided pass/fail sequence: poll TV, power status,
                   wake, input switch, audio, optional standby.
  monitor          Raw CEC traffic (sudo cectool monitor; Ctrl-C exits).
                   Rootless: busctl --user monitor com.steampowered.CecDaemon1
  remote           TV-remote relay state + the input devices cecd made.

FILE MAP (everything survives SteamOS updates)
  ~/.config/cecd/config.d/50-bc250.toml       osd_name
  ~/.config/cecd/config.d/99-zz-bc250.toml    toggle overrides (outranks
                                              Steam UI's 99-steamos-manager.toml)
  ~/.config/systemd/user/bc250-cec-boot-wake.service
  /etc/systemd/system/bc250-cec-poweroff-standby.service
  (nothing in /usr or /boot; cecd itself is part of the OS image)
EOF
}

# ============================ dispatch ====================================

case "${1:-}" in
    status)            cmd_status ;;
    setup)             cmd_setup ;;
    osd-name)          shift; cmd_osd_name "$@" ;;
    toggle)            shift; cmd_toggle "$@" ;;
    clear-overrides)   cmd_clear_overrides ;;
    shutdown-standby)  shift; cmd_shutdown_standby "${1:-status}" ;;
    boot-wake)         shift; cmd_boot_wake "${1:-status}" ;;
    test)              cmd_test ;;
    monitor)           cmd_monitor ;;
    remote)            cmd_remote ;;
    tv-on)             cmd_tv_on ;;
    tv-off)            cmd_tv_off ;;
    switch)            cmd_switch ;;
    vol-up)            cmd_vol_up ;;
    vol-down)          cmd_vol_down ;;
    mute)              cmd_mute ;;
    menu)              cmd_menu ;;
    help|-h|--help)    cmd_help ;;
    "") if [[ -t 0 && -t 1 ]]; then cmd_menu; exit 0; fi ;&
    *) echo "Usage: $0 {status|setup|osd-name|toggle|clear-overrides|shutdown-standby|boot-wake|"
       echo "           test|monitor|remote|tv-on|tv-off|switch|vol-up|vol-down|mute|menu|help}"
       echo "  (no arguments on a terminal opens the guided menu)"
       echo
       echo "Run '$0 help' for the full explanation of every command."
       exit 1 ;;
esac
