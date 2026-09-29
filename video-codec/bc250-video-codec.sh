#!/usr/bin/env bash
# Install the pinned BC-250 VA-API compute codec in persistent SteamOS storage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE=v0.5.1
SOURCE_COMMIT=180aab87fa84b68f8d4a9d6bf8d4c1fb0cac940e
SOURCE_ARCHIVE_NAME="bc250-encoding-decoding-fix-$SOURCE_COMMIT.tar.gz"
SOURCE_ARCHIVE_SHA256=c735c3c566882b1e8594eff7e163feb0d62e2ad52d83c104c5178a34f5a2784a
SOURCE_ARCHIVE_URL="https://codeload.github.com/simpmix/bc250-encoding-decoding-fix/tar.gz/$SOURCE_COMMIT"
SOURCE_ROOT_NAME="bc250-encoding-decoding-fix-$SOURCE_COMMIT"
SHADER_NAMES=(
    color_convert.comp.spv
    dct_transform.comp.spv
    deblock_filter.comp.spv
    entropy_encode.comp.spv
    intra_wavefront.comp.spv
    motion_estimation.comp.spv
    quantize.comp.spv
    reconstruct.comp.spv
    residual_predict.comp.spv
    video_proc.comp.spv
    video_proc10.comp.spv
)

DATA_DIR="${BC250_VIDEO_DATA_DIR:-/var/lib/bc250-control/video-codec}"
RUNTIME_DIR="$DATA_DIR/runtime"
COMPAT_DIR="${BC250_VIDEO_COMPAT_DIR:-/var/lib/bc250}"
ENV_FILE="${BC250_VIDEO_ENV_FILE:-/etc/environment.d/90-bc250-video-codec.conf}"
PROFILE_FILE="${BC250_VIDEO_PROFILE_FILE:-/etc/profile.d/zz-bc250-video-codec.sh}"
LEGACY_PROFILE_FILE=""
if [[ -z "${BC250_VIDEO_PROFILE_FILE+x}" ]]; then
    LEGACY_PROFILE_FILE=/etc/profile.d/90-bc250-video-codec.sh
fi
KEEP_FILE="${BC250_VIDEO_KEEP_FILE:-/etc/atomic-update.conf.d/bc250-video-codec.conf}"
LOCK_FILE="${BC250_VIDEO_LOCK_FILE:-/run/lock/bc250-video-codec.lock}"
PKG_CONFIG_LIBDIR32="${BC250_VIDEO_PKG_CONFIG_LIBDIR32:-/usr/lib32/pkgconfig:/usr/share/pkgconfig}"
MANAGED_MARKER="bc250-toolkit-video-codec-v1"
ENV_MARKER="# BC-250 toolkit managed VA-API video codec"
PROFILE_MARKER="# BC-250 toolkit managed VA-API video codec shell environment"
KEEP_MARKER="# BC-250 toolkit managed VA-API video codec update persistence"
STAGE=""

log() { echo "[bc250-video-codec] $*"; }
die() { log "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "$STAGE" && -d "$STAGE" && ! -L "$STAGE" ]]; then
        rm -rf -- "$STAGE"
    fi
}
trap cleanup EXIT

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this action with sudo."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

runtime_marker() {
    cat <<EOF
$MANAGED_MARKER
release=$RELEASE
source_commit=$SOURCE_COMMIT
source_sha256=$SOURCE_ARCHIVE_SHA256
build=local-source
EOF
}

environment_config() {
    local driver_path
    driver_path=$(configured_driver_path)
    cat <<EOF
$ENV_MARKER
LIBVA_DRIVER_NAME=bc250
LIBVA_DRIVERS_PATH=$driver_path
BC250_SHADER_DIR=$COMPAT_DIR/shaders
BC250_FAST_MODE=1
BC250_SLICES_PER_FRAME=4
BC250_HEVC_SLICES=4
OMP_WAIT_POLICY=PASSIVE
GOMP_SPINCOUNT=0
OMP_NUM_THREADS=2
OMP_DYNAMIC=FALSE
EOF
}

profile_config() {
    local driver_path
    driver_path=$(configured_driver_path)
    cat <<EOF
$PROFILE_MARKER
export LIBVA_DRIVER_NAME=bc250
export LIBVA_DRIVERS_PATH=$driver_path
export BC250_SHADER_DIR=$COMPAT_DIR/shaders
export BC250_FAST_MODE=1
export BC250_SLICES_PER_FRAME=4
export BC250_HEVC_SLICES=4
export OMP_WAIT_POLICY=PASSIVE
export GOMP_SPINCOUNT=0
export OMP_NUM_THREADS=2
export OMP_DYNAMIC=FALSE
EOF
}

runtime_has_32bit() {
    local runtime="${1:-$RUNTIME_DIR}"
    [[ -f "$runtime/dri32/bc250_drv_video.so" \
        && ! -L "$runtime/dri32/bc250_drv_video.so" ]]
}

configured_driver_path() {
    local path="$COMPAT_DIR/dri"
    if runtime_has_32bit; then
        path="$path:$COMPAT_DIR/dri32"
    fi
    printf '%s\n' "$path"
}

managed_driver_path_variant() {
    [[ "$1" == "$COMPAT_DIR/dri" \
        || "$1" == "$COMPAT_DIR/dri:$COMPAT_DIR/dri32" ]]
}

keep_config() {
    cat <<EOF
$KEEP_MARKER
$COMPAT_DIR
$ENV_FILE
$PROFILE_FILE
EOF
}

