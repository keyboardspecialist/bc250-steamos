# BC-250 (Cyan Skillfish) SMU / power-management analysis

Static teardown of the BC-250's platform BIOS to answer one question: **can the
board do a real low-power sleep state (GFXOFF / BACO / suspend), or only idle?**

Short answer: **no true sleep.** The GPU's power-management firmware (PMFW,
a.k.a. SMU) that would implement GFXOFF/BACO is *not present in the binary* —
its message-dispatch table has 64 slots but only 13 real handlers; the rest
route to an "unsupported" stub. And the firmware is PSP-signed, so the missing
handlers can't be added. The reachable ceiling is deep idle (PPT cap + C-states
+ undervolt), documented in `AMDSETUP-power-knobs.txt`.

## Provenance
| Artifact | SHA-256 |
|---|---|
| `BC250_3.00_CHIPSETMENU.ROM` (16 MiB SPI BIOS) | `48fbe5d366e6a56e2fdffdca848426216ba1f083610dab63db89d2f4e6c940b5` |
| `cyan-skillfish-smu-fw.bin` (extracted SMU PMFW) | `6a3da1ef6024c3143283fb92468fd71d628e9402a751c4a9799a20f473549ad9` |

## How the SMU firmware was located
The BIOS is an AMI Aptio image with an AMD PSP directory (`$PSP` @ flash
`0x8e0000`). Parsing its entries:

```
type=0x08 SMU_FW   size=262656  -> flash 0x8ff000   (the live copy)
type=0x12 SMU_FW2  size=262656  -> flash 0x93f700   (B-slot, blank: all 0x00)
```

`cyan-skillfish-smu-fw.bin` is the `0x08` blob (flash `0x8ff000`, 262656 bytes).
Layout: 0x100-byte PSP firmware-entry header (`$PS1` magic at +0x10, payload
size `0x40000` at +0x14) followed by a 256 KiB payload.

- Payload entropy ≈ **5.09 bits/byte** → plaintext code, **not encrypted**
  (encrypted would be ≈ 8.0). Signed, but readable.
- Payload strings are stripped (release build). Only marker found: `AMD BC-250`.
- ISA is AMD's proprietary MP1 core — not ARM-Thumb/Xtensa by opcode-signature
  density — so there is no off-the-shelf disassembler. Analysis below is
  structural, not a full disassembly.

## The message-dispatch table (the key evidence)
An ISA-agnostic scan for runs of code-range pointers found the PPSMC message
dispatch table at **payload offset `0x15200`** (i.e. file `0x15300`):

- **64 entries** (message IDs 0..63).
- Entry `0x1f4d0` appears **51 times** — the shared "unsupported message" stub.
- **13 real handlers**, at message indices:

```
 idx  handler        idx  handler        idx  handler
   0  0x1f520         14  0x1fa60         22  0x1fa68
   8  0x1fa70         16  0x1fa9c         28  0x1f634
   9  0x1faac         17  0x1fabc         29  0x1f910
  12  0x1f59c         20  0x1f5d8
  13  0x1f5e8         21  0x1f624
```

13 implemented handlers ≈ the 11 messages the amdgpu driver maps for cyan
skillfish (`cyan_skillfish_message_map` in `cyan_skillfish_ppt.c`:
TestMessage, GetSmuVersion, GetDriverIfVersion, Set/TransferTable pair,
GetEnabledSmuFeatures, RequestGfxclk, Force/UnforceGfxVid) plus a couple
internal. Everything else — `AllowGfxOff`, `EnterBaco`/`ArmD3`,
`SetSoftMin/MaxGfxclk`, `SetPptLimit` — indexes into the 51 stub slots.

## Conclusion
| Layer | Finding |
|---|---|
| amdgpu driver message map | 11 messages; no GFXOFF/BACO/DPM-min-max |
| **SMU PMFW binary (this file)** | **64 slots, 13 real handlers, GFXOFF/BACO IDs → stub** |
| PSP signing | missing handlers cannot be added (signature enforced) |

Sleep is not firmware-toggleable, not a hidden register, and not a hidden
message. The GPU can gate clocks (see the `bc250-audio-fix/bc250-cg-flags*`
patches) and can be parked at a low fixed voltage via `RequestGfxclk` +
`ForceGfxVid` (the `pp_od_clk_voltage` VDDC-curve path), and the platform can be
throttled via the AMD CBS knobs in `AMDSETUP-power-knobs.txt`. That is the
floor.

## Caveats
- Handler identification is structural (64-slot, stub-dominated table with a
  13≈11 match to the known driver messages). The MP1 mailbox ISR was not
  disassembled to trace the index register into this table.
- Offsets are specific to this BIOS build (`BC250 3.00 CHIPSETMENU`). Re-extract
  for other builds.
- Live corroboration (no reflash, on the board): read `GetEnabledSmuFeatures`
  via the SMU mailbox — the returned feature bitmask shows which power features
  the PMFW actually has compiled/enabled.

## Method / tooling
- BIOS FV/PSP extraction: `uefi-firmware-parser` (Tiano/LZMA decompressor).
- PSP directory + SMU header parse, entropy, dispatch-table scan: ad-hoc Python
  (no external binaries executed).
