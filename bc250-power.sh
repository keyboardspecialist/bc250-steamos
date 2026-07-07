#!/usr/bin/env bash
# bc250-power.sh
#
# Complete power-management setup for the BC-250 on SteamOS 3.8.x:
#
#   ACPI fix (bc250-collective/bc250-acpi-fix):
#     SSDT-CST -> CPU C-states (C1/C2/C3 idle sleep)
#     SSDT-PST -> CPU P-states (800-3200 MHz cpufreq scaling)
#     Loaded as an early-initrd ACPI override via GRUB. The BC-250 BIOS
#     ships no CPU power tables at all -- without this, cores never idle.
#
#   GPU governor (filippor/cyan-skillfish-governor, SMU variant):
#     Dynamic freq/voltage via SMU firmware calls. NO kernel patch needed.
#     Without a governor the GPU is locked at 1500 MHz and idles hot.
#
# SteamOS persistence model used throughout:
#   /var/lib/bc250-40cu  master copies (binaries, cpio, SSDTs)  -- survives updates
#   /etc                 configs, systemd units, grub defaults  -- survives updates
#   /boot                cpio must live here for GRUB           -- WIPED by updates
#                        -> a boot-time self-heal service restores it
#
# Usage (root):
#   ./bc250-power.sh acpi          install ACPI override + self-heal
#   ./bc250-power.sh governor      install SMU GPU governor (test-start)
#   ./bc250-power.sh enable        enable governor + cpufreq at boot
#   ./bc250-power.sh status        clocks, C-states, temps, services
#   ./bc250-power.sh all           acpi + governor
set -euo pipefail

PREFIX="/var/lib/bc250-40cu"
BIN_DIR="$PREFIX/bin"
ACPI_DIR="$PREFIX/acpi"
CPIO_MASTER="$ACPI_DIR/acpi_override.cpio"
CPIO_BOOT="/boot/acpi_override.cpio"
ACPI_RAW_BASE="https://raw.githubusercontent.com/bc250-collective/bc250-acpi-fix/main"

GOV_BIN="$BIN_DIR/cyan-skillfish-governor-smu"
PERF_BIN="$BIN_DIR/cyan-skillfish-performance-mode"
GOV_CONF_DIR="/etc/cyan-skillfish-governor-smu"
GOV_CONF="$GOV_CONF_DIR/config.toml"
GOV_UNIT="/etc/systemd/system/cyan-skillfish-governor-smu.service"
GOV_SVC="cyan-skillfish-governor-smu.service"
DBUS_POLICY="/etc/dbus-1/system.d/com.cyan.SkillFishGovernor.conf"
GOV_API="https://api.github.com/repos/filippor/cyan-skillfish-governor/releases/latest"
GOV_RAW="https://raw.githubusercontent.com/filippor/cyan-skillfish-governor/smu"

HEAL_UNIT="/etc/systemd/system/bc250-acpi-heal.service"
CPUFREQ_UNIT="/etc/systemd/system/bc250-cpufreq.service"

FREQ_STATE="$GOV_CONF_DIR/freq-state"
RESTORE_BIN="$BIN_DIR/bc250-gpu-freq-restore"
RESTORE_UNIT="/etc/systemd/system/bc250-gpu-freq-restore.service"
RESTORE_SVC="bc250-gpu-freq-restore.service"

# CPU OC (bc250-collective/bc250_smu_oc) -- fetched from upstream at a pinned
# commit, then our SteamOS patches (shipped in smu-oc-patches/ next to this
# script) are overlaid. No local clone is kept.
OC_PIN="43d6b4c6e38c57bc9ec8908c44675ce7d5fd3d2f"
OC_TARBALL="https://github.com/bc250-collective/bc250_smu_oc/archive/$OC_PIN.tar.gz"
OC_PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/smu-oc-patches"
OC_DIR="$PREFIX/smu-oc"
OC_STAGE_CONF="$OC_DIR/overclock.conf"
OC_CONF="/etc/bc250-smu-oc.conf"
OC_UNIT="/etc/systemd/system/bc250-smu-oc.service"
OC_SVC="bc250-smu-oc.service"

log()  { echo -e "\033[1;32m[power]\033[0m $*"; }
warn() { echo -e "\033[1;33m[power]\033[0m $*"; }
die()  { echo -e "\033[1;31m[power]\033[0m $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

RO_WAS_DISABLED=0
unlock_rootfs() {
    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        steamos-readonly disable; RO_WAS_DISABLED=1
    fi
}
# NB: must return 0 when idle -- a nonzero return from the EXIT trap under
# set -e overrides the script's real exit status (every run would exit 1)
relock_rootfs() {
    if [[ $RO_WAS_DISABLED -eq 1 ]]; then
        steamos-readonly enable
        RO_WAS_DISABLED=0
    fi
}

# Both the GPU governor and the CPU OC tool drive the SMU through the same
# PCI-config indirect window (0xB8/0xBC) -- never let them run concurrently.
GOV_STOPPED=0
pause_governor() {
    if systemctl is-active "$GOV_SVC" >/dev/null 2>&1; then
        log "Pausing GPU governor while touching the SMU..."
        systemctl stop "$GOV_SVC"; GOV_STOPPED=1
    fi
}
resume_governor() {
    if [[ $GOV_STOPPED -eq 1 ]]; then
        systemctl start "$GOV_SVC" && log "GPU governor resumed."
        GOV_STOPPED=0
    fi
}

cleanup() { tui_show_cursor; resume_governor; relock_rootfs; }
trap cleanup EXIT

# ========================= pure-bash TUI menu =============================
# Zero dependencies: ANSI colors + read -rsn1 keyboard handling. The guided
# menu (run with no arguments) is a thin skin -- every action calls the same
# cmd_* function as the CLI, so nothing is menu-only.
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
# action drops back to the menu instead of killing it, and the subshell
# still relocks the rootfs / resumes the governor on the way out
run_action() {
    local rc=0
    ( trap cleanup EXIT; "$@" ) || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo -e "${CR}${CB}[power]${C0} action failed (exit $rc) -- see message above."
    fi
    pause_key
}

b_ok()   { printf '%s' "${CG}[$1]${C0}"; }
b_mid()  { printf '%s' "${CY}[$1]${C0}"; }
b_off()  { printf '%s' "${CD}[$1]${C0}"; }

c_state() {   # colorize systemctl is-enabled / is-active words
    case "$1" in
        enabled|active|running) printf '%s' "${CG}$1${C0}" ;;
        failed|masked)          printf '%s' "${CR}$1${C0}" ;;
        disabled|inactive|-)    printf '%s' "${CD}$1${C0}" ;;
        *)                      printf '%s' "${CY}$1${C0}" ;;
    esac
}

