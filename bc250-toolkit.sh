#!/usr/bin/env bash
# Unified launcher for the BC-250 SteamOS management tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
POWER_SH="$SCRIPT_DIR/bc250-power.sh"
RAM_SPLIT_SH="$SCRIPT_DIR/bc250-ram-split.sh"
SWAP_SH="$SCRIPT_DIR/bc250-swap.sh"
COMPUTE_SH="$SCRIPT_DIR/bc250-40cu.sh"
CEC_SH="$SCRIPT_DIR/bc250-cec.sh"
STORAGE_SH="$SCRIPT_DIR/bc250-storage.sh"
PERSISTENCE_SH="$SCRIPT_DIR/bc250-update-persistence.sh"
CU_STATUS_SH="$SCRIPT_DIR/bc250-cu-status.sh"
AIC_SETUP_SH="$SCRIPT_DIR/aic8800/steamdeck-setup.sh"
FAN_SETUP_SH="$SCRIPT_DIR/nct6687d/steamdeck-setup.sh"
AUDIO_FIX_SH="$SCRIPT_DIR/bc250-audio-fix/patch-driver.sh"
AUDIO_CLEAN_SH="$SCRIPT_DIR/bc250-audio-fix/clean.sh"
AMDGPU_BOOT_CONFIG_SH="$SCRIPT_DIR/bc250-audio-fix/boot-config.sh"
HDMI_AC3_SH="$SCRIPT_DIR/hdmi-ac3/hdmi-ac3.sh"
MESH_SHADER_SH="$SCRIPT_DIR/bc250-mesh-shader.sh"
PROTON_SH="${BC250_PROTON_TOOL:-$SCRIPT_DIR/bc250-proton.sh}"
MEMORY_TEMP_SH="$SCRIPT_DIR/bc250-memory-temperature.sh"
DECKY_INSTALL_SH="$SCRIPT_DIR/decky-plugin/install.sh"
DESKTOP_INSTALL_SH="$SCRIPT_DIR/desktop-control/install.sh"
TRAINER_RELEASE_INSTALLER="$SCRIPT_DIR/trainer/install-release.py"
COOLERCONTROL_INSTALL_SH="$SCRIPT_DIR/coolercontrol/install.sh"
MAINTENANCE_SH="$SCRIPT_DIR/bc250-maintenance.sh"
TOOLKIT_VERSION="development"
if [[ -f "$SCRIPT_DIR/VERSION" && ! -L "$SCRIPT_DIR/VERSION" ]]; then
    TOOLKIT_VERSION=$(< "$SCRIPT_DIR/VERSION")
