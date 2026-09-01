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
AUDIO_FIX_SH="$SCRIPT_DIR/bc250-audio-fix/patch-driver.sh"
AUDIO_CLEAN_SH="$SCRIPT_DIR/bc250-audio-fix/clean.sh"
AMDGPU_BOOT_CONFIG_SH="$SCRIPT_DIR/bc250-audio-fix/boot-config.sh"
HDMI_AC3_SH="$SCRIPT_DIR/hdmi-ac3/hdmi-ac3.sh"
MESH_SHADER_SH="$SCRIPT_DIR/bc250-mesh-shader.sh"
DECKY_INSTALL_SH="$SCRIPT_DIR/decky-plugin/install.sh"
DESKTOP_INSTALL_SH="$SCRIPT_DIR/desktop-control/install.sh"
TRAINER_RELEASE_INSTALLER="$SCRIPT_DIR/trainer/install-release.py"
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

install_audio_fix() {
    require_normal_user
    require_script "$AUDIO_FIX_SH"
    confirm_action \
        "Build and install the matching AMDGPU kernel fixes?" \
        bash "$AUDIO_FIX_SH"
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
    status=$(bash "$AUDIO_FIX_SH" status 2>/dev/null || true)
    case "$status" in
        *"state: installed"*) printf '%s' "${CG}[installed]${C0}" ;;
        *"state: incomplete"*) printf '%s' "${CY}[incomplete]${C0}" ;;
        *) printf '%s' "${CD}[not installed]${C0}" ;;
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

radv_badge() {
    local status=""
    if [[ ! -f "$MESH_SHADER_SH" || -L "$MESH_SHADER_SH" ]]; then
        printf '%s' "${CR}[unavailable]${C0}"
        return
    fi
    status=$(bash "$MESH_SHADER_SH" status 2>/dev/null || true)
    case "$status" in
        *"runtime: installed"*) printf '%s' "${CG}[installed]${C0}" ;;
        *"runtime: incomplete"*|*"legacy install"*) printf '%s' "${CY}[repair needed]${C0}" ;;
        *) printf '%s' "${CD}[optional]${C0}" ;;
    esac
}

toggle_scheduler_policy() {
    require_normal_user
    require_script "$AMDGPU_BOOT_CONFIG_SH"
    if bash "$AMDGPU_BOOT_CONFIG_SH" configured 2>/dev/null; then
        confirm_action \
            "Disable amdgpu.sched_policy=2? Compute repair will be incomplete until re-enabled; reboot required." \
            sudo bash "$AMDGPU_BOOT_CONFIG_SH" policy-remove
    elif bash "$AMDGPU_BOOT_CONFIG_SH" runlist-configured 2>/dev/null; then
        confirm_action \
            "Enable amdgpu.sched_policy=2? This disables the incompatible KFD HWS runlist workaround and requires a reboot." \
            sudo bash "$AMDGPU_BOOT_CONFIG_SH" install
    elif bash "$AMDGPU_BOOT_CONFIG_SH" present 2>/dev/null; then
        die "Scheduler policy state is incomplete. Review '$AMDGPU_BOOT_CONFIG_SH status' before changing it."
    else
        require_script "$MESH_SHADER_SH"
        bash "$MESH_SHADER_SH" status-json 2>/dev/null \
            | grep -qF '"runtimeState":"ready"' \
            || die "Install the Mesa / RADV async-compute patch before enabling amdgpu.sched_policy=2."
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
        swap-zram-install) run_sudo_script "$SWAP_SH" install zram ;;
        swap-zswap-install) run_sudo_script "$SWAP_SH" install zswap ;;
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
        storage-remove|power-remove|ram-remove|swap-remove|compute-remove|cec-remove|aic-remove|audio-remove|mesh-remove|decky-remove|desktop-remove)
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
    printf '  %-20s %s%-16s%s %s\n' "$label" "$color" "[$state]" "$C0" "$detail"
}

