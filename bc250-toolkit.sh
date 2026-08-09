#!/usr/bin/env bash
# Unified launcher for the BC-250 SteamOS management tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
POWER_SH="$SCRIPT_DIR/bc250-power.sh"
RAM_SPLIT_SH="$SCRIPT_DIR/bc250-ram-split.sh"
COMPUTE_SH="$SCRIPT_DIR/bc250-40cu.sh"
CEC_SH="$SCRIPT_DIR/bc250-cec.sh"
STORAGE_SH="$SCRIPT_DIR/bc250-storage.sh"
PERSISTENCE_SH="$SCRIPT_DIR/bc250-update-persistence.sh"
CU_STATUS_SH="$SCRIPT_DIR/bc250-cu-status.sh"
AIC_SETUP_SH="$SCRIPT_DIR/aic8800/steamdeck-setup.sh"
AUDIO_FIX_SH="$SCRIPT_DIR/bc250-audio-fix/patch-driver.sh"
MESH_SHADER_SH="$SCRIPT_DIR/bc250-mesh-shader.sh"
DECKY_INSTALL_SH="$SCRIPT_DIR/decky-plugin/install.sh"
DESKTOP_INSTALL_SH="$SCRIPT_DIR/desktop-control/install.sh"
TRAINER_INSTALL_SH="$SCRIPT_DIR/trainer/install.sh"
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

run_sudo_script() {
    local script="$1"
    shift
    require_script "$script"
    sudo bash "$script" "$@"
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
        "Build and install the matching AMDGPU kernel fixes?" \
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

install_trainer() {
    require_normal_user
    require_script "$TRAINER_INSTALL_SH"
    confirm_action \
        "Install or upgrade BC250 Trainer?" \
        bash "$TRAINER_INSTALL_SH" install
}

run_machine_action() {
    (($# == 1)) || die "Usage: $0 action OPERATION_ID"
    require_normal_user
    local operation="$1"
    export BC250_TOOLKIT_MACHINE=1

    case "$operation" in
        storage-install) run_sudo_script "$STORAGE_SH" install ;;
        storage-repair) run_sudo_script "$STORAGE_SH" repair-infrastructure ;;
        power-install) run_sudo_script "$POWER_SH" all ;;
        ram-install) run_sudo_script "$RAM_SPLIT_SH" install ;;
        compute-build) run_sudo_script "$COMPUTE_SH" prep ;;
        cec-setup) run_script "$CEC_SH" setup ;;
        cec-repair) run_script "$CEC_SH" repair ;;
        persistence-install) run_sudo_script "$PERSISTENCE_SH" install all ;;
        aic-install) run_sudo_script "$AIC_SETUP_SH" install ;;
        audio-build) run_script "$AUDIO_FIX_SH" ;;
        mesh-setup) run_script "$MESH_SHADER_SH" setup ;;
        decky-install) run_script "$DECKY_INSTALL_SH" install ;;
        desktop-install) run_script "$DESKTOP_INSTALL_SH" install ;;
        persistence-remove) run_sudo_script "$PERSISTENCE_SH" remove all ;;
        storage-remove|power-remove|ram-remove|compute-remove|cec-remove|aic-remove|audio-remove|mesh-remove|decky-remove|desktop-remove)
            require_script "$MAINTENANCE_SH"
            bash "$MAINTENANCE_SH" uninstall "${operation%-remove}" --yes
            ;;
        *) die "Unknown operation ID: $operation" ;;
    esac
}