badge_acpi() {
    if compgen -G /sys/devices/system/cpu/cpu0/cpufreq >/dev/null; then b_ok "active"
    elif [[ -f "$HEAL_UNIT" ]]; then b_mid "installed - reboot pending"
    else b_off "not installed"; fi
}
badge_governor() {
    if systemctl is-active "$GOV_SVC" >/dev/null 2>&1; then b_ok "running"
    elif [[ -x "$GOV_BIN" ]]; then b_mid "installed - not running"
    else b_off "not installed"; fi
}
badge_gov_boot() {
    if [[ "$(systemctl is-enabled "$GOV_SVC" 2>/dev/null)" == enabled ]]; then b_ok "enabled"
    else b_off "not enabled"; fi
}
badge_freq() {
    if [[ -f "$FREQ_STATE" ]]; then
        b_mid "saved: $( (. "$FREQ_STATE" && echo "$MODE ${A:-} ${B:-}") 2>/dev/null | xargs || true)"
    else b_off "config defaults"; fi
}
badge_oc() {
    local f=""
    [[ -f "$OC_CONF" ]] && f=", $(sed -n 's/^frequency = //p' "$OC_CONF" | head -1) MHz"
    if [[ "$(systemctl is-enabled "$OC_SVC" 2>/dev/null)" == enabled ]]; then b_ok "enabled$f"
    elif [[ -f "$OC_CONF" || -f "$OC_STAGE_CONF" ]]; then b_mid "detected - not enabled"
    else b_off "stock"; fi
}

