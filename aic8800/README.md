# AIC8800 USB Driver

This package installs AIC8800 USB Wi-Fi support on SteamOS.

## Install

Run:

```sh
sudo bash steamdeck-setup.sh install
```

The setup performs these tasks:

1. Downloads headers for the active kernel.
2. Prepares matching Valve kernel source when the kernel requires source preparation.
3. Builds and validates each kernel module.
4. Installs firmware and device rules in persistent storage.
5. Enables module recovery after a SteamOS update.

Run setup again when the recovery service requests source preparation.

## Status

Run:

```sh
bash steamdeck-setup.sh status
```

The command reports module, firmware, device-rule, and recovery-service status.

## Remove

Run:

```sh
sudo bash steamdeck-setup.sh uninstall
```

The command removes modules, firmware, device rules, and the recovery service.
Persistent source and build caches remain available for reuse.

## Mode Switching

The setup supports these mass-storage identities:

| USB identity | Switch method | Runtime identity |
|---|---|---|
| `1111:1111` | Two usb_modeswitch messages | `a69c:8d80` loader |
| `a69c:5724` | SCSI eject | `368b:8d88` Wi-Fi |
| Known `a69c:572x` variants | SCSI eject | Device-specific AIC8800 identity |

Use custom values for another usb_modeswitch device:

```sh
sudo AIC_MODESWITCH_ID=1234:5678 \
  AIC_MODESWITCH_MESSAGE=0123456789abcdef \
  AIC_MODESWITCH_MESSAGE2=fedcba9876543210 \
  bash steamdeck-setup.sh install
```

Set `AIC_MODESWITCH_MESSAGE2` for a device that uses two messages.
Use values supplied by the device manufacturer.

## Modules

| Module | Function |
|---|---|
| `aic_load_fw` | Loads AIC firmware |
| `aic8800_fdrv` | Provides Wi-Fi support |
| `aic_zlp_quirk` | Applies the Bluetooth ZLP correction for `368b:8d81` and `a69c:8d81` |

The combo adapter uses the system `btusb` driver. The ZLP module adds the ACL
bulk-transfer termination used by AIC's vendor Bluetooth driver without replacing
`btusb`. Setup also disables USB autosuspend specifically for these two combo
adapter identities. Run setup again and reboot to apply a changed quirk module.

## Game Mode Wi-Fi and Controller Troubleshooting

Check the driver and the network service separately:

```sh
bash steamdeck-setup.sh status
journalctl -b -u aic8800-modules -u NetworkManager -u iwd -u wpa_supplicant
rfkill list
```

If `wlan0` appears and starts associating at boot, firmware initialization has
already completed. Association rejects or authentication timeouts need investigation
in the Wi-Fi backend, rather than an extra boot delay. A final `no-secrets` error
can follow repeated authentication failures even when the saved password exists.

For the observed AIC8800D80/WPA3 failure with `wpa_supplicant`, SteamOS's `iwd`
backend successfully performed SAE external authentication with the same adapter
and access point. Check or select that backend using SteamOS's helper:

```sh
steamos-wifi-set-backend --check
steamos-wifi-set-backend iwd
nmcli radio wifi on
```

Changing backend restarts networking. The backend setting applies in both Desktop
and Game Mode. Wi-Fi must also be enabled: a software rfkill block persists
independently of whether the driver is loaded.

After a live driver reinstall, `iwd` can retain stale device state: Linux has
`wlan0`, Wi-Fi is unblocked, but `iwctl device list` is empty and NetworkManager
keeps the interface unavailable. Restarting the backend restored the connection
in the observed case:

```sh
sudo systemctl restart iwd
```

If the saved network does not reconnect automatically after that restart, use
`nmcli connection up "YOUR SAVED CONNECTION"`. A fresh boot starts a new backend
process; verify cold-boot behavior separately from this live-reload recovery.

For controller lag, inspect the Bluetooth transport and report gaps:

