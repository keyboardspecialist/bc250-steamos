# Robin 3 metrics analysis

The driver retains table-6 polling, the direct GFX-frequency query, and
`GRBM_STATUS` activity sampling for GPU metrics. On unlocked Robin 3, only the
corrupted CPU and L3 rows are replaced from PM status table 3.

## Lockup finding

The removed experiment used queue-3 messages `0x7a`, `0x7b`, and `0x22`. Its
last build wrote arguments to `0x03b10a60`, which is queue 1's response
register. Robin 3 queue 3 uses:

| Role | Register |
|---|---|
| Command | `0x03b10a20` |
| Response | `0x03b10a80` |
| Argument | `0x03b10a88` |

The register error allowed address and transfer handlers to consume stale
arguments. Because the transfer can initiate firmware DMA, this explains a
machine-wide SMU/GPU-fabric wedge better than a bounded Linux mutex wait.

Correcting the register is not sufficient. Ghidra analysis shows that primary
messages `0x04/0x05` and queue-3 messages `0x7a/0x7b` share driver-address
handlers `0x1b998/0x1b9b4`. Table 3 uses a different tools descriptor, so those
messages cannot configure its destination and can redirect later table-6
transfers instead.

The firmware-supported table-3 route uses queue 4:

| Operation | Message | Handler |
|---|---:|---:|
| Set tools address high | `0x3e` | `0x1b9f4` |
| Set tools address low | `0x3f` | `0x1ba10` |
| Transfer SMU to DRAM | `0x22` | `0x1ba5c` |

Queue 4 uses command `0x03b10a24`, response `0x03b10a84`, and argument
`0x03b10a8c`. Queues 3 and 4 share the same dispatch table, but have separate
mailbox registers. Table 3's permission mask is `0x18`, explicitly allowing
both queues. Queue 4 avoids normal queue-3 OC clients and its tools setters do
not alter the table-6 driver address.

## Firmware provenance

| Artifact | SHA-256 |
|---|---|
| Robin 3.00 ROM | `48fbe5d366e6a56e2fdffdca848426216ba1f083610dab63db89d2f4e6c940b5` |
| Extracted SMU firmware | `6a3da1ef6024c3143283fb92468fd71d628e9402a751c4a9799a20f473549ad9` |

The SMU image is the `0x40200`-byte ROM slice at flash offset `0x8ff000`.
Runtime PMFW addresses map to extracted-file offsets by adding `0x104`.
`verify-robin3-firmware.py` validates the hashes, ROM extraction, relevant
dispatch pointers, table-3 callback `0x276dc`, and queue mask `0x18`.

The existing Ghidra project is
`~/tools/ghidra-projects/bc250-smu-3-aligned.gpr`. Its program is loaded as
`Xtensa:LE:32:default`, and the exported decompilation is
`~/tools/bc250-ghidra-analysis/smu-3.00-aligned-decompiled.c`.

## CPU layout

Callback `0x276dc` produces a 209-float, `0x344`-byte snapshot. The CPU fields
used by the driver are:

| Offset | Elements | Field | Conversion |
|---:|---:|---|---|
| `0x118` | 8 | Average core power in W | `*1000` to mW |
| `0x158` | 8 | Average core temperature in C | `*100` to centi-C |
| `0x198` | 8 | Average core frequency in GHz | `*1000` to MHz |
| `0x2a8` | 2 | Average L3 temperature in C | `*100` to centi-C |
| `0x2c0` | 2 | Average L3 frequency in GHz | `*1000` to MHz |

The destination is poisoned before each transfer. If firmware has no completed
sampling window, callback `0x276dc` returns without DMA and float validation
rejects the poison. CPU fields remain at the `0xffff` ABI sentinel while GPU
metrics from table 6 remain available.

## Instrumentation

`bc250-cyan-skillfish-8core-cpu-metrics.patch` calls a no-op probe hook after a
successful table-3 transfer. `trace-cyan-skillfish-metrics.sh` captures the five
CPU/L3 float arrays, the exported `gpu_metrics` blob, CPU frequencies, and hwmon
temperatures. It refuses to run on a module without that hook.
