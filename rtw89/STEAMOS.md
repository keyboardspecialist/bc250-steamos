# RTW89 on SteamOS

This directory vendors morrownr/rtw89 at commit
`08b8d326937a200a706ec9c501374eec15835b5a`. It provides out-of-kernel
Realtek RTW89 Wi-Fi 6 and Wi-Fi 7 drivers for supported PCIe cards and USB
adapters. Bluetooth is a separate function and requires a separate Bluetooth
driver; these scripts do not install one.

Supported families include RTL8851, RTL8852, and RTL8922A-based AE/AU adapters
connected through PCIe or USB. RTL8922DE source is present upstream but is not
enabled by this pinned build and its firmware is not bundled. Installation
selects the matching endpoint from the adapter modalias and the aliases
exported by the validated built modules.

USB adapters must expose their WiFi function before installation. If a Realtek
adapter still appears in CD-ROM mode as `0bda:1a2b` or `0bda:a192`, install and
run `usb_modeswitch` first. The managed modprobe configuration includes the
upstream `usb_storage` quirks so those devices are not claimed as storage on
subsequent boots.

## Commands

```sh
sudo bash rtw89/steamdeck-setup.sh install
bash rtw89/steamdeck-setup.sh status
sudo bash rtw89/steamdeck-setup.sh uninstall
bash rtw89/steamdeck-setup.sh help
```

`install` builds as the invoking `SUDO_USER` against the exact running-kernel
Kbuild tree. It does not use DKMS and never runs the vendored Makefile as root
from this checkout. If `/usr/lib/modules/$(uname -r)/build` is absent, it uses
the bundled `prepare-kbuild.sh` to fetch and extract the exact SteamOS headers
package into that user's cache. It does not invoke anything outside this
directory.

The external-module build does not require `vmlinux`. The header preparer
removes the packaged kernel image so Kbuild consistently skips optional module
BTF without adding a `pahole` dependency. The installer reports that once and
filters Kbuild's repetitive per-module skip messages. The exact nonempty
`Module.symvers` from the headers package is always required for strict modpost
validation.

Validated source, per-kernel module stages, and driver-owned firmware copies
live below `/home/.steamos/offload/var/lib/rtw89-steamos`. The installer owns
its update keep list and boot service directly; it does not require the BC-250
toolkit's storage, control, plugin, audio, or other driver scripts. The boot
service can restore a wiped SteamOS root filesystem offline. It never downloads
files or installs packages; if exact headers or the toolchain are unavailable,
rerun interactive setup.

`status` is read-only and exits 0 only for a complete current-kernel install.
`uninstall` removes only manifest-owned modules and hash-matching driver
firmware. It preserves the persistent source snapshot and module build caches.
Reboot after uninstall if a module could not be unloaded or to bind the stock
driver cleanly.
