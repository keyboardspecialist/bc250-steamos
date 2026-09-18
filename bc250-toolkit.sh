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
        rebuild-required) printf '%s' "${CY}[rebuild needed]${C0}" ;;
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

native_mesh_badge() {
    local status="" state
    if [[ ! -f "$MESH_SHADER_SH" || -L "$MESH_SHADER_SH" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
        return
    fi
    status=$(bash "$MESH_SHADER_SH" status-json 2>/dev/null || true)
    state=$(json_field "$status" nativeMeshState || true)
    case "$state" in
        ready) printf '%s' "${CG}[installed]${C0}" ;;
        invalid) printf '%s' "${CY}[repair needed]${C0}" ;;
        not-installed) printf '%s' "${CD}[not installed]${C0}" ;;
        *) printf '%s' "${CR}[status unavailable]${C0}" ;;
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
    printf '%s\n' "  Excludes hardware unlocks, tuning, swap, device-specific drivers, interfaces, FSR4, and private native mesh."
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
        not-installed|rebuild-required)
            if [[ "$amdgpu_state" == rebuild-required ]]; then
                log "Rebuilding the AMDGPU prerequisite for the running kernel."
            else
                log "Installing the AMDGPU prerequisite for the async-compute stack."
            fi
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
    bash "$MESH_SHADER_SH" setup "$@"
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
        not-installed|rebuild-required|reboot-required|ready) ;;
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
        native-mesh-install) run_script "$MESH_SHADER_SH" setup --native-mesh ;;
        native-mesh-remove) run_script "$MESH_SHADER_SH" uninstall --native-mesh ;;
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

    status_heading "POWER & THERMALS"
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

    if [[ $power_rc -ne 0 ]]; then
        failed=1; failed_components+=("Power management")
    fi

    status_heading "GRAPHICS STACK"
    state=$(json_field "$amdgpu_output" state || true)
    case "$state" in
        ready) status_row "AMDGPU kernel fixes" "active" good "patched module loaded for $(json_field "$amdgpu_output" runningKernel || true)" ;;
        reboot-required) status_row "AMDGPU kernel fixes" "reboot needed" warn "installed and selected for the running kernel" ;;
        rebuild-required) status_row "AMDGPU kernel fixes" "rebuild needed" warn "retained configuration is valid; rebuild for the running kernel" ;;
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

    state=$(json_field "$radv_output" nativeMeshState || true)
    detail=$(json_field "$radv_output" nativeMeshRunnerPath || true)
    case "$state" in
        ready) status_row "Private native-mesh profile" "installed" good "manual per-game runner: $detail" ;;
        not-installed) status_row "Private native-mesh profile" "not installed" dim "optional; never globally enabled or added to Steam" ;;
        invalid)
            status_row "Private native-mesh profile" "incomplete" bad "repair or remove the private profile"
            failed=1; failed_components+=("Private native-mesh profile") ;;
        *)
            status_row "Private native-mesh profile" "unavailable" bad "Mesa / RADV status probe failed"
            failed=1; failed_components+=("Private native-mesh profile") ;;
    esac

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

    status_heading "HARDWARE UNLOCKS"
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

    if [[ $cu_rc -ne 0 ]]; then
        status_row "GPU compute-unit unlock" "unavailable" bad "${cu_output:-register read failed}"
        failed=1; failed_components+=("GPU compute-unit unlock")
    elif [[ "$cu_output" == 40/40 ]]; then
        status_row "GPU compute-unit unlock" "40 / 40" good "all compute units routed"
    else
        status_row "GPU compute-unit unlock" "${cu_output:-unknown}" warn "current hardware route"
    fi

    status_heading "DEVICES & CONNECTIVITY"
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

    printf '\n%s%s%s\n' "${CB}${CC}" "  CEC BUS MAP" "$C0"
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