fi
[[ "$TOOLKIT_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || TOOLKIT_VERSION="development"

C0=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'; CI=$'\033[7m'
CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'; CC=$'\033[36m'
TUI_CURSOR_HIDDEN=0
SUDO_KEEPALIVE_PID=0

log() { echo "[bc250-toolkit] $*"; }
die() { echo "[bc250-toolkit] $*" >&2; exit 1; }

tui_show_cursor() {
    if [[ $TUI_CURSOR_HIDDEN -eq 1 ]]; then
        printf '\033[?25h'
        TUI_CURSOR_HIDDEN=0
    fi
}

toolkit_cleanup() {
    tui_show_cursor
    if [[ $SUDO_KEEPALIVE_PID -gt 0 ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        sudo -n -k >/dev/null 2>&1 || true
        SUDO_KEEPALIVE_PID=0
    fi
}
trap toolkit_cleanup EXIT

require_terminal() {
    [[ -t 0 && -t 1 ]] || die "This action requires an interactive terminal."
}

require_normal_user() {
    [[ $EUID -ne 0 ]] \
        || die "Run the toolkit as the logged-in Deck user, not with sudo. Child tools request administrator access when needed."
}

start_sudo_session() {
    [[ $SUDO_KEEPALIVE_PID -eq 0 ]] || return 0
    sudo -v
    local toolkit_pid=$$
    (
        while true; do
            sleep 45
            kill -0 "$toolkit_pid" 2>/dev/null || exit 0
            sudo -n -v >/dev/null 2>&1 || exit 0
        done
    ) </dev/null >/dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!
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

install_fan_driver() {
    require_normal_user
    require_script "$FAN_SETUP_SH"
    confirm_action \
        "Build and install the NCT6687 fan-control driver?" \
        sudo bash "$FAN_SETUP_SH" install
}

install_audio_fix() {
    require_normal_user
    require_script "$AUDIO_FIX_SH"
    confirm_action \
        "Build and install the matching AMDGPU kernel fixes?" \
        choose_dcn201_display_patches
}

choose_dcn201_display_patches() {
    local answer
    require_terminal
    printf '%s' "${CB}Include experimental DSC and HDMI 2.1 PCON support on kernel 7.2? This may cause display instability. [y/N] ${C0}"
    IFS= read -r answer
    case "$answer" in
        y|Y|yes|YES)
            bash "$AUDIO_FIX_SH" --acknowledge-dcn201-display-risk
            ;;
        *)
            log "Building without the experimental DSC/PCON patches."
            bash "$AUDIO_FIX_SH"
            ;;
    esac
}

clean_audio_fix() {
    require_normal_user
    require_script "$AUDIO_CLEAN_SH"
    confirm_action \
        "Clean the AMDGPU kernel source tree and preserved build output? Downloads and dependencies will be kept." \
        bash "$AUDIO_CLEAN_SH"
}

enable_hdmi_ac3() {
    require_normal_user
    require_script "$HDMI_AC3_SH"
    confirm_action \
        "Enable real-time Dolby Digital 5.1 encoding for HDMI/DisplayPort?" \
        bash "$HDMI_AC3_SH" install
}

revert_hdmi_ac3() {
    require_normal_user
    require_script "$HDMI_AC3_SH"
    confirm_action \
        "Remove the toolkit AC-3 profile and restore default HDMI stereo?" \
        bash "$HDMI_AC3_SH" revert
}

scheduler_policy_badge() {
    if [[ ! -f "$AMDGPU_BOOT_CONFIG_SH" || -L "$AMDGPU_BOOT_CONFIG_SH" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
    elif bash "$AMDGPU_BOOT_CONFIG_SH" configured 2>/dev/null; then
        if bash "$AMDGPU_BOOT_CONFIG_SH" active 2>/dev/null; then
            printf '%s' "${CG}[active]${C0}"
        else
            printf '%s' "${CY}[reboot needed]${C0}"
        fi
    elif bash "$AMDGPU_BOOT_CONFIG_SH" runlist-configured 2>/dev/null; then
        printf '%s' "${CD}[disabled]${C0}"
    elif bash "$AMDGPU_BOOT_CONFIG_SH" present 2>/dev/null; then
        printf '%s' "${CY}[incomplete]${C0}"
    else
        printf '%s' "${CD}[disabled]${C0}"
    fi
}

kfd_runlist_supported() {
    command -v modinfo >/dev/null 2>&1 \
        && modinfo -p amdgpu 2>/dev/null | grep -q '^bc250_flush_by_runlist:'
}

kfd_runlist_badge() {
    if [[ ! -f "$AMDGPU_BOOT_CONFIG_SH" || -L "$AMDGPU_BOOT_CONFIG_SH" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
    elif ! kfd_runlist_supported; then
        printf '%s' "${CY}[rebuild required]${C0}"
    elif bash "$AMDGPU_BOOT_CONFIG_SH" runlist-configured 2>/dev/null; then
        if bash "$AMDGPU_BOOT_CONFIG_SH" runlist-active 2>/dev/null; then
            printf '%s' "${CG}[active]${C0}"
        else
            printf '%s' "${CY}[reboot needed]${C0}"
        fi
    elif bash "$AMDGPU_BOOT_CONFIG_SH" configured 2>/dev/null; then
        printf '%s' "${CD}[blocked by policy 2]${C0}"
    elif bash "$AMDGPU_BOOT_CONFIG_SH" present 2>/dev/null; then
        printf '%s' "${CY}[incomplete]${C0}"
    else
        printf '%s' "${CD}[disabled]${C0}"
    fi
}

component_badge() {
    local script="$1" command="${2:-installed}"
    if [[ ! -f "$script" || -L "$script" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
    elif bash "$script" "$command" >/dev/null 2>&1; then
        printf '%s' "${CG}[installed]${C0}"
    else
        printf '%s' "${CD}[not installed]${C0}"
    fi
}

power_foundation_badge() {
    if [[ ! -f "$POWER_SH" || -L "$POWER_SH" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
    elif [[ -f /etc/systemd/system/bc250-acpi-heal.service \
        && -f /etc/systemd/system/bc250-cpufreq.service ]] \
        && systemctl is-active --quiet cyan-skillfish-governor-smu.service 2>/dev/null \
        && systemctl is-enabled --quiet cyan-skillfish-governor-smu.service 2>/dev/null; then
        printf '%s' "${CG}[active]${C0}"
    elif [[ -f /etc/systemd/system/bc250-acpi-heal.service \
        || -f /etc/systemd/system/bc250-cpufreq.service ]] \
        || systemctl cat cyan-skillfish-governor-smu.service >/dev/null 2>&1; then
        printf '%s' "${CY}[continue setup]${C0}"
    else
        printf '%s' "${CD}[not installed]${C0}"
    fi
}

amdgpu_badge() {
    local status=""
    if [[ ! -f "$AUDIO_FIX_SH" || -L "$AUDIO_FIX_SH" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
        return
    fi
    if ! status=$(bash "$AUDIO_FIX_SH" status-json 2>/dev/null); then
        printf '%s' "${CR}[status unavailable]${C0}"
        return
    fi
    case "$(json_field "$status" state || true)" in
        ready) printf '%s' "${CG}[active]${C0}" ;;
        reboot-required) printf '%s' "${CY}[reboot needed]${C0}" ;;
        invalid) printf '%s' "${CY}[repair needed]${C0}" ;;
        not-installed) printf '%s' "${CD}[not installed]${C0}" ;;
        *) printf '%s' "${CR}[status unavailable]${C0}" ;;
    esac
}

hdmi_ac3_badge() {
    local status=""
    if [[ ! -f "$HDMI_AC3_SH" || -L "$HDMI_AC3_SH" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
        return
    fi
    status=$(bash "$HDMI_AC3_SH" status 2>/dev/null || true)
    case "$status" in
        *"state: active"*) printf '%s' "${CG}[active]${C0}" ;;
        *"state: configured"*) printf '%s' "${CY}[configured]${C0}" ;;
        *"state: incomplete"*) printf '%s' "${CY}[incomplete]${C0}" ;;
        *) printf '%s' "${CD}[not installed]${C0}" ;;
    esac
}

fan_driver_badge() {
    local status=""
    if [[ ! -f "$FAN_SETUP_SH" || -L "$FAN_SETUP_SH" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
        return
    fi
    status=$(bash "$FAN_SETUP_SH" status 2>/dev/null || true)
    case "$status" in
        *"state: installed"*) printf '%s' "${CG}[installed]${C0}" ;;
        *"state: incomplete"*) printf '%s' "${CY}[incomplete]${C0}" ;;
        *) printf '%s' "${CD}[not installed]${C0}" ;;
    esac
}

radv_badge() {
    local status="" runtime_state kernel_ready scheduler_configured scheduler_active global_enabled
    if [[ ! -f "$MESH_SHADER_SH" || -L "$MESH_SHADER_SH" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
        return
    fi
    if ! status=$(bash "$MESH_SHADER_SH" status-json 2>/dev/null); then
        printf '%s' "${CR}[status unavailable]${C0}"
        return
    fi
    runtime_state=$(json_field "$status" runtimeState || true)
    kernel_ready=$(json_field "$status" kernelReady || true)
    scheduler_configured=$(json_field "$status" schedulerConfigured || true)
    scheduler_active=$(json_field "$status" schedulerActive || true)
    global_enabled=$(json_field "$status" globalEnabled || true)
    case "$runtime_state:$kernel_ready:$scheduler_configured:$scheduler_active:$global_enabled" in
        ready:true:true:true:true) printf '%s' "${CG}[active]${C0}" ;;
        ready:true:true:false:*) printf '%s' "${CY}[reboot needed]${C0}" ;;
        ready:true:true:true:false) printf '%s' "${CY}[sign-out needed]${C0}" ;;
        ready:*) printf '%s' "${CY}[repair needed]${C0}" ;;
        invalid:*) printf '%s' "${CY}[repair needed]${C0}" ;;
        *) printf '%s' "${CD}[not installed]${C0}" ;;
    esac
}

proton_badge() {
    local status=""
    if [[ ! -f "$PROTON_SH" || -L "$PROTON_SH" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
        return
    fi
    status=$(bash "$PROTON_SH" status 2>/dev/null || true)
    case "$status" in
        *"state: installed"*) printf '%s' "${CG}[installed]${C0}" ;;
        *"state: upgrade-required"*) printf '%s' "${CY}[update available]${C0}" ;;
        *"state: incomplete"*) printf '%s' "${CR}[repair needed]${C0}" ;;
        *) printf '%s' "${CD}[not installed]${C0}" ;;
    esac
}

install_proton() {
    require_normal_user
    require_script "$PROTON_SH"
    confirm_action \
        "Download and install the pinned BC-250 GE-Proton build with FSR4?" \
        bash "$PROTON_SH" install
}

update_proton() {
    require_normal_user
    require_script "$PROTON_SH"
    confirm_action \
        "Verify and update the BC-250 GE-Proton compatibility tool?" \
        bash "$PROTON_SH" update
}

uninstall_proton() {
    require_normal_user
    require_script "$PROTON_SH"
    confirm_action \
        "Remove BC-250 GE-Proton while preserving Steam prefixes and saves?" \
        bash "$PROTON_SH" uninstall
}

json_field() {
    local json="$1" key="$2" tail
    tail=${json#*\"$key\":}
    [[ "$tail" != "$json" ]] || return 1
    if [[ "$tail" == \"* ]]; then
        tail=${tail#\"}
        printf '%s' "${tail%%\"*}"
    else
        tail=${tail%%,*}
        tail=${tail%%\}*}
        printf '%s' "$tail"
    fi
}

power_foundation_installed() {
    bash "$POWER_SH" foundation-ready >/dev/null 2>&1
}

show_auto_base_installation_plan() {
    printf '%s\n' "${CB}${CC}Auto Base Toolkit Installation${C0}"
    printf '%s\n' "  Installs or repairs:"
    printf '%s\n' "    - Power foundation (ACPI and test-started GPU governor)"
    printf '%s\n' "    - RAM / VRAM helper (no memory split is selected automatically)"
    printf '%s\n' "    - AMDGPU kernel fixes"
    printf '%s\n' "    - Mesa / RADV async compute and its scheduler policy"
    printf '%s\n' "    - Required signed packages, storage, and update protection"
    printf '%s\n' "  Excludes hardware unlocks, tuning, swap, device-specific drivers, interfaces, and FSR4."
    printf '%s\n' "  Re-run this same option after each requested reboot to resume."
}

show_graphics_setup_plan() {
    printf '%s\n' "${CB}${CC}Async-compute graphics installation${C0}"
    printf '%s\n' "  Installs or repairs AMDGPU kernel fixes, Mesa / RADV async compute,"
    printf '%s\n' "  its scheduler policy, and required signed SteamOS packages."
    printf '%s\n' "  Re-run this same option after each requested reboot to resume."
}

run_graphics_setup() {
    require_normal_user
    require_script "$AUDIO_FIX_SH"
    require_script "$MESH_SHADER_SH"
    local amdgpu_json amdgpu_state radv_json runtime_state
    local scheduler_configured scheduler_active global_enabled

    amdgpu_json=$(bash "$AUDIO_FIX_SH" status-json 2>/dev/null) \
        || die "Could not determine current-kernel AMDGPU state."
    amdgpu_state=$(json_field "$amdgpu_json" state || true)
    case "$amdgpu_state" in
        not-installed)
            log "Installing the AMDGPU prerequisite for the async-compute stack."
            bash "$AUDIO_FIX_SH"
            amdgpu_json=$(bash "$AUDIO_FIX_SH" status-json 2>/dev/null) \
                || die "AMDGPU installation completed, but its state could not be verified."
            amdgpu_state=$(json_field "$amdgpu_json" state || true)
            ;;
        reboot-required|ready) ;;
        invalid) die "Current-kernel AMDGPU state is incomplete or unsafe. Review '$AUDIO_FIX_SH status' before continuing." ;;
        *) die "Unknown current-kernel AMDGPU state: ${amdgpu_state:-unavailable}" ;;
    esac

    if [[ "$amdgpu_state" == reboot-required ]]; then
        log "CHECKPOINT: Reboot to activate the AMDGPU kernel fixes, then run this graphics setup again."
        return 0
    fi
    [[ "$amdgpu_state" == ready ]] \
        || die "AMDGPU installation did not reach a safe reboot or active state."

    # Setup is idempotent and performs ownership checks before mutation. Let it
    # repair python and other prerequisites before asking it for JSON status.
    bash "$MESH_SHADER_SH" setup
    radv_json=$(bash "$MESH_SHADER_SH" status-json 2>/dev/null) \
        || die "Mesa / RADV setup completed, but its state could not be verified."

    runtime_state=$(json_field "$radv_json" runtimeState || true)
    scheduler_configured=$(json_field "$radv_json" schedulerConfigured || true)
    scheduler_active=$(json_field "$radv_json" schedulerActive || true)
    global_enabled=$(json_field "$radv_json" globalEnabled || true)
    [[ "$runtime_state" == ready && "$scheduler_configured" == true ]] \
        || die "Mesa / RADV setup did not produce a complete, safely gated runtime."
    if [[ "$scheduler_active" != true ]]; then
        log "CHECKPOINT: Reboot to activate the scheduler policy and Mesa / RADV together, then run this graphics setup again."
    elif [[ "$global_enabled" != true ]]; then
        log "CHECKPOINT: Sign out and back in so the graphical session inherits Mesa / RADV, then run this graphics setup again."
    else
        log "The async-compute graphics stack is active."
    fi
}

