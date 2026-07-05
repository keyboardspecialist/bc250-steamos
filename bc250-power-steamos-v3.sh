#!/usr/bin/env bash
# bc250-power-steamos.sh
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
#   ./bc250-power-steamos.sh acpi          install ACPI override + self-heal
#   ./bc250-power-steamos.sh governor      install SMU GPU governor (test-start)
#   ./bc250-power-steamos.sh enable        enable governor + cpufreq at boot
#   ./bc250-power-steamos.sh status        clocks, C-states, temps, services
#   ./bc250-power-steamos.sh all           acpi + governor
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
relock_rootfs() {
    [[ $RO_WAS_DISABLED -eq 1 ]] && { steamos-readonly enable; RO_WAS_DISABLED=0; }
}
trap relock_rootfs EXIT

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
            auto|off)      "$PERF_BIN" --off ;;
            max|on)        "$PERF_BIN" --on ;;
            [0-9]*)
                if [[ -n "$b" ]]; then "$PERF_BIN" --range "$a" "$b"
                else                   "$PERF_BIN" --fixed-frequency "$a"; fi ;;
            *) die "Usage: $0 freq [status|auto|max|<MHz>|<min> <max>]" ;;
        esac
        return
    fi

    # busctl fallback (helper missing)
    case "$a" in
        ""|status)
            busctl --system get-property "$BUS_NAME" "$BUS_PATH" "$BUS_IFACE" Enabled \
                || warn "Bus name absent -- D-Bus policy not active? (reboot after policy install)" ;;
        auto|off)  gov_dbus Disable && log "Adaptive scaling restored (config defaults apply)." ;;
        max|on)    gov_dbus Enable  && log "Performance mode ON (max frequency, no idle downscale)." ;;
        [0-9]*)
            if [[ -n "$b" ]]; then
                gov_dbus SetRange uu "$a" "$b" && log "Range set: ${a}-${b} MHz (0 = no limit)."
            else
                gov_dbus SetFixedFrequency u "$a" && log "Pinned at $a MHz (perf mode on -- '$0 freq auto' when done)."
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

cmd_status() {
    echo "=== Services ==="
    local s
    for s in bc250-cu-live-manager "$GOV_SVC" bc250-acpi-heal bc250-cpufreq; do
        printf '  %-38s %s / %s\n' "$s" \
            "$(systemctl is-enabled "$s" 2>/dev/null || echo -)" \
            "$(systemctl is-active "$s" 2>/dev/null || echo -)"
    done
    echo
    echo "=== GPU ==="
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

cmd_help() {
    cat << 'EOF'
bc250-power-steamos.sh -- BC-250 power management for SteamOS
==============================================================
CPU C/P-states via ACPI SSDT override + adaptive GPU governor (SMU).
Everything installs to update-proof locations (/etc + /var/lib);
SteamOS updates cannot break any of it.

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

EVERYDAY COMMANDS
  status      One-screen health check: all four services, GPU DPM level
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
              All of this is runtime state -- a governor restart or
              reboot returns to the config file. Thermal throttling
              (85C) applies no matter what you set.

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
  /etc/cyan-skillfish-governor-smu/config.toml              (persists)
  /etc/systemd/system/*.service, /etc/dbus-1/system.d/      (persists)
  /boot/acpi_override.cpio     WIPED by updates -- bc250-acpi-heal
                               restores it and warns in the journal

RELATED (separate scripts, same family)
  bc250-40cu-steamos-v2.sh     the 38/40 CU unlock (umr + live manager)
  bc250-cu-status.sh           read-only CU dispatch report
EOF
}

case "${1:-}" in
    acpi)         cmd_acpi ;;
    governor)     cmd_governor ;;
    helpers)      cmd_helpers ;;
    freq)         shift; cmd_freq "$@" ;;
    enable)       cmd_enable ;;
    status)       cmd_status ;;
    all)          cmd_acpi; cmd_governor ;;
    help|-h|--help) cmd_help ;;
    *) echo "Usage: $0 {acpi|governor|helpers|freq|enable|status|all|help}"
       echo "  freq                 show performance-mode state"
       echo "  freq 1800            pin GPU at 1800 MHz (perf mode)"
       echo "  freq 0 2000          range: no floor, 2000 MHz cap, adaptive"
       echo "  freq auto            back to adaptive + config defaults"
       echo "  freq max             performance mode, full-curve max"
       echo
       echo "Run '$0 help' for the full explanation of every command."
       exit 1 ;;
esac