```sh
lsusb -t
journalctl -b -k --grep='aic_zlp|Bluetooth: hci|nintendo.*(dropped|delta=|timeout|failed)'
journalctl -b -u bluetooth --grep='connect|failed|error'
cat /sys/module/aic_zlp_quirk/parameters/hook
cat /sys/module/aic_zlp_quirk/parameters/injections
```

Dropped Nintendo IMU reports are evidence of irregular report delivery, but do
not alone identify whether USB, radio interference, firmware, or host scheduling
caused it. The ZLP counter counts flagged outgoing transfers; it does not measure
latency or prove that a packet needed a ZLP. Compare the same controller with Wi-Fi
off and then on a 5 GHz network. A short USB extension separating the adapter from
the chassis and other 2.4 GHz receivers is also a useful interference test.
On the observed adapter the Bluetooth bulk endpoint has a 512-byte maximum packet
size; the ZLP flag only adds a packet for transfers that are exact multiples of
that size. It may therefore help some Bluetooth traffic without resolving short
controller-report stalls.

### Investigation on 2026-10-13

On kernel `7.2.7-valve1-1-neptune-72-gc8730d37f9c6`, the adapter enumerated as
`a69c:8d81`, with Bluetooth on interfaces 0/1 and Wi-Fi on interface 2:

- Module recovery finished around 8 seconds; `wlan0` appeared around 12 seconds
  and attempted a connection around 14 seconds.
- `wpa_supplicant` repeatedly received association rejection codes 53 and 1.
  Desktop Mode retried using the same backend and still failed. Switching to
  `iwd` later succeeded immediately using SAE external authentication.
- Wi-Fi was subsequently disabled by Plasma, leaving a software rfkill block.
- The original ZLP quirk only matched `368b:8d81`, so the installed status command
  incorrectly reported it as unnecessary for this adapter. AIC's vendor driver
  matches `a69c:8d81` and sets `URB_ZERO_PACKET` for ACL output as well.
- Switch Pro controllers produced 669 dropped-IMU-report warnings, including
  report gaps up to 433 ms. USB autosuspend was enabled, but the device reported
  zero suspended time, so autosuspend was not established as the cause.

The adapter-ID correction and USB power policy were installed successfully: the
Bluetooth hook is active and the USB autosuspend delay is `-1`. The live reinstall
left `iwd` without a usable device; restarting `iwd` restored the saved Wi-Fi
connection. Cold-boot Game Mode behavior and controller latency still need
hardware validation.

## Source

The USB driver uses
[`shenmintao/aic8800d80`](https://github.com/shenmintao/aic8800d80)
commit `5327c777d00a94ee3bea09525b3acc8e1b031993` (rebased from
`e93a7d2b6b9634acefc2aae2891e787fb48fdb01`, 23 upstream commits).
The integrated source includes SteamOS build, firmware-path, teardown, and Wi-Fi Direct adaptations.

The rebase merges the 17 changed driver files, not upstream installers or
distribution packaging. It adds cfg80211 7.3 cookie handling, the 7.1+ TDLS
discovery-response length correction, header-type monitor callback selection
(including stable-kernel backports), bounded firmware-path concatenation, and
USB-down disconnect-wait suppression. `CFG80211_VERSION=major.minor.patch`
can describe an explicitly backported wireless stack without changing timer or
USB API checks. SteamOS header preparation, persistent firmware paths, deferred
RX teardown, Wi-Fi Direct OFDM/control-port changes, OEM Bluetooth ZLP support,
and adapter-specific autosuspend policy remain local. Firmware is unchanged.

This is a source review with offline regression/ABI-harness coverage, not a
hardware qualification. Full module builds against each target SteamOS kernel,
cold boot, USB unplug/replug, suspend/resume, WPA3, Wi-Fi Direct, and Bluetooth
controller latency/coexistence still require testing on the actual adapter.