# ============================== ACPI fix ==================================
cmd_acpi() {
    require_root
    mkdir -p "$ACPI_DIR"

    # --- fetch SSDTs and build the override cpio (master in /var/lib) -----
    if [[ ! -f "$CPIO_MASTER" ]]; then
        log "Fetching SSDT tables (bc250-collective/bc250-acpi-fix)..."
        local work=/tmp/bc250-acpi
        rm -rf "$work"; mkdir -p "$work/kernel/firmware/acpi"
        curl -fL -o "$work/kernel/firmware/acpi/SSDT-CST.aml" "$ACPI_RAW_BASE/SSDT-CST.aml"
        curl -fL -o "$work/kernel/firmware/acpi/SSDT-PST.aml" "$ACPI_RAW_BASE/SSDT-PST.aml"
        # keep master copies of the raw tables too
        cp "$work"/kernel/firmware/acpi/*.aml "$ACPI_DIR/"

        command -v cpio >/dev/null 2>&1 || {
            unlock_rootfs
            pacman -Sy --noconfirm cpio || die "cpio unavailable and pacman install failed."
        }
        log "Building early-initrd ACPI override cpio..."
        ( cd "$work" && find kernel | cpio -o -H newc > "$CPIO_MASTER" )
        log "Master cpio -> $CPIO_MASTER"
    else
        log "Master cpio already built at $CPIO_MASTER"
    fi

    # --- install into /boot and wire up GRUB ------------------------------
    unlock_rootfs
    cp -f "$CPIO_MASTER" "$CPIO_BOOT"
    log "Installed -> $CPIO_BOOT"

    # /etc/default/grub persists across updates; upstream grub-mkconfig
    # honors GRUB_EARLY_INITRD_LINUX_CUSTOM (file must sit in /boot).
    if grep -q '^GRUB_EARLY_INITRD_LINUX_CUSTOM=' /etc/default/grub 2>/dev/null; then
        sed -i 's|^GRUB_EARLY_INITRD_LINUX_CUSTOM=.*|GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"|' \
            /etc/default/grub
    else
        echo 'GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"' >> /etc/default/grub
    fi
    log "GRUB_EARLY_INITRD_LINUX_CUSTOM set in /etc/default/grub"

    log "Regenerating GRUB config..."
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    else
        grub-mkconfig -o /boot/grub/grub.cfg
    fi

    if grep -q 'acpi_override.cpio' /boot/grub/grub.cfg 2>/dev/null; then
        log "grub.cfg references the override -- good."
    else
        warn "grub.cfg does NOT reference acpi_override.cpio."
        warn "Your SteamOS grub build may ignore GRUB_EARLY_INITRD_LINUX_CUSTOM."
        warn "Fallback: manually prepend it on the initrd line(s) in /boot/grub/grub.cfg:"
        warn "    initrd /acpi_override.cpio /initramfs-...img"
        warn "(the self-heal service checks the cpio file, not the cfg edit)"
    fi

    # --- self-heal service: SteamOS updates wipe /boot --------------------
    log "Installing boot-time self-heal service..."
    cat > "$HEAL_UNIT" << EOF
[Unit]
Description=BC-250 ACPI override self-heal (restore after SteamOS updates)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  if [[ ! -f $CPIO_BOOT ]] || ! cmp -s "$CPIO_MASTER" "$CPIO_BOOT"; then \
    steamos-readonly disable; \
    cp -f "$CPIO_MASTER" "$CPIO_BOOT"; \
    command -v update-grub >/dev/null && update-grub || grub-mkconfig -o /boot/grub/grub.cfg; \
    steamos-readonly enable; \
    echo "bc250: ACPI override restored after OS update; REBOOT to re-activate C/P-states" | systemd-cat -p warning; \
  fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # --- cpufreq governor setter (schedutil once P-states exist) ----------
    cat > "$CPUFREQ_UNIT" << 'EOF'
[Unit]
Description=BC-250 set schedutil cpufreq governor (needs ACPI P-states)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  if compgen -G /sys/devices/system/cpu/cpu0/cpufreq >/dev/null; then \
    echo schedutil | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null; \
  else \
    echo "bc250: cpufreq not present -- ACPI override not active this boot" | systemd-cat -p warning; \
  fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bc250-acpi-heal.service bc250-cpufreq.service
    relock_rootfs

    log "ACPI fix installed. REBOOT required, then verify:"
    log "  ls /sys/devices/system/cpu/cpu0/cpuidle/          # state0..state3"
    log "  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies"
    log "  (expect 800 MHz .. 3200 MHz steps)"
}

# ============================ GPU governor ================================
check_conflicts() {
    local s
    for s in cyan-skillfish-governor.service cyan-skillfish-governor-tt.service \
             oberon-governor.service; do
        if systemctl is-active "$s" >/dev/null 2>&1; then
            warn "Conflicting governor $s active -- disabling (two controllers fight)."
            systemctl disable --now "$s"
        fi
    done
}

cmd_governor() {
    require_root
    mkdir -p "$BIN_DIR" "$GOV_CONF_DIR"
    check_conflicts

    log "Resolving latest cyan-skillfish-governor-smu release..."
    local url api_json rel_tag
    api_json=$(curl -fsSL "$GOV_API") || die "GitHub API request failed (network?)."
    # Pin any raw-file fallback fetches to the SAME release as the binary --
    # branch HEAD can have renamed D-Bus interfaces vs the release binary.
    rel_tag=$(grep -oP '"tag_name":\s*"\K[^"]+' <<< "$api_json" | head -1 || true)
    [[ -n "$rel_tag" ]] && GOV_RAW="https://raw.githubusercontent.com/filippor/cyan-skillfish-governor/$rel_tag"
    log "Release: ${rel_tag:-unknown} (raw fallbacks pinned to it)"
    # NB: '|| true' guards are load-bearing -- under set -e/pipefail a
    # non-matching grep would otherwise kill the script silently.
    url=$(grep -oP '"browser_download_url":\s*"\K[^"]*smu[^"]*x86_64[^"]*\.tar\.gz' \
              <<< "$api_json" | head -1 || true)
    [[ -n "$url" ]] || url=$(grep -oP '"browser_download_url":\s*"\K[^"]*\.tar\.gz' \
              <<< "$api_json" | head -1 || true)
    [[ -n "$url" ]] || die "No .tar.gz asset found in the latest release. Assets were:
$(grep -oP '"browser_download_url":\s*"\K[^"]*' <<< "$api_json" || echo '  (none / API rate-limited)')"
    log "  $url"

    local work=/tmp/csg-install
    rm -rf "$work"; mkdir -p "$work"
    curl -fL -o "$work/csg.tar.gz" "$url"
    tar -xf "$work/csg.tar.gz" -C "$work"

    local bin perf policy
    bin=$(find "$work" -type f -name 'cyan-skillfish-governor-smu' \
              ! -name '*.service' ! -name '*.spec' | head -1 || true)
    [[ -n "$bin" ]] || die "No prebuilt binary in archive. Contents:
$(find "$work" -type f | head -20)"
    install -m 755 "$bin" "$GOV_BIN";  log "Binary -> $GOV_BIN"

    # perf-mode helper + D-Bus policy: not always in the tarball -- fall
    # back to fetching them straight from the smu branch of the repo.
    perf=$(find "$work" -type f -name 'cyan-skillfish-performance-mode*' | head -1 || true)
    if [[ -n "$perf" ]]; then
        install -m 755 "$perf" "$PERF_BIN"
    else
        log "Helper not in tarball; fetching from repo..."
        curl -fL -o "$PERF_BIN" "$GOV_RAW/scripts/cyan-skillfish-performance-mode" \
            || warn "Could not fetch perf-mode helper; busctl SetRange works as a substitute."
        [[ -s "$PERF_BIN" ]] && chmod 755 "$PERF_BIN" || rm -f "$PERF_BIN"
    fi
    [[ -x "$PERF_BIN" ]] && log "Perf-mode helper -> $PERF_BIN"

    # D-Bus policy: upstream's shipped policy file is STALE vs its own binary
    # (file grants com.cyan.SkillFishGovernor; the v0.4.x binary requests
    # com.cyanskillfish.Governor -- verified via strings on the binary).
    # Write our own policy granting both names.
    mkdir -p /etc/dbus-1/system.d
    cat > "$DBUS_POLICY" << 'EOF'
<!DOCTYPE busconfig PUBLIC
 "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="root">
    <allow own="com.cyan.SkillFishGovernor"/>
    <allow own="com.cyanskillfish.Governor"/>
    <allow send_destination="com.cyan.SkillFishGovernor"/>
    <allow send_destination="com.cyanskillfish.Governor"/>
  </policy>
  <policy context="default">
    <allow send_destination="com.cyan.SkillFishGovernor"/>
    <allow send_destination="com.cyanskillfish.Governor"/>
    <allow send_interface="com.cyan.SkillFishGovernor.PerformanceMode"/>
    <allow send_interface="com.cyanskillfish.Governor.PerformanceMode"/>
    <allow send_interface="org.freedesktop.DBus.Properties"/>
  </policy>
</busconfig>
EOF
    log "D-Bus policy (dual-name) -> $DBUS_POLICY"
    # dbus-broker only reliably reloads files in dirs it saw at launch; try a
    # reload, and warn that a reboot may be needed if the dir is brand new.
    busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig \
        2>/dev/null || warn "D-Bus policy reload failed; a reboot will activate it."

    if [[ -f "$GOV_CONF" ]]; then
        warn "Existing config kept at $GOV_CONF"
    else
        log "Writing tuned config (38/40 CU, docs-schema) -> $GOV_CONF"
        cat > "$GOV_CONF" << 'EOF'
# BC-250 SMU governor -- tuned for the 38/40 CU unlock on stock-class cooling.
# Full community voltage curve; operating range capped at 1500 MHz (the
# unlock sweet spot). Raise live without restart when cooling allows:
#   cyan-skillfish-performance-mode --range 0 2000
# Thermal throttling applies regardless of range.

[timing.intervals]
sample = 500
adjust = 200_000

[gpu-usage]
fix-metrics = true          # also fixes MangoHud/radeontop 655% bug
method = "busy-flag"
flush-every = 10

[gpu]
set-method = "smu"          # firmware calls; no kernel patch

[dbus]
enabled = true

[timing.ramp-rates]
normal = 1
burst = 50

[timing]
burst-samples = 60
down-events = 5

[frequency-thresholds]
adjust = 10

[load-target]
upper = 0.80
lower = 0.65

[frequency-range]
max = 1500                  # sustained-safe with 38 CUs routed

[temperature]
throttling = 85
throttling_recovery = 75

# Voltage curve: flat 1000 mV ceiling (2026 community finding: most boards
# hold it; bump the TOP point +15-25 mV only if yours proves unstable there)
[[safe-points]]
frequency = 1000
voltage = 800

[[safe-points]]
frequency = 1500
voltage = 900

[[safe-points]]
frequency = 2000
voltage = 1000

[[safe-points]]
frequency = 2150
voltage = 1000
EOF
    fi

    log "Writing systemd unit (persistent paths) -> $GOV_UNIT"
    cat > "$GOV_UNIT" << EOF
[Unit]
Description=Cyan Skillfish GPU governor (SMU) -- BC-250
After=multi-user.target bc250-cu-live-manager.service

[Service]
Type=simple
ExecStart=$GOV_BIN $GOV_CONF
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload

    install_freq_persistence force

    log "Test-starting (not yet enabled at boot)..."
    systemctl restart "$GOV_SVC"; sleep 2
    systemctl is-active "$GOV_SVC" >/dev/null || {
        journalctl -u "$GOV_SVC" -n 30 --no-pager
        die "Governor failed to start -- log above."
    }
    log "Running. Load the GPU for a few minutes; watch clocks and temps:"
    log "  watch -n1 'cat /sys/class/drm/card*/device/pp_dpm_sclk 2>/dev/null; sensors | grep -E \"edge|PPT\"'"
    log "Then lock it in: sudo $0 enable"
}

