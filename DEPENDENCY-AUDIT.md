# External dependency update audit

Checked and implementation summary updated: 2026-10-21. Pre-change toolkit
baseline: `ce9d1fc` (`v0.34.3`).

## Implemented outcomes and remaining qualification

The source integrations and lockfile/CI changes below supersede the historical
assessment later in this document. They do **not** mean users' installed
components were upgraded or that hardware was qualified. Dynamic discovery and
intentionally retained pins prevent any claim that all packages are "latest."

| Component | Implemented outcome / retained decision | Validation and remaining gaps |
| --- | --- | --- |
| Global RADV / DirectMesh | Mesa **26.2.5**, commit `ddaf85e353442d9d7f192fdcf1823e652e3f2ee3`, with MastaG `f05991ace64a42eda3d2dc583e96b8d35ce393e3` and **DirectMesh 1.3.1**. `setup --directmesh` installs the global runtime; enabled by default on BC-250, per-game opt-out `RADV_DIRECTMESH=0 %command%`. | All seven patches apply with zero fuzz; full RADV `ninja -j2` build **passed**. Rebaser preserves `force_exact_glsl_fma` and padded-VA unmapping and expands compiler-key arrays/assertions from 24 to 28 bytes. No installation or GPU/gameplay qualification. |
| Retired R2 profile | New R2 installation refused. DirectMesh setup first verifies/removes recognized toolkit-owned R2 tool/profile files; `uninstall --native-mesh` remains available. Historical manifests/hashes exist only for removal. | Modified recorded profiles, unrecognized tools, symlinks, and unsafe ancestors fail closed. Historical private Proton has no full-tree manifest; preserve personal additions before its entire copy is removed. Original Proton, prefixes, saves, and Steam settings stay unchanged; select ordinary Proton and remove old `bc250-r2` launch options manually. |
| libdrm fallback | Source-build fallback advanced to **2.4.134**, independently checksum-pinned. | Full RADV rebuild with forced static libdrm/libdrm_amdgpu fallback **passed**. Not a replacement of the host's system libdrm; target SteamOS installation remains unqualified. |
| Portable FSR4 | **RC11** ZIP/DLL pins, safe ZIP extraction, notices, existing backup/rollback handling; legacy tar.xz support retained. | Packaging and rollback coverage are not GPU testing or an FPS claim. RC11 is still a prerelease. |
| HelixSR | **2.0.0, upscaling only**. Exact 149-entry ZIP inventory; extracts 52 preparation files, passes `--no-fg --separate-files`, requires 200 shaders. Scaler and frame generation are not integrated. | Archive/inventory and command-argument checks only: no actual shader build or GPU test. `--latest` remains optional/YMMV rather than a promise of future-layout compatibility. |
| VA-API codec | **0.5.4**, commit `bc1191850fa521ceb3345986c59c1a882ed757fc`; inventories all **17** compute shaders. Optional x264/x265 adapters use runtime probing; full implementations need already-present headers. | Native source build and all 17 shaders **passed**. No 32-bit runtime, Gamescope/Steam Link/Sunshine, or GPU streaming qualification. |
| CoolerControl | **5.1.1** verified AppImage; complete private pre-upgrade config/data snapshots, existing settings retained. REST/gRPC share authenticated **11987**; **11988 removed**. | Fan fail-safe behavior, migrated sensor/profile assignments, daemon startup, and remote clients still need live qualification. Snapshots are retained on uninstall. |
| AIC8800 | Source rebased to **`5327c777d00a94ee3bea09525b3acc8e1b031993`**, preserving SteamOS, teardown, Wi-Fi Direct, OEM ZLP, and power-policy adaptations; firmware unchanged. | Source review and offline regression/ABI harness tests, not a full target-kernel module build or adapter qualification. Cold boot, reconnect, PM, WPA3, Wi-Fi Direct, and Bluetooth coexistence remain open. |
| NCT6687D | Pin advanced to **`ec1030ba7acc32b36723af0c7c9c9aead5e57b54`**; signed temperatures, EC window and lifecycle fixes, corrected min/max ABI. | Source/hash and offline lifecycle coverage only; no full module build or fan/sensor/PWM/watchdog/PM hardware qualification. |
| Memory temperature | Reviewed source **`4a2221d1da387fa2e738bb9368b39594e242ba4b`** with binary/symbol pins, bounded polling, packed reads, firmware-version gate, and schema-2 backups covering the 908-byte runtime footprint. Legacy schema-1 accepted only for restore; no force-overwrite mode. | Current component README records the guarded migration and restore ordering. No live firmware writes or hardware qualification. Keep state until successful restore; see `memory-temperature/README.md`. |
| Decky dependencies | UI **4.16.0**, Rollup/native binaries **4.64.12**, React/DOM typings **19.3.0**; `brace-expansion` maintenance fixes **1.1.21/2.1.7**. **TypeScript 5.9.3 retained** because TypeScript 7 is incompatible with the current build integration; host React remains Decky's responsibility. | Compatible lockfile refresh, not forced latest majors. Production audit is clean; one unfixed build-only **`braces` 3.0.3** advisory remains. Avoid untrusted glob inputs; this is not a security certification or a Decky host-runtime qualification. |
| Build toolchain | Exact **pnpm 9.15.9**, checksum-verified private installer under user-local state; Node **>=24.12 <25**, CI Node **24**. | Does not replace user-global tooling; intentionally retains pnpm 9 configuration compatibility rather than claiming latest pnpm. |
| CI / Trainer packaging | Actions checkout **7.0.1**, setup-python **7.0.0**, setup-node **7.1.0**, upload-artifact **7.0.2**, pnpm/action-setup **6.1.0**; Flatpak KDE **6.11**. Supported Python checks coexist with Python 3.8 compatibility coverage. | Configuration changes are not proof of successful hosted release workflows or live Flatpak multimedia/D-Bus operation. |
| EFI headers | Advanced to **`d438479f1e2b3a9c99623a5127d9e65bbeb813e7`**, additive `EFI_ERROR` macro only. | Source/hash checks passed; EFI compilation unavailable locally because `clang` is missing. No boot/firmware validation. |
| Intentionally retained / dynamic components | OptiScaler **0.9.4** and vendored dbus-next **0.2.3** retained; GFX1013 kernel repair, SMU OC, Linux core unlock (`87ec098`), EFI unlock (`3e45131`), and ACPI safety baselines retained after review. GE-Proton, governor, RAM utility, Decky Loader, UMR and CU-manager discovery/cache policies remain distinct. | Upstream metadata alone does not justify changing hardware semantics, prove cached installations current, or qualify rolling assets. Reviewed core-unlock changes were not imported because they alter unqualified SMN/mask behavior or overlap existing guarded telemetry. Historical tables below record upstream observations, not new pin recommendations. |