run_auto_base_installation() {
    require_normal_user
    require_script "$POWER_SH"
    require_script "$RAM_SPLIT_SH"
    require_script "$AUDIO_FIX_SH"
    require_script "$MESH_SHADER_SH"
    local amdgpu_json amdgpu_state radv_json ram_json ram_tool_state

    amdgpu_json=$(bash "$AUDIO_FIX_SH" status-json 2>/dev/null) \
        || die "Could not determine current-kernel AMDGPU state."
    amdgpu_state=$(json_field "$amdgpu_json" state || true)
    case "$amdgpu_state" in
        not-installed|reboot-required|ready) ;;
        invalid) die "Current-kernel AMDGPU state is incomplete or unsafe. Review '$AUDIO_FIX_SH status' before continuing." ;;
        *) die "Unknown current-kernel AMDGPU state: ${amdgpu_state:-unavailable}" ;;
    esac
    ram_json=$(bash "$RAM_SPLIT_SH" status-json 2>/dev/null) \
        || die "Could not determine RAM / VRAM helper state."
    ram_tool_state=$(json_field "$ram_json" toolState || true)
    case "$ram_tool_state" in
        verified|not-installed) ;;
        invalid) die "The existing RAM / VRAM helper is incomplete or unverified. Review '$RAM_SPLIT_SH status' before continuing." ;;
        *) die "Unknown RAM / VRAM helper state: ${ram_tool_state:-unavailable}" ;;
    esac
    if ! power_foundation_installed; then
        log "Installing the power foundation."
        sudo bash "$POWER_SH" all
        power_foundation_installed \
            || die "Power installation completed, but the foundation did not pass verification."
        log "The GPU governor is test-started only. Load-test it before enabling it at boot."
    fi
    if [[ "$ram_tool_state" == not-installed ]]; then
        log "Installing the RAM / VRAM helper."
        sudo bash "$RAM_SPLIT_SH" install
        ram_json=$(bash "$RAM_SPLIT_SH" status-json 2>/dev/null) \
            || die "RAM / VRAM helper installation completed, but its state could not be verified."
        [[ "$(json_field "$ram_json" toolState || true)" == verified ]] \
            || die "RAM / VRAM helper installation did not pass verification."
        log "No CMOS UMA or dynamic TTM value was selected automatically."
    fi

    run_graphics_setup

    amdgpu_json=$(bash "$AUDIO_FIX_SH" status-json 2>/dev/null || true)
    radv_json=$(bash "$MESH_SHADER_SH" status-json 2>/dev/null || true)
    ram_json=$(bash "$RAM_SPLIT_SH" status-json 2>/dev/null || true)
    if power_foundation_installed \
        && [[ "$(json_field "$ram_json" toolState || true)" == verified \
            && "$(json_field "$amdgpu_json" state || true)" == ready \
            && "$(json_field "$radv_json" globalEnabled || true)" == true ]]; then
        log "Auto Base Toolkit Installation is complete."
        show_status || true
    else
        log "Auto Base Toolkit Installation is safely paused. Re-run this option after the checkpoint above."
    fi
}

install_auto_base_installation() {
    show_auto_base_installation_plan
    echo
    confirm_action "Install or resume Auto Base Toolkit Installation?" run_auto_base_installation
}

toggle_scheduler_policy() {
    require_normal_user
    require_script "$AMDGPU_BOOT_CONFIG_SH"
    if bash "$AMDGPU_BOOT_CONFIG_SH" configured 2>/dev/null; then
        confirm_action \
            "Disable amdgpu.sched_policy=2? Global RADV async compute will remain inactive after reboot until re-enabled." \
            sudo bash "$AMDGPU_BOOT_CONFIG_SH" policy-remove
    elif bash "$AMDGPU_BOOT_CONFIG_SH" runlist-configured 2>/dev/null; then
        require_script "$MESH_SHADER_SH"
        local radv_json
        radv_json=$(bash "$MESH_SHADER_SH" status-json 2>/dev/null || true)
        [[ "$(json_field "$radv_json" runtimeState || true)" == ready \
            && "$(json_field "$radv_json" kernelReady || true)" == true ]] \
            || die "Install and activate the AMDGPU and Mesa / RADV async-compute stack before enabling amdgpu.sched_policy=2."
        confirm_action \
            "Enable amdgpu.sched_policy=2? This disables the incompatible KFD HWS runlist workaround and requires a reboot." \
            sudo bash "$AMDGPU_BOOT_CONFIG_SH" install
    elif bash "$AMDGPU_BOOT_CONFIG_SH" present 2>/dev/null; then
        die "Scheduler policy state is incomplete. Review '$AMDGPU_BOOT_CONFIG_SH status' before changing it."
    else
        require_script "$MESH_SHADER_SH"
        local radv_json
        radv_json=$(bash "$MESH_SHADER_SH" status-json 2>/dev/null || true)
        [[ "$(json_field "$radv_json" runtimeState || true)" == ready \
            && "$(json_field "$radv_json" kernelReady || true)" == true ]] \
            || die "Install and activate the AMDGPU and Mesa / RADV async-compute stack before enabling amdgpu.sched_policy=2."
        confirm_action \
            "Enable amdgpu.sched_policy=2 for the installed RADV async-compute patch? Reboot required." \
            sudo bash "$AMDGPU_BOOT_CONFIG_SH" install
    fi
}

toggle_kfd_runlist() {
    require_normal_user
    require_script "$AMDGPU_BOOT_CONFIG_SH"
    if bash "$AMDGPU_BOOT_CONFIG_SH" runlist-configured 2>/dev/null; then
        confirm_action \
            "Disable the experimental KFD HWS runlist TLB-flush workaround? A reboot is required." \
            sudo bash "$AMDGPU_BOOT_CONFIG_SH" runlist-remove
    elif bash "$AMDGPU_BOOT_CONFIG_SH" configured 2>/dev/null; then
        die "The workaround requires KFD hardware scheduling. Disable amdgpu.sched_policy=2 and reboot before enabling it."
    elif bash "$AMDGPU_BOOT_CONFIG_SH" present 2>/dev/null; then
        die "AMDGPU boot-option state is incomplete. Review '$AMDGPU_BOOT_CONFIG_SH status' before changing it."
    else
        kfd_runlist_supported \
            || die "The selected AMDGPU module lacks this workaround. Rebuild and reboot into the current toolkit module first."
        confirm_action \
            "Enable the experimental BC-250 KFD HWS runlist TLB-flush workaround? Use only for stale ROCm/KFD mappings. A reboot is required." \
            sudo bash "$AMDGPU_BOOT_CONFIG_SH" runlist-install
    fi
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
    require_script "$TRAINER_RELEASE_INSTALLER"
    confirm_action \
        "Download and install the latest BC250 Trainer release?" \
        python3 "$TRAINER_RELEASE_INSTALLER"
}

install_coolercontrol() {
    require_normal_user
    require_script "$COOLERCONTROL_INSTALL_SH"
    confirm_action \
        "Install or upgrade CoolerControl for the onboard fan controller?" \
        bash "$COOLERCONTROL_INSTALL_SH" install
}

run_machine_action() {
    (($# == 1)) || die "Usage: $0 action OPERATION_ID"
    require_normal_user
    local operation="$1"
    export BC250_TOOLKIT_MACHINE=1

    case "$operation" in
        auto-base-installation) run_auto_base_installation ;;
        graphics-setup) run_graphics_setup ;;
        storage-install) run_sudo_script "$STORAGE_SH" install ;;
        storage-repair) run_sudo_script "$STORAGE_SH" repair-infrastructure ;;
        power-install) run_sudo_script "$POWER_SH" all ;;
        ram-install) run_sudo_script "$RAM_SPLIT_SH" install ;;
        swap-zram-install) run_sudo_script "$SWAP_SH" install zram ;;
        swap-zswap-install) run_sudo_script "$SWAP_SH" install zswap ;;
        compute-build) run_sudo_script "$COMPUTE_SH" prep ;;
        ac3-install) run_script "$HDMI_AC3_SH" install ;;
        proton-install|proton-update) run_script "$PROTON_SH" "${operation#proton-}" ;;
        cec-setup) run_script "$CEC_SH" setup ;;
        cec-repair) run_script "$CEC_SH" repair ;;
        persistence-install) run_sudo_script "$PERSISTENCE_SH" install all ;;
        aic-install) run_sudo_script "$AIC_SETUP_SH" install ;;
        fan-install) run_sudo_script "$FAN_SETUP_SH" install ;;
        audio-build) run_script "$AUDIO_FIX_SH" ;;
        mesh-setup) run_script "$MESH_SHADER_SH" setup ;;
        decky-install) run_script "$DECKY_INSTALL_SH" install ;;
        desktop-install) run_script "$DESKTOP_INSTALL_SH" install ;;
        coolercontrol-install) run_script "$COOLERCONTROL_INSTALL_SH" install ;;
        persistence-remove) run_sudo_script "$PERSISTENCE_SH" remove all ;;
        storage-remove|power-remove|ram-remove|swap-remove|compute-remove|cec-remove|ac3-remove|proton-remove|aic-remove|fan-remove|audio-remove|mesh-remove|decky-remove|desktop-remove|coolercontrol-remove)
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