menu_graph_badge() {
    local node="$1" style="$2"
    case "$node" in
        action__auto_base_installation) printf '%s' "${CG}[install / resume]${C0}" ;;
        action__amdgpu) amdgpu_badge ;;
        action__graphics_setup|child__radv) radv_badge ;;
        action__fan_driver) fan_driver_badge ;;
        action__proton_status|action__proton_install|action__proton_update|action__proton_uninstall|menu__cmd_proton_menu) proton_badge ;;
        action__hdmi_ac3_enable|menu__cmd_audio_menu) hdmi_ac3_badge ;;
        action__coolercontrol) component_badge "$COOLERCONTROL_INSTALL_SH" status ;;
        child__storage) component_badge "$STORAGE_SH" ;;
        child__ram) component_badge "$RAM_SPLIT_SH" ;;
        child__swap) component_badge "$SWAP_SH" ;;
        child__power_foundation) power_foundation_badge ;;
        child__compute) component_badge "$COMPUTE_SH" ;;
        child__cpu_unlock) printf '%s' "${CD}[guided test]${C0}" ;;
        *)
            case "$style" in
                root|menu|entry) printf '%s' "${CG}[menu]${C0}" ;;
                install) printf '%s' "${CY}[installer]${C0}" ;;
                read_only) printf '%s' "${CD}[read only]${C0}" ;;
                advanced) printf '%s' "${CY}[advanced]${C0}" ;;
                cleanup) printf '%s' "${CY}[cleanup]${C0}" ;;
                experimental) printf '%s' "${CR}[experimental]${C0}" ;;
                hardware_specific) printf '%s' "${CY}[hardware specific]${C0}" ;;
                *) printf '%s' "${CD}[unknown]${C0}" ;;
            esac
            ;;
    esac
}

menu_graph_activate() {
    case "$1" in
        action__auto_base_installation) run_menu_action auto-base-installation ;;
        action__system_health) run_menu_action status ;;
        action__guided_overview) show_guided_setup_overview ;;
        action__amdgpu) run_menu_action amdgpu ;;
        action__graphics_setup) run_menu_action graphics-setup ;;
        action__amdgpu_clean) run_menu_action amdgpu-clean ;;
        action__fan_driver) run_menu_action fan-driver ;;
        action__wifi) run_menu_action wifi ;;
        action__decky) run_menu_action decky ;;
        action__desktop) run_menu_action desktop ;;
        action__coolercontrol) run_menu_action coolercontrol ;;
        action__trainer) run_menu_action trainer ;;
        action__proton_status) run_menu_action proton-status ;;
        action__proton_install) run_menu_action proton-install ;;
        action__proton_update) run_menu_action proton-update ;;
        action__proton_uninstall) run_menu_action proton-uninstall ;;
        action__memory_status) run_menu_action memory-temperature-status ;;
        action__memory_prepare)
            run_confirmed_menu_action "Download and verify the pinned memory-temperature source?" \
                bash "$SELF" memory-temperature-prepare
            ;;
        action__memory_patch)
            run_confirmed_menu_action "Apply the P3.0-only live SMU payload? Memory corruption, data loss, crashes, and a required cold power cycle are possible." \
                bash "$SELF" memory-temperature-patch
            ;;
        action__memory_read) run_menu_action memory-temperature-read ;;
        action__memory_restore)
            run_confirmed_menu_action "Restore the recorded original live SMU handler and bytes?" \
                bash "$SELF" memory-temperature-restore
            ;;
        action__hdmi_ac3_enable) run_menu_action hdmi-ac3-enable ;;
        action__hdmi_ac3_revert) run_menu_action hdmi-ac3-revert ;;
        action__scheduler_policy) run_menu_action scheduler-policy ;;
        action__kfd_runlist) run_menu_action kfd-runlist ;;
        child__storage) run_menu_child storage ;;
        child__ram) run_menu_child ram ;;
        child__swap) run_menu_child swap ;;
        child__persistence) run_menu_child persistence ;;
        child__power_foundation) run_menu_child power foundation ;;
        child__power_frequency) run_menu_child power frequency ;;
        child__power_load) run_menu_child power load ;;
        child__power_ramp) run_menu_child power ramp ;;
        child__power_cpu) run_menu_child power cpu ;;
        child__radv) run_menu_child radv ;;
        child__compute) run_menu_child compute ;;
        child__cpu_unlock) run_menu_child cpu-unlock ;;
        child__cec) run_menu_child cec ;;
        child__manage) run_menu_child manage ;;
        *) die "Unknown generated menu target: $1" ;;
    esac
}

