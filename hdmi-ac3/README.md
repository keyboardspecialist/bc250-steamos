# HDMI AC-3 surround encoding

Enables real-time Dolby Digital 5.1 encoding over HDMI/DisplayPort on the
BC-250. SteamOS includes an `hdmi-ac3.conf` ALSA card profile, but its Valve
hardware rule does not select that profile for the BC-250 DMI identity.

The integration routes six-channel PCM through ALSA's `a52` plugin, keeps the
encoded sink alive between normal playback gaps, and buffers one 1536-sample
AC-3 frame before playback starts. It requires PipeWire, WirePlumber,
`alsa-plugins`, FFmpeg, and an AC-3-capable receiver or soundbar.

## Usage

Use **Device drivers & connectivity > HDMI audio** in `bc250-toolkit.sh`, or run:

```bash
./hdmi-ac3/hdmi-ac3.sh install
./hdmi-ac3/hdmi-ac3.sh status
./hdmi-ac3/hdmi-ac3.sh revert
```

Run the script as the logged-in Deck user. It requests administrator access
for the udev rule and SteamOS update-retention entry. Revert removes only
recognized toolkit configuration and restores `output:hdmi-stereo`.

The AMDGPU DisplayPort audio-clock correction remains a separate prerequisite
for reliable BC-250 HDMI/DP audio. Install it from the toolkit's Core System or
Drivers menu and reboot before enabling AC-3.

## Attribution

This implementation is based on the HDMI AC-3 encoding implementation guide
and scripts from
[`rpf16rj/bc250-steamos-real-toolkit`](https://github.com/rpf16rj/bc250-steamos-real-toolkit/tree/main/extras/hdmi-ac3-encoding).
The documented ALSA `a52` routing, WirePlumber profile selection, one-hour
suspend timeout, and 1536-sample start delay are adapted here with dynamic card
detection, toolkit-owned filenames, lifecycle checks, and SteamOS update
retention.

The managed udev and WirePlumber rules match AMD product ID `0x13ff`, the
Cyan Skillfish HDMI/DisplayPort audio function. `0x1640` belongs to a different
AMD audio controller and does not activate the BC-250 profile.