status_capture() {
    local output_name="$1" result_name="$2" output result=0
    shift 2
    output=$("$@" 2>&1) || result=$?
    printf -v "$output_name" '%s' "$output"
    printf -v "$result_name" '%s' "$result"
}

status_script_capture() {
    local output_name="$1" result_name="$2" privilege="$3" script="$4"
    shift 4
    if [[ ! -f "$script" || -L "$script" ]]; then
        printf -v "$output_name" '%s' "Component is missing or unsafe: $script"
        printf -v "$result_name" '%s' 126
    elif [[ "$privilege" == root ]]; then
        status_capture "$output_name" "$result_name" sudo bash "$script" "$@"
    else
        status_capture "$output_name" "$result_name" bash "$script" "$@"
    fi
}

status_value() {
    local output="$1" key="$2" line value
    while IFS= read -r line; do
        if [[ "$line" == *"$key"* ]]; then
            value=${line#*"$key"}
            value=${value#"${value%%[![:space:]]*}"}
            value=${value%"${value##*[![:space:]]}"}
            printf '%s' "$value"
            return 0
        fi
    done <<< "$output"
    return 1
}

status_heading() {
    printf '\n%s%s%s\n' "${CB}${CC}" "$1" "$C0"
}

status_row() {
    local label="$1" state="$2" tone="$3" detail="$4" color
    case "$tone" in
        good) color="$CG" ;;
        warn) color="$CY" ;;
        bad) color="$CR" ;;
        *) color="$CD" ;;
    esac
    printf '  %-30s %s%-16s%s %s\n' "$label" "$color" "[$state]" "$C0" "$detail"
}

