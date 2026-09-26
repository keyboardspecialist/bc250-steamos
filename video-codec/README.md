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

The installer downloads the pinned 64-bit release archive, verifies its
SHA-256 digest, validates its archive layout, and verifies every installed
file against [`v0.5.1.sha256`](v0.5.1.sha256). It also checks the binary's
dynamic dependencies before it activates the driver. The upstream build links
to `libx264.so.163`; installation stops without changing VA-API selection when
that ABI is unavailable.

Runtime files use `/var/lib/bc250-control/video-codec/runtime`. The managed
environment file is `/etc/environment.d/90-bc250-video-codec.conf`.

Sign out or reboot after installation or removal. New processes then use the
new VA-API selection.

## Scope

The toolkit installs the 64-bit driver. It does not replace the stock
`radeonsi_drv_video.so`, modify `/usr`, install the upstream audio module, or
enable the upstream Sunshine boot redirect.

Applications that discard VA-API environment selection, including some
capability-enabled Sunshine installations, can require upstream-specific
configuration. Review the upstream documentation before applying a global
driver redirect.

## License

The downloaded driver, shaders, and upstream tools use GPL-3.0-only. The
installed runtime retains the upstream license and README. The pinned source
commit is `180aab87fa84b68f8d4a9d6bf8d4c1fb0cac940e`.