See `bc250-mesa-patches/README.md`, `video-codec/README.md`,
`coolercontrol/README.md`, `aic8800/README.md`, `nct6687d/README.md`, and
`memory-temperature/README.md` for current provenance and migration details.

### Final local validation

- Integration suite: **614 tests, 612 passed and 2 skipped**.
- Shared backend: **140 passed**; desktop D-Bus/control service: **53 passed**.
- Decky typecheck and Rollup bundle passed against isolated updated dependencies.
- Fresh Mesa source accepted all seven patches and the libdrm wrap patch with
  zero fuzz. Full RADV builds passed with host libdrm and with forced static
  libdrm/libdrm_amdgpu 2.4.134 fallback; final ELF/linkage and feature markers passed.
- Native codec source/shader build passed. Generated menus, QML utility checks,
  changed Bash syntax, and whitespace checks passed.
- Native Trainer/QML execution remains blocked by missing Qt6 development files;
  EFI compilation remains blocked by missing clang. No global installation,
  live firmware writes, kernel-module loading, or gameplay qualification occurred.
- Validation was completed before preparing `v0.35.0`; tag-triggered CI builds
  and publishes the release artifacts separately.

## Historical assessment — baseline before these changes

**Everything below records the read-only assessment of `ce9d1fc`, before the
implemented updates above.** "Integrated", "locked", "repository setting",
"current", "not integrated", and recommendations in these historical tables
refer to that baseline, not the updated working tree. Upstream observations are
dated 2026-10-21 and may subsequently change. The initial assessment itself
changed no dependency pins, installed drivers, firmware, or package locks.

### Original recommended order (historical)

1. Address the npm build-dependency advisories and move CI off end-of-life Node
   20. Refresh the Decky UI/build dependencies with typecheck and bundle tests.
2. Qualify the video codec `v0.5.4` and CoolerControl `5.1.1` on SteamOS.
3. Review the memory-temperature payload and NCT6687D changes; both touch hardware
   and need more than a checksum refresh.