show_status() {
    require_normal_user
    local failed=0 failed_list="" state detail secondary
    local storage_output="" storage_rc=0 power_output="" power_rc=0
    local ram_output="" ram_rc=0 swap_output="" swap_rc=0
    local persistence_output="" persistence_rc=0 cpu_output="" cpu_rc=0
    local amdgpu_output="" amdgpu_rc=0 radv_output="" radv_rc=0
    local proton_output="" proton_rc=0
    local cu_output="" cu_rc=0 cec_output="" cec_rc=0
    local cec_bus_output="" cec_bus_rc=0
    local fan_output="" fan_rc=0
    local enabled active mode installed_count pending_count
    local failed_components=()
    sudo -v

    status_script_capture storage_output storage_rc user "$STORAGE_SH" status
    status_script_capture power_output power_rc user "$POWER_SH" status
    status_script_capture ram_output ram_rc user "$RAM_SPLIT_SH" status
    status_script_capture swap_output swap_rc root "$SWAP_SH" verify
    status_script_capture persistence_output persistence_rc user "$PERSISTENCE_SH" status
    status_script_capture cpu_output cpu_rc root "$POWER_SH" cpu-unlock status
    status_script_capture amdgpu_output amdgpu_rc user "$AUDIO_FIX_SH" status-json
    status_script_capture radv_output radv_rc user "$MESH_SHADER_SH" status-json
    status_script_capture proton_output proton_rc user "$PROTON_SH" status
    status_script_capture cu_output cu_rc root "$CU_STATUS_SH" -q
    status_script_capture cec_output cec_rc user "$CEC_SH" status
    status_script_capture cec_bus_output cec_bus_rc user "$CEC_SH" scan
    status_script_capture fan_output fan_rc user "$FAN_SETUP_SH" status

    printf '%s\n' "${CB}${CC}BC-250 system health ${CD}[${TOOLKIT_VERSION}]${C0}"

    status_heading "CORE SYSTEM"
    state=$(status_value "$storage_output" "storage: " || true)
    secondary=$(status_value "$storage_output" "backing data: " || true)
    if [[ $storage_rc -eq 0 ]]; then
        status_row "Persistent storage" "${state:-ready}" good \
            "${secondary:+backing data $secondary}"
    else
        status_row "Persistent storage" "failed" bad "${state:-status unavailable}"
        failed=1; failed_components+=("Persistent storage")
    fi

    state=$(status_value "$ram_output" "CMOS minimum VRAM: " || true)
    secondary=$(status_value "$ram_output" "TTM configured: " || true)
    if [[ $ram_rc -eq 0 ]]; then
        state=${state%% (*}
        if [[ "$secondary" == *"("* ]]; then
            secondary=${secondary#*(}
            secondary=${secondary%)}
        fi
        status_row "RAM / VRAM split" "configured" good "VRAM ${state:-ready}; TTM ${secondary:-ready}"
    else
        status_row "RAM / VRAM split" "incomplete" bad "${state:-status unavailable}"
        failed=1; failed_components+=("RAM / VRAM split")
    fi

    state=$(status_value "$swap_output" "configured: " || true)
    secondary=$(status_value "$swap_output" "runtime: " || true)
    if [[ $swap_rc -eq 0 ]]; then
        status_row "Compressed swap" "${state:-ready}" good "runtime ${secondary:-active}"
    elif [[ $swap_rc -eq 1 && "${state:-none}" == none ]]; then
        status_row "Compressed swap" "disabled" dim "optional; runtime ${secondary:-inactive}"
    else
        status_row "Compressed swap" "incomplete" bad "configured ${state:-unknown}; runtime ${secondary:-unknown}"
        failed=1; failed_components+=("Compressed swap")
    fi

    installed_count=$(grep -c 'keep list: installed' <<< "$persistence_output" || true)
    pending_count=$(grep -Ec 'keep list: (stale|foreign)' <<< "$persistence_output" || true)
    if [[ $persistence_rc -ne 0 ]]; then
        status_row "SteamOS update protection" "failed" bad "status unavailable"
        failed=1; failed_components+=("SteamOS update persistence")
    elif [[ $pending_count -gt 0 ]]; then
        status_row "SteamOS update protection" "attention" warn "$installed_count protected; $pending_count stale or foreign"
        failed=1; failed_components+=("SteamOS update persistence")
    elif [[ $installed_count -gt 0 ]]; then
        status_row "SteamOS update protection" "protected" good "$installed_count managed component lists"
    else
        status_row "SteamOS update protection" "not configured" dim "no managed component lists"
    fi

    status_heading "POWER FOUNDATION"
    enabled=$(systemctl is-enabled cyan-skillfish-governor-smu.service 2>/dev/null || true)
    active=$(systemctl is-active cyan-skillfish-governor-smu.service 2>/dev/null || true)
    detail=$(status_value "$power_output" "saved freq setting (reapplied at boot): " || true)
    if [[ "$detail" =~ ^MODE=range[[:space:]]+A=([0-9]+)[[:space:]]+B=([0-9]+)$ ]]; then
        detail="${BASH_REMATCH[1]}-${BASH_REMATCH[2]} MHz saved range"
    elif [[ "$detail" =~ ^MODE=pin[[:space:]]+A=([0-9]+)[[:space:]]+B=$ ]]; then
        detail="${BASH_REMATCH[1]} MHz saved pin"
    elif [[ "$detail" =~ ^MODE=max[[:space:]]+A=[[:space:]]+B=$ ]]; then
        detail="saved maximum-frequency mode"
    else
        detail=$(status_value "$power_output" "max MHz: " || true)
    fi
    if [[ "$enabled" == enabled && "$active" == active ]]; then
        status_row "GPU governor" "active" good "${detail:-enabled at boot}"
    elif [[ -n "$enabled$active" && "$enabled$active" != not-foundinactive ]]; then
        status_row "GPU governor" "partial" warn "${enabled:--} / ${active:--}; ${detail:-no clock data}"
    else
        status_row "GPU governor" "disabled" dim "not installed"
    fi

    enabled=$(systemctl is-active bc250-acpi-heal.service 2>/dev/null || true)
    active=$(systemctl is-active bc250-cpufreq.service 2>/dev/null || true)
    state=$(status_value "$power_output" "governor: " || true)
    secondary=$(status_value "$power_output" "current:  " || true)
    if [[ "$enabled" == active && "$active" == active ]]; then
        status_row "CPU ACPI / freq" "active" good "${state:-cpufreq ready}${secondary:+; $secondary}"
    else
        status_row "CPU ACPI / freq" "incomplete" warn "ACPI $enabled; cpufreq $active"
    fi

    enabled=$(systemctl is-enabled bc250-smu-oc.service 2>/dev/null || true)
    active=$(systemctl is-active bc250-smu-oc.service 2>/dev/null || true)
    if [[ "$enabled" == enabled && "$active" == active ]]; then
        status_row "CPU overclock" "active" good "enabled at boot"
    elif [[ "$enabled" == enabled || "$active" == active ]]; then
        status_row "CPU overclock" "partial" warn "${enabled:--} / ${active:--}"
    else
        status_row "CPU overclock" "disabled" dim "stock tuning"
    fi

    state=$(status_value "$power_output" "Tctl:" || true)
    detail=$(status_value "$power_output" "edge:" || true)
    secondary=$(status_value "$power_output" "PPT:" || true)
    if [[ -n "$state$detail$secondary" ]]; then
        status_row "Thermals" "live" good "CPU ${state:--}; GPU ${detail:--}; PPT ${secondary:--}"
    else
        status_row "Thermals" "unavailable" dim "sensor data not exposed"
    fi

    state=$(status_value "$cpu_output" "automatic unlock: " || true)
    detail=$(status_value "$cpu_output" "CPU topology: " || true)
    secondary=$(status_value "$cpu_output" "unlock attempt/reboot guard: " || true)
    if [[ $cpu_rc -ne 0 || -z "$detail" ]]; then
        status_row "CPU core unlock" "unavailable" bad "${detail:-status probe failed}"
        failed=1; failed_components+=("CPU core unlock")
    elif [[ "$detail" == *"(unlocked)"* ]]; then
        status_row "CPU core unlock" "unlocked" good "$detail; ${state:-mode unknown}${secondary:+; guard $secondary}"
    elif [[ "$detail" == *"(locked)"* && "${state:-disabled}" == disabled ]]; then
        status_row "CPU core unlock" "stock" dim "$detail; automatic unlock disabled"
    elif [[ "$detail" == *"(locked)"* ]]; then
        status_row "CPU core unlock" "reboot needed" warn "$detail; ${state:-mode unknown}${secondary:+; guard $secondary}"
    else
        status_row "CPU core unlock" "unexpected" bad "$detail; ${state:-mode unknown}"
        failed=1; failed_components+=("CPU core unlock")
    fi

    if [[ $power_rc -ne 0 ]]; then
        failed=1; failed_components+=("Power management")
    fi

    state=$(status_value "$fan_output" "state: " || true)
    detail=$(status_value "$fan_output" "hwmon: " || true)
    secondary=$(status_value "$fan_output" "load option: " || true)
    case "$state" in
        installed) status_row "NCT6687 fan-control driver" "installed" good "hwmon ${detail:--}; ${secondary:-force=0}" ;;
        not-installed) status_row "NCT6687 fan-control driver" "not installed" dim "onboard controller uses firmware control" ;;
        *)
            status_row "NCT6687 fan-control driver" "${state:-incomplete}" bad "${detail:+hwmon $detail; }${secondary:-status unavailable}"
            failed=1; failed_components+=("NCT6687 fan-control driver") ;;
    esac

    status_heading "GRAPHICS STACK"
    state=$(json_field "$amdgpu_output" state || true)
    case "$state" in
        ready) status_row "AMDGPU kernel fixes" "active" good "patched module loaded for $(json_field "$amdgpu_output" runningKernel || true)" ;;
        reboot-required) status_row "AMDGPU kernel fixes" "reboot needed" warn "installed and selected for the running kernel" ;;
        not-installed) status_row "AMDGPU kernel fixes" "not installed" dim "stock kernel module" ;;
        *)
            status_row "AMDGPU kernel fixes" "${state:-incomplete}" bad "current-kernel module state is invalid"
            failed=1; failed_components+=("AMDGPU kernel fixes") ;;
    esac

    state=$(json_field "$radv_output" runtimeState || true)
    enabled=$(json_field "$radv_output" schedulerConfigured || true)
    active=$(json_field "$radv_output" schedulerActive || true)
    if [[ $radv_rc -ne 0 \
        || ( "$state" != ready && "$state" != not-installed && "$state" != invalid ) ]]; then
        status_row "AMDGPU scheduler policy" "unavailable" bad "Mesa / RADV status probe failed"
        status_row "Mesa / RADV async compute" "unavailable" bad "status probe failed"
        failed=1; failed_components+=("Mesa / RADV async compute")
    else
        if [[ "$active" == true ]]; then
            status_row "AMDGPU scheduler policy" "active" good "managed by Mesa / RADV setup"
        elif [[ "$enabled" == true ]]; then
            status_row "AMDGPU scheduler policy" "reboot needed" warn "configured for the next boot"
            failed=1; failed_components+=("AMDGPU scheduler policy")
        else
            status_row "AMDGPU scheduler policy" "disabled" dim "enabled automatically with Mesa / RADV"
        fi
        detail=$(json_field "$radv_output" globalEnabled || true)
        if [[ "$state" == ready && "$detail" == true ]]; then
            status_row "Mesa / RADV async compute" "active" good "global user environment enabled"
        elif [[ "$state" == ready && "$active" == true ]]; then
            status_row "Mesa / RADV async compute" "sign-out needed" warn "runtime installed; session environment is stale"
            failed=1; failed_components+=("Mesa / RADV async compute")
        elif [[ "$state" == ready ]]; then
            status_row "Mesa / RADV async compute" "reboot needed" warn "runtime installed; scheduler policy is not active"
            failed=1; failed_components+=("Mesa / RADV async compute")
        elif [[ "$state" == not-installed ]]; then
            status_row "Mesa / RADV async compute" "not installed" dim "optional global runtime"
        else
            status_row "Mesa / RADV async compute" "incomplete" bad "$state"
            failed=1; failed_components+=("Mesa / RADV async compute")
        fi
    fi

    state=$(status_value "$proton_output" "state: " || true)
    case "$state" in
        installed) status_row "BC-250 GE-Proton" "installed" good "FSR4 compatibility tool" ;;
        not-installed) status_row "BC-250 GE-Proton" "not installed" dim "optional integrated FSR4 route" ;;
        upgrade-required)
            status_row "BC-250 GE-Proton" "update needed" warn "run proton-update"
            failed=1; failed_components+=("BC-250 GE-Proton") ;;
        incomplete)
            status_row "BC-250 GE-Proton" "incomplete" bad "repair or remove the recorded compatibility tool"
            failed=1; failed_components+=("BC-250 GE-Proton") ;;
        *)
            status_row "BC-250 GE-Proton" "unavailable" bad "status probe failed (exit $proton_rc)"
            failed=1; failed_components+=("BC-250 GE-Proton") ;;
    esac

    if [[ $cu_rc -ne 0 ]]; then
        status_row "GPU compute-unit unlock" "unavailable" bad "${cu_output:-register read failed}"
        failed=1; failed_components+=("GPU compute-unit unlock")
    elif [[ "$cu_output" == 40/40 ]]; then
        status_row "GPU compute-unit unlock" "40 / 40" good "all compute units routed"
    else
        status_row "GPU compute-unit unlock" "${cu_output:-unknown}" warn "current hardware route"
    fi

    status_heading "DISPLAY"
    state=$(status_value "$cec_output" "cecd.service: " || true)
    detail=$(status_value "$cec_output" "aggregate integration: " || true)
    secondary=$(status_value "$cec_output" "poweroff standby unit: " || true)
    enabled=$(status_value "$cec_output" "boot wake unit (user): " || true)
    mode=$(status_value "$cec_output" "boot wake mode: " || true)
    if [[ $cec_rc -ne 0 ]]; then
        status_row "CEC setup & automation" "unavailable" bad "status probe failed"
        failed=1; failed_components+=("CEC")
    elif [[ "$state" == *active* ]]; then
        if [[ "$detail" == installed ]]; then
            status_row "CEC setup & automation" "configured" good "pre-installed CEC active"
        else
            status_row "CEC setup & automation" "defaults" dim \
                "pre-installed CEC active; optional automation not configured"
        fi
        case "$secondary" in
            *enabled*|*active*) status_row "  Poweroff standby" "enabled" good "TV standby during system shutdown" ;;
            *disabled*|*inactive*|*not-found*) status_row "  Poweroff standby" "disabled" dim "optional automation" ;;
            *) status_row "  Poweroff standby" "unknown" warn "${secondary:-state unavailable}" ;;
        esac
        case "$enabled" in
            *enabled*|*active*) status_row "  Boot wake" "enabled" good "TV wake at session start" ;;
            *disabled*|*inactive*|*not-found*) status_row "  Boot wake" "disabled" dim "optional automation" ;;
            *) status_row "  Boot wake" "unknown" warn "${enabled:-state unavailable}" ;;
        esac
        case "$mode" in
            polite) status_row "  Boot wake mode" "polite" good "backs off when another source is active" ;;
            grab) status_row "  Boot wake mode" "grab" warn "always takes the TV input at session start" ;;
            not-installed) status_row "  Boot wake mode" "not installed" dim "install boot wake to choose a mode" ;;
            *) status_row "  Boot wake mode" "unknown" warn "helper mode could not be verified" ;;
        esac
    elif [[ "$cec_output" == *"/dev/cec0: present"* ]]; then
        status_row "CEC setup & automation" "available" warn "daemon ${state:-inactive}"
    else
        status_row "CEC setup & automation" "not available" dim "no active CEC adapter"
    fi

    status_heading "CEC BUS MAP"
    if [[ $cec_bus_rc -eq 0 && -n "$cec_bus_output" ]]; then
        printf '%s\n' "$cec_bus_output"
    else
        status_row "CEC bus" "unavailable" warn "${cec_bus_output:-no bus map returned}"
    fi

    if [[ $failed -ne 0 ]]; then
        printf -v failed_list '%s, ' "${failed_components[@]}"
        printf '\n%s\n' "${CR}${CB}OVERALL  [attention required]${C0} ${failed_list%, }"
    else
        printf '\n%s\n' "${CG}${CB}OVERALL  [healthy]${C0} All configured components passed their checks."
    fi
    return "$failed"
}