# ================================ misc ====================================
# Live GPU frequency control. Prefers the perf-mode helper; falls back to
# direct busctl using the bus name the v0.4.x binary ACTUALLY registers
# (com.cyanskillfish.Governor -- not the documented com.cyan.SkillFishGovernor).
BUS_NAME="com.cyanskillfish.Governor"
BUS_PATH="/com/cyanskillfish/Governor"
BUS_IFACE="com.cyanskillfish.Governor.PerformanceMode"

gov_dbus() { busctl --system call "$BUS_NAME" "$BUS_PATH" "$BUS_IFACE" "$@"; }

# --- freq persistence: save the last applied setting and reapply at boot ---
# The governor's D-Bus state is runtime-only; a restart/reboot reverts to
# config.toml. We record the last 'freq' command in a state file and a
# oneshot service replays it once the governor's bus name is up.
install_freq_persistence() {
    # fast path for everyday 'freq' calls; 'force' (used by installs)
    # rewrites the files so script updates propagate
    if [[ "${1:-}" != force && -x "$RESTORE_BIN" && -f "$RESTORE_UNIT" ]] \
       && [[ "$(systemctl is-enabled "$RESTORE_SVC" 2>/dev/null)" == enabled ]]; then
        return 0
    fi

    cat > "$RESTORE_BIN" << EOF
#!/usr/bin/env bash
# bc250: reapply the saved GPU freq setting after the governor starts.
# Written by bc250-power.sh -- do not edit; it gets regenerated.
set -u
STATE="$FREQ_STATE"
PERF="$PERF_BIN"
BUS_NAME="$BUS_NAME"; BUS_PATH="$BUS_PATH"; BUS_IFACE="$BUS_IFACE"
[[ -f "\$STATE" ]] || exit 0
. "\$STATE"
# governor registers its bus name shortly after start; give it up to 30 s
for _ in \$(seq 1 30); do
    busctl --system status "\$BUS_NAME" >/dev/null 2>&1 && break
    sleep 1
done
if ! busctl --system status "\$BUS_NAME" >/dev/null 2>&1; then
    echo "bc250: governor bus name never appeared -- GPU freq state NOT restored" \
        | systemd-cat -p warning
    exit 1
fi
if [[ -x "\$PERF" ]]; then
    case "\$MODE" in
        max)   "\$PERF" --on ;;
        pin)   "\$PERF" --fixed-frequency "\$A" ;;
        range) "\$PERF" --range "\$A" "\$B" ;;
        *)     exit 0 ;;
    esac
else
    case "\$MODE" in
        max)   busctl --system call "\$BUS_NAME" "\$BUS_PATH" "\$BUS_IFACE" Enable ;;
        pin)   busctl --system call "\$BUS_NAME" "\$BUS_PATH" "\$BUS_IFACE" SetFixedFrequency u "\$A" ;;
        range) busctl --system call "\$BUS_NAME" "\$BUS_PATH" "\$BUS_IFACE" SetRange uu "\$A" "\$B" ;;
        *)     exit 0 ;;
    esac
fi && echo "bc250: restored GPU freq setting (\$MODE \${A:-} \${B:-})" | systemd-cat -p info
EOF
    chmod 755 "$RESTORE_BIN"

    cat > "$RESTORE_UNIT" << EOF
[Unit]
Description=BC-250 restore saved GPU freq setting (survives reboots)
After=$GOV_SVC

[Service]
Type=oneshot
ExecStart=$RESTORE_BIN
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$RESTORE_SVC" >/dev/null 2>&1
    log "Boot-time freq restore installed ($RESTORE_SVC)."
}

save_freq_state() {           # save_freq_state <max|pin|range> [a] [b]
    install_freq_persistence
    printf 'MODE=%s\nA=%s\nB=%s\n' "$1" "${2:-}" "${3:-}" > "$FREQ_STATE"
    log "Saved -- reapplied automatically at boot ('$0 freq auto' to clear)."
}

clear_freq_state() {
    if [[ -f "$FREQ_STATE" ]]; then
        rm -f "$FREQ_STATE"
        log "Saved freq state cleared -- boots return to config defaults."
    fi
}