4. Evaluate DirectMesh as an isolated per-game alternative. Update Mesa and its
   patch series together, retaining the existing R2 recovery path.
5. Qualify HelixSR 2.0 and FSR4 RC11 packaging/rollback before changing defaults.

### Graphics and upscaling (pre-change baseline)

| Component | Integrated version | Upstream finding | Assessment |
| --- | --- | --- | --- |
| Native mesh profile | `luckiskind/bc250-radv-r2`, `r2-20260921`, commit `3367cd5` | Same R2 assets and hashes remain published. A newer `performance-r4-20260926` prerelease is a separate opt-in profile; upstream explicitly retains R2 for Borderlands 4 and containment-sensitive games. | Do not replace R2 with R4 automatically. |
| LoneWolf DirectMesh | Not currently integrated; the old LoneWolf profile is recognized only for migration/removal | Latest release is `directmesh-v1.3.1`, published October 9. It adds the VRAM-to-GTT storage fix for 4K hangs and enables DirectMesh by default on BC-250. Earlier DirectMesh releases add mesh conversion, device-generated commands, multiview, and indexed draws. | Worth integrating/evaluating, but this is a new driver route, not a version bump to our R2 bundle. |
| Mesa build baseline | `26.2.2`, commit `3281a69` | Latest published stable tarball is `26.2.5`; `26.3.0-rc1` is also available. | Update candidate. Rebase and validate the complete patch set; do not just change the Mesa tag. |
| MastaG RADV/FSR4 patches | Commit `db49878` | Default branch is 145 commits ahead, at `f05991a`. Its current series includes DirectMesh 1.3.1, renames/reorders FSR4 patches, and maintains stable-Mesa and mesa-git variants. Its documentation describes the stable DirectMesh rebase against Mesa 26.2.4. | Coordinated integration work, not a blind commit/hash replacement. Existing kernel, cache, opt-in, and profile-attestation assumptions need review. |
| libdrm source-build fallback | `2.4.133` | Latest published tarball is `2.4.134`. | Small update candidate; regenerate the archive checksum and test the SteamOS build. This is separate from the host's system libdrm. |
| Portable FSR4 DLL | `v4.0.0-rc9`, docs2 tar.xz | Latest DLL release is `v4.0.0-rc11`, still marked prerelease. RC10 reduced synthetic cold compilation/setup work; RC11 retains those shaders and updates identity/tooling. Newer OptiClient releases are not newer DLL versions. | Update candidate. RC11 publishes a ZIP, whereas our helper expects an RC9-style tar.xz. Adapt extraction, notices, hashes, records, and rollback tests. Do not present this as an established FPS improvement. |
| OptiScaler | `v0.9.4`, `Optiscaler_0.9.4-final.20260718._MM.7z` | Latest stable release and archive SHA-256 exactly match our pin. | Current; no pin update needed. |
| HelixSR default | `v1.4.3` | Latest stable release is `v2.0.0`, published October 19. It combines upscaling and DLSS frame generation in one DLL, changes packaging, includes Scaler 1.1.0, and adds performance work. | Major integration review. Our helper has a fixed file allowlist, generated-payload schema, and 30/60-shader checks. Qualify new layouts and preparation behavior rather than changing only the release/hash. |
| HelixSR optional latest route | Resolves GitHub `/releases/latest` dynamically | It will resolve `v2.0.0` now. | No discovery-pin update required, but dynamic discovery is not proof that the existing preparer supports the latest payload. Current 2.0 preparation/gameplay was not executed in this audit. |
| BC-250 GE-Proton | Dynamically selects the newest matching package in MastaG's rolling `repo` release | Newest matching package observed: `protonge-latest-bc250-11.11-323-x86_64.pkg.tar.zst`. | Discovery is already dynamic. Users can update through the existing Proton update action; installation state was not inspected. |
| R2 Proton/vkd3d/source snapshots | Exact Proton `11.0-2c` plus pinned R2 Mesa/vkd3d artifacts | R2 still documents these as the tested combination. | Keep coupled to R2. A newer general Proton package is not a substitute for R2's required private base. |
| Retired private FSR4 V3 route | `dmorazasanchez/bc250-fsr4` commit `741ff3e` retained for legacy recognition | Latest release listed is `v3.0.0`; the active integrated route uses MastaG's series instead. | No reason to revive or independently bump a retired profile. |

Sources:

