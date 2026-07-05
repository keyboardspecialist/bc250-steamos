#!/usr/bin/env bash
# bc250-40cu-steamos.sh  (v2 -- battle-tested edition)
#
# All-in-one BC-250 40 CU unlock for SteamOS 3.8.x via the runtime UMR route.
#
# Everything lives in update-proof locations:
#   /var/lib/bc250-40cu   umr binary + ASIC database + manager script
#   /etc                  systemd unit + boot table config
# SteamOS updates wipe /usr (including /usr/local and pacman packages);
# they do NOT touch /etc, /var, /home.
#
# Lessons baked in from getting this working on a real SteamOS 3.8.10 box:
#   * SteamOS strips headers and .pc files from image packages, including
#     GLIBC'S OWN HEADERS. Explicit pacman reinstalls restore full file sets.
#   * pkgconf resolves packages interactively but fails under cmake's
#     pkg_check_modules on this image. We bypass pkg-config entirely with
#     auto-generated hardcoded stub Find modules (prefix parsed from the
#     originals so variable names always match).
#   * The stubs satisfy configure+compile but not the link stage; libs are
#     injected via CMAKE_EXE_LINKER_FLAGS with -Wl,--no-as-needed.
#   * A binary-only umr copy has an EMPTY ASIC database and fails every
#     named-register read. cmake --install with our prefix installs
#     share/umr/database alongside the binary.
#   * bc250-cu-live-manager's find_umr() NEVER consults PATH -- it checks
#     the $UMR env var, then /usr/bin, /usr/local/bin, /opt/umr/... .
#     We always launch it with UMR= set, and quarantine stale copies.
#   * The manager's write-service-table saves UMR=<path> into the conf the
#     service loads via EnvironmentFile, so the umr path self-persists.
#   * The manager's install-service copies itself to /usr/local/bin
#     (read-only AND update-wiped on SteamOS): install needs the rootfs
#     unlocked, and the binary must be relocated afterwards ('persist').
#   * Check the dashboard's harvest map BEFORE full dispatch. Scattered
#     patterns (a mid-row WGP the factory routed around) likely mark bad
#     silicon -- enable selectively with [e] instead of [f].
#
# Usage (run as root):
#   ./bc250-40cu-steamos.sh check      board / debugfs / install state
#   ./bc250-40cu-steamos.sh prep       deps + build umr into /var/lib
#   ./bc250-40cu-steamos.sh manager    launch the live-manager TUI correctly
#   ./bc250-40cu-steamos.sh persist    relocate service off the wipeable rootfs
#   ./bc250-40cu-steamos.sh verify     registers + service + guidance
#   ./bc250-40cu-steamos.sh revert     disable service (reboot -> stock 24 CU)
#   ./bc250-40cu-steamos.sh all        check + prep + manager
#
set -euo pipefail

PREFIX="/var/lib/bc250-40cu"
UMR_BIN="$PREFIX/bin/umr"
MANAGER_SH="$PREFIX/bc250-cu-live-manager.sh"
MANAGER_URL="https://raw.githubusercontent.com/WinnieLV/bc250-cu-live-manager/refs/heads/main/bc250-cu-live-manager.sh"
UMR_GIT="https://gitlab.freedesktop.org/tomstdenis/umr.git"
SRC="/tmp/umr-build"
BLD="$SRC/b"
SERVICE="/etc/systemd/system/bc250-cu-live-manager.service"
SERVICE_CONF="/etc/bc250-cu-live-manager.conf"
ROOTFS_MANAGER_BIN="/usr/local/bin/bc250-cu-live-manager"
PERSIST_MANAGER_BIN="$PREFIX/bc250-cu-live-manager"