is_managed_runtime() {
    [[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" \
        && -f "$RUNTIME_DIR/.bc250-toolkit-managed" \
        && ! -L "$RUNTIME_DIR/.bc250-toolkit-managed" ]] \
        && grep -qxF "$MANAGED_MARKER" "$RUNTIME_DIR/.bc250-toolkit-managed"
}

is_managed_compatibility_link() {
    [[ -L "$COMPAT_DIR" ]] \
        && [[ "$(readlink "$COMPAT_DIR")" == "$RUNTIME_DIR" ]]
}

compatibility_link_valid() {
    is_managed_compatibility_link \
        && [[ -d "$COMPAT_DIR/dri" && -d "$COMPAT_DIR/shaders" ]]
}

is_managed_environment() {
    [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] \
        && IFS= read -r first_line < "$ENV_FILE" \
        && [[ "$first_line" == "$ENV_MARKER" ]]
}

is_managed_profile() {
    local profile="${1:-$PROFILE_FILE}" first_line
    [[ -n "$profile" && -f "$profile" && ! -L "$profile" ]] \
        && IFS= read -r first_line < "$profile" \
        && [[ "$first_line" == "$PROFILE_MARKER" ]]
}

is_managed_keep_file() {
    local first_line
    [[ -f "$KEEP_FILE" && ! -L "$KEEP_FILE" ]] \
        && IFS= read -r first_line < "$KEEP_FILE" \
        && [[ "$first_line" == "$KEEP_MARKER" ]]
}

runtime_valid() {
    local manifest_has_32bit=0 runtime_has_32bit_file=0
    is_managed_runtime || return 1
    diff -q <(runtime_marker) "$RUNTIME_DIR/.bc250-toolkit-managed" >/dev/null 2>&1 \
        || return 1
    [[ -f "$RUNTIME_DIR/manifest.sha256" && ! -L "$RUNTIME_DIR/manifest.sha256" ]] \
        || return 1
    manifest_layout_valid "$RUNTIME_DIR/manifest.sha256" || return 1
    grep -qE '^[0-9a-f]{64}  dri32/bc250_drv_video\.so$' \
        "$RUNTIME_DIR/manifest.sha256" && manifest_has_32bit=1
    runtime_has_32bit && runtime_has_32bit_file=1
    [[ "$manifest_has_32bit" == "$runtime_has_32bit_file" ]] || return 1
    (cd "$RUNTIME_DIR" && sha256sum -c --quiet manifest.sha256) >/dev/null 2>&1 \
        || return 1
    [[ -x "$RUNTIME_DIR/dri/bc250_drv_video.so" ]] || return 1
    elf_class_is "$RUNTIME_DIR/dri/bc250_drv_video.so" 2 || return 1
    runtime_dependencies_valid "$RUNTIME_DIR/dri/bc250_drv_video.so" || return 1
    if runtime_has_32bit; then
        [[ -x "$RUNTIME_DIR/dri32/bc250_drv_video.so" ]] || return 1
        elf_class_is "$RUNTIME_DIR/dri32/bc250_drv_video.so" 1 || return 1
        elf_machine_is_i386 "$RUNTIME_DIR/dri32/bc250_drv_video.so" || return 1
        runtime_dependencies_valid "$RUNTIME_DIR/dri32/bc250_drv_video.so" || return 1
    fi
}

manifest_paths() {
    local include_32bit="${1:-0}" shader
    echo "dri/bc250_drv_video.so"
    [[ "$include_32bit" == 1 ]] && echo "dri32/bc250_drv_video.so"
    for shader in "${SHADER_NAMES[@]}"; do
        echo "shaders/$shader"
    done
    echo "LICENSE.upstream"
    echo "README.upstream.md"
}

manifest_layout_valid() {
    local manifest="$1" expected64 expected32 actual
    expected64=$(manifest_paths 0)
    expected32=$(manifest_paths 1)
    actual=$(sed -nE 's/^[0-9a-f]{64}  //p' "$manifest")
    [[ "$actual" == "$expected64" || "$actual" == "$expected32" ]] \
        && [[ $(wc -l < "$manifest") -eq 14 || $(wc -l < "$manifest") -eq 15 ]] \
        && ! grep -Evq '^[0-9a-f]{64}  (dri/bc250_drv_video\.so|dri32/bc250_drv_video\.so|shaders/[a-z0-9_]+\.comp\.spv|LICENSE\.upstream|README\.upstream\.md)$' "$manifest"
}

write_runtime_manifest() {
    local runtime="$1" include_32bit=0 path
    runtime_has_32bit "$runtime" && include_32bit=1
    : > "$runtime/manifest.sha256"
    while IFS= read -r path; do
        (cd "$runtime" && sha256sum "$path") >> "$runtime/manifest.sha256"
    done < <(manifest_paths "$include_32bit")
    chmod 0644 "$runtime/manifest.sha256"
}

runtime_dependencies_valid() {
    local output
    command -v ldd >/dev/null 2>&1 || return 1
    output=$(ldd -r "$1" 2>&1) || return 1
    [[ "$output" != *"not found"* \
        && "$output" != *"undefined symbol"* \
        && "$output" != *"libx264"* ]]
}

environment_valid() {
    is_managed_environment || return 1
    diff -q <(environment_config) "$ENV_FILE" >/dev/null 2>&1 || return 1
    is_managed_profile || return 1
    diff -q <(profile_config) "$PROFILE_FILE" >/dev/null 2>&1 || return 1
    is_managed_keep_file || return 1
    diff -q <(keep_config) "$KEEP_FILE" >/dev/null 2>&1
}

shell_environment_active() {
    local driver_path
    driver_path=$(configured_driver_path)
    [[ "${LIBVA_DRIVER_NAME:-}" == bc250 \
        && "${LIBVA_DRIVERS_PATH:-}" == "$driver_path" \
        && "${BC250_SHADER_DIR:-}" == "$COMPAT_DIR/shaders" ]]
}

manager_environment_active() {
    local driver_path environment
    driver_path=$(configured_driver_path)
    command -v systemctl >/dev/null 2>&1 || return 1
    environment=$(systemctl --user show-environment 2>/dev/null) || return 1
    grep -qxF "LIBVA_DRIVER_NAME=bc250" <<< "$environment" \
        && grep -qxF "LIBVA_DRIVERS_PATH=$driver_path" <<< "$environment" \
        && grep -qxF "BC250_SHADER_DIR=$COMPAT_DIR/shaders" <<< "$environment"
}

session_environment_conflicted() {
    local driver_path manager_driver_path="" environment=""
    driver_path=$(configured_driver_path)
    if [[ ( -n "${LIBVA_DRIVER_NAME:-}" && "${LIBVA_DRIVER_NAME:-}" != bc250 ) \
        || ( -n "${BC250_SHADER_DIR:-}" && "${BC250_SHADER_DIR:-}" != "$COMPAT_DIR/shaders" ) ]]; then
        return 0
    fi
    if [[ -n "${LIBVA_DRIVERS_PATH:-}" && "${LIBVA_DRIVERS_PATH:-}" != "$driver_path" ]] \
        && ! managed_driver_path_variant "$LIBVA_DRIVERS_PATH"; then
        return 0
    fi
    command -v systemctl >/dev/null 2>&1 || return 1
    environment=$(systemctl --user show-environment 2>/dev/null) || return 1
    if grep -q '^LIBVA_DRIVER_NAME=' <<< "$environment" \
        && ! grep -qxF 'LIBVA_DRIVER_NAME=bc250' <<< "$environment"; then
        return 0
    fi
    manager_driver_path=$(sed -n 's/^LIBVA_DRIVERS_PATH=//p' <<< "$environment" | tail -n 1)
    if [[ -n "$manager_driver_path" && "$manager_driver_path" != "$driver_path" ]]; then
        managed_driver_path_variant "$manager_driver_path" || return 0
    fi
    if grep -q '^BC250_SHADER_DIR=' <<< "$environment" \
        && ! grep -qxF "BC250_SHADER_DIR=$COMPAT_DIR/shaders" <<< "$environment"; then
        return 0
    fi
    return 1
}

show_status() {
    local runtime_present=0 compatibility_present=0 environment_present=0
    [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]] && runtime_present=1
    [[ -e "$COMPAT_DIR" || -L "$COMPAT_DIR" ]] && compatibility_present=1
    [[ -e "$ENV_FILE" || -L "$ENV_FILE" \
        || -e "$PROFILE_FILE" || -L "$PROFILE_FILE" \
        || -e "$KEEP_FILE" || -L "$KEEP_FILE" \
        || ( -n "$LEGACY_PROFILE_FILE" \
            && ( -e "$LEGACY_PROFILE_FILE" || -L "$LEGACY_PROFILE_FILE" ) ) ]] \
        && environment_present=1

    if [[ $runtime_present -eq 0 && $compatibility_present -eq 0 \
        && $environment_present -eq 0 ]]; then
        echo "state: not-installed"
        echo "release: $RELEASE"
        echo "session: stock"
        return 1
    fi

    if runtime_valid && compatibility_link_valid && environment_valid; then
        echo "state: installed"
        echo "release: $RELEASE"
        echo "driver: verified local source build"
        if runtime_has_32bit; then
            echo "driver32: installed"
        else
            echo "driver32: not-installed"
        fi
        echo "shaders: 11 verified"
        echo "SteamOS path: $COMPAT_DIR"
        echo "configuration: installed"
        if shell_environment_active; then
            echo "session: active"
        elif manager_environment_active; then
            echo "session: manager-active"
        elif session_environment_conflicted; then
            echo "session: environment-conflict"
        else
            echo "session: restart-required"
        fi
        return 0
    fi

    echo "state: incomplete"
    echo "release: $RELEASE"
    if runtime_valid; then echo "driver: verified"; else echo "driver: missing-or-invalid"; fi
    if compatibility_link_valid; then echo "SteamOS path: installed"; else echo "SteamOS path: missing-or-invalid"; fi
    if environment_valid; then echo "configuration: installed"; else echo "configuration: missing-or-invalid"; fi
    echo "session: unavailable"
    return 2
}

detect_bc250() {
    local device vendor
    for vendor in /sys/bus/pci/devices/*/vendor; do
        [[ -r "$vendor" && "$(<"$vendor")" == 0x1002 ]] || continue
        device="${vendor%/vendor}/device"
        [[ -r "$device" && "$(<"$device")" == 0x13fe ]] && return 0
    done
    command -v lspci >/dev/null 2>&1 \
        && lspci -Dn 2>/dev/null | grep -Eqi '1002:13fe([[:space:]]|$)'
}

bc250_render_node() {
    local node vendor device
    for node in /sys/class/drm/renderD*; do
        [[ -e "$node" ]] || continue
        vendor="$node/device/vendor"
        device="$node/device/device"
        [[ -r "$vendor" && -r "$device" \
            && "$(<"$vendor")" == 0x1002 \
            && "$(<"$device")" == 0x13fe ]] || continue
        printf '/dev/dri/%s\n' "${node##*/}"
        return 0
    done
    return 1
}