- [DirectMesh 1.3.1 release](https://github.com/lonewolf0622/bc250meshtaskwork/releases/tag/directmesh-v1.3.1)
- [R2 recovery](https://github.com/luckiskind/bc250-radv-r2/releases/tag/r2-20260921) and [separate R4 performance profile](https://github.com/luckiskind/bc250-radv-r2/releases/tag/performance-r4-20260926)
- [Mesa release archive](https://archive.mesa3d.org/) and [libdrm archive](https://dri.freedesktop.org/libdrm/)
- [MastaG changes since our pin](https://github.com/MastaG/linux-cachyos-bc250/compare/db49878af40551b481f511053201fcf1e1bd5d90...f05991ace64a42eda3d2dc583e96b8d35ce393e3) and [patch documentation at audited head](https://github.com/MastaG/linux-cachyos-bc250/blob/f05991ace64a42eda3d2dc583e96b8d35ce393e3/docs/PATCHES.md)
- [FSR4 RC11](https://github.com/daniel-h-0/bc250-fsr4-fork/releases/tag/v4.0.0-rc11), [OptiScaler 0.9.4](https://github.com/optiscaler/OptiScaler/releases/tag/v0.9.4), and [HelixSR 2.0.0](https://github.com/lonewolf0622/HelixSR/releases/tag/v2.0.0)
- [Rolling BC-250 package release](https://github.com/MastaG/linux-cachyos-bc250/releases/tag/repo)

Local integration: `bc250-mesh-shader.sh`, `bc250-fsr4.sh`,
`bc250-optiscaler.sh`, `bc250-helixsr.sh`, `bc250-proton.sh`, and
`bc250-mesa-patches/README.md`.

### Drivers, hardware helpers, and applications (pre-change baseline)

| Component | Integrated baseline | Upstream finding | Assessment |
| --- | --- | --- | --- |
| VA-API compute video codec | `v0.5.1`, commit `180aab8` | Latest stable release is `v0.5.4`, October 17. Release notes describe runtime x264/x265 library probing, multiarch lookup, DMA-BUF/thread lifecycle leak fixes, and telemetry hardening. 0.5.2 also introduced HEVC/live-streaming and DMA-BUF work. | High-value update candidate. Adapt the pinned source build and shader inventory, then test 64-/32-bit loading, Gamescope, Steam Link, and Sunshine. |
| CoolerControl daemon AppImage | `5.0.0` | Latest release is `5.1.1`, October 19. Intervening releases add per-device I/O isolation/failsafe fixes and security updates. 5.1 moves gRPC onto authenticated port 11987 and removes port 11988. | Update candidate. Validate AppImage startup, service restrictions, fan fail-safe behavior, existing settings, and the local Web UI. |
| GDDR6 temperature payload | `pan-Rijovich/bc250-memory-temperature` commit `b7e6bff` | Four commits ahead, latest `4a2221d`: UMC polling validation/timeouts, packed reads, symbol-driven SMU patching, and memory bounds checks. | Prioritize review, not an automatic firmware write. The toolkit uses its own guarded launcher; payload bytes, manifests, symbols, and response interpretation must be updated together. |
| NCT6687D | `Fred78290/nct6687d` commit `a49a8ab` | 19 commits ahead, latest `ec1030b`: includes signed-temperature fixes, EC port reservation and min/max ABI changes, plus reversions of EC I/O locking changes. | Update candidate with kernel-build and fan/sensor validation. Review the final diff rather than applying intermediate locking commits indiscriminately. |
| AIC8800 USB source | `shenmintao/aic8800d80` commit `e93a7d2`, with local adaptations | 23 commits ahead, latest `5327c77`, including cfg80211 monitor-channel callback compatibility work and other driver changes. | Review/rebase candidate. Preserve SteamOS header detection, firmware paths, teardown, Wi-Fi Direct, Bluetooth ZLP, and OEM-ID changes. A commit-count difference alone does not prove every change is missing locally. |
| GFX1013 kernel repair | `DryhoppedIPA/bc250-gfx1013-fix` commit `d3e6dc0` | Three commits ahead, latest `5bb0dac`: diagnostics, disabling unsafe old mesh/task patches, and consolidation of PASID invalidation patches. Latest release is `v0.2.1-alpha`. | No demonstrated urgent missing kernel fix. We already omit the unsafe mesh/task patches. Review any consolidation against our three-part repair and matching runtime attestations before updating. |
| CPU SMU overclocking | `bc250-collective/bc250_smu_oc` commit `43d6b4c` | Two commits ahead, latest `327014d`; only `stress_helper.py` changed to scale workers by CPU count. | No missing worker-count feature: our SteamOS override already uses `os.cpu_count()`. A baseline refresh would require rebasing our patches but is not urgent. |
| Linux CPU core-unlock helper | Derived from `rw-r-r-0644/bc250-core-unlock` commit `87ec098` | Ten commits ahead, latest `569785a`: includes SMN address/base and mask-handling changes, a force option, and documentation updates. | Review hardware semantics, not wholesale replacement. Preserve our BC-250 identity checks, locking, bounded mailbox transactions, topology checks, and reboot guards. |
| EFI core-unlock implementation | Derived from `Hexxeh/bc250-efi-core-unlock` commit `3e45131` | Three commits ahead, latest `671936b`, including SMU telemetry support and removal of a mask check. | Compare with our separately integrated metrics injector and hardened EFI flow. Do not automatically duplicate firmware patching or overwrite our boot safeguards. |
| EFI headers | `yoppeh/efi` commit `761b114` | Two commits ahead, latest `d438479`; only `efi.h` changes, adding `EFI_ERROR`. | Low-priority baseline refresh, not a demonstrated missing fix in our application. |
| ACPI state definitions | `bc250-collective/bc250-acpi-fix` commit `1594d72` | Identical to current default branch. | Current. |
| Eight-core ACPI coverage reference | `mendesrr/bc250-acpi-fix-updated-8c` commit `6ebdb89` | 35 commits ahead, but the net changed file is only `README.md`. | No newer ACPI table content to import. Keep our six-/eight-core conditional scopes. |
| RAM configuration utility | Resolves `fanoush/bc250_memcfg` latest release dynamically | Latest release remains `v0.1`. | No code pin change needed. |
| GPU governor | Resolves `filippor/cyan-skillfish-governor` latest release dynamically | Latest stable is `v0.4.14`, October 3; improved errors and graceful shutdown. | Discovery is already dynamic. Existing installations are not automatically proven current. |
| CU live manager | Toolkit-local implementation plus a moving-main download fallback | Upstream head is `a929085`, July 30. Cached downloaded managers are reused rather than refreshed automatically. | Not a versioned pin to bump. Record provenance and define cache-refresh policy before calling this automatically up to date. Preserve the toolkit's safety changes. |
| UMR | Fresh installs clone upstream HEAD; existing source clones are reused | Latest listed upstream tag is `1.0.11`. | No fixed version comparison is possible from the installer alone. Pinning and explicit cached-source upgrades would improve reproducibility. |
| Original 40-CU unlock reference | Toolkit-local adaptation; no recorded source commit pin | Upstream head is `ae7c30c`, June 24. | No reliable ahead/behind claim without a source baseline. Review relevant changes manually rather than replace local hardware-control code. |

Sources:

- [Video codec 0.5.4](https://github.com/simpmix/bc250-encoding-decoding-fix/releases/tag/v0.5.4)
- [CoolerControl 5.1.1](https://gitlab.com/coolercontrol/coolercontrol/-/releases/5.1.1)
- [Temperature payload comparison](https://github.com/pan-Rijovich/bc250-memory-temperature/compare/b7e6bffcb5d592fc03edde375b7598ddc79aa846...4a2221d1da387fa2e738bb9368b39594e242ba4b)
- [NCT6687D comparison](https://github.com/Fred78290/nct6687d/compare/a49a8abdfb6221772ecc836b3109e0cc338203cf...ec1030ba7acc32b36723af0c7c9c9aead5e57b54)
- [AIC8800 comparison](https://github.com/shenmintao/aic8800d80/compare/e93a7d2b6b9634acefc2aae2891e787fb48fdb01...5327c777d00a94ee3bea09525b3acc8e1b031993)
- [GFX1013 comparison](https://github.com/DryhoppedIPA/bc250-gfx1013-fix/compare/d3e6dc062c34d2523db0abe5741d1f5b0dea00d9...5bb0dac39d094fe9cbd10d2b34868837125d9c39)
- [SMU OC comparison](https://github.com/bc250-collective/bc250_smu_oc/compare/43d6b4c6e38c57bc9ec8908c44675ce7d5fd3d2f...327014d6515d7108b1144adfa7203b4cc2eefd0b)
- [Linux core-unlock comparison](https://github.com/rw-r-r-0644/bc250-core-unlock/compare/87ec09877df57d2e310a9b9961584a78b6d1c79d...569785a36bd19008f8d83eb91c0b3ee80596c430)
- [EFI core-unlock comparison](https://github.com/Hexxeh/bc250-efi-core-unlock/compare/3e45131678b111c50e5c285834869ecd3c487a2e...671936bd2655542326496518afdd2d8c9510b7d5)
- [EFI header comparison](https://github.com/yoppeh/efi/compare/761b114e3b186adb82516d5fa8e7a4c559f56ba5...d438479f1e2b3a9c99623a5127d9e65bbeb813e7)
- [ACPI source](https://github.com/bc250-collective/bc250-acpi-fix), [eight-core ACPI comparison](https://github.com/mendesrr/bc250-acpi-fix-updated-8c/compare/6ebdb89b9d96f51cb34b060056e72c5cd42e3320...83686c4670f29316bc4c396a9bda75281327a5e3)
- [RAM utility](https://github.com/fanoush/bc250_memcfg/releases/tag/v0.1), [governor](https://github.com/filippor/cyan-skillfish-governor/releases/tag/v0.4.14), [CU manager](https://github.com/WinnieLV/bc250-cu-live-manager), [UMR tags](https://gitlab.freedesktop.org/tomstdenis/umr/-/tags), and [40-CU reference](https://github.com/duggasco/bc250-40cu-unlock)

### Decky frontend and vendored Python (pre-change baseline)

Compared all **137 distinct npm package names** in the tracked
`decky-plugin/pnpm-lock.yaml` against the registry's latest dist-tags, and queried
the npm bulk advisory endpoint for the locked versions. Latest does not imply
compatible with the current dependency ranges or Decky's host React runtime.

| Direct npm dependency | Locked | Latest observed |
| --- | --- | --- |
| `@decky/api` | 1.1.3 | 1.1.3 |
| `@decky/rollup` | 1.0.2 | 1.0.2 |
| `@decky/ui` | 4.12.0 | 4.16.0 |
| `rollup` and native Rollup binaries | 4.62.2 | 4.64.12 |
| `typescript` | 5.9.3 | 7.0.2 |
| `@types/react` | 19.1.1 | 19.3.0 |
| `@types/react-dom` | 19.1.1 | 19.3.0 |
| `@types/react-router` | 5.1.20 | 5.1.20 |
| `react-icons` | 5.7.0 | 5.7.0 |
| `tslib` | 2.8.1 | 2.8.1 |

The lock also includes React 19.2.7 versus registry latest 19.3.1. Decky supplies
the runtime React integration; do not treat an auto-installed peer as an
independently upgradeable embedded React runtime. New React DOM typings require
matching React typings. TypeScript 7 is a major-version migration and needs
separate validation with `@decky/rollup`, not an indiscriminate lock refresh.

Other transitive update families include Rollup plugins, glob/micromatch tooling,
source-map helpers, and terminal/string utilities. Many latest versions are new
majors. Update via compatible parents or reviewed overrides, not by forcing all
137 packages to their latest versions.

#### Original npm advisory findings

- **`brace-expansion` 1.1.16 and 2.1.2:** high-severity denial-of-service findings
  involving expansion, intermediate arrays, and recursion, plus a moderate
  quadratic-time case. At audit time the maintenance releases 1.1.21 and 2.1.7
  are available. Preserve the appropriate major per dependency chain and
  re-query advisories after updating.
  [GHSA-mh99-v99m-4gvg](https://github.com/advisories/GHSA-mh99-v99m-4gvg),
  [GHSA-rgw5-rvv9-x895](https://github.com/advisories/GHSA-rgw5-rvv9-x895),
  [GHSA-6j4f-fj2g-mc7p](https://github.com/advisories/GHSA-6j4f-fj2g-mc7p),
  [GHSA-qhr7-859c-m2p7](https://github.com/advisories/GHSA-qhr7-859c-m2p7),
  [GHSA-q2hr-2g5m-vwhr](https://github.com/advisories/GHSA-q2hr-2g5m-vwhr).
- **`braces` 3.0.3:** high-severity stack-exhaustion denial of service for deeply
  nested patterns. The npm registry still lists 3.0.3 as latest, so a normal
  latest-version bump does not fix it. Evaluate upstream mitigation or removing
  the affected build-tool chain; avoid untrusted glob patterns.
  [GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm).

These are build-tool dependency findings, not proof of a remotely exploitable
Decky plugin runtime. No exploitability test was performed. The check returned
advisories for these two package names; it is not a security certification.

Vendored `desktop-control/vendor/dbus_next` is **0.2.3**, which matches the latest
[PyPI `dbus-next` release](https://pypi.org/project/dbus-next/). No newer published
version to import was found.

### CI and application runtimes (pre-change baseline)

| Dependency | Repository setting | Latest/upstream observation | Assessment |
| --- | --- | --- | --- |
| Node.js CI | 20 | Node 20 support ended April 30, 2026. Node 24 remains supported through April 2028; Node 26 is scheduled to enter LTS October 28, after this audit date. | Move to a supported baseline such as Node 24 after build validation. |
| pnpm CI | 9 | Latest registry release is 12.14.0. The installer already fetches the latest pnpm when absent. | Align installer/CI intentionally. pnpm 12 ignores the old `package.json` peerDependencyRules location, as seen in the user's error report. Test lock/config compatibility before moving CI. |
| Python test baseline | 3.8 | Intentionally exercises Decky-era compatibility; Python 3.8 is end of life. | Add a supported-Python matrix without silently dropping required target compatibility. New action versions may change availability of old Python distributions. |
| `actions/checkout` | v4 | v7.0.1 | Major action upgrade available. |
| `actions/setup-python` | v5 | v7.0.0 | Major action upgrade available. |
| `actions/setup-node` | v4 | v7.1.0 | Major action upgrade available. |
| `actions/upload-artifact` | v4 | v7.0.2 | Major action upgrade available. |
| `pnpm/action-setup` | v4 | v6.1.0 | Major action upgrade available; current release explicitly supports pnpm 12. |
| Trainer Flatpak KDE Platform/SDK | 6.10 | Flathub remote lists 6.10 and newer 6.11. Both refs resolve. | Qualify 6.11 with Qt Quick, Multimedia, D-Bus, and packaging tests before changing the manifest. |
| Native Qt/CMake/system build tools | Qt >=6.4, CMake >=3.22; distro-provided tools/libraries | Minimum supported versions, not bundled fixed release pins. | Keep distro/SteamOS compatibility. Do not replace system libraries simply because newer upstream releases exist. |
| Decky Loader | Latest-release installer when Loader is absent | Latest stable Loader is v3.3.0, October 18, including UI/beta compatibility and plugin update API changes. | Existing Loader installations are not updated by our install-if-missing branch. Test the plugin against 3.3.0; no toolkit Loader pin to bump. |

Sources: npm registry metadata; [Node support schedule](https://github.com/nodejs/Release/blob/main/schedule.json);
[checkout](https://github.com/actions/checkout/releases/tag/v7.0.1),
[setup-python](https://github.com/actions/setup-python/releases/tag/v7.0.0),
[setup-node](https://github.com/actions/setup-node/releases/tag/v7.1.0),
[upload-artifact](https://github.com/actions/upload-artifact/releases/tag/v7.0.2),
[pnpm/action-setup](https://github.com/pnpm/action-setup/releases/tag/v6.1.0), and
[Decky Loader](https://github.com/SteamDeckHomebrew/decky-loader/releases/tag/v3.3.0).
KDE runtime branches were checked with read-only Flathub remote queries.

### Original assessment scope and limits

- Inventory used tracked scripts, manifests/lockfiles, vendored-version metadata,
  and upstream/provenance documentation. Untracked user files were not treated as
  toolkit dependencies.
- Checked GitHub/GitLab release APIs, comparisons against pinned commits, official
  Mesa/libdrm archive indexes, npm/PyPI registries, and Flathub runtime metadata.
- SteamOS kernel sources and prerequisite packages are intentionally resolved for
  the running kernel and configured Valve repositories. This audit does not
  recommend installing a newer unrelated kernel or performing a host OS upgrade.
- Third-party libraries/firmware nested inside upstream binary bundles are not
  independently re-versioned here; upgrading their parent bundle needs its own
  provenance/license and compatibility review. Existing hashes are retained.
- Read-only metadata checks do not establish patched-source build success,
  GPU stability, firmware safety, game compatibility, or absence of advisories.
- No upgrades were installed and no release was tagged as part of the initial
  read-only assessment. Subsequent source/lockfile/CI changes are summarized
  above; they do not establish installation or hardware qualification.
