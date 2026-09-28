# BC-250 VA-API video codec

The toolkit installs the verified `v0.5.1` release from
[`simpmix/bc250-encoding-decoding-fix`](https://github.com/simpmix/bc250-encoding-decoding-fix).

The driver provides VA-API H.264 and HEVC encoding, decoding, and video
processing. Encoding uses Vulkan compute. Decoding uses the BC-250 CPU through
the VA-API interface.

## Commands

Run the toolkit as the logged-in user:

```bash
./bc250-toolkit.sh video-codec
./bc250-toolkit.sh video-codec-status
./bc250-toolkit.sh video-codec-test
./bc250-toolkit.sh video-codec-install
./bc250-toolkit.sh video-codec-remove
```

The installer downloads the source at the pinned `v0.5.1` commit, verifies its
SHA-256 digest, validates its archive layout, and builds it against the active
SteamOS image. It disables the optional libx264 backend so the installed driver
uses the Vulkan-compute H.264 path and does not depend on an upstream distro's
libx264 ABI. Before activation, it verifies the ELF architecture, dynamic
dependencies, shaders, license, README, and a locally generated payload
manifest.

When required build headers or tools are missing, the installer temporarily
unlocks the SteamOS root filesystem, installs signed packages with `pacman`,
and restores the original read-only state. It force-repairs the concrete
development packages because SteamOS can retain package records after removing
their headers. Failed probes identify the exact command, header, pkg-config
module, or compiler/link check that remains unavailable. Runtime files remain
in persistent storage.

Runtime files are physically stored in
`/var/lib/bc250-control/video-codec/runtime`, which the toolkit's storage
setup can offload to SteamOS's large persistent `/home` partition. The
installer exposes that runtime at the upstream SteamOS path `/var/lib/bc250`
with a managed symlink. Thus the driver and shaders are available as
`/var/lib/bc250/dri/bc250_drv_video.so` and `/var/lib/bc250/shaders/` without
duplicating them. The managed environment files are
`/etc/environment.d/90-bc250-video-codec.conf` and
`/etc/profile.d/zz-bc250-video-codec.sh`. The late-loading shell profile is
intentional: SteamOS provides `/etc/profile.d/libva.sh`, which otherwise resets
the selected driver to `radeonsi` after the toolkit profile is read. The
atomic-update keep list `/etc/atomic-update.conf.d/bc250-video-codec.conf`
explicitly preserves both configuration files and the `/var/lib/bc250`
compatibility link across SteamOS image updates. The link target remains backed
by persistent `/home` storage.

Sign out or reboot after installation or removal. New processes then use the
new VA-API selection.

Test the selected driver explicitly:

```bash
source /etc/profile.d/zz-bc250-video-codec.sh
vainfo --display drm --device /dev/dri/renderD128
./bc250-toolkit.sh video-codec-test
```

The installer runs initialization plus an eight-frame FFmpeg H.264 VA-API
encode/decode test against the staged runtime before changing the system
environment. It also checks relocated symbols with `ldd -r`; failed validation
leaves the previous runtime active.

## Scope

The toolkit installs the 64-bit runtime in persistent storage. It does not
replace the stock `radeonsi_drv_video.so`, install runtime files into `/usr`,
install the upstream audio module, or enable the upstream Sunshine boot
redirect. Signed source-build prerequisite packages remain subject to SteamOS
system-update replacement.

Applications that discard VA-API environment selection, including some
capability-enabled Sunshine installations, can require upstream-specific
configuration. Review the upstream documentation before applying a global
driver redirect.

## License

The downloaded driver, shaders, and upstream tools use GPL-3.0-only. The
installed runtime retains the upstream license and README. The pinned source
commit is `180aab87fa84b68f8d4a9d6bf8d4c1fb0cac940e`.
