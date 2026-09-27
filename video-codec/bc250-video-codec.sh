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
ENV_FILE="${BC250_VIDEO_ENV_FILE:-/etc/environment.d/90-bc250-video-codec.conf}"
PROFILE_FILE="${BC250_VIDEO_PROFILE_FILE:-/etc/profile.d/zz-bc250-video-codec.sh}"
LEGACY_PROFILE_FILE=""
if [[ -z "${BC250_VIDEO_PROFILE_FILE+x}" ]]; then
    LEGACY_PROFILE_FILE=/etc/profile.d/90-bc250-video-codec.sh
fi
LOCK_FILE="${BC250_VIDEO_LOCK_FILE:-/run/lock/bc250-video-codec.lock}"
MANAGED_MARKER="bc250-toolkit-video-codec-v1"
ENV_MARKER="# BC-250 toolkit managed VA-API video codec"
PROFILE_MARKER="# BC-250 toolkit managed VA-API video codec shell environment"
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
    cat <<EOF
$ENV_MARKER
LIBVA_DRIVER_NAME=bc250
LIBVA_DRIVERS_PATH=$RUNTIME_DIR/dri
BC250_SHADER_DIR=$RUNTIME_DIR/shaders
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
    cat <<EOF
$PROFILE_MARKER
export LIBVA_DRIVER_NAME=bc250
export LIBVA_DRIVERS_PATH=$RUNTIME_DIR/dri
export BC250_SHADER_DIR=$RUNTIME_DIR/shaders
export BC250_FAST_MODE=1
export BC250_SLICES_PER_FRAME=4
export BC250_HEVC_SLICES=4
export OMP_WAIT_POLICY=PASSIVE
export GOMP_SPINCOUNT=0
export OMP_NUM_THREADS=2
export OMP_DYNAMIC=FALSE
EOF
}