# BEGIN GENERATED TOOLKIT MENUS
# Generated from menus/toolkit.mmd by scripts/generate-menus.py.
# Do not edit this region directly.
menu_graph_render() {
    local menu_id="$1" title target badge
    if declare -F menu_graph_prepare >/dev/null; then menu_graph_prepare "$menu_id"; fi
    while true; do
        local items=() targets=() badges=()
        case "$menu_id" in
            menu__cmd_menu)
                title="BC-250 SteamOS toolkit [${TOOLKIT_VERSION}]"
                if ! badge=$(menu_graph_badge action__auto_base_installation install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__auto_base_installation"
                fi
                items+=("Auto Base Toolkit Installation|${badge}|Install or resume the safe foundation in dependency order.")
                targets+=("action__auto_base_installation")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_guided_setup_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_guided_setup_menu"
                fi
                items+=("Manual Guided Setup|${badge}|Follow the safe setup order without crossing through sibling categories.")
                targets+=("menu__cmd_guided_setup_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_core_system_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_core_system_menu"
                fi
                items+=("Core System|${badge}|Manage storage, memory allocation, swap, and update protection.")
                targets+=("menu__cmd_core_system_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_power_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_power_menu"
                fi
                items+=("Power & Thermals|${badge}|Configure power, GPU and CPU tuning, memory sensors, and fan control.")
                targets+=("menu__cmd_power_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_graphics_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_graphics_menu"
                fi
                items+=("Graphics Stack|${badge}|Manage AMDGPU, Mesa and RADV, FSR4, and GE-Proton.")
                targets+=("menu__cmd_graphics_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_unlocks_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_unlocks_menu"
                fi
                items+=("Hardware Unlocks|${badge}|Test CPU cores or GPU compute units with explicit recovery paths.")
                targets+=("menu__cmd_unlocks_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_devices_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_devices_menu"
                fi
                items+=("Devices & Connectivity|${badge}|Configure HDMI audio, CEC, fan control, and hardware-specific wireless support.")
                targets+=("menu__cmd_devices_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_interfaces_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_interfaces_menu"
                fi
                items+=("Control Interfaces|${badge}|Install Gaming Mode, desktop, fan-control, or standalone interfaces.")
                targets+=("menu__cmd_interfaces_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_maintenance_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_maintenance_menu"
                fi
                items+=("Maintenance & Recovery|${badge}|Recover updates, clean build state, or remove installed components.")
                targets+=("menu__cmd_maintenance_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__system_health read_only); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__system_health"
                fi
                items+=("System Health|${badge}|Show operational state using the same domain names as the menu.")
                targets+=("action__system_health")
                badges+=("$badge")
                ;;
            menu__cmd_guided_setup_menu)
                title="Manual Guided Setup"
                if ! badge=$(menu_graph_badge action__guided_overview read_only); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__guided_overview"
                fi
                items+=("Setup Overview|${badge}|Review goals, current state, and restart checkpoints.")
                targets+=("action__guided_overview")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__compute menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__compute"
                fi
                items+=("GPU Compute-Unit Unlock|${badge}|Inspect harvesting, test live routing, stress-test, and persist.")
                targets+=("child__compute")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__cpu_unlock experimental); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__cpu_unlock"
                fi
                items+=("CPU Core Unlock|${badge}|Test eight cores, then choose one automatic unlock method.")
                targets+=("child__cpu_unlock")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__amdgpu install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__amdgpu"
                fi
                items+=("AMDGPU Kernel Fixes|${badge}|Build the corrected kernel module and reboot before RADV setup.")
                targets+=("action__amdgpu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__power_foundation menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__power_foundation"
                fi
                items+=("Power Foundation|${badge}|Install ACPI, test the GPU governor, then enable it at boot.")
                targets+=("child__power_foundation")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__ram menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__ram"
                fi
                items+=("RAM and VRAM Split|${badge}|Balance the CMOS minimum and dynamic Linux TTM limit.")
                targets+=("child__ram")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__graphics_setup install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__graphics_setup"
                fi
                items+=("Install or Resume Async Compute|${badge}|Install AMDGPU first when needed, then resume Mesa and RADV.")
                targets+=("action__graphics_setup")
                badges+=("$badge")
                ;;
            menu__cmd_core_system_menu)
                title="Core System"
                if ! badge=$(menu_graph_badge child__storage menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__storage"
                fi
                items+=("Persistent Storage|${badge}|Inspect or repair privileged storage and boot recovery.")
                targets+=("child__storage")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__ram menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__ram"
                fi
                items+=("RAM and VRAM Split|${badge}|Balance the CMOS minimum and dynamic Linux TTM limit.")
                targets+=("child__ram")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__swap menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__swap"
                fi
                items+=("Compressed Swap|${badge}|Choose mutually exclusive zram or zswap-backed disk profiles.")
                targets+=("child__swap")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__persistence menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__persistence"
                fi
                items+=("SteamOS Update Protection|${badge}|Protect and recover supported component settings across updates.")
                targets+=("child__persistence")
                badges+=("$badge")
                ;;
            menu__cmd_power_menu)
                title="Power & Thermals"
                if ! badge=$(menu_graph_badge child__power_foundation menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__power_foundation"
                fi
                items+=("Power Foundation|${badge}|Install ACPI, test the GPU governor, then enable it at boot.")
                targets+=("child__power_foundation")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__power_frequency menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__power_frequency"
                fi
                items+=("GPU Frequency and Voltage|${badge}|Set adaptive ranges, pinned clocks, or voltage-curve points.")
                targets+=("child__power_frequency")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__power_load menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__power_load"
                fi
                items+=("GPU Load Targets|${badge}|Choose when the governor clocks up and down.")
                targets+=("child__power_load")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__power_ramp menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__power_ramp"
                fi
                items+=("GPU Ramp Behavior|${badge}|Choose how quickly and granularly GPU clocks move.")
                targets+=("child__power_ramp")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__power_cpu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__power_cpu"
                fi
                items+=("CPU Performance and Security|${badge}|Configure CPU undervolt, overclock, and mitigation policy.")
                targets+=("child__power_cpu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_memory_temperature_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_memory_temperature_menu"
                fi
                items+=("GDDR6 Memory Temperature|${badge}|Manage the experimental P3.0-only live SMU temperature payload.")
                targets+=("menu__cmd_memory_temperature_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__fan_driver install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__fan_driver"
                fi
                items+=("NCT6687 Fan-Control Driver|${badge}|Install Linux hwmon fan-speed and PWM support.")
                targets+=("action__fan_driver")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__coolercontrol install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__coolercontrol"
                fi
                items+=("CoolerControl|${badge}|Install fan profiles, curves, and monitoring for the onboard controller.")
                targets+=("action__coolercontrol")
                badges+=("$badge")
                ;;
            menu__cmd_graphics_menu)
                title="Graphics Stack"
                if ! badge=$(menu_graph_badge action__amdgpu install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__amdgpu"
                fi
                items+=("AMDGPU Kernel Fixes|${badge}|Build the corrected kernel module and reboot before RADV setup.")
                targets+=("action__amdgpu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__graphics_setup install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__graphics_setup"
                fi
                items+=("Install or Resume Async Compute|${badge}|Install AMDGPU first when needed, then resume Mesa and RADV.")
                targets+=("action__graphics_setup")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__radv menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__radv"
                fi
                items+=("GPU Driver and FSR4 Options|${badge}|Manage Mesa and RADV, portable FSR4 DLLs, native mesh, or cleanup.")
                targets+=("child__radv")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_proton_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_proton_menu"
                fi
                items+=("BC-250 GE-Proton|${badge}|Inspect, install, repair, or remove the pinned compatibility tool.")
                targets+=("menu__cmd_proton_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge menu__cmd_amdgpu_boot_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_amdgpu_boot_menu"
                fi
                items+=("Advanced AMDGPU Boot Options|${badge}|Manage mutually exclusive scheduler and KFD runlist policies.")
                targets+=("menu__cmd_amdgpu_boot_menu")
                badges+=("$badge")
                ;;
            menu__cmd_unlocks_menu)
                title="Hardware Unlocks"
                if ! badge=$(menu_graph_badge child__compute menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__compute"
                fi
                items+=("GPU Compute-Unit Unlock|${badge}|Inspect harvesting, test live routing, stress-test, and persist.")
                targets+=("child__compute")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__cpu_unlock experimental); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__cpu_unlock"
                fi
                items+=("CPU Core Unlock|${badge}|Test eight cores, then choose one automatic unlock method.")
                targets+=("child__cpu_unlock")
                badges+=("$badge")
                ;;
            menu__cmd_devices_menu)
                title="Devices & Connectivity"
                if ! badge=$(menu_graph_badge menu__cmd_audio_menu menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: menu__cmd_audio_menu"
                fi
                items+=("HDMI Audio|${badge}|Enable Dolby Digital 5.1 or return to the default stereo profile.")
                targets+=("menu__cmd_audio_menu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__cec menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__cec"
                fi
                items+=("HDMI-CEC|${badge}|Configure automation, everyday controls, and diagnostics.")
                targets+=("child__cec")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__fan_driver install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__fan_driver"
                fi
                items+=("NCT6687 Fan-Control Driver|${badge}|Install Linux hwmon fan-speed and PWM support.")
                targets+=("action__fan_driver")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__wifi hardware_specific); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__wifi"
                fi
                items+=("AIC8800 WiFi and Bluetooth|${badge}|Install only on systems using the AIC8800 adapter.")
                targets+=("action__wifi")
                badges+=("$badge")
                ;;
            menu__cmd_interfaces_menu)
                title="Control Interfaces"
                if ! badge=$(menu_graph_badge action__decky install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__decky"
                fi
                items+=("Decky Plugin|${badge}|Install BC-250 controls for Gaming Mode and Quick Access.")
                targets+=("action__decky")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__desktop install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__desktop"
                fi
                items+=("Plasma Desktop Control|${badge}|Install the shared service and Plasma system-tray control.")
                targets+=("action__desktop")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__coolercontrol install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__coolercontrol"
                fi
                items+=("CoolerControl|${badge}|Install fan profiles, curves, and monitoring for the onboard controller.")
                targets+=("action__coolercontrol")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__trainer install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__trainer"
                fi
                items+=("BC250 Trainer|${badge}|Install the standalone native Qt control application.")
                targets+=("action__trainer")
                badges+=("$badge")
                ;;
            menu__cmd_maintenance_menu)
                title="Maintenance & Recovery"
                if ! badge=$(menu_graph_badge child__persistence menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__persistence"
                fi
                items+=("SteamOS Update Protection|${badge}|Protect and recover supported component settings across updates.")
                targets+=("child__persistence")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__amdgpu_clean cleanup); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__amdgpu_clean"
                fi
                items+=("Clean AMDGPU Build Tree|${badge}|Remove generated build output while retaining downloads and dependencies.")
                targets+=("action__amdgpu_clean")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__manage menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__manage"
                fi
                items+=("Manage Installed Components|${badge}|Review removal plans, uninstall components, or purge preserved data.")
                targets+=("child__manage")
                badges+=("$badge")
                ;;
            menu__cmd_proton_menu)
                title="BC-250 GE-Proton"
                if ! badge=$(menu_graph_badge action__proton_status read_only); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__proton_status"
                fi
                items+=("Status|${badge}|Verify the pinned compatibility tool and required files.")
                targets+=("action__proton_status")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__proton_install install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__proton_install"
                fi
                items+=("Install|${badge}|Install GE-Proton after the required FSR4 RADV runtime is active.")
                targets+=("action__proton_install")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__proton_update install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__proton_update"
                fi
                items+=("Update or Repair|${badge}|Transactionally replace an older or incomplete toolkit installation.")
                targets+=("action__proton_update")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__proton_uninstall cleanup); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__proton_uninstall"
                fi
                items+=("Uninstall|${badge}|Remove the compatibility tool while preserving prefixes and saves.")
                targets+=("action__proton_uninstall")
                badges+=("$badge")
                ;;
            menu__cmd_memory_temperature_menu)
                title="GDDR6 Memory Temperature"
                if ! badge=$(menu_graph_badge action__memory_status read_only); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__memory_status"
                fi
                items+=("Status|${badge}|Verify source and recorded original-SMU backup state.")
                targets+=("action__memory_status")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__memory_prepare install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__memory_prepare"
                fi
                items+=("Prepare Verified Source|${badge}|Download and verify the pinned payload, source, README, and license.")
                targets+=("action__memory_prepare")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__memory_patch experimental); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__memory_patch"
                fi
                items+=("Apply Live SMU Payload|${badge}|Patch this SMU runtime after explicit risk acknowledgement.")
                targets+=("action__memory_patch")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__memory_read read_only); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__memory_read"
                fi
                items+=("Read GDDR6 Temperatures|${badge}|Attest the payload and read all eight memory chips.")
                targets+=("action__memory_read")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__memory_restore cleanup); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__memory_restore"
                fi
                items+=("Restore Original SMU Bytes|${badge}|Restore the recorded handler and overwritten bytes.")
                targets+=("action__memory_restore")
                badges+=("$badge")
                ;;
            menu__cmd_audio_menu)
                title="HDMI Audio"
                if ! badge=$(menu_graph_badge action__hdmi_ac3_enable install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__hdmi_ac3_enable"
                fi
                items+=("Enable HDMI AC-3 5.1|${badge}|Encode system audio as Dolby Digital 5.1.")
                targets+=("action__hdmi_ac3_enable")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__hdmi_ac3_revert cleanup); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__hdmi_ac3_revert"
                fi
                items+=("Revert HDMI AC-3 to Stereo|${badge}|Remove toolkit AC-3 configuration and restore default stereo.")
                targets+=("action__hdmi_ac3_revert")
                badges+=("$badge")
                ;;
            menu__cmd_amdgpu_boot_menu)
                title="Advanced AMDGPU Boot Options"
                if ! badge=$(menu_graph_badge action__scheduler_policy advanced); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__scheduler_policy"
                fi
                items+=("AMDGPU Scheduler Policy|${badge}|Normally managed by Mesa and RADV setup.")
                targets+=("action__scheduler_policy")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__kfd_runlist experimental); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__kfd_runlist"
                fi
                items+=("KFD Runlist Workaround|${badge}|Experimental ROCm workaround that cannot coexist with sched_policy=2.")
                targets+=("action__kfd_runlist")
                badges+=("$badge")
                ;;
            menu__cmd_drivers_menu)
                title="Legacy Drivers Entry"
                if ! badge=$(menu_graph_badge action__amdgpu install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__amdgpu"
                fi
                items+=("AMDGPU Kernel Fixes|${badge}|Build the corrected kernel module and reboot before RADV setup.")
                targets+=("action__amdgpu")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__amdgpu_clean cleanup); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__amdgpu_clean"
                fi
                items+=("Clean AMDGPU Build Tree|${badge}|Remove generated build output while retaining downloads and dependencies.")
                targets+=("action__amdgpu_clean")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__scheduler_policy advanced); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__scheduler_policy"
                fi
                items+=("AMDGPU Scheduler Policy|${badge}|Normally managed by Mesa and RADV setup.")
                targets+=("action__scheduler_policy")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__kfd_runlist experimental); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__kfd_runlist"
                fi
                items+=("KFD Runlist Workaround|${badge}|Experimental ROCm workaround that cannot coexist with sched_policy=2.")
                targets+=("action__kfd_runlist")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__graphics_setup install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__graphics_setup"
                fi
                items+=("Install or Resume Async Compute|${badge}|Install AMDGPU first when needed, then resume Mesa and RADV.")
                targets+=("action__graphics_setup")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__fan_driver install); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__fan_driver"
                fi
                items+=("NCT6687 Fan-Control Driver|${badge}|Install Linux hwmon fan-speed and PWM support.")
                targets+=("action__fan_driver")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge action__wifi hardware_specific); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: action__wifi"
                fi
                items+=("AIC8800 WiFi and Bluetooth|${badge}|Install only on systems using the AIC8800 adapter.")
                targets+=("action__wifi")
                badges+=("$badge")
                ;;
            menu__cmd_storage_updates_menu)
                title="Legacy Storage and Updates Entry"
                if ! badge=$(menu_graph_badge child__storage menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__storage"
                fi
                items+=("Persistent Storage|${badge}|Inspect or repair privileged storage and boot recovery.")
                targets+=("child__storage")
                badges+=("$badge")
                if ! badge=$(menu_graph_badge child__persistence menu); then badge=; fi
                if [[ "$badge" == *"|"* || "$badge" == *$'\n'* ]]; then
                    die "Invalid generated menu badge: child__persistence"
                fi
                items+=("SteamOS Update Protection|${badge}|Protect and recover supported component settings across updates.")
                targets+=("child__persistence")
                badges+=("$badge")
                ;;
            *) die "Unknown generated toolkit menu ID: $menu_id" ;;
        esac
        if [[ "$title" == *"|"* || "$title" == *[[:cntrl:]]* ]]; then
            die "Invalid generated toolkit menu title"
        fi
        menu_select "$title" "${items[@]}" || { echo; return 0; }
        target=${targets[$MENU_CHOICE]}
        if [[ "$target" == menu__* ]]; then
            menu_graph_render "$target"
        else
            menu_graph_activate "$target" "${badges[$MENU_CHOICE]}"
        fi
    done
}