cmd_freq() {
    require_root
    systemctl is-active "$GOV_SVC" >/dev/null 2>&1 \
        || die "Governor not running -- freq control goes through it."

    local a="${1:-}" b="${2:-}"
    # Helper handles everything including status; use it when available.
    if [[ -x "$PERF_BIN" ]]; then
        case "$a" in
            "")            "$PERF_BIN" --status ;;
            status)        "$PERF_BIN" --status ;;
            auto|off)      "$PERF_BIN" --off && clear_freq_state ;;
            max|on)        "$PERF_BIN" --on  && save_freq_state max ;;
            [0-9]*)
                if [[ -n "$b" ]]; then "$PERF_BIN" --range "$a" "$b" && save_freq_state range "$a" "$b"
                else                   "$PERF_BIN" --fixed-frequency "$a" && save_freq_state pin "$a"; fi ;;
            *) die "Usage: $0 freq [status|auto|max|<MHz>|<min> <max>]" ;;
        esac
        return
    fi

    # busctl fallback (helper missing)
    case "$a" in
        ""|status)
            busctl --system get-property "$BUS_NAME" "$BUS_PATH" "$BUS_IFACE" Enabled \
                || warn "Bus name absent -- D-Bus policy not active? (reboot after policy install)" ;;
        auto|off)  gov_dbus Disable && log "Adaptive scaling restored (config defaults apply)." \
                       && clear_freq_state ;;
        max|on)    gov_dbus Enable  && log "Performance mode ON (max frequency, no idle downscale)." \
                       && save_freq_state max ;;
        [0-9]*)
            if [[ -n "$b" ]]; then
                gov_dbus SetRange uu "$a" "$b" && log "Range set: ${a}-${b} MHz (0 = no limit)." \
                    && save_freq_state range "$a" "$b"
            else
                gov_dbus SetFixedFrequency u "$a" && log "Pinned at $a MHz ('$0 freq auto' when done)." \
                    && save_freq_state pin "$a"
            fi ;;
        *) die "Usage: $0 freq [status|auto|max|<MHz>|<min> <max>]" ;;
    esac
}

cmd_helpers() {
    require_root
    mkdir -p "$BIN_DIR" /etc/dbus-1/system.d
    # Pin to the latest release tag so helper and installed binary agree on
    # the D-Bus interface name (HEAD renamed it after v0.4.x).
    local rel_tag
    rel_tag=$(curl -fsSL "$GOV_API" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1 || true)
    [[ -n "$rel_tag" ]] && GOV_RAW="https://raw.githubusercontent.com/filippor/cyan-skillfish-governor/$rel_tag"
    log "Fetching helpers from ${rel_tag:-smu branch HEAD}..."
    curl -fL -o "$PERF_BIN" "$GOV_RAW/scripts/cyan-skillfish-performance-mode" \
        && chmod 755 "$PERF_BIN" && log "  -> $PERF_BIN" \
        || warn "Helper fetch failed; check the scripts/ dir name on the smu branch."
    if [[ ! -s "$DBUS_POLICY" ]] || ! grep -q 'com.cyanskillfish.Governor' "$DBUS_POLICY"; then
        log "Writing dual-name D-Bus policy (upstream's is stale vs its binary)..."
        cat > "$DBUS_POLICY" << 'EOF'
<!DOCTYPE busconfig PUBLIC
 "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="root">
    <allow own="com.cyan.SkillFishGovernor"/>
    <allow own="com.cyanskillfish.Governor"/>
    <allow send_destination="com.cyan.SkillFishGovernor"/>
    <allow send_destination="com.cyanskillfish.Governor"/>
  </policy>
  <policy context="default">
    <allow send_destination="com.cyan.SkillFishGovernor"/>
    <allow send_destination="com.cyanskillfish.Governor"/>
    <allow send_interface="com.cyan.SkillFishGovernor.PerformanceMode"/>
    <allow send_interface="com.cyanskillfish.Governor.PerformanceMode"/>
    <allow send_interface="org.freedesktop.DBus.Properties"/>
  </policy>
</busconfig>
EOF
        busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig \
            2>/dev/null || warn "D-Bus reload failed; reboot to activate the policy."
        systemctl restart "$GOV_SVC" 2>/dev/null || true
    else
        log "Dual-name D-Bus policy already present."
    fi
    log "Test: sudo $PERF_BIN --status"
}

cmd_enable() {
    require_root
    systemctl enable "$GOV_SVC"
    log "Governor enabled at boot (order: CU table -> governor)."
    log "cpufreq + ACPI self-heal were enabled during 'acpi'. All set."
}

# ============================ CPU overclock ===============================
# Wraps bc250-collective/bc250_smu_oc: CPU max boost clock + vid-curve
# undervolt via SMU mailbox messages (queue 3). CPU only -- it never touches
# GPU clocks/voltage, so it coexists with the GPU governor; the only shared
# resource is the SMU indirect window, handled by pause_governor + unit
# ordering. SteamOS-friendly: pure-stdlib python run straight from files
# (no pip/git), sources fetched as a pinned-commit tarball with our patches
# overlaid (see smu-oc-patches/README.md), master copies in /var/lib,
# config + unit in /etc -- all update-proof.

