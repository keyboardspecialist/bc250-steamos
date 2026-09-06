# NCT6687D Fan-Control Driver

This component installs the enhanced `nct6687` hwmon driver from
[`Fred78290/nct6687d`](https://github.com/Fred78290/nct6687d). It exposes fan
tachometers and writable `pwmN` / `pwmN_enable` controls on supported NCT6683,
NCT6686D, and NCT6687-family Super-I/O controllers.

The source is pinned to commit
`a49a8abdfb6221772ecc836b3109e0cc338203cf`. The installer downloads only the
required upstream files, verifies fixed SHA-256 hashes, and retains the GPL-2.0
source and license in root-owned persistent storage before installing the
module.

```bash
sudo bash ./nct6687d/steamdeck-setup.sh install
bash ./nct6687d/steamdeck-setup.sh status
sudo bash ./nct6687d/steamdeck-setup.sh uninstall
```

Unknown `0xdxxx` chip IDs can be attempted explicitly with:

```bash
sudo bash ./nct6687d/steamdeck-setup.sh install --force-unknown
```

Do not use that option merely to bypass a failed probe. A wrong register map can
write unknown controller bits and may leave fan control in a state the BIOS
cannot recover. IDs outside the `0xdxxx` range remain rejected by the driver.

After installation, locate the dynamic hwmon directory with:

```bash
grep -H . /sys/class/hwmon/hwmon*/name | grep -E 'nct668[367]'
```

Writing `1` to `pwmN_enable` selects manual control, while `2` restores firmware
automatic control. A PWM value of zero can stop fans that support zero-RPM mode.
Fan-control software must restore automatic mode before exiting and should use
temperature safeguards rather than assuming any fixed PWM is safe.

SteamOS updates can wipe `/usr`. The enabled `nct6687-modules.service` restores
only a hash-verified module already staged for the running kernel. It never
downloads build input or executes Kbuild as root. After a kernel change, rerun
the interactive installer so source preparation and compilation occur as the
logged-in user before a new root-owned module is staged.

While installed, the generated modprobe file blacklists the stock `nct6683`
module so it cannot reserve the same controller before the enhanced `nct6687`
driver. Uninstall removes that blacklist and restores the stock module policy.

After this driver is active, the toolkit's **CoolerControl** interface can use
the onboard controller for fan profiles, curves, and monitoring.
