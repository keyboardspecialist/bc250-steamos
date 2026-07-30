# Universal BC-250 ACPI power tables

These SSDTs add the CPU C-states and P-states missing from the BC-250
firmware. They cover both the factory 6-core/12-thread topology and the
unlocked 8-core/16-thread topology.

The state definitions come from
[`bc250-collective/bc250-acpi-fix`](https://github.com/bc250-collective/bc250-acpi-fix)
commit `1594d72f11d674bd7e46f4e51eee4216155e52fb`. Processor coverage through
`P00F` comes from
[`mendesrr/bc250-acpi-fix-updated-8c`](https://github.com/mendesrr/bc250-acpi-fix-updated-8c)
commit `6ebdb89b9d96f51cb34b060056e72c5cd42e3320`.

The additional `P00C` through `P00F` scopes and aliases are guarded with
`CondRefOf`. This prevents ACPICA from rejecting the complete SSDT when a
factory six-core firmware namespace does not contain those processor objects.

`bc250-power.sh acpi` compiles these sources with `iasl` and stores a versioned
early-initrd archive in `/var/lib/bc250-control/acpi`.
