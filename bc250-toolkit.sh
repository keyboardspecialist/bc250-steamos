#!/usr/bin/env bash
# Unified launcher for the BC-250 SteamOS management tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
POWER_SH="$SCRIPT_DIR/bc250-power.sh"
COMPUTE_SH="$SCRIPT_DIR/bc250-40cu.sh"
CEC_SH="$SCRIPT_DIR/bc250-cec.sh"
STORAGE_SH="$SCRIPT_DIR/bc250-storage.sh"
PERSISTENCE_SH="$SCRIPT_DIR/bc250-update-persistence.sh"
CU_STATUS_SH="$SCRIPT_DIR/bc250-cu-status.sh"
AIC_SETUP_SH="$SCRIPT_DIR/aic8800/steamdeck-setup.sh"
AUDIO_FIX_SH="$SCRIPT_DIR/bc250-audio-fix/patch-driver.sh"
DECKY_INSTALL_SH="$SCRIPT_DIR/decky-plugin/install.sh"
DESKTOP_INSTALL_SH="$SCRIPT_DIR/desktop-control/install.sh"
MAINTENANCE_SH="$SCRIPT_DIR/bc250-maintenance.sh"

C0=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'; CI=$'\033[7m'
CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'; CC=$'\033[36m'
TUI_CURSOR_HIDDEN=0

log() { echo "[bc250-toolkit] $*"; }
die() { echo "[bc250-toolkit] $*" >&2; exit 1; }

tui_show_cursor() {
    if [[ $TUI_CURSOR_HIDDEN -eq 1 ]]; then
        printf '\033[?25h'
        TUI_CURSOR_HIDDEN=0
    fi
}
trap tui_show_cursor EXIT

require_terminal() {
    [[ -t 0 && -t 1 ]] || die "This action requires an interactive terminal."
}

require_normal_user() {
    [[ $EUID -ne 0 ]] \
        || die "Run the toolkit as the logged-in Deck user, not with sudo. Child tools request administrator access when needed."
}

require_script() {
    [[ -f "$1" && ! -L "$1" ]] || die "Toolkit component is missing or unsafe: $1"
}

run_script() {
    local script="$1"
    shift
    require_script "$script"
    bash "$script" "$@"
}

confirm_action() {
    local prompt="$1" answer
    shift
    require_terminal
    printf '%s' "${CB}${prompt} [y/N] ${C0}"
    IFS= read -r answer
    case "$answer" in
        y|Y|yes|YES) "$@" ;;
        *) log "Cancelled." ;;
    esac
}

install_wifi() {
    require_normal_user
    require_script "$AIC_SETUP_SH"
    confirm_action \
        "Build and install the AIC8800 WiFi and Bluetooth drivers?" \
        sudo bash "$AIC_SETUP_SH"
}

install_audio_fix() {
    require_normal_user
    require_script "$AUDIO_FIX_SH"
    confirm_action \
        "Build and install the matching AMDGPU display/audio clock fix?" \
        bash "$AUDIO_FIX_SH"
}

install_decky() {
    require_normal_user
    require_script "$DECKY_INSTALL_SH"
    confirm_action \
        "Build and install the BC-250 Decky plugin?" \
        bash "$DECKY_INSTALL_SH"
}

install_desktop() {
    require_normal_user
    require_script "$DESKTOP_INSTALL_SH"
    confirm_action \
        "Install or upgrade the BC-250 Plasma desktop control?" \
        bash "$DESKTOP_INSTALL_SH" install
}

status_section() {
    local title="$1" script="$2" rc=0
    shift 2
    printf '\n%s\n' "${CB}${CC}-- ${title} --${C0}"
    if [[ ! -f "$script" || -L "$script" ]]; then
        log "Component is missing or unsafe: $script"
        return 1
    fi
    bash "$script" "$@" || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s\n' "${CR}${title} status failed (exit $rc).${C0}"
        return "$rc"
    fi
}

show_status() {
    require_normal_user
    local failed=0
    status_section "Persistent storage" "$STORAGE_SH" status || failed=1
    status_section "Power management" "$POWER_SH" status || failed=1
    status_section "CEC" "$CEC_SH" status || failed=1
    status_section "SteamOS update persistence" "$PERSISTENCE_SH" status \
        || failed=1
    printf '\n%s\n' "${CB}${CC}-- Compute units --${C0}"
    if [[ -f "$CU_STATUS_SH" && ! -L "$CU_STATUS_SH" ]]; then
        printf '%s\n' "Run 'sudo bash $CU_STATUS_SH' for register status."
    else
        log "Component is missing or unsafe: $CU_STATUS_SH"
        failed=1
    fi
    return "$failed"
}

menu_select() {
    local title="$1"
    shift
    local items=("$@") n=$# cur=0 drawn=0 key rest i label badge hint
    local lines=$((n + 4))
    printf '\033[?25l'
    TUI_CURSOR_HIDDEN=1
    while true; do
        if [[ $drawn -eq 1 ]]; then printf '\033[%dA' "$lines"; fi
        printf '\r\033[K%s\n' "${CB}${CC}${title}${C0}"
        printf '\033[K%s\n' "${CD}  up/down move - Enter select - q quit${C0}"
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
            $'\033[A'|k) if ((cur > 0)); then cur=$((cur - 1)); else cur=$((n - 1)); fi ;;
            $'\033[B'|j) if ((cur < n - 1)); then cur=$((cur + 1)); else cur=0; fi ;;
            "") MENU_CHOICE=$cur; tui_show_cursor; return 0 ;;
            q|Q|$'\033') tui_show_cursor; return 1 ;;
        esac
    done
}

