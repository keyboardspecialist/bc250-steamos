# aic8800

[![Release](https://github.com/radxa-pkg/aic8800/actions/workflows/release.yaml/badge.svg)](https://github.com/radxa-pkg/aic8800/actions/workflows/release.yaml)

## Build

1. `git clone --recurse-submodules https://github.com/radxa-pkg/aic8800.git`
2. Open in [`devcontainer`](https://code.visualstudio.com/docs/devcontainers/containers)
3. `make deb`

## SteamOS

Use `sudo bash steamdeck-setup.sh` from the BC-250 toolkit. It first downloads the headers matching the running kernel. If Valve never published that exact package, interactive setup checks out the exact Evlav source, reconstructs the running configuration, and runs `modules_prepare` before compiling AIC8800.

SteamOS has `CONFIG_MODVERSIONS` disabled, so this WiFi-only fallback can defer exported-symbol validation to module load time instead of compiling the complete kernel for `Module.symvers`. Exact release checks still run, and the kernel refuses a module if any required symbol is unavailable. The boot service only reuses staged modules or published headers; rerun `steamdeck-setup.sh` when it reports that interactive source preparation is required.

Run `bash steamdeck-setup.sh status` as the logged-in user to inspect the
installation. Run `sudo bash steamdeck-setup.sh uninstall` to disable automatic
repair and remove runtime modules, firmware, and configuration. Uninstall keeps
the persistent source snapshot and downloaded kernel/build caches for reuse.