verify_vaapi_initialization() {
    local runtime="$1" render_node output
    render_node=$(bc250_render_node) \
        || die "Could not identify the BC-250 DRM render node."
    if ! output=$(env \
        LIBVA_DRIVER_NAME=bc250 \
        LIBVA_DRIVERS_PATH="$runtime/dri" \
        BC250_SHADER_DIR="$runtime/shaders" \
        vainfo --display drm --device "$render_node" 2>&1); then
        printf '%s\n' "$output" >&2
        die "The locally built driver failed explicit VA-API initialization. No driver was activated."
    fi
    grep -qF "AMD BC-250 Compute VA-API Driver" <<< "$output" \
        || { printf '%s\n' "$output" >&2; die "VA-API initialized without the BC-250 driver. No driver was activated."; }
    log "Verified VA-API initialization on $render_node."
}

verify_ffmpeg_pipeline() {
    local runtime="$1" render_node test_directory encoded decoded encode_output decode_output
    render_node=$(bc250_render_node) \
        || die "Could not identify the BC-250 DRM render node."
    test_directory=$(mktemp -d "${TMPDIR:-/tmp}/bc250-video-codec.ffmpeg.XXXXXX") \
        || die "Could not create the FFmpeg validation directory."
    encoded="$test_directory/test.h264"
    decoded="$test_directory/test.nv12"

    if ! encode_output=$(env \
        LIBVA_DRIVER_NAME=bc250 \
        LIBVA_DRIVERS_PATH="$runtime/dri" \
        BC250_SHADER_DIR="$runtime/shaders" \
        BC250_FAST_MODE=1 \
        BC250_SLICES_PER_FRAME=4 \
        BC250_HEVC_SLICES=4 \
        OMP_WAIT_POLICY=PASSIVE \
        GOMP_SPINCOUNT=0 \
        OMP_NUM_THREADS=2 \
        OMP_DYNAMIC=FALSE \
        ffmpeg -nostdin -hide_banner -loglevel verbose \
            -vaapi_device "$render_node" \
            -f lavfi -i testsrc2=size=320x240:rate=30 \
            -vf 'format=nv12,hwupload' \
            -c:v h264_vaapi -b:v 2M -frames:v 8 -f h264 "$encoded" 2>&1); then
        rm -rf -- "$test_directory"
        printf '%s\n' "$encode_output" >&2
        die "FFmpeg failed the BC-250 VA-API encode test. No driver was activated."
    fi
    if [[ ! -s "$encoded" ]] \
        || ! grep -qF 'VAAPI driver: AMD BC-250 Compute VA-API Driver' <<< "$encode_output"; then
        rm -rf -- "$test_directory"
        printf '%s\n' "$encode_output" >&2
        die "FFmpeg did not encode with the BC-250 VA-API driver. No driver was activated."
    fi

    if ! decode_output=$(env \
        LIBVA_DRIVER_NAME=bc250 \
        LIBVA_DRIVERS_PATH="$runtime/dri" \
        BC250_SHADER_DIR="$runtime/shaders" \
        BC250_FAST_MODE=1 \
        BC250_SLICES_PER_FRAME=4 \
        BC250_HEVC_SLICES=4 \
        OMP_WAIT_POLICY=PASSIVE \
        GOMP_SPINCOUNT=0 \
        OMP_NUM_THREADS=2 \
        OMP_DYNAMIC=FALSE \
        ffmpeg -nostdin -hide_banner -loglevel verbose \
            -hwaccel vaapi -hwaccel_device "$render_node" \
            -hwaccel_output_format vaapi -i "$encoded" \
            -vf 'hwdownload,format=nv12' -frames:v 8 \
            -pix_fmt nv12 -f rawvideo "$decoded" 2>&1); then
        rm -rf -- "$test_directory"
        printf '%s\n' "$decode_output" >&2
        die "FFmpeg failed the BC-250 VA-API decode test. No driver was activated."
    fi
    if [[ $(wc -c < "$decoded") -ne 921600 ]] \
        || ! grep -qF 'VAAPI driver: AMD BC-250 Compute VA-API Driver' <<< "$decode_output"; then
        rm -rf -- "$test_directory"
        printf '%s\n' "$decode_output" >&2
        die "FFmpeg did not decode eight frames with the BC-250 VA-API driver. No driver was activated."
    fi
    rm -rf -- "$test_directory"
    log "Verified FFmpeg VA-API H.264 encode and decode on $render_node."
}

