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

Runtime files use `/var/lib/bc250-control/video-codec/runtime`. The managed
environment file is `/etc/environment.d/90-bc250-video-codec.conf`.

Sign out or reboot after installation or removal. New processes then use the
new VA-API selection.

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