menu_graph_open() {
    case "${1:-root}" in
        root) menu_graph_render menu__cmd_menu ;;
        setup) menu_graph_render menu__cmd_guided_setup_menu ;;
        core) menu_graph_render menu__cmd_core_system_menu ;;
        power) menu_graph_render menu__cmd_power_menu ;;
        graphics) menu_graph_render menu__cmd_graphics_menu ;;
        unlocks) menu_graph_render menu__cmd_unlocks_menu ;;
        devices) menu_graph_render menu__cmd_devices_menu ;;
        interfaces) menu_graph_render menu__cmd_interfaces_menu ;;
        maintenance) menu_graph_render menu__cmd_maintenance_menu ;;
        proton) menu_graph_render menu__cmd_proton_menu ;;
        memory-temperature) menu_graph_render menu__cmd_memory_temperature_menu ;;
        audio) menu_graph_render menu__cmd_audio_menu ;;
        amdgpu-boot) menu_graph_render menu__cmd_amdgpu_boot_menu ;;
        drivers) menu_graph_render menu__cmd_drivers_menu ;;
        storage-updates) menu_graph_render menu__cmd_storage_updates_menu ;;
        *) return 2 ;;
    esac
}

# END GENERATED TOOLKIT MENUS

cmd_menu() {
    require_terminal
    require_normal_user
    start_sudo_session
    menu_graph_open root
}