fetch_oc_sources() {
    [[ -f "$OC_PATCH_DIR/transport.py" && -f "$OC_PATCH_DIR/stress_helper.py" ]] \
        || die "Patch overlays not found at $OC_PATCH_DIR (should ship next to this script)."
    local work=/tmp/bc250-smu-oc
    rm -rf "$work"; mkdir -p "$work"
    log "Fetching bc250_smu_oc @ ${OC_PIN:0:7} (pinned)..."
    curl -fsSL "$OC_TARBALL" | tar -xz -C "$work" --strip-components=1 \
        || die "Fetch failed (network?): $OC_TARBALL"
    log "Overlaying SteamOS patches (transaction flock, no-'stress' fallback)..."
    install -m 644 "$OC_PATCH_DIR/transport.py"     "$work/bc250_smu/transport.py"
    install -m 644 "$OC_PATCH_DIR/stress_helper.py" "$work/stress_helper.py"
    mkdir -p "$OC_DIR/bc250_smu"
    install -m 644 "$work"/bc250_apply.py "$work"/bc250_detect.py \
                   "$work"/bc250_limits.py "$work"/stress_helper.py "$OC_DIR/"
    install -m 644 "$work"/bc250_smu/*.py "$OC_DIR/bc250_smu/"
    python3 -m py_compile "$OC_DIR"/*.py "$OC_DIR"/bc250_smu/*.py \
        || die "Staged sources do not compile -- bad fetch or patch/pin mismatch."
    rm -rf "$work"
    log "Staged -> $OC_DIR"
}

install_oc_files() {
    if [[ ! -f "$OC_DIR/bc250_apply.py" || "${1:-}" == force ]]; then
        fetch_oc_sources
    fi
    grep -q 'lock across the whole pair' "$OC_DIR/bc250_smu/transport.py" \
        || warn "transport.py missing the transaction-flock patch -- SMU races with the governor possible; run '$0 cpu-oc update'."
    grep -q '_burn' "$OC_DIR/stress_helper.py" \
        || warn "stress_helper.py missing the no-'stress' fallback -- 'cpu-oc detect' needs the stress binary; run '$0 cpu-oc update'."
}

# detect prefers the real `stress` tool; pacman packages are wiped by SteamOS
# updates, so this may reinstall later. The python burner fallback in
# stress_helper.py covers a failed/unavailable install either way.
ensure_stress() {
    command -v stress >/dev/null 2>&1 && return 0
    log "Installing 'stress' via pacman (SteamOS updates wipe it; will reinstall then)..."
    unlock_rootfs
    pacman -Sy --noconfirm stress \
        || warn "pacman install failed -- detect will use the python burner fallback."
    relock_rootfs
}

oc_detect() {
    require_root
    local freq="${1:-}" vid="${2:-}" temp="${3:-90}"
    [[ -n "$freq" && -n "$vid" ]] || die "Usage: $0 cpu-oc detect <targetMHz> <vidLimit_mV> [tempC]
Community reference: 4000 1275 (retry at 1300 mV if it crashes).
NEVER above 1325 mV -- exceeding it has bricked boards."
    install_oc_files
    ensure_stress
    warn "This stress-steps the CPU in 100 MHz increments and CAN hard-crash"
    warn "the system if pushed too far. Close everything else first."
    warn "The result stays applied afterwards: 'cpu-oc enable' to persist,"
    warn "'cpu-oc off' to revert to stock."
    pause_governor
    local rc=0
    python3 "$OC_DIR/bc250_detect.py" -f "$freq" -v "$vid" -t "$temp" \
            --keep -c "$OC_STAGE_CONF" || rc=$?
    resume_governor
    [[ $rc -eq 0 ]] || die "Detection failed (rc=$rc)."
    log "Detected config -> $OC_STAGE_CONF"
    log "Stability-test now (games / OCCT), watch: grep MHz /proc/cpuinfo"
    log "Happy with it?  sudo $0 cpu-oc enable"
}

oc_apply() {
    require_root
    install_oc_files
    local conf="$OC_CONF"
    [[ -f "$conf" ]] || conf="$OC_STAGE_CONF"
    [[ -f "$conf" ]] || die "No overclock config -- run '$0 cpu-oc detect' first."
    pause_governor
    python3 "$OC_DIR/bc250_apply.py" --apply "$conf"
    resume_governor
}

oc_enable() {
    require_root
    install_oc_files
    [[ -f "$OC_STAGE_CONF" || -f "$OC_CONF" ]] \
        || die "No overclock config -- run '$0 cpu-oc detect' first."
    if [[ -f "$OC_STAGE_CONF" ]]; then
        cp -f "$OC_STAGE_CONF" "$OC_CONF"
        log "Config -> $OC_CONF"
    fi
    cat > "$OC_UNIT" << EOF
[Unit]
Description=BC-250 CPU overclock/undervolt (bc250_smu_oc, SMU)
# strictly before the GPU governor: both drive the same SMU indirect window
Before=$GOV_SVC

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 $OC_DIR/bc250_apply.py --apply $OC_CONF

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$OC_SVC"
    log "CPU OC enabled at boot (ordered before the GPU governor)."
    oc_apply
}

oc_off() {
    require_root
    systemctl disable --now "$OC_SVC" 2>/dev/null || true
    if [[ -d "$OC_DIR/bc250_smu" ]]; then
        pause_governor
        PYTHONPATH="$OC_DIR" python3 - << 'EOF'
from bc250_smu import Bc250Smu
smu = Bc250Smu(use_flock=True)
smu.check_test_message()
smu.q3_0x8f_set_max_cpu_boost_clk(3500)
smu.q3_0x50_scale_f_vid_curve(0)
smu.disable_extra_cpu_gpu_voltage(False)
smu.q3_0x8b_set_cpu_max_temperature(100)
smu.q3_0x8c_set_gpu_max_temperature(100)
print("CPU restored to stock: 3500 MHz, factory vid curve, 100 C limits")
EOF
        resume_governor
    fi
    log "CPU OC disabled at boot and reverted to stock. Config kept --"
    log "re-activate any time with '$0 cpu-oc enable'."
}

oc_status() {
    echo "=== CPU OC (bc250_smu_oc) ==="
    printf '  %-38s %s / %s\n' "$OC_SVC" \
        "$(systemctl is-enabled "$OC_SVC" 2>/dev/null || echo -)" \
        "$(systemctl is-active "$OC_SVC" 2>/dev/null || echo -)"
    if [[ -f "$OC_CONF" ]]; then
        echo "  installed config ($OC_CONF):"
        sed 's/^/    /' "$OC_CONF"
    elif [[ -f "$OC_STAGE_CONF" ]]; then
        echo "  detected but NOT enabled ($OC_STAGE_CONF):"
        sed 's/^/    /' "$OC_STAGE_CONF"
    else
        echo "  no config -- start with: sudo $0 cpu-oc detect 4000 1275"
    fi
    echo "  effective clocks: watch -n1 'grep MHz /proc/cpuinfo'"
}

cmd_cpu_oc() {
    local sub="${1:-status}"
    shift || true
    case "$sub" in
        detect)  oc_detect "$@" ;;
        apply)   oc_apply ;;
        enable)  oc_enable ;;
        off)     oc_off ;;
        status)  oc_status ;;
        update)  require_root; install_oc_files force ;;
        *) die "Usage: $0 cpu-oc {detect <MHz> <mV> [tempC] | enable | apply | off | status | update}" ;;
    esac
}

cmd_status() {
    echo -e "${CB}=== Services ===${C0}"
    local s en ac
    for s in bc250-cu-live-manager "$GOV_SVC" bc250-acpi-heal bc250-cpufreq "$RESTORE_SVC" "$OC_SVC"; do
        en=$(systemctl is-enabled "$s" 2>/dev/null) || en=-
        ac=$(systemctl is-active "$s" 2>/dev/null) || ac=-
        printf '  %-38s %s / %s\n' "$s" "$(c_state "$en")" "$(c_state "$ac")"
    done
    echo
    echo "=== GPU ==="
    if [[ -f "$FREQ_STATE" ]]; then
        echo "  saved freq setting (reapplied at boot): $(tr '\n' ' ' < "$FREQ_STATE")"
    else
        echo "  no saved freq setting -- config defaults apply at boot"
    fi
    cat /sys/class/drm/card*/device/pp_dpm_sclk 2>/dev/null || echo "  pp_dpm_sclk not exposed"
    echo
    echo "=== CPU (ACPI fix active if these exist) ==="
    if compgen -G /sys/devices/system/cpu/cpu0/cpufreq >/dev/null; then
        echo "  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
        echo "  current:  $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) kHz"
        echo "  c-states: $(ls /sys/devices/system/cpu/cpu0/cpuidle/ 2>/dev/null | tr '\n' ' ')"
    else
        echo "  cpufreq absent -- ACPI override not active (not installed, or reboot pending)"
    fi
    echo
    sensors 2>/dev/null | grep -E 'edge|junction|PPT|Tctl|power' || true
}