show_status() {
    require_normal_user
    local failed=0 failed_list="" state detail secondary
    local storage_output="" storage_rc=0 power_output="" power_rc=0
    local ram_output="" ram_rc=0 swap_output="" swap_rc=0
    local persistence_output="" persistence_rc=0 cpu_output="" cpu_rc=0
    local amdgpu_output="" amdgpu_rc=0 radv_output="" radv_rc=0
    local cu_output="" cu_rc=0 cec_output="" cec_rc=0
    local enabled active installed_count pending_count
    local failed_components=()
    sudo -v

    status_script_capture storage_output storage_rc user "$STORAGE_SH" status
    status_script_capture power_output power_rc user "$POWER_SH" status
    status_script_capture ram_output ram_rc user "$RAM_SPLIT_SH" status
    status_script_capture swap_output swap_rc root "$SWAP_SH" verify
    status_script_capture persistence_output persistence_rc user "$PERSISTENCE_SH" status
    status_script_capture cpu_output cpu_rc root "$POWER_SH" cpu-unlock status
    status_script_capture amdgpu_output amdgpu_rc user "$AUDIO_FIX_SH" status
    status_script_capture radv_output radv_rc user "$MESH_SHADER_SH" status
    status_script_capture cu_output cu_rc root "$CU_STATUS_SH" -q
    status_script_capture cec_output cec_rc user "$CEC_SH" status

    printf '%s\n' "${CB}${CC}BC-250 complete system status ${CD}[${TOOLKIT_VERSION}]${C0}"

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
        status_row "RAM / VRAM" "configured" good "VRAM ${state:-ready}; TTM ${secondary:-ready}"
    else
        status_row "RAM / VRAM" "incomplete" bad "${state:-status unavailable}"
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
        status_row "Update persistence" "failed" bad "status unavailable"
        failed=1; failed_components+=("SteamOS update persistence")
    elif [[ $pending_count -gt 0 ]]; then
        status_row "Update persistence" "attention" warn "$installed_count protected; $pending_count stale or foreign"
        failed=1; failed_components+=("SteamOS update persistence")
    elif [[ $installed_count -gt 0 ]]; then
        status_row "Update persistence" "protected" good "$installed_count managed component lists"
    else
        status_row "Update persistence" "not configured" dim "no managed component lists"
    fi

    status_heading "CPU AND POWER"
    enabled=$(systemctl is-enabled cyan-skillfish-governor-smu.service 2>/dev/null || true)
    active=$(systemctl is-active cyan-skillfish-governor-smu.service 2>/dev/null || true)
    detail=$(status_value "$power_output" "max MHz: " || true)
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

    status_heading "GRAPHICS"
    state=$(status_value "$amdgpu_output" "state: " || true)
    detail=$(status_value "$amdgpu_output" "scheduler policy: " || true)
    case "$state" in
        installed) status_row "AMDGPU fixes" "installed" good "${detail:-module active}" ;;
        not-installed) status_row "AMDGPU fixes" "not installed" dim "stock kernel module" ;;
        *)
            status_row "AMDGPU fixes" "${state:-incomplete}" bad "${detail:-module status invalid}"
            failed=1; failed_components+=("AMDGPU kernel fixes") ;;
    esac

    state=$(status_value "$radv_output" "runtime: " || true)
    detail=$(status_value "$radv_output" "FSR4: " || true)
    if [[ $radv_rc -eq 0 && "$state" == installed* ]]; then
        status_row "Mesa / RADV" "installed" good "$state${detail:+; FSR4 $detail}"
    elif [[ $radv_rc -le 1 && ( -z "$state" || "$state" == "not installed"* ) ]]; then
        status_row "Mesa / RADV" "not installed" dim "optional async-compute runtime"
    else
        status_row "Mesa / RADV" "incomplete" bad "${state:-status unavailable}"
        failed=1; failed_components+=("Mesa / RADV async-compute patch")
    fi

    if [[ $cu_rc -ne 0 ]]; then
        status_row "GPU compute units" "unavailable" bad "${cu_output:-register read failed}"
        failed=1; failed_components+=("GPU compute units")
    elif [[ "$cu_output" == 40/40 ]]; then
        status_row "GPU compute units" "40 / 40" good "all compute units routed"
    else
        status_row "GPU compute units" "${cu_output:-unknown}" warn "current hardware route"
    fi

    status_heading "DISPLAY"
    state=$(status_value "$cec_output" "cecd.service: " || true)
    detail=$(status_value "$cec_output" "power status: " || true)
    secondary=$(status_value "$cec_output" "active source: " || true)
    if [[ $cec_rc -ne 0 ]]; then
        status_row "HDMI-CEC" "unavailable" bad "status probe failed"
        failed=1; failed_components+=("CEC")
    elif [[ "$state" == *active* ]]; then
        secondary=${secondary%% *}
        status_row "HDMI-CEC" "active" good "TV ${detail:-unknown}; source ${secondary:-unknown}"
    elif [[ "$cec_output" == *"/dev/cec0: present"* ]]; then
        status_row "HDMI-CEC" "available" warn "daemon ${state:-inactive}"
    else
        status_row "HDMI-CEC" "not available" dim "no active CEC adapter"
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