show_inventory_json() {
    require_normal_user
    run_script "$MAINTENANCE_SH" status-json
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
    local failed=0 amdgpu_rc=0 amdgpu_status="" radv_rc=0
    status_section "Persistent storage" "$STORAGE_SH" status || failed=1
    status_section "Power management" "$POWER_SH" status || failed=1
    status_section "RAM / VRAM split" "$RAM_SPLIT_SH" status || failed=1
    status_section "CEC" "$CEC_SH" status || failed=1
    status_section "SteamOS update persistence" "$PERSISTENCE_SH" status \
        || failed=1
    printf '\n%s\n' "${CB}${CC}-- AMDGPU kernel fixes --${C0}"
    if [[ -f "$AUDIO_FIX_SH" && ! -L "$AUDIO_FIX_SH" ]]; then
        amdgpu_status=$(bash "$AUDIO_FIX_SH" status) || amdgpu_rc=$?
        printf '%s\n' "$amdgpu_status"
        if [[ $amdgpu_rc -ne 0 ]] \
            && ! grep -qxF '[bc250-amdgpu] state: not-installed' <<< "$amdgpu_status"; then
            failed=1
        fi
    else
        log "Component is missing or unsafe: $AUDIO_FIX_SH"
        failed=1
    fi
    printf '\n%s\n' "${CB}${CC}-- Mesa / RADV performance patch --${C0}"
    if [[ -f "$MESH_SHADER_SH" && ! -L "$MESH_SHADER_SH" ]]; then
        bash "$MESH_SHADER_SH" status || radv_rc=$?
        [[ $radv_rc -le 1 ]] || failed=1
    else
        log "Component is missing or unsafe: $MESH_SHADER_SH"
        failed=1
    fi
    printf '\n%s\n' "${CB}${CC}-- GPU compute units --${C0}"
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

cmd_drivers_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "AMDGPU kernel fixes|${CY}[build]${C0}|Install first: display/audio clocks, telemetry, and GFX1013 compute queues. Reboot afterward."
            "Mesa / RADV performance patch (optional)|${CG}[menu]${C0}|Highly recommended for performance. Requires the active AMDGPU fixes and applies globally to this user."
            "AIC8800 WiFi / Bluetooth|${CY}[installer]${C0}|Install only when the system uses the AIC8800 wireless adapter."
        )
        menu_select "BC-250 drivers" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action amdgpu ;;
            1) run_menu_child radv ;;
            2) run_menu_action wifi ;;
        esac
    done
}

cmd_unlocks_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "GPU compute-unit unlock|${CG}[menu]${C0}|Configure GPU CU/WGP routing from the factory 24 CU toward the board's stable maximum."
            "CPU core unlock|${CG}[menu]${C0}|Test and configure the experimental CPU topology change from 6c/12t to 8c/16t."
        )
        menu_select "BC-250 hardware unlocks" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_child compute ;;
            1) run_menu_child cpu-unlock ;;
        esac
    done
}

cmd_storage_updates_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "Persistent storage & boot recovery|${CG}[menu]${C0}|Install, inspect, or repair the toolkit's persistent privileged storage."
            "SteamOS update persistence|${CG}[menu]${C0}|Protect and recover supported component configuration across SteamOS updates."
        )
        menu_select "BC-250 storage & SteamOS updates" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_child storage ;;
            1) run_menu_child persistence ;;
        esac
    done
}

cmd_interfaces_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "Decky plugin|${CY}[installer]${C0}|Install the BC-250 controls for Gaming Mode and Quick Access."
            "Plasma desktop control|${CY}[installer]${C0}|Install the system service and Plasma system-tray control."
            "BC250 Trainer|${CY}[installer]${C0}|Install the standalone native Qt control application."
        )
        menu_select "BC-250 control interfaces" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action decky ;;
            1) run_menu_action desktop ;;
            2) run_menu_action trainer ;;
        esac
    done
}

cmd_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "System status|${CD}[read only]${C0}|Show system integration, graphics-driver, and GPU compute-unit status."
            "Drivers|${CG}[menu]${C0}|Install the related AMDGPU and Mesa / RADV graphics fixes or AIC8800 wireless support."
            "Hardware unlocks|${CG}[menu]${C0}|Configure GPU compute units or CPU cores without confusing the two workflows."
            "Power management|${CG}[menu]${C0}|Configure power states, GPU tuning, and CPU overclocking."
            "RAM / VRAM split|${CG}[menu]${C0}|Configure the CMOS UMA minimum and Linux dynamic TTM VRAM limit."
            "CEC / HDMI control|${CG}[menu]${C0}|Configure and control TVs, receivers, and active source."
            "Storage & SteamOS updates|${CG}[menu]${C0}|Manage persistent storage, boot recovery, and update protection."
            "Control interfaces|${CG}[menu]${C0}|Install Decky, Plasma, or the standalone BC250 Trainer."
            "Manage installed components|${CG}[menu]${C0}|Review uninstall plans, remove components, or purge preserved data."
        )
        menu_select "BC-250 SteamOS toolkit" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action status ;;
            1) cmd_drivers_menu ;;
            2) cmd_unlocks_menu ;;
            3) run_menu_child power ;;
            4) run_menu_child ram ;;
            5) run_menu_child cec ;;
            6) cmd_storage_updates_menu ;;
            7) cmd_interfaces_menu ;;
            8) run_menu_child manage ;;
        esac
    done
}