cmd_guided_setup_menu() {
    require_terminal
    require_normal_user
    menu_graph_open setup
}

cmd_core_system_menu() {
    require_terminal
    require_normal_user
    menu_graph_open core
}

cmd_power_menu() {
    require_terminal
    require_normal_user
    menu_graph_open power
}

cmd_graphics_menu() {
    require_terminal
    require_normal_user
    menu_graph_open graphics
}

cmd_unlocks_menu() {
    require_terminal
    require_normal_user
    menu_graph_open unlocks
}

cmd_devices_menu() {
    require_terminal
    require_normal_user
    menu_graph_open devices
}

cmd_interfaces_menu() {
    require_terminal
    require_normal_user
    menu_graph_open interfaces
}

cmd_maintenance_menu() {
    require_terminal
    require_normal_user
    menu_graph_open maintenance
}

cmd_proton_menu() {
    require_terminal
    require_normal_user
    menu_graph_open proton
}

cmd_memory_temperature_menu() {
    require_terminal
    require_normal_user
    menu_graph_open memory-temperature
}

cmd_audio_menu() {
    require_terminal
    require_normal_user
    menu_graph_open audio
}

cmd_amdgpu_boot_menu() {
    require_terminal
    require_normal_user
    menu_graph_open amdgpu-boot
}

