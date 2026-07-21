# aic8800

[![Release](https://github.com/radxa-pkg/aic8800/actions/workflows/release.yaml/badge.svg)](https://github.com/radxa-pkg/aic8800/actions/workflows/release.yaml)

## Build

1. `git clone --recurse-submodules https://github.com/radxa-pkg/aic8800.git`
2. Open in [`devcontainer`](https://code.visualstudio.com/docs/devcontainers/containers)
3. `make deb`

## SteamOS

Use `sudo bash steamdeck-setup.sh` from the BC-250 toolkit. It first downloads the headers matching the running kernel. If Valve never published that exact package, interactive setup prepares the exact Evlav source and performs a complete kernel build before compiling AIC8800.

The source fallback can take hours and requires about 40 GiB free. It never installs the locally built kernel. The boot service only reuses staged modules or published headers; rerun `steamdeck-setup.sh` when the service reports that an interactive source build is required.