validate_elf64() {
    elf_class_is "$1" 2 || die "The release driver is not a 64-bit ELF file."
}

validate_elf32() {
    elf_class_is "$1" 1 || die "The companion driver is not a 32-bit ELF file."
    elf_machine_is_i386 "$1" || die "The companion driver is not an i386 ELF file."
    no_text_relocations "$1" \
        || die "The companion driver contains forbidden text relocations."
}

elf_class_is() {
    local class
    class=$(od -An -tu1 -j4 -N1 "$1" 2>/dev/null | tr -d '[:space:]')
    [[ "$class" == "$2" ]]
}

elf_machine_is_i386() {
    local machine
    machine=$(od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d '[:space:]')
    [[ "$machine" == 3 ]]
}

no_text_relocations() {
    local dynamic
    command -v readelf >/dev/null 2>&1 || return 1
    dynamic=$(readelf -d "$1" 2>/dev/null) || return 1
    [[ "$dynamic" != *"(TEXTREL)"* ]]
}

verify_vaapi_initialization_32() {
    local runtime="$1" working="$2" render_node source probe flags output
    local -a flag_list=()
    render_node=$(bc250_render_node) \
        || die "Could not identify the BC-250 DRM render node."
    source="$working/bc250-vaapi-probe32.c"
    probe="$working/bc250-vaapi-probe32"
    cat > "$source" <<'EOF'
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>

int main(int argc, char **argv) {
    int fd, major = 0, minor = 0;
    VADisplay display;
    VAStatus status;
    const char *vendor;
    if (argc != 2) return 2;
    fd = open(argv[1], O_RDWR | O_CLOEXEC);
    if (fd < 0) return 3;
    display = vaGetDisplayDRM(fd);
    if (!display) { close(fd); return 4; }
    status = vaInitialize(display, &major, &minor);
    if (status != VA_STATUS_SUCCESS) { close(fd); return 5; }
    vendor = vaQueryVendorString(display);
    if (vendor) puts(vendor);
    status = vendor && strstr(vendor, "AMD BC-250 Compute VA-API Driver")
        ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_UNKNOWN;
    vaTerminate(display);
    close(fd);
    return status == VA_STATUS_SUCCESS ? 0 : 6;
}
EOF
    flags=$(env PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR32" \
        pkg-config --cflags --libs libva-drm) \
        || die "Could not resolve the 32-bit libva DRM build flags."
    read -r -a flag_list <<< "$flags"
    # Convert the trusted package-owned flag list into argv without glob expansion.
    if ! gcc -m32 -O2 -Wl,-z,text "$source" -o "$probe" "${flag_list[@]}"; then
        die "Could not compile the 32-bit VA-API initialization probe."
    fi
    if ! output=$(env \
        LIBVA_DRIVER_NAME=bc250 \
        LIBVA_DRIVERS_PATH="$runtime/dri32" \
        BC250_SHADER_DIR="$runtime/shaders" \
        "$probe" "$render_node" 2>&1); then
        printf '%s\n' "$output" >&2
        die "The 32-bit companion failed explicit VA-API initialization. No driver was activated."
    fi
    grep -qF "AMD BC-250 Compute VA-API Driver" <<< "$output" \
        || { printf '%s\n' "$output" >&2; die "The 32-bit probe initialized without the BC-250 driver. No driver was activated."; }
    log "Verified 32-bit VA-API initialization on $render_node."
}

extract_source() {
    local archive="$1" destination="$2"
    python3 - "$archive" "$destination" "$SOURCE_ROOT_NAME" <<'PY'
import pathlib
import shutil
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
expected_root = sys.argv[3]
member_limit = 2000
size_limit = 128 * 1024 * 1024

with tarfile.open(archive, "r:gz") as bundle:
    members = bundle.getmembers()
    if not members or len(members) > member_limit:
        raise SystemExit("source archive has an invalid member count")
    total = 0
    seen = set()
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if (
            path.is_absolute()
            or ".." in path.parts
            or not path.parts
            or path.parts[0] != expected_root
        ):
            raise SystemExit(f"unsafe source archive path: {member.name}")
        if not member.isdir() and not member.isreg():
            raise SystemExit(f"unsafe source archive entry type: {member.name}")
        if member.name in seen:
            raise SystemExit(f"duplicate source archive entry: {member.name}")
        seen.add(member.name)
        total += member.size
        if total > size_limit:
            raise SystemExit("source archive exceeds the extraction safety limit")

    required = {
        f"{expected_root}/LICENSE",
        f"{expected_root}/README.md",
        f"{expected_root}/approach1-compute-encoder/CMakeLists.txt",
    }
    if not required.issubset(seen):
        raise SystemExit("source archive is missing required build files")

    for member in members:
        relative = pathlib.PurePosixPath(member.name).relative_to(expected_root)
        if not relative.parts:
            continue
        target = destination.joinpath(*relative.parts)
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
            target.chmod(0o755)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        stream = bundle.extractfile(member)
        if stream is None:
            raise SystemExit(f"could not read source archive file: {member.name}")
        with stream, target.open("xb") as output:
            shutil.copyfileobj(stream, output)
        target.chmod(0o644)
PY
}

missing_build_prerequisites() {
    local command package
    for command in cmake ffmpeg gcc make pkg-config glslangValidator vainfo; do
        command -v "$command" >/dev/null 2>&1 || echo "command:$command"
    done
    if command -v pkg-config >/dev/null 2>&1; then
        for package in libva libdrm vulkan; do
            pkg-config --exists "$package" 2>/dev/null || echo "pkg-config:$package"
        done
    fi
    [[ -r /usr/include/va/va.h ]] || echo "header:/usr/include/va/va.h"
    [[ -r /usr/include/xf86drm.h ]] || echo "header:/usr/include/xf86drm.h"
    [[ -r /usr/include/linux/types.h ]] || echo "header:/usr/include/linux/types.h"
    [[ -r /usr/include/vulkan/vulkan.h ]] || echo "header:/usr/include/vulkan/vulkan.h"
    if command -v gcc >/dev/null 2>&1 \
        && command -v pkg-config >/dev/null 2>&1 \
        && pkg-config --exists libva libdrm vulkan 2>/dev/null; then
        printf '%s\n' \
            '#include <va/va.h>' \
            '#include <xf86drm.h>' \
            '#include <vulkan/vulkan.h>' \
            '#include <omp.h>' \
            'int main(void) { return 0; }' \
            | gcc -x c -fopenmp $(pkg-config --cflags --libs libva libdrm vulkan) \
                -o /dev/null - >/dev/null 2>&1 \
            || echo "compiler-link-probe:libva+libdrm+vulkan+openmp"
    fi
}

build_prerequisites_ready() {
    [[ -z "$(missing_build_prerequisites)" ]]
}

missing_32bit_build_prerequisites() {
    local flags probe
    local -a flag_list=()
    [[ -d /usr/lib32/pkgconfig ]] || echo "directory:/usr/lib32/pkgconfig"
    if command -v pkg-config >/dev/null 2>&1; then
        for package in libva libva-drm libdrm vulkan; do
            env PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR32" \
                pkg-config --exists "$package" 2>/dev/null \
                || echo "pkg-config32:$package"
        done
    fi
    if command -v gcc >/dev/null 2>&1 \
        && command -v pkg-config >/dev/null 2>&1 \
        && flags=$(env PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR32" \
            pkg-config --cflags --libs libva-drm libdrm vulkan 2>/dev/null); then
        probe=$(mktemp "${TMPDIR:-/tmp}/bc250-video-codec.probe32.XXXXXX") \
            || { echo "compiler-link-probe32:temporary-file"; return; }
        read -r -a flag_list <<< "$flags"
        if ! printf '%s\n' \
            '#include <omp.h>' \
            '#include <va/va.h>' \
            '#include <xf86drm.h>' \
            '#include <vulkan/vulkan.h>' \
            'int bc250_probe(void) {' \
            '  int major = 0, minor = 0;' \
            '  VkInstance instance = 0;' \
            '  vaInitialize((VADisplay)0, &major, &minor);' \
            '  drmGetVersion(-1);' \
            '  vkCreateInstance((const VkInstanceCreateInfo *)0, 0, &instance);' \
            '  return omp_get_max_threads();' \
            '}' \
            | gcc -m32 -shared -fPIC -fopenmp -Wl,-z,text,-z,defs \
                -x c -o "$probe" - "${flag_list[@]}" >/dev/null 2>&1; then
            echo "compiler-link-probe32:libva+libdrm+vulkan+openmp"
        elif ! no_text_relocations "$probe"; then
            echo "elf32:DT_TEXTREL"
        fi
        rm -f -- "$probe"
    else
        echo "compiler-link-probe32:libva+libdrm+vulkan+openmp"
    fi
}

build_32bit_prerequisites_ready() {
    [[ -z "$(missing_32bit_build_prerequisites)" ]]
}

install_build_prerequisites() (
    local readonly_was_enabled=0
    restore_readonly() {
        local rc=${1:-$?}
        trap - EXIT INT TERM HUP
        if [[ $readonly_was_enabled -eq 1 ]]; then
            steamos-readonly enable || rc=1
        fi
        exit "$rc"
    }
    trap restore_readonly EXIT
    trap 'restore_readonly 130' INT
    trap 'restore_readonly 143' TERM
    trap 'restore_readonly 129' HUP

    for command in steamos-readonly pacman pacman-key; do
        command -v "$command" >/dev/null 2>&1 \
            || die "$command is required to install the verified source-build prerequisites."
    done
    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        steamos-readonly disable
        readonly_was_enabled=1
    fi
    pacman-key --init
    pacman-key --populate archlinux holo 2>/dev/null || pacman-key --populate
    pacman -S --needed --noconfirm base-devel
    # SteamOS can record these packages while omitting development files.
    # Force a signed reinstall instead of trusting pacman's --needed state.
    pacman -S --noconfirm \
        cmake make gcc binutils glibc linux-api-headers pkgconf libva libdrm ffmpeg \
        vulkan-headers vulkan-icd-loader glslang libva-utils
    if [[ $readonly_was_enabled -eq 1 ]]; then
        steamos-readonly enable
        readonly_was_enabled=0
    fi
)

install_32bit_build_prerequisites() (
    local readonly_was_enabled=0
    restore_readonly() {
        local rc=${1:-$?}
        trap - EXIT INT TERM HUP
        if [[ $readonly_was_enabled -eq 1 ]]; then
            steamos-readonly enable || rc=1
        fi
        exit "$rc"
    }
    trap restore_readonly EXIT
    trap 'restore_readonly 130' INT
    trap 'restore_readonly 143' TERM
    trap 'restore_readonly 129' HUP

    for command in steamos-readonly pacman pacman-key; do
        command -v "$command" >/dev/null 2>&1 \
            || die "$command is required to install the signed 32-bit build prerequisites."
    done
    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        steamos-readonly disable
        readonly_was_enabled=1
    fi
    pacman-key --init
    pacman-key --populate archlinux holo 2>/dev/null || pacman-key --populate
    # Force-repair the concrete multilib packages for the same reason as the
    # native development packages: SteamOS records can outlive their files.
    pacman -S --noconfirm \
        lib32-glibc lib32-gcc-libs lib32-libva lib32-libdrm \
        lib32-vulkan-icd-loader lib32-vulkan-radeon
    if [[ $readonly_was_enabled -eq 1 ]]; then
        steamos-readonly enable
        readonly_was_enabled=0
    fi
)

ensure_build_prerequisites() {
    local missing
    if ! build_prerequisites_ready; then
        missing=$(missing_build_prerequisites)
        printf '%s\n' "$missing" | sed 's/^/[bc250-video-codec] Missing prerequisite: /'
        log "Installing signed SteamOS source-build prerequisites..."
        install_build_prerequisites
    fi
    if ! build_prerequisites_ready; then
        missing=$(missing_build_prerequisites)
        printf '%s\n' "$missing" | sed 's/^/[bc250-video-codec] Still missing: /' >&2
        die "SteamOS did not provide the required VA-API codec build tools and headers."
    fi
}

ensure_32bit_build_prerequisites() {
    local missing
    if ! build_32bit_prerequisites_ready; then
        missing=$(missing_32bit_build_prerequisites)
        printf '%s\n' "$missing" | sed 's/^/[bc250-video-codec] Missing 32-bit prerequisite: /'
        log "Installing signed SteamOS multilib source-build prerequisites..."
        install_32bit_build_prerequisites
    fi
    if ! build_32bit_prerequisites_ready; then
        missing=$(missing_32bit_build_prerequisites)
        printf '%s\n' "$missing" | sed 's/^/[bc250-video-codec] Still missing 32-bit prerequisite: /' >&2
        die "SteamOS did not provide the required 32-bit VA-API codec libraries."
    fi
}

build_runtime() {
    local source="$1" build="$2" build32="$3" runtime="$4" include_32bit="$5" shader
    cmake -S "$source/approach1-compute-encoder" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTS=OFF \
        -DBC250_WITH_X264=OFF
    cmake --build "$build" --parallel "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"

    install -d -m 0755 "$runtime/dri" "$runtime/shaders"
    install -m 0755 "$build/bc250_drv_video.so" "$runtime/dri/bc250_drv_video.so"
    if [[ "$include_32bit" == 1 ]]; then
        cmake -S "$source/approach1-compute-encoder" -B "$build32" \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_TESTS=OFF \
            -DBUILD_32BIT=ON \
            -DBC250_WITH_X264=OFF
        cmake --build "$build32" --parallel "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" \
            --target bc250_drv_video
        install -d -m 0755 "$runtime/dri32"
        install -m 0755 "$build32/bc250_drv_video.so" "$runtime/dri32/bc250_drv_video.so"
    fi
    for shader in "${SHADER_NAMES[@]}"; do
        [[ -f "$build/$shader" && ! -L "$build/$shader" ]] \
            || die "The source build did not produce shader $shader."
        install -m 0644 "$build/$shader" "$runtime/shaders/$shader"
    done
    install -m 0644 "$source/LICENSE" "$runtime/LICENSE.upstream"
    install -m 0644 "$source/README.md" "$runtime/README.upstream.md"
    write_runtime_manifest "$runtime"
}

write_environment_atomically() {
    local environment_dir profile_dir keep_dir temporary profile_temporary keep_temporary
    environment_dir=$(dirname "$ENV_FILE")
    profile_dir=$(dirname "$PROFILE_FILE")
    keep_dir=$(dirname "$KEEP_FILE")
    [[ ! -L "$environment_dir" ]] || die "Refusing symlinked environment directory: $environment_dir"
    [[ ! -L "$profile_dir" ]] || die "Refusing symlinked profile directory: $profile_dir"
    [[ ! -L "$keep_dir" ]] || die "Refusing symlinked atomic-update directory: $keep_dir"
    install -d -m 0755 "$environment_dir"
    install -d -m 0755 "$profile_dir"
    install -d -m 0755 "$keep_dir"
    temporary=$(mktemp "$environment_dir/.bc250-video-codec.XXXXXX")
    profile_temporary=$(mktemp "$profile_dir/.bc250-video-codec.XXXXXX")
    keep_temporary=$(mktemp "$keep_dir/.bc250-video-codec.XXXXXX")
    environment_config > "$temporary"
    profile_config > "$profile_temporary"
    keep_config > "$keep_temporary"
    chmod 0644 "$temporary"
    chmod 0644 "$profile_temporary"
    chmod 0644 "$keep_temporary"
    if ! mv -f -- "$temporary" "$ENV_FILE"; then
        rm -f -- "$temporary" "$profile_temporary" "$keep_temporary"
        return 1
    fi
    if ! mv -f -- "$profile_temporary" "$PROFILE_FILE"; then
        rm -f -- "$profile_temporary" "$keep_temporary"
        return 1
    fi
    if ! mv -f -- "$keep_temporary" "$KEEP_FILE"; then
        rm -f -- "$keep_temporary"
        return 1
    fi
}

backup_managed_configuration() {
    local backup="$1" path name
    install -d -m 0700 "$backup"
    while IFS='|' read -r path name; do
        [[ -n "$path" ]] || continue
        if [[ -f "$path" && ! -L "$path" ]]; then
            cp -p -- "$path" "$backup/$name"
            : > "$backup/$name.present"
        fi
    done <<EOF
$ENV_FILE|environment
$PROFILE_FILE|profile
$KEEP_FILE|keep
$LEGACY_PROFILE_FILE|legacy-profile
EOF
}

restore_managed_configuration() {
    local backup="$1" path name
    while IFS='|' read -r path name; do
        [[ -n "$path" ]] || continue
        if [[ -f "$backup/$name.present" ]]; then
            install -d -m 0755 "$(dirname "$path")"
            cp -p -- "$backup/$name" "$path"
        else
            rm -f -- "$path"
        fi
    done <<EOF
$ENV_FILE|environment
$PROFILE_FILE|profile
$KEEP_FILE|keep
$LEGACY_PROFILE_FILE|legacy-profile
EOF
}

remove_legacy_profile() {
    [[ -n "$LEGACY_PROFILE_FILE" && "$LEGACY_PROFILE_FILE" != "$PROFILE_FILE" ]] \
        || return 0
    if [[ -e "$LEGACY_PROFILE_FILE" || -L "$LEGACY_PROFILE_FILE" ]]; then
        is_managed_profile "$LEGACY_PROFILE_FILE" \
            || die "Refusing to replace an unrecognized legacy shell profile: $LEGACY_PROFILE_FILE"
        rm -f -- "$LEGACY_PROFILE_FILE"
    fi
}

install_compatibility_link() {
    local compatibility_parent
    if [[ -e "$COMPAT_DIR" || -L "$COMPAT_DIR" ]]; then
        is_managed_compatibility_link \
            || die "Refusing to replace an unrecognized SteamOS runtime path: $COMPAT_DIR"
        return 0
    fi
    compatibility_parent=$(dirname "$COMPAT_DIR")
    [[ ! -L "$compatibility_parent" ]] \
        || die "Refusing symlinked SteamOS runtime parent: $compatibility_parent"
    install -d -m 0755 "$compatibility_parent"
    ln -s -- "$RUNTIME_DIR" "$COMPAT_DIR"
}

install_codec() {
    local include_32bit="${1:-0}" archive actual parent source build build32
    local dependency_status="" backup="" configuration_backup="" compatibility_created=0
    require_root
    [[ "$include_32bit" == 0 || "$include_32bit" == 1 ]] \
        || die "Invalid 32-bit companion selection."
    for command in curl flock ldd od python3 readelf sha256sum; do require_command "$command"; done
    detect_bc250 || die "AMD BC-250 PCI device 1002:13fe was not detected."
    [[ "$DATA_DIR" == /* && "$DATA_DIR" != / ]] || die "The runtime path is invalid."
    [[ "$COMPAT_DIR" == /* && "$COMPAT_DIR" != / \
        && "$COMPAT_DIR" != "$DATA_DIR" && "$COMPAT_DIR" != "$RUNTIME_DIR" ]] \
        || die "The SteamOS compatibility path is invalid."
    [[ ! -L "$DATA_DIR" ]] || die "Refusing symlinked runtime directory: $DATA_DIR"
    if [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]]; then
        is_managed_runtime \
            || die "Refusing to replace an unrecognized runtime at $RUNTIME_DIR"
    fi
    if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
        is_managed_environment \
            || die "Refusing to replace an unrecognized environment file: $ENV_FILE"
    fi
    if [[ -e "$PROFILE_FILE" || -L "$PROFILE_FILE" ]]; then
        is_managed_profile \
            || die "Refusing to replace an unrecognized shell profile: $PROFILE_FILE"
    fi
    if [[ -n "$LEGACY_PROFILE_FILE" && "$LEGACY_PROFILE_FILE" != "$PROFILE_FILE" \
        && ( -e "$LEGACY_PROFILE_FILE" || -L "$LEGACY_PROFILE_FILE" ) ]]; then
        is_managed_profile "$LEGACY_PROFILE_FILE" \
            || die "Refusing to replace an unrecognized legacy shell profile: $LEGACY_PROFILE_FILE"
    fi
    if [[ -e "$KEEP_FILE" || -L "$KEEP_FILE" ]]; then
        is_managed_keep_file \
            || die "Refusing to replace an unrecognized atomic-update keep list: $KEEP_FILE"
    fi
    if [[ -e "$COMPAT_DIR" || -L "$COMPAT_DIR" ]]; then
        is_managed_compatibility_link \
            || die "Refusing to replace an unrecognized SteamOS runtime path: $COMPAT_DIR"
    fi

    install -d -m 0755 "$DATA_DIR"
    install -d -m 0755 "$(dirname "$LOCK_FILE")"
    exec 9> "$LOCK_FILE"
    flock 9
    ensure_build_prerequisites
    if [[ "$include_32bit" == 1 ]]; then
        ensure_32bit_build_prerequisites
    fi

    parent=$(dirname "$DATA_DIR")
    STAGE=$(mktemp -d "$parent/.bc250-video-codec.XXXXXX")
    archive="$STAGE/$SOURCE_ARCHIVE_NAME"
    source="$STAGE/source"
    build="$STAGE/build"
    build32="$STAGE/build32"
    log "Downloading verified upstream source $RELEASE..."
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --output "$archive" "$SOURCE_ARCHIVE_URL"
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [[ "$actual" == "$SOURCE_ARCHIVE_SHA256" ]] \
        || die "Source archive checksum mismatch."

    mkdir "$source" "$STAGE/runtime"
    extract_source "$archive" "$source"
    log "Building the driver against this SteamOS image (libx264-independent)..."
    build_runtime "$source" "$build" "$build32" "$STAGE/runtime" "$include_32bit"
    runtime_marker > "$STAGE/runtime/.bc250-toolkit-managed"
    chmod 0644 "$STAGE/runtime/.bc250-toolkit-managed"
    manifest_layout_valid "$STAGE/runtime/manifest.sha256" \
        || die "The locally built runtime manifest is invalid."
    (cd "$STAGE/runtime" && sha256sum -c --quiet manifest.sha256) \
        || die "Locally built runtime files failed verification."
    validate_elf64 "$STAGE/runtime/dri/bc250_drv_video.so"
    if ! dependency_status=$(ldd -r "$STAGE/runtime/dri/bc250_drv_video.so" 2>&1) \
        || [[ "$dependency_status" == *"not found"* \
            || "$dependency_status" == *"undefined symbol"* \
            || "$dependency_status" == *"libx264"* ]]; then
        printf '%s\n' "$dependency_status" >&2
        die "The local source build has unavailable runtime dependencies. No driver was activated."
    fi
    if [[ "$include_32bit" == 1 ]]; then
        validate_elf32 "$STAGE/runtime/dri32/bc250_drv_video.so"
        if ! dependency_status=$(ldd -r "$STAGE/runtime/dri32/bc250_drv_video.so" 2>&1) \
            || [[ "$dependency_status" == *"not found"* \
                || "$dependency_status" == *"undefined symbol"* \
                || "$dependency_status" == *"libx264"* ]]; then
            printf '%s\n' "$dependency_status" >&2
            die "The 32-bit source build has unavailable runtime dependencies. No driver was activated."
        fi
    fi
    verify_vaapi_initialization "$STAGE/runtime"
    verify_ffmpeg_pipeline "$STAGE/runtime"
    if [[ "$include_32bit" == 1 ]]; then
        verify_vaapi_initialization_32 "$STAGE/runtime" "$build32"
        chmod 0755 "$STAGE/runtime/dri32"
    fi
    chmod 0755 "$STAGE/runtime" "$STAGE/runtime/dri" "$STAGE/runtime/shaders"
    configuration_backup="$STAGE/configuration.previous"
    backup_managed_configuration "$configuration_backup"

    if [[ -d "$RUNTIME_DIR" ]]; then
        backup="$DATA_DIR/.runtime.previous.$$"
        mv -- "$RUNTIME_DIR" "$backup"
    fi
    mv -- "$STAGE/runtime" "$RUNTIME_DIR"
    if [[ ! -L "$COMPAT_DIR" ]]; then
        install_compatibility_link
        compatibility_created=1
    fi
    if ! write_environment_atomically; then
        [[ $compatibility_created -eq 0 ]] || rm -f -- "$COMPAT_DIR"
        rm -rf -- "$RUNTIME_DIR"
        [[ -z "$backup" ]] || mv -- "$backup" "$RUNTIME_DIR"
        restore_managed_configuration "$configuration_backup"
        die "Could not install the managed environment configuration."
    fi
    if ! runtime_valid || ! compatibility_link_valid || ! environment_valid; then
        [[ $compatibility_created -eq 0 ]] || rm -f -- "$COMPAT_DIR"
        rm -rf -- "$RUNTIME_DIR"
        [[ -z "$backup" ]] || mv -- "$backup" "$RUNTIME_DIR"
        restore_managed_configuration "$configuration_backup"
        die "The installed runtime failed final verification."
    fi
    remove_legacy_profile
    [[ -z "$backup" ]] || rm -rf -- "$backup"
    log "Installed BC-250 VA-API video codec $RELEASE from verified source."
    if [[ "$include_32bit" == 1 ]]; then
        log "Installed the verified 32-bit companion for Steam and Remote Play."
    else
        log "Installed the 64-bit runtime without the optional 32-bit companion."
    fi
    log "SteamOS runtime path: $COMPAT_DIR -> $RUNTIME_DIR"
    log "Sign out or reboot before using the new VA-API selection."
}

test_codec() {
    for command in ffmpeg ldd sha256sum vainfo; do require_command "$command"; done
    detect_bc250 || die "AMD BC-250 PCI device 1002:13fe was not detected."
    runtime_valid || die "The installed BC-250 VA-API runtime is missing or invalid."
    verify_vaapi_initialization "$RUNTIME_DIR"
    verify_ffmpeg_pipeline "$RUNTIME_DIR"
    if runtime_has_32bit; then
        for command in gcc pkg-config; do require_command "$command"; done
        STAGE=$(mktemp -d "${TMPDIR:-/tmp}/bc250-video-codec.test32.XXXXXX")
        verify_vaapi_initialization_32 "$RUNTIME_DIR" "$STAGE"
    fi
}

uninstall_codec() {
    require_root
    require_command flock
    install -d -m 0755 "$(dirname "$LOCK_FILE")"
    exec 9> "$LOCK_FILE"
    flock 9

    if [[ -e "$COMPAT_DIR" || -L "$COMPAT_DIR" ]]; then
        is_managed_compatibility_link \
            || die "Refusing to remove an unrecognized SteamOS runtime path: $COMPAT_DIR"
    fi
    if [[ -e "$KEEP_FILE" || -L "$KEEP_FILE" ]]; then
        is_managed_keep_file \
            || die "Refusing to remove an unrecognized atomic-update keep list: $KEEP_FILE"
    fi
    if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
        is_managed_environment \
            || die "Refusing to remove an unrecognized environment file: $ENV_FILE"
    fi
    if [[ -e "$PROFILE_FILE" || -L "$PROFILE_FILE" ]]; then
        is_managed_profile \
            || die "Refusing to remove an unrecognized shell profile: $PROFILE_FILE"
    fi
    if [[ -n "$LEGACY_PROFILE_FILE" && "$LEGACY_PROFILE_FILE" != "$PROFILE_FILE" \
        && ( -e "$LEGACY_PROFILE_FILE" || -L "$LEGACY_PROFILE_FILE" ) ]]; then
        is_managed_profile "$LEGACY_PROFILE_FILE" \
            || die "Refusing to remove an unrecognized legacy shell profile: $LEGACY_PROFILE_FILE"
    fi
    if [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]]; then
        [[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" \
            && -f "$RUNTIME_DIR/.bc250-toolkit-managed" \
            && ! -L "$RUNTIME_DIR/.bc250-toolkit-managed" ]] \
            || die "Refusing to remove an unrecognized runtime at $RUNTIME_DIR"
        grep -qxF "$MANAGED_MARKER" "$RUNTIME_DIR/.bc250-toolkit-managed" \
            || die "Refusing to remove an unrecognized runtime at $RUNTIME_DIR"
    fi

    rm -f -- "$ENV_FILE" "$PROFILE_FILE" "$KEEP_FILE" "$COMPAT_DIR"
    if [[ -n "$LEGACY_PROFILE_FILE" && "$LEGACY_PROFILE_FILE" != "$PROFILE_FILE" ]]; then
        rm -f -- "$LEGACY_PROFILE_FILE"
    fi
    if [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]]; then
        rm -rf -- "$RUNTIME_DIR"
    fi
    rmdir "$DATA_DIR" 2>/dev/null || true
    log "Removed the BC-250 VA-API video codec."
    log "Sign out or reboot to restore the stock VA-API selection."
}

usage() {
    cat <<EOF
Usage: $0 {install|status|test|uninstall}

  install --with-32bit
             Build 64-bit plus the optional 32-bit Steam companion
  install --without-32bit
             Build only the standard 64-bit runtime
  status     Verify the runtime, environment, and current session
  test       Run VA-API initialization and FFmpeg encode/decode tests
  uninstall  Remove only toolkit-managed codec files
EOF
}

case "${1:-help}" in
    install)
        (($# == 2)) || die "Usage: $0 install {--with-32bit|--without-32bit}"
        case "$2" in
            --with-32bit) install_codec 1 ;;
            --without-32bit) install_codec 0 ;;
            *) die "Usage: $0 install {--with-32bit|--without-32bit}" ;;
        esac
        ;;
    status) (($# == 1)) || die "Usage: $0 status"; show_status ;;
    test) (($# == 1)) || die "Usage: $0 test"; test_codec ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; uninstall_codec ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 1 ;;
esac
