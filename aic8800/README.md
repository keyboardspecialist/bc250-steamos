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
| `aic_zlp_quirk` | Applies the Bluetooth ZLP correction for `368b:8d81` |

## Source

The USB driver uses
[`shenmintao/aic8800d80`](https://github.com/shenmintao/aic8800d80)
commit `e93a7d2b6b9634acefc2aae2891e787fb48fdb01`.
The integrated source includes SteamOS build, firmware-path, teardown, and Wi-Fi Direct adaptations.