menu_select() {
    local title="$1"
    shift
    local items=("$@") n=$# cur=0 key rest i label badge hint exit_label=back label_width=0
    [[ "$title" == BC-250\ SteamOS\ toolkit* ]] && exit_label=quit
    for i in "${!items[@]}"; do
        IFS='|' read -r label badge hint <<< "${items[$i]}"
        if ((${#label} > label_width)); then label_width=${#label}; fi
    done
    printf '\033[?25l'
    TUI_CURSOR_HIDDEN=1
    while true; do
        printf '\033[H\033[2J'
        printf '\r\033[K%s\n' "${CB}${CC}${title}${C0}"
        printf '\033[K%s\n' "${CB}${CC}  CONTROLS  [Up/Down or J/K] Move  [Enter] Select  [Q/Esc] ${exit_label^}${C0}"
        printf '\033[K\n'
        for i in "${!items[@]}"; do
            IFS='|' read -r label badge hint <<< "${items[$i]}"
            if [[ $i -eq $cur ]]; then
                printf '\033[K  %s > %-*s %s %s\n' "${CI}${CB}" "$label_width" "$label" "${C0}" "$badge"
            else
                printf '\033[K     %-*s  %s\n' "$label_width" "$label" "$badge"
            fi
        done
        IFS='|' read -r label badge hint <<< "${items[$cur]}"
        printf '\033[K\n\033[K%s\n' "  ${CD}${hint}${C0}"
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
        if [[ ${1:-} == status ]]; then
            printf '%s\n' "${CR}${CB}[bc250-toolkit]${C0} system status is incomplete (exit $rc)"
        else
            printf '%s\n' "${CR}${CB}[bc250-toolkit]${C0} action failed (exit $rc)"
        fi
    fi
    pause_key
}

run_confirmed_menu_action() {
    local prompt="$1" rc=0
    shift
    echo
    confirm_action "$prompt" "$@" || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s\n' "${CR}${CB}[bc250-toolkit]${C0} action failed (exit $rc)"
    fi
    pause_key
}

show_guided_setup_overview() {
    echo
    printf '%s\n' "${CB}${CC}BC-250 guided setup${C0}"
    printf '%s\n' "Start with the hardware unlock you care about, then complete its supporting setup."
    printf '%s\n' "Each unlock has its own test and recovery path; performance tuning comes afterward."
    echo
    printf '  %-24s %s\n' "GPU compute-unit unlock" "$(component_badge "$COMPUTE_SH")"
    printf '  %-24s %s\n' "CPU core unlock" "${CD}[guided test]${C0}"
    printf '  %-24s %s\n' "AMDGPU kernel fixes" "$(amdgpu_badge)"
    printf '  %-24s %s\n' "Power foundation" "$(power_foundation_badge)"
    printf '  %-24s %s\n' "RAM / VRAM split" "$(component_badge "$RAM_SPLIT_SH")"
    printf '  %-24s %s\n' "Mesa / RADV async compute" "$(radv_badge)"
    printf '  %-24s %s\n' "BC-250 GE-Proton" "$(proton_badge)"
    printf '  %-24s %s\n' "Compressed swap" "$(component_badge "$SWAP_SH")"
    echo
    printf '  %-24s %s\n' "Persistent storage" "$(component_badge "$STORAGE_SH")"
    printf '%s\n' "  Persistent storage is installed automatically by components that need it."
    echo
    printf '%s\n' "${CY}Checkpoints:${C0} Reboot after AMDGPU, install RADV, then reboot again to enable async compute safely."
    printf '%s\n' "Power setup still requires an ACPI reboot and a load test before enabling the GPU governor at boot."
    pause_key
}

cmd_guided_setup_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "Setup overview|${CD}[read only]${C0}|Show the goal-first order, current component state, and restart checkpoints."
            "GPU compute-unit unlock|$(component_badge "$COMPUTE_SH")|Inspect the harvest map, test live routing, stress-test it, then choose whether to persist it."
            "CPU core unlock|${CD}[guided test]${C0}|Test eight cores once, then choose one automatic unlock method: standard Linux or EFI pre-boot. Install AMDGPU fixes afterward for corrected eight-core telemetry."
            "AMDGPU kernel fixes|$(amdgpu_badge)|Build the corrected kernel module, but leave sched_policy=2 off. Reboot before RADV setup."
            "Power foundation|$(power_foundation_badge)|Install ACPI, reboot, then load-test the GPU governor before enabling it at boot."
            "RAM / VRAM split|$(component_badge "$RAM_SPLIT_SH")|Install the helper, then choose CMOS minimum VRAM and the dynamic TTM limit."
            "Performance tuning|$(radv_badge)|Build the Mesa RADV async-compute patch or tune GPU and CPU behavior after unlock testing. RADV takes about 3-5 minutes."
            "Device drivers & connectivity||Configure HDMI audio, CEC, NCT6687 fan control, or hardware-specific AIC8800 support."
            "Choose control interface||Install Decky, Plasma, CoolerControl, or the standalone Trainer."
        )
        menu_select "BC-250 guided setup  ${CD}(choose by goal)${C0}" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) show_guided_setup_overview ;;
            1) run_menu_child compute ;;
            2) run_menu_child cpu-unlock ;;
            3) run_menu_action amdgpu ;;
            4) run_menu_child power ;;
            5) run_menu_child ram ;;
            6) cmd_performance_menu ;;
            7) cmd_devices_menu ;;
            8) cmd_interfaces_menu ;;
        esac
    done
}

cmd_drivers_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "AMDGPU kernel fixes|${CY}[build]${C0}|Install the required kernel module first. sched_policy=2 stays off until the RADV patch is installed. Reboot afterward."
            "Clean AMDGPU build tree|${CY}[cleanup]${C0}|Reset patched source and generated build output while keeping cached downloads and dependencies."
            "AMDGPU scheduler policy (advanced)|$(scheduler_policy_badge)|Normally managed by RADV setup. Enabling is blocked until the patched RADV runtime is installed."
            "KFD HWS runlist TLB flush (experimental)|$(kfd_runlist_badge)|Opt-in ROCm workaround for stale mappings. Requires HWS and cannot coexist with sched_policy=2."
            "Install / resume async-compute stack|$(radv_badge)|Automatically installs AMDGPU first when needed, then resumes Mesa / RADV after reboot."
            "NCT6687 fan-control driver|$(fan_driver_badge)|Install Linux hwmon fan-speed and PWM support for the BC-250's onboard controller."
            "AIC8800 WiFi / Bluetooth|${CY}[installer]${C0}|Install only when the system uses the AIC8800 wireless adapter."
        )
        menu_select "BC-250 drivers" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action amdgpu ;;
            1) run_menu_action amdgpu-clean ;;
            2) run_menu_action scheduler-policy ;;
            3) run_menu_action kfd-runlist ;;
            4) run_menu_action graphics-setup ;;
            5) run_menu_action fan-driver ;;
            6) run_menu_action wifi ;;
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
            "Persistent storage|${CG}[menu]${C0}|Install, inspect, or repair the toolkit's persistent privileged storage and boot recovery."
            "SteamOS update protection|${CG}[menu]${C0}|Protect and recover supported component configuration across SteamOS updates."
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
            "CoolerControl|$(component_badge "$COOLERCONTROL_INSTALL_SH" status)|Control the BC-250's onboard fan controller with profiles, curves, and monitoring."
            "BC250 Trainer|${CY}[installer]${C0}|Install the standalone native Qt control application."
        )
        menu_select "BC-250 control interfaces" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action decky ;;
            1) run_menu_action desktop ;;
            2) run_menu_action coolercontrol ;;
            3) run_menu_action trainer ;;
        esac
    done
}

cmd_amdgpu_boot_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "AMDGPU scheduler policy|$(scheduler_policy_badge)|Normally managed automatically by Mesa / RADV setup."
            "KFD runlist workaround (experimental)|$(kfd_runlist_badge)|Opt-in ROCm workaround for stale mappings; cannot coexist with the RADV scheduler policy."
        )
        menu_select "BC-250 advanced AMDGPU boot options" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action scheduler-policy ;;
            1) run_menu_action kfd-runlist ;;
        esac
    done
}