show_guided_setup_overview() {
    echo
    printf '%s\n' "${CB}${CC}BC-250 guided setup${C0}"
    printf '%s\n' "Complete the foundation in order. Return after each required reboot."
    printf '%s\n' "Power setup deliberately stops before enabling the GPU governor at boot; load-test it first."
    echo
    printf '  %-24s %s\n' "1. AMDGPU kernel fixes" "$(amdgpu_badge)"
    printf '  %-24s %s\n' "2. Power foundation" "$(power_foundation_badge)"
    printf '  %-24s %s\n' "3. RAM / VRAM helper" "$(component_badge "$RAM_SPLIT_SH")"
    printf '  %-24s %s\n' "Optional compressed swap" "$(component_badge "$SWAP_SH")"
    printf '  %-24s %s\n' "Optional Mesa / RADV" "$(radv_badge)"
    printf '  %-24s %s\n' "Optional GPU CU unlock" "$(component_badge "$COMPUTE_SH")"
    printf '  %-24s %s\n' "Optional CPU core unlock" "${CD}[guided test]${C0}"
    printf '  %-24s %s\n' "Optional HDMI-CEC" "$(component_badge "$CEC_SH")"
    echo
    printf '  %-24s %s\n' "Automatic infrastructure" "$(component_badge "$STORAGE_SH")"
    printf '%s\n' "  Persistent storage is installed automatically by components that need it."
    echo
    printf '%s\n' "${CY}Checkpoints:${C0} Reboot after AMDGPU, install RADV, then reboot again to enable async compute safely."
    printf '%s\n' "CMOS, CPU-core, and GPU-CU changes are advanced and stay outside the foundation path."
    pause_key
}

cmd_guided_setup_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "Setup overview|${CD}[read only]${C0}|Show the recommended order, current component state, and restart checkpoints."
            "Step 1 - AMDGPU kernel fixes|$(amdgpu_badge)|Build and install the required kernel module, but leave sched_policy=2 off. Reboot before RADV setup."
            "Step 2 - Power foundation|$(power_foundation_badge)|Install ACPI, reboot, then load-test the GPU governor before enabling it at boot."
            "Step 3 - Memory balance|$(component_badge "$RAM_SPLIT_SH")|Install the helper, then choose CMOS minimum VRAM and the dynamic TTM limit."
            "Optional performance|$(radv_badge)|Build the Mesa RADV patch that enables GFX1013 async compute, or tune GPU and CPU behavior. RADV takes about 3-5 minutes."
            "Optional GPU CU unlock|$(component_badge "$COMPUTE_SH")|Inspect the harvest map, test live routing, stress-test it, then choose whether to persist it."
            "Optional CPU core unlock|${CD}[guided test]${C0}|Test eight cores once, then choose one automatic unlock method: standard Linux or EFI pre-boot."
            "Optional devices||Configure HDMI audio or CEC, or install AIC8800 support only when matching hardware is present."
            "Choose control interface||Install Decky for Gaming Mode, Plasma for desktop, or the standalone Trainer."
            "Finish - Verify system|${CD}[read only]${C0}|Run the complete status report after required reboot and sign-out checkpoints."
        )
        menu_select "BC-250 guided setup  ${CD}(safe order)${C0}" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) show_guided_setup_overview ;;
            1) run_menu_action amdgpu ;;
            2) run_menu_child power ;;
            3) run_menu_child ram ;;
            4) cmd_performance_menu ;;
            5) run_menu_child compute ;;
            6) run_menu_child cpu-unlock ;;
            7) cmd_devices_menu ;;
            8) cmd_interfaces_menu ;;
            9) run_menu_action status ;;
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
            "Mesa / RADV async-compute patch (optional)|${CG}[menu]${C0}|Enables GFX1013 async compute. Requires the patched AMDGPU module; builds in about 3-5 minutes."
            "AIC8800 WiFi / Bluetooth|${CY}[installer]${C0}|Install only when the system uses the AIC8800 wireless adapter."
        )
        menu_select "BC-250 drivers" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action amdgpu ;;
            1) run_menu_action amdgpu-clean ;;
            2) run_menu_action scheduler-policy ;;
            3) run_menu_action kfd-runlist ;;
            4) run_menu_child radv ;;
            5) run_menu_action wifi ;;
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