cmd_drivers_menu() {
    require_terminal
    require_normal_user
    menu_graph_open drivers
}

cmd_storage_updates_menu() {
    require_terminal
    require_normal_user
    menu_graph_open storage-updates
}

cmd_help() {
    cat << EOF
Usage: $0 [menu|setup|auto-base-installation|graphics-setup|status|inventory-json|action OPERATION_ID|drivers|unlocks|storage-updates|interfaces|power [ENTRY]|ram|swap|compute|cpu-unlock|cec|audio-output|hdmi-ac3-enable|hdmi-ac3-revert|storage|persistence|wifi|fan-driver|memory-temperature|amdgpu|amdgpu-clean|scheduler-policy|kfd-runlist|radv|proton|proton-install|proton-update|proton-status|proton-uninstall|decky|desktop|coolercontrol|trainer|manage|help]

Run without arguments in a terminal to open the unified toolkit menu.
Run the toolkit as the logged-in Deck user, not with sudo; child tools request
administrator access when needed.

Commands:
  setup                  Open the status-aware guided setup checklist
  auto-base-installation Run Auto Base Toolkit Installation
  graphics-setup [--replace-unmanaged]
                         Install or resume AMDGPU and Mesa / RADV in order
  status                 Show read-only system health
  inventory-json         Emit versioned JSON component inventory for automation
  action OPERATION_ID    Run one fixed, noninteractive dashboard operation
  drivers                Open AMDGPU, Mesa / RADV, and wireless drivers
  unlocks                Open GPU compute-unit and CPU core unlocks
  storage-updates        Open persistent storage and update protection
  interfaces             Open Decky, Plasma, CoolerControl, and Trainer installers
  power [ENTRY]          Open Power Management at root, foundation, frequency,
                         load, ramp, or CPU tuning
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
  mesh-setup             native-mesh-install
  decky-install          desktop-install         coolercontrol-install
  storage-repair         cec-repair
  storage-remove         power-remove           ram-remove
  swap-remove
  compute-remove         cec-remove             persistence-remove
  aic-remove             fan-remove             audio-remove
  mesh-remove            native-mesh-remove
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
    graphics-setup)
        if (($# == 1)); then
            [[ "$1" == --replace-unmanaged ]] \
                || die "Usage: $0 graphics-setup [--replace-unmanaged]"
        else
            (($# == 0)) || die "Usage: $0 graphics-setup [--replace-unmanaged]"
        fi
        show_graphics_setup_plan
        echo
        if [[ "${1:-}" == --replace-unmanaged ]]; then
            confirm_action "Replace any unverified regular async-compute runtime files?" \
                run_graphics_setup --replace-unmanaged
        else
            confirm_action "Install or resume the async-compute graphics stack?" \
                run_graphics_setup
        fi
        ;;
    status) (($# == 0)) || die "Usage: $0 status"; show_status ;;
    inventory-json) (($# == 0)) || die "Usage: $0 inventory-json"; show_inventory_json ;;
    action) run_machine_action "$@" ;;
    drivers) (($# == 0)) || die "Usage: $0 drivers"; cmd_drivers_menu ;;
    unlocks) (($# == 0)) || die "Usage: $0 unlocks"; cmd_unlocks_menu ;;
    storage-updates) (($# == 0)) || die "Usage: $0 storage-updates"; cmd_storage_updates_menu ;;
    interfaces) (($# == 0)) || die "Usage: $0 interfaces"; cmd_interfaces_menu ;;
    power)
        (($# <= 1)) || die "Usage: $0 power [root|foundation|frequency|load|ramp|cpu]"
        case "${1:-root}" in
            root|foundation|frequency|load|ramp|cpu) ;;
            *) die "Usage: $0 power [root|foundation|frequency|load|ramp|cpu]" ;;
        esac
        if (($# == 0)); then
            run_sudo_script "$POWER_SH" menu
        else
            run_sudo_script "$POWER_SH" menu "$1"
        fi
        ;;
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