pause_key() {
    echo
    printf '%s' "${CD}-- press any key to return to the toolkit --${C0}"
    IFS= read -rsn1 || true
    printf '\r\033[K'
}

run_menu_child() {
    local rc=0
    echo
    bash "$SELF" "$@" || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s\n' "${CR}${CB}[bc250-toolkit]${C0} action failed (exit $rc)"
        pause_key
    fi
}

run_menu_action() {
    local rc=0
    echo
    bash "$SELF" "$@" || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s\n' "${CR}${CB}[bc250-toolkit]${C0} action failed (exit $rc)"
    fi
    pause_key
}

cmd_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "System status|${CD}[read only]${C0}|Show storage, power, CEC, update, and CU status paths."
            "Power management|${CG}[menu]${C0}|Configure power states, GPU tuning, and CPU overclocking."
            "Compute units|${CG}[menu]${C0}|Prepare UMR, configure CU routing, and manage persistence."
            "CEC / HDMI control|${CG}[menu]${C0}|Configure and control TVs, receivers, and active source."
            "Persistent storage|${CG}[menu]${C0}|Install, inspect, or repair privileged persistent storage."
            "SteamOS update persistence|${CG}[menu]${C0}|Protect or recover component configuration across updates."
            "WiFi and Bluetooth|${CY}[installer]${C0}|Build and install the AIC8800 kernel modules and firmware."
            "Patch AMDGPU Driver|${CY}[build]${C0}|Build and install the matching patched AMDGPU module."
            "Decky plugin|${CY}[installer]${C0}|Build and install the BC-250 Quick Access plugin."
            "Plasma desktop control|${CY}[installer]${C0}|Install the system service and Plasma system-tray control."
            "Manage installed components|${CR}[maintenance]${C0}|Review uninstall plans, remove components, or purge preserved data."
        )
        menu_select "BC-250 SteamOS toolkit" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action status ;;
            1) run_menu_child power ;;
            2) run_menu_child compute ;;
            3) run_menu_child cec ;;
            4) run_menu_child storage ;;
            5) run_menu_child persistence ;;
            6) run_menu_action wifi ;;
            7) run_menu_action audio ;;
            8) run_menu_action decky ;;
            9) run_menu_action desktop ;;
            10) run_menu_child manage ;;
        esac
    done
}

cmd_help() {
    cat << EOF
Usage: $0 [menu|status|power|compute|cec|storage|persistence|wifi|audio|decky|desktop|manage|help]

Run without arguments in a terminal to open the unified toolkit menu.
Run the toolkit as the logged-in Deck user, not with sudo; child tools request
administrator access when needed.

Commands:
  status                 Show a read-only component status overview
  power                  Open the Power Management menu
  compute                Open the Compute Units menu
  cec                    Open the CEC / HDMI Control menu
  storage                Open the Persistent Storage menu
  persistence            Open the SteamOS Update Persistence menu
  wifi                   Confirm and run the AIC8800 installer
  audio                  Confirm and run the AMDGPU clock-fix builder
  decky                  Confirm and run the Decky plugin installer
  desktop                Confirm and run the Plasma desktop-control installer
  manage                 Open installed-component maintenance and cleanup
EOF
}

if [[ $# -eq 0 ]]; then
    if [[ -t 0 && -t 1 ]]; then
        cmd_menu
        exit 0
    fi
    cmd_help >&2
    exit 1
fi

command_name="$1"
shift
case "$command_name" in
    menu) (($# == 0)) || die "Usage: $0 menu"; cmd_menu ;;
    status) (($# == 0)) || die "Usage: $0 status"; show_status ;;
    power) (($# == 0)) || die "Usage: $0 power"; run_script "$POWER_SH" menu ;;
    compute) (($# == 0)) || die "Usage: $0 compute"; run_script "$COMPUTE_SH" menu ;;
    cec) (($# == 0)) || die "Usage: $0 cec"; require_normal_user; run_script "$CEC_SH" menu ;;
    storage) (($# == 0)) || die "Usage: $0 storage"; run_script "$STORAGE_SH" menu ;;
    persistence) (($# == 0)) || die "Usage: $0 persistence"; run_script "$PERSISTENCE_SH" menu ;;
    wifi) (($# == 0)) || die "Usage: $0 wifi"; install_wifi ;;
    audio) (($# == 0)) || die "Usage: $0 audio"; install_audio_fix ;;
    decky) (($# == 0)) || die "Usage: $0 decky"; install_decky ;;
    desktop) (($# == 0)) || die "Usage: $0 desktop"; install_desktop ;;
    manage) (($# == 0)) || die "Usage: $0 manage"; run_script "$MAINTENANCE_SH" menu ;;
    help|-h|--help) (($# == 0)) || die "Usage: $0 help"; cmd_help ;;
    *) cmd_help >&2; exit 1 ;;
esac