is_managed_runtime() {
    [[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" \
        && -f "$RUNTIME_DIR/.bc250-toolkit-managed" \
        && ! -L "$RUNTIME_DIR/.bc250-toolkit-managed" ]] \
        && grep -qxF "$MANAGED_MARKER" "$RUNTIME_DIR/.bc250-toolkit-managed"
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

runtime_valid() {
    is_managed_runtime || return 1
    diff -q <(runtime_marker) "$RUNTIME_DIR/.bc250-toolkit-managed" >/dev/null 2>&1 \
        || return 1
    [[ -f "$RUNTIME_DIR/manifest.sha256" && ! -L "$RUNTIME_DIR/manifest.sha256" ]] \
        || return 1
    manifest_layout_valid "$RUNTIME_DIR/manifest.sha256" || return 1
    (cd "$RUNTIME_DIR" && sha256sum -c --quiet manifest.sha256) >/dev/null 2>&1 \
        || return 1
    [[ -x "$RUNTIME_DIR/dri/bc250_drv_video.so" ]] || return 1
    runtime_dependencies_valid "$RUNTIME_DIR/dri/bc250_drv_video.so" || return 1
}

manifest_paths() {
    local shader
    echo "dri/bc250_drv_video.so"
    for shader in "${SHADER_NAMES[@]}"; do
        echo "shaders/$shader"
    done
    echo "LICENSE.upstream"
    echo "README.upstream.md"
}

manifest_layout_valid() {
    local manifest="$1" expected actual
    expected=$(manifest_paths)
    actual=$(sed -nE 's/^[0-9a-f]{64}  //p' "$manifest")
    [[ "$actual" == "$expected" ]] \
        && [[ $(wc -l < "$manifest") -eq 14 ]] \
        && ! grep -Evq '^[0-9a-f]{64}  (dri/bc250_drv_video\.so|shaders/[a-z0-9_]+\.comp\.spv|LICENSE\.upstream|README\.upstream\.md)$' "$manifest"
}

write_runtime_manifest() {
    local runtime="$1" path
    : > "$runtime/manifest.sha256"
    while IFS= read -r path; do
        (cd "$runtime" && sha256sum "$path") >> "$runtime/manifest.sha256"
    done < <(manifest_paths)
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
    diff -q <(profile_config) "$PROFILE_FILE" >/dev/null 2>&1
}

shell_environment_active() {
    [[ "${LIBVA_DRIVER_NAME:-}" == bc250 \
        && "${LIBVA_DRIVERS_PATH:-}" == "$RUNTIME_DIR/dri" \
        && "${BC250_SHADER_DIR:-}" == "$RUNTIME_DIR/shaders" ]]
}

manager_environment_active() {
    local environment
    command -v systemctl >/dev/null 2>&1 || return 1
    environment=$(systemctl --user show-environment 2>/dev/null) || return 1
    grep -qxF "LIBVA_DRIVER_NAME=bc250" <<< "$environment" \
        && grep -qxF "LIBVA_DRIVERS_PATH=$RUNTIME_DIR/dri" <<< "$environment" \
        && grep -qxF "BC250_SHADER_DIR=$RUNTIME_DIR/shaders" <<< "$environment"
}

session_environment_conflicted() {
    local environment=""
    if [[ ( -n "${LIBVA_DRIVER_NAME:-}" && "${LIBVA_DRIVER_NAME:-}" != bc250 ) \
        || ( -n "${LIBVA_DRIVERS_PATH:-}" && "${LIBVA_DRIVERS_PATH:-}" != "$RUNTIME_DIR/dri" ) \
        || ( -n "${BC250_SHADER_DIR:-}" && "${BC250_SHADER_DIR:-}" != "$RUNTIME_DIR/shaders" ) ]]; then
        return 0
    fi
    command -v systemctl >/dev/null 2>&1 || return 1
    environment=$(systemctl --user show-environment 2>/dev/null) || return 1
    if grep -q '^LIBVA_DRIVER_NAME=' <<< "$environment" \
        && ! grep -qxF 'LIBVA_DRIVER_NAME=bc250' <<< "$environment"; then
        return 0
    fi
    if grep -q '^LIBVA_DRIVERS_PATH=' <<< "$environment" \
        && ! grep -qxF "LIBVA_DRIVERS_PATH=$RUNTIME_DIR/dri" <<< "$environment"; then
        return 0
    fi
    if grep -q '^BC250_SHADER_DIR=' <<< "$environment" \
        && ! grep -qxF "BC250_SHADER_DIR=$RUNTIME_DIR/shaders" <<< "$environment"; then
        return 0
    fi
    return 1
}

show_status() {
    local runtime_present=0 environment_present=0
    [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]] && runtime_present=1
    [[ -e "$ENV_FILE" || -L "$ENV_FILE" \
        || -e "$PROFILE_FILE" || -L "$PROFILE_FILE" \
        || ( -n "$LEGACY_PROFILE_FILE" \
            && ( -e "$LEGACY_PROFILE_FILE" || -L "$LEGACY_PROFILE_FILE" ) ) ]] \
        && environment_present=1

    if [[ $runtime_present -eq 0 && $environment_present -eq 0 ]]; then
        echo "state: not-installed"
        echo "release: $RELEASE"
        echo "session: stock"
        return 1
    fi

    if runtime_valid && environment_valid; then
        echo "state: installed"
        echo "release: $RELEASE"
        echo "driver: verified local source build"
        echo "shaders: 11 verified"
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
    local class
    class=$(od -An -tu1 -j4 -N1 "$1" | tr -d '[:space:]')
    [[ "$class" == 2 ]] || die "The release driver is not a 64-bit ELF file."
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

build_runtime() {
    local source="$1" build="$2" runtime="$3" shader
    cmake -S "$source/approach1-compute-encoder" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTS=OFF \
        -DBC250_WITH_X264=OFF
    cmake --build "$build" --parallel "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"

    install -d -m 0755 "$runtime/dri" "$runtime/shaders"
    install -m 0755 "$build/bc250_drv_video.so" "$runtime/dri/bc250_drv_video.so"
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
    local environment_dir profile_dir temporary profile_temporary
    environment_dir=$(dirname "$ENV_FILE")
    profile_dir=$(dirname "$PROFILE_FILE")
    [[ ! -L "$environment_dir" ]] || die "Refusing symlinked environment directory: $environment_dir"
    [[ ! -L "$profile_dir" ]] || die "Refusing symlinked profile directory: $profile_dir"
    install -d -m 0755 "$environment_dir"
    install -d -m 0755 "$profile_dir"
    temporary=$(mktemp "$environment_dir/.bc250-video-codec.XXXXXX")
    profile_temporary=$(mktemp "$profile_dir/.bc250-video-codec.XXXXXX")
    environment_config > "$temporary"
    profile_config > "$profile_temporary"
    chmod 0644 "$temporary"
    chmod 0644 "$profile_temporary"
    if ! mv -f -- "$temporary" "$ENV_FILE"; then
        rm -f -- "$temporary" "$profile_temporary"
        return 1
    fi
    if ! mv -f -- "$profile_temporary" "$PROFILE_FILE"; then
        rm -f -- "$profile_temporary"
        return 1
    fi
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

install_codec() {
    local archive actual parent source build dependency_status="" backup=""
    require_root
    for command in curl flock ldd od python3 sha256sum; do require_command "$command"; done
    detect_bc250 || die "AMD BC-250 PCI device 1002:13fe was not detected."
    [[ "$DATA_DIR" == /* && "$DATA_DIR" != / ]] || die "The runtime path is invalid."
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

    install -d -m 0755 "$DATA_DIR"
    install -d -m 0755 "$(dirname "$LOCK_FILE")"
    exec 9> "$LOCK_FILE"
    flock 9
    ensure_build_prerequisites

    parent=$(dirname "$DATA_DIR")
    STAGE=$(mktemp -d "$parent/.bc250-video-codec.XXXXXX")
    archive="$STAGE/$SOURCE_ARCHIVE_NAME"
    source="$STAGE/source"
    build="$STAGE/build"
    log "Downloading verified upstream source $RELEASE..."
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --output "$archive" "$SOURCE_ARCHIVE_URL"
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [[ "$actual" == "$SOURCE_ARCHIVE_SHA256" ]] \
        || die "Source archive checksum mismatch."

    mkdir "$source" "$STAGE/runtime"
    extract_source "$archive" "$source"
    log "Building the driver against this SteamOS image (libx264-independent)..."
    build_runtime "$source" "$build" "$STAGE/runtime"
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
    verify_vaapi_initialization "$STAGE/runtime"
    verify_ffmpeg_pipeline "$STAGE/runtime"
    chmod 0755 "$STAGE/runtime" "$STAGE/runtime/dri" "$STAGE/runtime/shaders"

    if [[ -d "$RUNTIME_DIR" ]]; then
        backup="$DATA_DIR/.runtime.previous.$$"
        mv -- "$RUNTIME_DIR" "$backup"
    fi
    mv -- "$STAGE/runtime" "$RUNTIME_DIR"
    if ! write_environment_atomically; then
        rm -rf -- "$RUNTIME_DIR"
        [[ -z "$backup" ]] || mv -- "$backup" "$RUNTIME_DIR"
        die "Could not install the managed environment configuration."
    fi
    remove_legacy_profile
    if ! runtime_valid || ! environment_valid; then
        rm -rf -- "$RUNTIME_DIR"
        [[ -z "$backup" ]] || mv -- "$backup" "$RUNTIME_DIR"
        die "The installed runtime failed final verification."
    fi
    [[ -z "$backup" ]] || rm -rf -- "$backup"
    log "Installed BC-250 VA-API video codec $RELEASE from verified source."
    log "Sign out or reboot before using the new VA-API selection."
}

test_codec() {
    for command in ffmpeg ldd sha256sum vainfo; do require_command "$command"; done
    detect_bc250 || die "AMD BC-250 PCI device 1002:13fe was not detected."
    runtime_valid || die "The installed BC-250 VA-API runtime is missing or invalid."
    verify_vaapi_initialization "$RUNTIME_DIR"
    verify_ffmpeg_pipeline "$RUNTIME_DIR"
}

uninstall_codec() {
    require_root
    require_command flock
    install -d -m 0755 "$(dirname "$LOCK_FILE")"
    exec 9> "$LOCK_FILE"
    flock 9

    if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
        is_managed_environment \
            || die "Refusing to remove an unrecognized environment file: $ENV_FILE"
        rm -f -- "$ENV_FILE"
    fi
    if [[ -e "$PROFILE_FILE" || -L "$PROFILE_FILE" ]]; then
        is_managed_profile \
            || die "Refusing to remove an unrecognized shell profile: $PROFILE_FILE"
        rm -f -- "$PROFILE_FILE"
    fi
    if [[ -n "$LEGACY_PROFILE_FILE" && "$LEGACY_PROFILE_FILE" != "$PROFILE_FILE" \
        && ( -e "$LEGACY_PROFILE_FILE" || -L "$LEGACY_PROFILE_FILE" ) ]]; then
        is_managed_profile "$LEGACY_PROFILE_FILE" \
            || die "Refusing to remove an unrecognized legacy shell profile: $LEGACY_PROFILE_FILE"
        rm -f -- "$LEGACY_PROFILE_FILE"
    fi
    if [[ -e "$RUNTIME_DIR" || -L "$RUNTIME_DIR" ]]; then
        [[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" \
            && -f "$RUNTIME_DIR/.bc250-toolkit-managed" \
            && ! -L "$RUNTIME_DIR/.bc250-toolkit-managed" ]] \
            || die "Refusing to remove an unrecognized runtime at $RUNTIME_DIR"
        grep -qxF "$MANAGED_MARKER" "$RUNTIME_DIR/.bc250-toolkit-managed" \
            || die "Refusing to remove an unrecognized runtime at $RUNTIME_DIR"
        rm -rf -- "$RUNTIME_DIR"
    fi
    rmdir "$DATA_DIR" 2>/dev/null || true
    log "Removed the BC-250 VA-API video codec."
    log "Sign out or reboot to restore the stock VA-API selection."
}

usage() {
    cat <<EOF
Usage: $0 {install|status|test|uninstall}

  install    Download verified source, build for SteamOS, and install $RELEASE
  status     Verify the runtime, environment, and current session
  test       Run VA-API initialization and FFmpeg encode/decode tests
  uninstall  Remove only toolkit-managed codec files
EOF
}

case "${1:-help}" in
    install) (($# == 1)) || die "Usage: $0 install"; install_codec ;;
    status) (($# == 1)) || die "Usage: $0 status"; show_status ;;
    test) (($# == 1)) || die "Usage: $0 test"; test_codec ;;
    uninstall) (($# == 1)) || die "Usage: $0 uninstall"; uninstall_codec ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 1 ;;
esac