cmd_core_system_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "Persistent storage & boot recovery|$(component_badge "$STORAGE_SH")|Installed automatically when needed; open for status, repair, or manual management."
            "AMDGPU kernel fixes|$(amdgpu_badge)|Install kernel-specific telemetry and GFX1013 async-compute fixes, plus display/audio corrections where required. Reboot afterward."
            "AMDGPU scheduler policy|$(scheduler_policy_badge)|Normally enabled by RADV setup after both async-compute halves are installed."
            "Power foundation & tuning|$(power_foundation_badge)|Set up ACPI and the GPU governor, then access GPU and CPU tuning."
            "RAM / VRAM split|$(component_badge "$RAM_SPLIT_SH")|Balance the persistent CMOS minimum and dynamic Linux TTM limit."
            "Compressed swap|$(component_badge "$SWAP_SH")|Choose mutually exclusive zram or zswap-backed disk swap profiles."
            "SteamOS update protection|${CG}[menu]${C0}|Protect installed integration and recover supported settings after updates."
        )
        menu_select "BC-250 core system" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_child storage ;;
            1) run_menu_action amdgpu ;;
            2) run_menu_action scheduler-policy ;;
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
            "Mesa / RADV async-compute patch|$(radv_badge)|Enables GFX1013 async compute globally. Requires the active patched AMDGPU module; builds in about 3-5 minutes."
            "GPU and CPU tuning|${CG}[menu]${C0}|Adjust GPU clocks, load response, ramp behavior, and CPU undervolt/overclock."
        )
        menu_select "BC-250 performance tuning" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_child radv ;;
            1) run_menu_child power ;;
        esac
    done
}

cmd_devices_menu() {
    require_terminal
    require_normal_user
    while true; do
        local items=(
            "HDMI audio|${CG}[menu]${C0}|Enable Dolby Digital 5.1 encoding or revert to the default HDMI stereo profile."
            "CEC / HDMI control|$(component_badge "$CEC_SH")|Set up TV and receiver behavior, then access everyday HDMI controls."
            "AIC8800 WiFi / Bluetooth|${CY}[hardware specific]${C0}|Install only when the system uses the AIC8800 wireless adapter."
        )
        menu_select "BC-250 display & connectivity" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) cmd_audio_menu ;;
            1) run_menu_child cec ;;
            2) run_menu_action wifi ;;
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
            "Complete system status|${CD}[read only]${C0}|Show a compact health dashboard for storage, power, CPU core unlock, graphics, and display integration."
            "SteamOS update recovery|${CG}[menu]${C0}|Inspect protection or restore supported settings from the newest update snapshot."
            "Clean AMDGPU build tree|${CY}[cleanup]${C0}|Reset patched source and build output while retaining downloads and dependencies."
            "Manage installed components|${CG}[menu]${C0}|Review removal plans, uninstall components, or permanently purge preserved data."
        )
        menu_select "BC-250 maintenance & recovery" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_menu_action status ;;
            1) run_menu_child persistence ;;
            2) run_menu_action amdgpu-clean ;;
            3) run_menu_child manage ;;
        esac
    done
}