cmd_help() {
    cat << EOF
Usage: $0 [menu|status|inventory-json|action OPERATION_ID|drivers|unlocks|storage-updates|interfaces|power|ram|compute|cpu-unlock|cec|storage|persistence|wifi|amdgpu|radv|decky|desktop|trainer|manage|help]

Run without arguments in a terminal to open the unified toolkit menu.
Run the toolkit as the logged-in Deck user, not with sudo; child tools request
administrator access when needed.

Commands:
  status                 Show a read-only component status overview
  inventory-json         Emit versioned JSON component inventory for automation
  action OPERATION_ID    Run one fixed, noninteractive dashboard operation
  drivers                Open AMDGPU, Mesa / RADV, and wireless drivers
  unlocks                Open GPU compute-unit and CPU core unlocks
  storage-updates        Open persistent storage and update protection
  interfaces             Open Decky, Plasma, and Trainer installers
  power                  Open the Power Management menu
  ram                    Open the RAM / VRAM Split menu
  compute                Open the GPU Compute-Unit Unlock menu
  cpu-unlock             Open the CPU Core Unlock menu
  cec                    Open the CEC / HDMI Control menu
  storage                Open the Persistent Storage menu
  persistence            Open the SteamOS Update Persistence menu
  wifi                   Confirm and run the AIC8800 installer
  amdgpu                 Confirm and build the AMDGPU kernel fixes
  radv                   Open the global Mesa / RADV performance patch
  decky                  Confirm and run the Decky plugin installer
  desktop                Confirm and run the Plasma desktop-control installer
  trainer                Confirm and run the BC250 Trainer installer
  manage                 Open installed-component maintenance and cleanup

Compatibility aliases: audio (amdgpu), mesh (radv)

Action operation IDs:
  storage-install        power-install          ram-install
  compute-build          cec-setup              persistence-install
  aic-install            audio-build            mesh-setup
  decky-install          desktop-install
  storage-repair         cec-repair
  storage-remove         power-remove           ram-remove
  compute-remove         cec-remove             persistence-remove
  aic-remove             audio-remove           mesh-remove
  decky-remove           desktop-remove
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
    inventory-json) (($# == 0)) || die "Usage: $0 inventory-json"; show_inventory_json ;;
    action) run_machine_action "$@" ;;
    drivers) (($# == 0)) || die "Usage: $0 drivers"; cmd_drivers_menu ;;
    unlocks) (($# == 0)) || die "Usage: $0 unlocks"; cmd_unlocks_menu ;;
    storage-updates) (($# == 0)) || die "Usage: $0 storage-updates"; cmd_storage_updates_menu ;;
    interfaces) (($# == 0)) || die "Usage: $0 interfaces"; cmd_interfaces_menu ;;
    power) (($# == 0)) || die "Usage: $0 power"; run_script "$POWER_SH" menu ;;
    ram) (($# == 0)) || die "Usage: $0 ram"; run_script "$RAM_SPLIT_SH" menu ;;
    compute) (($# == 0)) || die "Usage: $0 compute"; run_script "$COMPUTE_SH" menu ;;
    cpu-unlock) (($# == 0)) || die "Usage: $0 cpu-unlock"; run_script "$POWER_SH" cpu-unlock menu ;;
    cec) (($# == 0)) || die "Usage: $0 cec"; require_normal_user; run_script "$CEC_SH" menu ;;
    storage) (($# == 0)) || die "Usage: $0 storage"; run_script "$STORAGE_SH" menu ;;
    persistence) (($# == 0)) || die "Usage: $0 persistence"; run_script "$PERSISTENCE_SH" menu ;;
    wifi) (($# == 0)) || die "Usage: $0 wifi"; install_wifi ;;
    amdgpu|audio) (($# == 0)) || die "Usage: $0 amdgpu"; install_audio_fix ;;
    radv|mesh) (($# == 0)) || die "Usage: $0 radv"; require_normal_user; run_script "$MESH_SHADER_SH" menu ;;
    decky) (($# == 0)) || die "Usage: $0 decky"; install_decky ;;
    desktop) (($# == 0)) || die "Usage: $0 desktop"; install_desktop ;;
    trainer) (($# == 0)) || die "Usage: $0 trainer"; install_trainer ;;
    manage) (($# == 0)) || die "Usage: $0 manage"; run_script "$MAINTENANCE_SH" menu ;;
    help|-h|--help) (($# == 0)) || die "Usage: $0 help"; cmd_help ;;
    *) cmd_help >&2; exit 1 ;;
esac