log()  { echo -e "\033[1;32m[bc250]\033[0m $*"; }
warn() { echo -e "\033[1;33m[bc250]\033[0m $*"; }
die()  { echo -e "\033[1;31m[bc250]\033[0m $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

RO_WAS_DISABLED=0
unlock_rootfs() {
    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        log "Disabling read-only rootfs (temporary)..."
        steamos-readonly disable
        RO_WAS_DISABLED=1
    fi
}
relock_rootfs() {
    if [[ $RO_WAS_DISABLED -eq 1 ]]; then
        log "Re-enabling read-only rootfs."
        steamos-readonly enable
        RO_WAS_DISABLED=0
    fi
}
trap relock_rootfs EXIT

# Prefer bare .so symlink; fall back to highest versioned .so.N present.
resolve_lib() {
    local base="$1"
    if [[ -e "${base}.so" ]]; then echo "${base}.so"; return; fi
    local best
    best=$(ls -1 "${base}".so.* 2>/dev/null | sort -V | tail -1 || true)
    [[ -n "$best" ]] || return 1
    echo "$best"
}

# Overwrite a pkg_check_modules-based Find module with a hardcoded stub.
# Variable prefix is parsed from the original so names match CMakeLists.
stub_find_module() {
    local file="$1" fallback="$2" incdirs="$3" cflags="$4"; shift 4
    local libs="$*" prefix
    prefix=$(grep -oP 'pkg_check_modules\(\s*\K[A-Za-z0-9_]+' "$file" | head -1 || true)
    [[ -n "$prefix" ]] || prefix="$fallback"
    log "Stubbing $(basename "$file") (prefix: $prefix)"
    cat > "$file" << EOF
# Auto-generated stub (SteamOS pkgconf-under-cmake bypass).
set(${prefix}_FOUND TRUE)
set(${prefix}_INCLUDE_DIR ${incdirs})
set(${prefix}_INCLUDE_DIRS ${incdirs})
set(${prefix}_LIBRARY ${libs})
set(${prefix}_LIBRARIES ${libs})
set(${prefix}_LDFLAGS ${libs})
set(${prefix}_LINK_LIBRARIES ${libs})
set(${prefix}_CFLAGS "${cflags}")
set(${prefix}_CFLAGS_OTHER "${cflags}")
set(${prefix}_VERSION 99.0)
mark_as_advanced(${prefix}_INCLUDE_DIR ${prefix}_LIBRARY)
EOF
}

# Stale umr copies on the manager's hardcoded search paths cause it to
# silently pick the wrong binary. Quarantine them.
quarantine_stale_umr() {
    local p
    for p in /usr/bin/umr /usr/local/bin/umr /opt/umr/build/src/app/umr; do
        if [[ -e "$p" && "$p" != "$UMR_BIN" ]]; then
            warn "Stale umr at $p -- renaming to ${p}.stale (manager would pick it up)"
            mv -f "$p" "${p}.stale" 2>/dev/null || warn "  could not rename (rootfs locked?); UMR env var still overrides it."
        fi
    done
}

# ================================ check ===================================
cmd_check() {
    require_root   # debugfs mount + globbing inside /sys/kernel/debug need root
    log "Board:"
    lspci -n | grep -qi '1002:13fe' \
        && log "  BC-250 (0x13FE / Cyan Skillfish) detected." \
        || die "  No 1002:13FE device found."
    log "Kernel: $(uname -r)"

    if ! mount | grep -q 'debugfs on /sys/kernel/debug'; then
        warn "debugfs not mounted; mounting..."
        mount -t debugfs none /sys/kernel/debug || die "Could not mount debugfs."
    fi
    # NOTE: glob must run as root -- deck can't read inside /sys/kernel/debug
    sh -c 'ls /sys/kernel/debug/dri/*/amdgpu_regs2' >/dev/null 2>&1 \
        && log "amdgpu debugfs register interface present." \
        || warn "amdgpu_regs2 not found under /sys/kernel/debug/dri -- umr banked reads may fail."

    [[ -x "$UMR_BIN" ]] && log "Persistent umr: $UMR_BIN" \
                        || warn "No umr at $UMR_BIN -- run: $0 prep"
    [[ -f "$MANAGER_SH" ]] && log "Manager script cached." || warn "Manager not fetched yet."
    [[ -f "$SERVICE" ]] && log "Boot service installed: $(systemctl is-enabled bc250-cu-live-manager.service 2>/dev/null || echo present)" \
                        || warn "Boot service not installed yet."
    [[ -f "$SERVICE_CONF" ]] && log "Boot table saved: $(grep BC250_WGP_MASKS "$SERVICE_CONF" || true)"
}

# ================================ prep ====================================
cmd_prep() {
    require_root
    mkdir -p "$PREFIX/bin"
    unlock_rootfs

    if ! pacman-key --list-keys >/dev/null 2>&1; then
        log "Initialising pacman keyring..."
        pacman-key --init
        pacman-key --populate archlinux holo 2>/dev/null || pacman-key --populate
    fi

    log "Installing/reinstalling build deps (explicit installs restore"
    log "headers and .pc files that the SteamOS image strips)..."
    pacman -Sy
    pacman -S --needed --noconfirm base-devel cmake git pkgconf || true
    pacman -S --noconfirm glibc linux-api-headers ncurses libpciaccess libdrm

    local f
    for f in /usr/include/stdio.h /usr/include/unistd.h /usr/include/linux/types.h \
             /usr/include/curses.h /usr/include/pciaccess.h /usr/include/xf86drm.h; do
        [[ -e "$f" ]] || die "Missing $f after reinstall -- investigate before continuing."
    done
    log "All required headers verified on disk."

    if [[ ! -d "$SRC/.git" ]]; then
        log "Cloning umr..."
        rm -rf "$SRC"
        git clone --depth 1 "$UMR_GIT" "$SRC"
    else
        log "Reusing existing umr clone at $SRC"
    fi

    local MODDIR="$SRC/cmake_modules"
    [[ -d "$MODDIR" ]] || die "No cmake_modules dir in umr source (layout changed?)"

    local PCI_LIB DRM_LIB DRM_AMDGPU_LIB
    PCI_LIB=$(resolve_lib /usr/lib/libpciaccess)        || die "libpciaccess lib not found"
    DRM_LIB=$(resolve_lib /usr/lib/libdrm)              || die "libdrm lib not found"
    DRM_AMDGPU_LIB=$(resolve_lib /usr/lib/libdrm_amdgpu)|| die "libdrm_amdgpu lib not found"
    log "Libs: $PCI_LIB | $DRM_LIB | $DRM_AMDGPU_LIB"

    local pci_mod drm_mod
    pci_mod=$(find "$MODDIR" -iname '*pciaccess*.cmake' | head -1 || true)
    drm_mod=$(find "$MODDIR" -iname '*drm*.cmake' | head -1 || true)
    [[ -n "$pci_mod" ]] && stub_find_module "$pci_mod" "PCIACCESS" \
        "/usr/include" "" "$PCI_LIB"
    [[ -n "$drm_mod" ]] && stub_find_module "$drm_mod" "LIBDRM" \
        "/usr/include /usr/include/libdrm" "-I/usr/include/libdrm" \
        "$DRM_LIB $DRM_AMDGPU_LIB"

    log "Configuring umr (fresh build dir)..."
    rm -rf "$BLD"
    env PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig \
        CFLAGS="-I/usr/include/libdrm ${CFLAGS:-}" \
        cmake -S "$SRC" -B "$BLD" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$PREFIX" \
          -DCMAKE_PREFIX_PATH=/usr \
          -DCMAKE_EXE_LINKER_FLAGS="-Wl,--no-as-needed $PCI_LIB $DRM_LIB $DRM_AMDGPU_LIB" \
          -DCURSES_NEED_NCURSES=TRUE \
          -DCURSES_INCLUDE_PATH=/usr/include \
          -DCURSES_NCURSES_LIBRARY=/usr/lib/libncursesw.so \
          -DUMR_NO_GUI=ON -DUMR_NO_LLVM=ON -DUMR_NO_SERVER=ON

    log "Building..."
    cmake --build "$BLD" -j"$(nproc)"
    log "Installing (binary + ASIC database) to $PREFIX..."
    cmake --install "$BLD"

    quarantine_stale_umr
    relock_rootfs

    [[ -x "$UMR_BIN" ]] || die "Install finished but $UMR_BIN missing."
    log "Enumeration check ('-e'; --list-asics does not exist on this umr):"
    if "$UMR_BIN" -e 2>/dev/null | grep -qi 'cyan_skillfish'; then
        log "SUCCESS -- board enumerates as cyan_skillfish. Next: $0 manager"
    else
        warn "Live enumeration didn't match; run: sudo $UMR_BIN -e   and inspect."
    fi
}

# =============================== manager ==================================
cmd_manager() {
    require_root
    [[ -x "$UMR_BIN" ]] || die "No umr at $UMR_BIN -- run: $0 prep"

    if [[ ! -f "$MANAGER_SH" ]]; then
        log "Fetching bc250-cu-live-manager..."
        curl -fL -o "$MANAGER_SH" "$MANAGER_URL"
        chmod +x "$MANAGER_SH"
    fi

    cat << 'EOT'
------------------------------------------------------------------------
 READ THE DASHBOARD TABLE BEFORE ENABLING ANYTHING.

 Contiguous factory pattern (WGP0-2 on, 3-4 off, ALL four rows identical):
   -> [f] full dispatch is reasonable.

 Scattered pattern (any row where the factory skipped a mid-row WGP and
 substituted a later one, e.g. D+ D+ -- D+ --):
   -> the skipped WGP likely FAILED FACTORY TEST. Do NOT use [f].
   -> use [e] and enable only the policy-harvested WGPs; leave the
      factory-skipped one off. Test it separately later with a Vulkan
      compute-correctness run before ever saving it into the boot table.

 Sequence: inspect -> [e] or [f] -> apply -> STRESS TEST WITH TEMPS IN
 VIEW (cap governor ~1500MHz first) -> [w] write table -> [i] install
 service (script unlocks rootfs for this) -> quit -> run 'persist'.

 Note: active_cu_number in the header stays 24 with the runtime route.
 That's the boot-time driver snapshot. Benchmark; don't trust it.
------------------------------------------------------------------------
EOT
    # install-service writes to /usr/local/bin -> rootfs must be unlocked.
    # Quarantine also needs it unlocked to rename stale /usr/bin copies.
    unlock_rootfs
    quarantine_stale_umr
    # find_umr() ignores PATH; the UMR env var is the supported override
    # and write-service-table persists it into the EnvironmentFile conf.
    UMR="$UMR_BIN" "$MANAGER_SH" "$@"
    relock_rootfs
    log "If you installed the service ('i'), now run: $0 persist"
}

# =============================== persist ==================================
cmd_persist() {
    require_root
    [[ -f "$SERVICE" ]] || die "No service at $SERVICE -- install from the manager first ('i')."

    if [[ -f "$ROOTFS_MANAGER_BIN" ]]; then
        log "Relocating service binary off the wipeable rootfs..."
        cp -f "$ROOTFS_MANAGER_BIN" "$PERSIST_MANAGER_BIN"
    elif [[ -f "$MANAGER_SH" && ! -f "$PERSIST_MANAGER_BIN" ]]; then
        warn "/usr/local copy missing (already wiped?); using cached manager script."
        cp -f "$MANAGER_SH" "$PERSIST_MANAGER_BIN"
    fi
    [[ -f "$PERSIST_MANAGER_BIN" ]] \
        || die "No manager binary found anywhere ($ROOTFS_MANAGER_BIN, $MANAGER_SH). Re-run: $0 manager"
    chmod 755 "$PERSIST_MANAGER_BIN"

    sed -i "s|$ROOTFS_MANAGER_BIN|$PERSIST_MANAGER_BIN|g" "$SERVICE"
    sed -i "s|/var/usrlocal/bin/bc250-cu-live-manager|$PERSIST_MANAGER_BIN|g" "$SERVICE"

    # Belt-and-suspenders: ensure the conf pins our persistent umr.
    # NB: sed exits 0 even with no match, so test with grep before choosing
    # replace-vs-append (an '|| append' after sed is dead code).
    if [[ -f "$SERVICE_CONF" ]] && ! grep -q "^UMR=$UMR_BIN$" "$SERVICE_CONF"; then
        warn "Conf's UMR path differs or is missing; pinning to $UMR_BIN"
        if grep -q '^UMR=' "$SERVICE_CONF"; then
            sed -i "s|^UMR=.*|UMR=$UMR_BIN|" "$SERVICE_CONF"
        else
            echo "UMR=$UMR_BIN" >> "$SERVICE_CONF"
        fi
    fi

    systemctl daemon-reload
    systemctl enable bc250-cu-live-manager.service
    log "Persisted. Chain is now: unit + conf in /etc, script + umr in /var/lib."
    log "A SteamOS update cannot break any link. Verify after reboot: $0 verify"
}

# =============================== verify ===================================
cmd_verify() {
    require_root
    [[ -x "$UMR_BIN" ]] || die "No umr at $UMR_BIN"
    log "Live SPI dispatch masks per shader array (0x1f = all 5 WGPs routed):"
    local se sh
    for se in 0 1; do for sh in 0 1; do
        printf '  SE%s.SH%s: ' "$se" "$sh"
        "$UMR_BIN" -r cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK \
            -b "$se" "$sh" 0xffffffff 2>/dev/null | grep -o '0x[0-9a-f]*' | tail -1
    done; done

    systemctl is-enabled bc250-cu-live-manager.service 2>/dev/null \
        && systemctl status bc250-cu-live-manager.service --no-pager -l | head -5 || true

    log "Reminder: dmesg active_cu_number stays 24 on the runtime route."
    log "Real proof = compute benchmark (llama-bench pp512 Vulkan): expect"
    log "~1.5-1.6x vs stock at matched clocks. Watch temps; cap 1500MHz/900mV"
    log "for sustained loads."
}

# =============================== revert ===================================
cmd_revert() {
    require_root
    systemctl disable --now bc250-cu-live-manager.service 2>/dev/null || true
    log "Boot service disabled. Reboot returns to stock 24 CU dispatch."
    log "(Table kept at $SERVICE_CONF; re-enable the service to restore.)"
}

# ================================ help ====================================
cmd_help() {
    cat << 'EOF'
bc250-40cu-steamos-v2.sh -- BC-250 40 CU unlock for SteamOS
============================================================
Re-enables the factory-harvested compute units at RUNTIME (no kernel
rebuild) by writing the CC/SPI/RLC dispatch registers via umr, using
WinnieLV's bc250-cu-live-manager. A boot service replays the saved WGP
table every boot. Everything lives update-proof in /etc + /var/lib.

Background: the BC-250 ships 24 of 40 RDNA2 CUs active. Two registers
gate them (CC = enumeration, SPI = wave dispatch); the runtime route
flips dispatch after boot. Compute scales ~1.6x; graphics only ~+4%.
Research: duggasco/bc250-40cu-unlock.

COMMANDS (setup order)
  check     Preflight: BC-250 PCI ID present, debugfs + amdgpu register
            interface available, what's installed so far. Needs root.

  prep      Build umr from source into /var/lib/bc250-40cu. Handles
            every SteamOS landmine found the hard way:
              - reinstalls glibc/ncurses/libpciaccess/libdrm because the
                SteamOS image STRIPS their headers and .pc files
              - bypasses pkgconf (broken under cmake on this image) with
                auto-generated stub Find modules
              - injects libs into the link line (--no-as-needed)
              - installs the ASIC DATABASE next to the binary; a
                binary-only umr knows zero ASICs and fails every read
            Verify with: sudo /var/lib/bc250-40cu/bin/umr -e
            (this umr has no --list-asics; -e enumerates live hardware)

  manager   Launch the live-manager TUI the RIGHT way: UMR env var set
            (its find_umr() ignores PATH), stale /usr/bin copies
            quarantined, rootfs unlocked so [i] can install the service.
            In the TUI:
              READ THE HARVEST MAP FIRST. Uniform rows (WGP0-2 on,
              3-4 off) -> [f] full dispatch is fine. A row where the
              factory SKIPPED a mid-row WGP (e.g. D+ D+ -- D+ --) means
              that WGP likely failed factory test: use [e], enable only
              the policy-harvested WGPs, leave the skipped one off.
              Then: apply -> stress test w/ temps -> [w] write table ->
              [i] install service -> quit -> run 'persist'.
            Extra args pass through to the manager CLI, e.g.:
              manager status
              manager enable-wgp 0.0.3 0.0.4 1.0.3 ...

  persist   Make the boot service update-proof: relocates the manager
            binary off /usr/local (wiped by SteamOS updates), rewrites
            the unit's ExecStart, pins UMR= in the EnvironmentFile conf,
            enables the service. Run once after [i].

  verify    Read the live SPI dispatch masks per shader array
            (0x1f = all 5 WGPs; 0x1b = WGP2 masked) + service state.
            NOTE: dmesg active_cu_number stays 24 on the runtime route
            -- that's the boot-time driver snapshot, not the truth.
            A compute benchmark (~1.5-1.6x vs stock) is the real proof.

  revert    Disable the boot service; reboot returns to stock 24 CU.
            The saved table is kept -- re-enable the service to restore.

  all       check + prep + manager.

FILE MAP
  /var/lib/bc250-40cu/bin/umr            our umr build      (persists)
  /var/lib/bc250-40cu/share/umr/         ASIC database      (persists)
  /var/lib/bc250-40cu/bc250-cu-live-manager*  manager       (persists)
  /etc/systemd/system/bc250-cu-live-manager.service         (persists)
  /etc/bc250-cu-live-manager.conf        WGP table + UMR=   (persists)
  /usr/*, /tmp/umr-build                 disposable -- wiped by updates
                                         and that's fine

RELATED
  bc250-cu-status.sh          read-only CU dispatch report (-q for N/40)
  bc250-power-steamos.sh      ACPI C/P-states + GPU governor + freq ctl
EOF
}

# ================================ main ====================================
case "${1:-}" in
    check)   cmd_check ;;
    prep)    cmd_prep ;;
    manager) shift; cmd_manager "$@" ;;
    persist) cmd_persist ;;
    verify)  cmd_verify ;;
    revert)  cmd_revert ;;
    all)     cmd_check; cmd_prep; cmd_manager ;;
    help|-h|--help) cmd_help ;;
    *) echo "Usage: $0 {check|prep|manager|persist|verify|revert|all|help}"
       echo "Run '$0 help' for the full walkthrough of every command."
       exit 1 ;;
esac