# ============================ guided menu =================================
menu_freq() {
    while true; do
        local items=(
            "Show current state|$(badge_freq)|Ask the governor for its performance-mode status."
            "Adaptive (auto)||Back to config defaults; clears the saved boot setting."
            "Set max cap||Raise/lower the ceiling, keep adaptive scaling + idle savings."
            "Set min + max range||Floor AND ceiling, adaptive in between."
            "Pin a frequency||Fixed clock, perf mode ON -- no idle downscale. For testing."
            "Max performance||Top of the voltage curve until you switch back to auto."
        )
        menu_select "GPU frequency control  ${CD}(persists across reboots)${C0}" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) run_action cmd_freq status ;;
            1) run_action cmd_freq auto ;;
            2) ask "Max MHz (0-2150 curve, 1500 = tuned default)" "2000"
               run_action cmd_freq 0 "$REPLY" ;;
            3) ask "Min MHz" "1200"; local mn="$REPLY"
               ask "Max MHz" "1800"
               run_action cmd_freq "$mn" "$REPLY" ;;
            4) ask "Pin at MHz" "1800"
               run_action cmd_freq "$REPLY" ;;
            5) run_action cmd_freq max ;;
        esac
    done
}

menu_cpu_oc() {
    while true; do
        local items=(
            "Show OC status|$(badge_oc)|Service state + active overclock config."
            "Detect stable overclock||Guided stress-stepped search. Start here. CAN hard-crash if pushed."
            "Enable at boot||Persist the detected config; applies before the GPU governor."
            "Apply now||Re-apply the saved config immediately."
            "Revert to stock||Disable at boot + back to 3500 MHz / factory curve now."
            "Update tool sources||Re-fetch bc250_smu_oc (pinned commit + our patches)."
        )
        menu_select "CPU overclock / undervolt  ${CD}(bc250_smu_oc)${C0}" "${items[@]}" || return 0
        case $MENU_CHOICE in
            0) run_action oc_status ;;
            1) echo
               echo -e "  ${CR}${CB}Vid limit is the safety-critical number. NEVER above 1325 mV --${C0}"
               echo -e "  ${CR}${CB}exceeding it has bricked boards. 1275 is the community reference;${C0}"
               echo -e "  ${CR}${CB}pure undervolt: target 3500 MHz with a 1000 mV limit.${C0}"
               echo
               ask "Target frequency MHz" "4000"; local f="$REPLY"
               ask "Vid limit mV (max 1325)" "1275"; local v="$REPLY"
               ask "Temp limit C" "90"
               run_action oc_detect "$f" "$v" "$REPLY" ;;
            2) run_action oc_enable ;;
            3) run_action oc_apply ;;
            4) run_action oc_off ;;
            5) run_action install_oc_files force ;;
        esac
    done
}

cmd_menu() {
    [[ -t 0 && -t 1 ]] || die "The menu needs an interactive terminal. See '$0 help' for CLI commands."
    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root -- setup actions will fail."
        ask "Restart with sudo? [Y/n]" "Y"
        if [[ "$REPLY" =~ ^[Yy] ]]; then exec sudo "$0" menu; fi
        echo
    fi
    while true; do
        local items=(
            "Status overview||Health check of every service, clock and temp. Always safe."
            "Step 1 - ACPI fix: CPU idle + scaling|$(badge_acpi)|SSDT override via GRUB + self-heal. Reboot needed after install."
            "Step 2 - GPU governor|$(badge_governor)|Adaptive GPU freq/voltage via SMU. Test under load before step 3."
            "Step 3 - Enable governor at boot|$(badge_gov_boot)|Lock it in once step 2 proves stable."
            "GPU frequency control|$(badge_freq)|Pin / cap / range via the governor. Settings survive reboots."
            "CPU overclock / undervolt|$(badge_oc)|bc250_smu_oc: ~200 mV undervolt even at stock clocks."
            "Reinstall D-Bus helpers||Fixes 'name is not activatable' errors from freq control."
            "Full help||The complete manual for every CLI command."
        )
        menu_select "BC-250 power setup  ${CD}(SteamOS)${C0}" "${items[@]}" || { echo; break; }
        case $MENU_CHOICE in
            0) run_action cmd_status ;;
            1) run_action cmd_acpi ;;
            2) run_action cmd_governor ;;
            3) run_action cmd_enable ;;
            4) menu_freq ;;
            5) menu_cpu_oc ;;
            6) run_action cmd_helpers ;;
            7) cmd_help; pause_key ;;
        esac
    done
}