cmd_core_system_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "Persistent storage|$(component_badge "$STORAGE_SH")|Installed automatically when needed; open for status, boot recovery, repair, or manual management."
            "AMDGPU kernel fixes|$(amdgpu_badge)|Install kernel-specific telemetry and GFX1013 async-compute fixes, plus display/audio corrections where required. Reboot afterward."
            "Advanced AMDGPU boot options|${CY}[advanced]${C0}|Inspect the RADV scheduler policy or experimental KFD runlist workaround."
            "Power foundation|$(power_foundation_badge)|Set up ACPI and the GPU governor. GPU and CPU tuning remains under Performance tuning."
            "RAM / VRAM split|$(component_badge "$RAM_SPLIT_SH")|Balance the persistent CMOS minimum and dynamic Linux TTM limit."
            "Compressed swap|$(component_badge "$SWAP_SH")|Choose mutually exclusive zram or zswap-backed disk swap profiles."
            "SteamOS update protection|${CG}[menu]${C0}|Protect installed integration and recover supported settings after updates."
        )
        menu_select "BC-250 core system" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_child storage ;;
            1) run_menu_action amdgpu ;;
            2) cmd_amdgpu_boot_menu ;;
            3) run_menu_child power ;;
            4) run_menu_child ram ;;
            5) run_menu_child swap ;;
            6) run_menu_child persistence ;;
        esac
    done
}

cmd_performance_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "Install / resume async-compute stack|$(radv_badge)|Automatically install AMDGPU first when needed, then resume Mesa / RADV after reboot."
            "GPU driver & FSR4 options|${CG}[menu]${C0}|Manage Mesa / RADV, portable FSR4 RC9 game DLLs, or cleanup."
            "GE-Proton with FSR4|$(proton_badge)|Install the pinned BC-250 GE build after FSR4 RADV is active; Steam prefixes and saves remain separate."
            "GPU / CPU tuning|${CG}[menu]${C0}|Adjust GPU clocks, load response, ramp behavior, and CPU undervolt/overclock."
            "GDDR6 memory temperature|${CY}[experimental]${C0}|Prepare, apply, read, or restore the P3.0-only live SMU temperature payload."
        )
        menu_select "BC-250 performance tuning" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action graphics-setup ;;
            1) run_menu_child radv ;;
            2) cmd_proton_menu ;;
            3) run_menu_child power ;;
            4) cmd_memory_temperature_menu ;;
        esac
    done
}

cmd_proton_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "Status|$(proton_badge)|Verify the pinned compatibility-tool version and required files."
            "Install|${CY}[731 MB download]${C0}|Require active FSR4 RADV, then install GE-Proton for the current user."
            "Update / repair|$(proton_badge)|Transactionally replace a recorded older or incomplete toolkit installation."
            "Uninstall|${CY}[preserves prefixes]${C0}|Remove only the compatibility tool; keep Steam prefixes, saves, and game data."
        )
        menu_select "BC-250 GE-Proton" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action proton-status ;;
            1) run_menu_action proton-install ;;
            2) run_menu_action proton-update ;;
            3) run_menu_action proton-uninstall ;;
        esac
    done
}

cmd_devices_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "HDMI audio|${CG}[menu]${C0}|Enable Dolby Digital 5.1 encoding or revert to the default HDMI stereo profile."
            "HDMI-CEC|${CG}[menu]${C0}|Review setup automation, everyday controls, and the live CEC bus."
            "NCT6687 fan-control driver|$(fan_driver_badge)|Install Linux hwmon fan-speed and PWM support for the BC-250's onboard controller."
            "AIC8800 WiFi / Bluetooth|${CY}[hardware specific]${C0}|Install only when the system uses the AIC8800 wireless adapter."
        )
        menu_select "BC-250 device drivers & connectivity" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) cmd_audio_menu ;;
            1) run_menu_child cec ;;
            2) run_menu_action fan-driver ;;
            3) run_menu_action wifi ;;
        esac
    done
}

cmd_memory_temperature_menu() {
    require_terminal
    require_normal_user
    require_script "$MEMORY_TEMP_SH"
    while true; do
        local items=(
            "Status|${CD}[read only]${C0}|Verify the pinned source and show whether an original-SMU backup is recorded."
            "Prepare verified source|${CY}[download]${C0}|Download the pinned upstream payload, source, README, and MIT license with fixed SHA-256 hashes."
            "Apply live SMU payload|${CR}[high risk]${C0}|Patch this SMU runtime only. Requires ASRock BC-250 P3.0 firmware and explicit acknowledgement."
            "Read GDDR6 temperatures|${CY}[live read]${C0}|Attest the payload, then read and validate MR3 data from all eight memory chips."
            "Restore original SMU bytes|${CR}[high risk]${C0}|Restore the recorded handler and overwritten bytes before purging state."
        )
        menu_select "BC-250 GDDR6 memory temperature" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action memory-temperature-status ;;
            1) run_confirmed_menu_action "Download and verify the pinned memory-temperature source?" \
                bash "$SELF" memory-temperature-prepare ;;
            2) run_confirmed_menu_action "Apply the P3.0-only live SMU payload? Memory corruption, data loss, crashes, and a required cold power cycle are possible." \
                bash "$SELF" memory-temperature-patch ;;
            3) run_menu_action memory-temperature-read ;;
            4) run_confirmed_menu_action "Restore the recorded original live SMU handler and bytes?" \
                bash "$SELF" memory-temperature-restore ;;
        esac
    done
}

cmd_audio_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "Enable HDMI AC-3 5.1|$(hdmi_ac3_badge)|Encode system audio as Dolby Digital 5.1. Requires the AMDGPU audio fix, an AC-3 receiver, and SteamOS audio packages."
            "Revert HDMI AC-3 to stereo|${CY}[revert]${C0}|Remove toolkit AC-3 configuration and restore the default HDMI stereo profile and sink."
        )
        menu_select "BC-250 HDMI audio" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action hdmi-ac3-enable ;;
            1) run_menu_action hdmi-ac3-revert ;;
        esac
    done
}

cmd_maintenance_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "SteamOS update recovery|${CG}[menu]${C0}|Inspect protection or restore supported settings from the newest update snapshot."
            "Clean AMDGPU build tree|${CY}[cleanup]${C0}|Reset patched source and build output while retaining downloads and dependencies."
            "Manage installed components|${CG}[menu]${C0}|Review removal plans, uninstall components, or permanently purge preserved data."
        )
        menu_select "BC-250 maintenance & recovery" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_child persistence ;;
            1) run_menu_action amdgpu-clean ;;
            2) run_menu_child manage ;;
        esac
    done
}

cmd_menu() {
    require_terminal
    require_normal_user
    start_sudo_session
    while true; do
        local items=(
            "Auto Base Toolkit Installation|${CG}[install / resume]${C0}|Install the safe foundation in dependency order; re-run this option after each requested reboot."
            "Manual guided setup|${CG}[menu]${C0}|Choose individual hardware goals and follow their support, reboot, load-test, and tuning checkpoints."
            "Core system|${CG}[menu]${C0}|Configure storage, AMDGPU, power foundations, memory balance, and update protection."
            "Performance tuning|${CG}[menu]${C0}|Configure Mesa / RADV and optional GPU or CPU tuning after setup is stable."
            "Hardware unlocks|${CG}[menu]${C0}|Test GPU compute units or CPU cores with explicit stability and recovery steps."
            "Device drivers & connectivity|${CG}[menu]${C0}|Configure HDMI audio, HDMI-CEC, NCT6687 fan control, or hardware-specific AIC8800 support."
            "Control interfaces|${CG}[menu]${C0}|Install Decky, Plasma, CoolerControl, or the standalone BC250 Trainer."
            "Maintenance & recovery|${CG}[menu]${C0}|Verify, repair, clean build state, remove components, or purge preserved data."
            "System health|${CD}[read only]${C0}|Show the operational state of configured components using the same names as their menu options."
        )
        menu_select "BC-250 SteamOS toolkit ${CD}[${TOOLKIT_VERSION}]${C0}" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action auto-base-installation ;;
            1) cmd_guided_setup_menu ;;
            2) cmd_core_system_menu ;;
            3) cmd_performance_menu ;;
            4) cmd_unlocks_menu ;;
            5) cmd_devices_menu ;;
            6) cmd_interfaces_menu ;;
            7) cmd_maintenance_menu ;;
            8) run_menu_action status ;;
        esac
    done
}