cmd_menu() {
    require_terminal
    require_normal_user
    start_sudo_session
    while true; do
        local items=(
            "Start here - Guided setup|${CG}[recommended]${C0}|Follow the safe dependency order with reboot, load-test, and sign-out checkpoints."
            "Core system|${CG}[menu]${C0}|Configure storage, AMDGPU, power foundations, memory balance, and update protection."
            "Performance tuning|${CG}[menu]${C0}|Configure Mesa / RADV and optional GPU or CPU tuning after setup is stable."
            "Hardware unlocks|${CG}[menu]${C0}|Test GPU compute units or CPU cores with explicit stability and recovery steps."
            "Display & connectivity|${CG}[menu]${C0}|Configure HDMI audio, HDMI-CEC, or hardware-specific AIC8800 wireless support."
            "Control interfaces|${CG}[menu]${C0}|Install Decky, Plasma, or the standalone BC250 Trainer."
            "Maintenance & recovery|${CG}[menu]${C0}|Verify, repair, clean build state, remove components, or purge preserved data."
            "Complete system status|${CD}[read only]${C0}|Show a compact health dashboard for storage, power, CPU core unlock, graphics, and display integration."
        )
        menu_select "BC-250 SteamOS toolkit ${CD}[${TOOLKIT_VERSION}]${C0}" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) cmd_guided_setup_menu ;;
            1) cmd_core_system_menu ;;
            2) cmd_performance_menu ;;
            3) cmd_unlocks_menu ;;
            4) cmd_devices_menu ;;
            5) cmd_interfaces_menu ;;
            6) cmd_maintenance_menu ;;
            7) run_menu_action status ;;
        esac
    done
}

cmd_help() {
    cat << EOF
Usage: $0 [menu|setup|status|inventory-json|action OPERATION_ID|drivers|unlocks|storage-updates|interfaces|power|ram|swap|compute|cpu-unlock|cec|audio-output|hdmi-ac3-enable|hdmi-ac3-revert|storage|persistence|wifi|amdgpu|amdgpu-clean|scheduler-policy|kfd-runlist|radv|decky|desktop|trainer|manage|help]

Run without arguments in a terminal to open the unified toolkit menu.
Run the toolkit as the logged-in Deck user, not with sudo; child tools request
administrator access when needed.

Commands:
  setup                  Open the status-aware guided setup checklist
  status                 Show a read-only component status overview
  inventory-json         Emit versioned JSON component inventory for automation
  action OPERATION_ID    Run one fixed, noninteractive dashboard operation
  drivers                Open AMDGPU, Mesa / RADV, and wireless drivers
  unlocks                Open GPU compute-unit and CPU core unlocks
  storage-updates        Open persistent storage and update protection
  interfaces             Open Decky, Plasma, and Trainer installers
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
  amdgpu                 Confirm and build the AMDGPU kernel fixes
  amdgpu-clean           Confirm and clean the AMDGPU kernel build tree
  scheduler-policy       Advanced: toggle policy only after RADV is installed
  kfd-runlist            Experimental: toggle the KFD HWS TLB-flush workaround
  radv                   Open the global Mesa / RADV async-compute patch
  decky                  Confirm and run the Decky plugin installer
  desktop                Confirm and run the Plasma desktop-control installer
  trainer                Download and install the latest BC250 Trainer release
  manage                 Open installed-component maintenance and cleanup

Compatibility aliases: audio (amdgpu), mesh (radv)

Action operation IDs:
  storage-install        power-install          ram-install
  swap-zram-install      swap-zswap-install     compute-build
  cec-setup              persistence-install
  aic-install            audio-build            mesh-setup
  decky-install          desktop-install
  storage-repair         cec-repair
  storage-remove         power-remove           ram-remove
  swap-remove
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
    setup) (($# == 0)) || die "Usage: $0 setup"; cmd_guided_setup_menu ;;
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
    amdgpu|audio) (($# == 0)) || die "Usage: $0 amdgpu"; install_audio_fix ;;
    amdgpu-clean) (($# == 0)) || die "Usage: $0 amdgpu-clean"; clean_audio_fix ;;
    scheduler-policy) (($# == 0)) || die "Usage: $0 scheduler-policy"; toggle_scheduler_policy ;;
    kfd-runlist) (($# == 0)) || die "Usage: $0 kfd-runlist"; toggle_kfd_runlist ;;
    radv|mesh) (($# == 0)) || die "Usage: $0 radv"; require_normal_user; run_script "$MESH_SHADER_SH" menu ;;
    decky) (($# == 0)) || die "Usage: $0 decky"; install_decky ;;
    desktop) (($# == 0)) || die "Usage: $0 desktop"; install_desktop ;;
    trainer) (($# == 0)) || die "Usage: $0 trainer"; install_trainer ;;
    manage) (($# == 0)) || die "Usage: $0 manage"; run_script "$MAINTENANCE_SH" menu ;;
    help|-h|--help) (($# == 0)) || die "Usage: $0 help"; cmd_help ;;
    *) cmd_help >&2; exit 1 ;;
esac