cmd_help() {
    cat << 'EOF'
bc250-power.sh -- BC-250 power management for SteamOS
==============================================================
CPU C/P-states via ACPI SSDT override + adaptive GPU governor (SMU).
Everything installs to update-proof locations (/etc + /var/lib);
SteamOS updates cannot break any of it.

GUIDED MENU
  Run with no arguments (or 'menu') in a terminal for an interactive,
  color-coded menu: arrow keys / j k to move, Enter to run, q to back
  out. Shows live install/active state per step and walks the setup
  order. Every menu action is one of the CLI commands below.

SETUP COMMANDS (run once, in this order)
  acpi        Install the ACPI fix: SSDT-CST (CPU idle C-states) and
              SSDT-PST (CPU 800-3200 MHz scaling) loaded via GRUB
              early-initrd. Also installs two boot services:
                bc250-acpi-heal  -- restores the override if a SteamOS
                                    update wipes /boot
                bc250-cpufreq    -- sets the schedutil CPU governor
              REBOOT REQUIRED before it takes effect.

  governor    Install cyan-skillfish-governor-smu (filippor): adaptive
              GPU freq/voltage via SMU firmware calls, no kernel patch.
              Downloads the latest release, writes a tuned config
              (voltage curve to 2150 MHz, operating cap 1500 MHz,
              thermal throttle 85C), TEST-STARTS the service but does
              not enable it at boot -- verify under load first.

  helpers     (Re)install the perf-mode helper script and the D-Bus
              policy. Fixes 'name is not activatable' errors. Note the
              policy grants BOTH bus names (upstream's shipped policy
              is stale vs its own binary).

  enable      Enable the governor at boot. Run after you've load-tested
              a 'governor' install.

  all         acpi + governor in sequence.

CPU OVERCLOCK / UNDERVOLT (bc250-collective/bc250_smu_oc, CPU only)
  cpu-oc detect <MHz> <mV> [tempC]
              Find a stable OC: steps up from 3.5 GHz while scaling the
              vid curve to stay under <mV>. Stress-tests each step -- CAN
              hard-crash if pushed. Community reference: detect 4000 1275.
              HARD LIMIT 1325 mV (higher has bricked boards). Even at
              stock 3500 this nets a ~200 mV undervolt = thermal headroom.
              The GPU governor is paused during the run (shared SMU
              mailbox window) and resumed after. Installs the 'stress'
              load tool via pacman if missing (SteamOS updates wipe it;
              it just reinstalls on the next detect run -- and a python
              burner fallback covers it if pacman fails).
  cpu-oc enable     Persist the detected config: /etc/bc250-smu-oc.conf +
                    boot service ordered BEFORE the GPU governor.
  cpu-oc apply      Re-apply the saved config right now.
  cpu-oc off        Disable at boot + revert to stock live (3500 MHz,
                    factory curve, 100 C). Config is kept for re-enable.
  cpu-oc status     Service state + active config.
  cpu-oc update     Re-fetch the tool sources. They come from upstream
                    (bc250-collective/bc250_smu_oc) at a pinned commit
                    with our patches overlaid from smu-oc-patches/ --
                    no local clone, no pip, no git needed. The first
                    detect/apply/enable fetches automatically (network).

EVERYDAY COMMANDS
  status      One-screen health check: all services, GPU DPM level
              table (* = active), CPU cpufreq/C-states (present only if
              the ACPI override loaded this boot), temps and power.

  freq        Live GPU frequency control (through the governor, D-Bus):
    freq              show performance-mode state
    freq 1800         pin at 1800 MHz  (perf mode ON: no idle downscale,
                      remember 'freq auto' when done)
    freq 0 2000       range 0-2000: raises the cap, keeps adaptive
                      scaling and idle savings (0 = no limit)
    freq 1200 1800    floor AND ceiling
    freq max          performance mode at the top of the voltage curve
    freq auto         back to adaptive + config defaults (1500 cap)
              Settings PERSIST across reboots: each set is saved to
              /etc/cyan-skillfish-governor-smu/freq-state and the
              bc250-gpu-freq-restore service reapplies it once the
              governor is up. 'freq auto' clears the saved state.
              Thermal throttling (85C) applies no matter what you set.

PERMANENT TUNING (config file, not this script)
  /etc/cyan-skillfish-governor-smu/config.toml
    [frequency-range] max = 1500     <- permanent ceiling
    [[safe-points]]                  <- the freq/voltage curve; anything
                                        you want to run must have a
                                        voltage point at or above it
  then: systemctl restart cyan-skillfish-governor-smu

STEAM LAUNCH OPTION (per-game max clocks, auto-restores on exit)
  /var/lib/bc250-40cu/bin/cyan-skillfish-performance-mode %command%
  /var/lib/bc250-40cu/bin/cyan-skillfish-performance-mode --range 0 2000 %command%

FILE MAP (what lives where, and why it survives OS updates)
  /var/lib/bc250-40cu/bin/     governor + helper binaries   (persists)
  /var/lib/bc250-40cu/acpi/    SSDTs + master override cpio (persists)
  /var/lib/bc250-40cu/smu-oc/  CPU OC tool (fetched @ pinned commit,
                               patched from smu-oc-patches/)
  /etc/bc250-smu-oc.conf       CPU OC config                (persists)
  /etc/cyan-skillfish-governor-smu/config.toml              (persists)
  /etc/cyan-skillfish-governor-smu/freq-state  last 'freq' setting,
                               replayed at boot by bc250-gpu-freq-restore
  /etc/systemd/system/*.service, /etc/dbus-1/system.d/      (persists)
  /boot/acpi_override.cpio     WIPED by updates -- bc250-acpi-heal
                               restores it and warns in the journal

RELATED (separate scripts, same family)
  bc250-40cu.sh     the 38/40 CU unlock (umr + live manager)
  bc250-cu-status.sh           read-only CU dispatch report
EOF
}

case "${1:-}" in
    acpi)         cmd_acpi ;;
    governor)     cmd_governor ;;
    helpers)      cmd_helpers ;;
    freq)         shift; cmd_freq "$@" ;;
    cpu-oc)       shift; cmd_cpu_oc "$@" ;;
    enable)       cmd_enable ;;
    status)       cmd_status ;;
    all)          cmd_acpi; cmd_governor ;;
    menu)         cmd_menu ;;
    help|-h|--help) cmd_help ;;
    "") if [[ -t 0 && -t 1 ]]; then cmd_menu; exit 0; fi ;&
    *) echo "Usage: $0 {acpi|governor|helpers|freq|cpu-oc|enable|status|all|menu|help}"
       echo "  (no arguments on a terminal opens the guided menu)"
       echo "  freq                 show performance-mode state"
       echo "  freq 1800            pin GPU at 1800 MHz (perf mode)"
       echo "  freq 0 2000          range: no floor, 2000 MHz cap, adaptive"
       echo "  freq auto            back to adaptive + config defaults"
       echo "  freq max             performance mode, full-curve max"
       echo
       echo "Run '$0 help' for the full explanation of every command."
       exit 1 ;;
esac