cmd_help() {
    cat << EOF
Usage: $0 [menu|setup|auto-base-installation|graphics-setup|status|inventory-json|action OPERATION_ID|drivers|unlocks|storage-updates|interfaces|power|ram|swap|compute|cpu-unlock|cec|audio-output|hdmi-ac3-enable|hdmi-ac3-revert|storage|persistence|wifi|fan-driver|memory-temperature|amdgpu|amdgpu-clean|scheduler-policy|kfd-runlist|radv|proton|proton-install|proton-update|proton-status|proton-uninstall|decky|desktop|coolercontrol|trainer|manage|help]

Run without arguments in a terminal to open the unified toolkit menu.
Run the toolkit as the logged-in Deck user, not with sudo; child tools request
administrator access when needed.

Commands:
  setup                  Open the status-aware guided setup checklist
  auto-base-installation Run Auto Base Toolkit Installation
  graphics-setup         Install or resume AMDGPU and Mesa / RADV in order
  status                 Show read-only system health
  inventory-json         Emit versioned JSON component inventory for automation
  action OPERATION_ID    Run one fixed, noninteractive dashboard operation
  drivers                Open AMDGPU, Mesa / RADV, and wireless drivers
  unlocks                Open GPU compute-unit and CPU core unlocks
  storage-updates        Open persistent storage and update protection
  interfaces             Open Decky, Plasma, CoolerControl, and Trainer installers
  power                  Open the Power Management menu
  ram                    Open the RAM / VRAM Split menu
  swap                   Choose zram or zswap-backed disk swap
  compute                Open the GPU Compute-Unit Unlock menu
  cpu-unlock             Open the CPU Core Unlock menu
  cec                    Open the CEC / HDMI Control menu
  audio-output           Open the HDMI audio menu
  hdmi-ac3-enable        Confirm and enable Dolby Digital 5.1 encoding
  hdmi-ac3-revert        Confirm and restore default HDMI stereo
  storage                Open the Persistent Storage menu
  persistence            Open the SteamOS Update Persistence menu
  wifi                   Confirm and run the AIC8800 installer
  fan-driver             Confirm and install NCT6687 hwmon fan/PWM support
  memory-temperature     Open the experimental GDDR6 temperature tool
  amdgpu                 Confirm and build the AMDGPU kernel fixes
  amdgpu-clean           Confirm and clean the AMDGPU kernel build tree
  scheduler-policy       Advanced: toggle policy only after RADV is installed
  kfd-runlist            Experimental: toggle the KFD HWS TLB-flush workaround
  radv                   Open the global Mesa / RADV async-compute patch
  proton                 Open BC-250 GE-Proton installation and cleanup
  proton-install         Confirm and install the pinned GE-Proton build
  proton-update          Confirm and update or repair GE-Proton
  proton-status          Verify the installed GE-Proton compatibility tool
  proton-uninstall       Confirm and remove GE-Proton; preserve prefixes/saves
  decky                  Confirm and run the Decky plugin installer
  desktop                Confirm and run the Plasma desktop-control installer
  coolercontrol          Install the CoolerControl daemon and local Web UI
  trainer                Download and install the latest BC250 Trainer release
  manage                 Open installed-component maintenance and cleanup

Compatibility aliases: audio (amdgpu), mesh (radv)

Action operation IDs:
  auto-base-installation graphics-setup
  storage-install        power-install          ram-install
  swap-zram-install      swap-zswap-install     compute-build
  cec-setup              persistence-install
  aic-install            fan-install             audio-build
  mesh-setup
  decky-install          desktop-install         coolercontrol-install
  storage-repair         cec-repair
  storage-remove         power-remove           ram-remove
  swap-remove
  compute-remove         cec-remove             persistence-remove
  aic-remove             fan-remove             audio-remove
  mesh-remove
  decky-remove           desktop-remove          coolercontrol-remove
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
    setup) (($# == 0)) || die "Usage: $0 setup"; cmd_guided_setup_menu ;;
    auto-base-installation) (($# == 0)) || die "Usage: $0 auto-base-installation"; install_auto_base_installation ;;
    graphics-setup) (($# == 0)) || die "Usage: $0 graphics-setup"; show_graphics_setup_plan; echo; confirm_action "Install or resume the async-compute graphics stack?" run_graphics_setup ;;
    status) (($# == 0)) || die "Usage: $0 status"; show_status ;;
    inventory-json) (($# == 0)) || die "Usage: $0 inventory-json"; show_inventory_json ;;
    action) run_machine_action "$@" ;;
    drivers) (($# == 0)) || die "Usage: $0 drivers"; cmd_drivers_menu ;;
    unlocks) (($# == 0)) || die "Usage: $0 unlocks"; cmd_unlocks_menu ;;
    storage-updates) (($# == 0)) || die "Usage: $0 storage-updates"; cmd_storage_updates_menu ;;
    interfaces) (($# == 0)) || die "Usage: $0 interfaces"; cmd_interfaces_menu ;;
    power) (($# == 0)) || die "Usage: $0 power"; run_sudo_script "$POWER_SH" menu ;;
    ram) (($# == 0)) || die "Usage: $0 ram"; run_script "$RAM_SPLIT_SH" menu ;;
    swap) (($# == 0)) || die "Usage: $0 swap"; run_sudo_script "$SWAP_SH" menu ;;
    compute) (($# == 0)) || die "Usage: $0 compute"; run_sudo_script "$COMPUTE_SH" menu ;;
    cpu-unlock) (($# == 0)) || die "Usage: $0 cpu-unlock"; run_sudo_script "$POWER_SH" cpu-unlock menu ;;
    cec) (($# == 0)) || die "Usage: $0 cec"; require_normal_user; run_script "$CEC_SH" menu ;;
    audio-output) (($# == 0)) || die "Usage: $0 audio-output"; cmd_audio_menu ;;
    hdmi-ac3-enable) (($# == 0)) || die "Usage: $0 hdmi-ac3-enable"; enable_hdmi_ac3 ;;
    hdmi-ac3-revert) (($# == 0)) || die "Usage: $0 hdmi-ac3-revert"; revert_hdmi_ac3 ;;
    storage) (($# == 0)) || die "Usage: $0 storage"; run_script "$STORAGE_SH" menu ;;
    persistence) (($# == 0)) || die "Usage: $0 persistence"; run_script "$PERSISTENCE_SH" menu ;;
    wifi) (($# == 0)) || die "Usage: $0 wifi"; install_wifi ;;
    fan-driver) (($# == 0)) || die "Usage: $0 fan-driver"; install_fan_driver ;;
    memory-temperature) (($# == 0)) || die "Usage: $0 memory-temperature"; cmd_memory_temperature_menu ;;
    memory-temperature-status) (($# == 0)) || die "Usage: $0 memory-temperature-status"; run_sudo_script "$MEMORY_TEMP_SH" status ;;
    memory-temperature-prepare) (($# == 0)) || die "Usage: $0 memory-temperature-prepare"; run_sudo_script "$MEMORY_TEMP_SH" prepare ;;
    memory-temperature-patch) (($# == 0)) || die "Usage: $0 memory-temperature-patch"; run_sudo_script "$MEMORY_TEMP_SH" patch --acknowledge-smu-risk ;;
    memory-temperature-read) (($# == 0)) || die "Usage: $0 memory-temperature-read"; run_sudo_script "$MEMORY_TEMP_SH" read ;;
    memory-temperature-restore) (($# == 0)) || die "Usage: $0 memory-temperature-restore"; run_sudo_script "$MEMORY_TEMP_SH" restore --acknowledge-smu-risk ;;
    amdgpu|audio) (($# == 0)) || die "Usage: $0 amdgpu"; install_audio_fix ;;
    amdgpu-clean) (($# == 0)) || die "Usage: $0 amdgpu-clean"; clean_audio_fix ;;
    scheduler-policy) (($# == 0)) || die "Usage: $0 scheduler-policy"; toggle_scheduler_policy ;;
    kfd-runlist) (($# == 0)) || die "Usage: $0 kfd-runlist"; toggle_kfd_runlist ;;
    radv|mesh) (($# == 0)) || die "Usage: $0 radv"; require_normal_user; run_script "$MESH_SHADER_SH" menu ;;
    proton) (($# == 0)) || die "Usage: $0 proton"; cmd_proton_menu ;;
    proton-install) (($# == 0)) || die "Usage: $0 proton-install"; install_proton ;;
    proton-update) (($# == 0)) || die "Usage: $0 proton-update"; update_proton ;;
    proton-status) (($# == 0)) || die "Usage: $0 proton-status"; require_normal_user; run_script "$PROTON_SH" status ;;
    proton-uninstall) (($# == 0)) || die "Usage: $0 proton-uninstall"; uninstall_proton ;;
    decky) (($# == 0)) || die "Usage: $0 decky"; install_decky ;;
    desktop) (($# == 0)) || die "Usage: $0 desktop"; install_desktop ;;
    coolercontrol) (($# == 0)) || die "Usage: $0 coolercontrol"; install_coolercontrol ;;
    trainer) (($# == 0)) || die "Usage: $0 trainer"; install_trainer ;;
    manage) (($# == 0)) || die "Usage: $0 manage"; run_script "$MAINTENANCE_SH" menu ;;
    help|-h|--help) (($# == 0)) || die "Usage: $0 help"; cmd_help ;;
    *) cmd_help >&2; exit 1 ;;
esac
