# SMU queue 3, queue 4, and table 3 reference

## Differences between queue 3 and queue 4

Queue 3 and queue 4 are separate host-to-SMU mailboxes. They use the same
firmware message dispatch table.

| Property | Queue 3 | Queue 4 |
|---|---|---|
| Command register | `0x03b10a20` | `0x03b10a24` |
| Response register | `0x03b10a80` | `0x03b10a84` |
| Argument register | `0x03b10a88` | `0x03b10a8c` |
| Firmware queue ID | 3 | 4 |
| Typical use | Overclocking and existing tools | Separate tools channel |
| Table-3 permission | Allowed | Allowed |

For a table-3 transfer, select the correct messages. Queue selection alone is
not sufficient:

- The current queue-3 patch uses messages `0x3e` and `0x3f`. These messages
  stage and publish the tools address descriptor at `0xcad8`. Table 3 requires
  this descriptor.
- The old queue-3 sequence used messages `0x7a` and `0x7b`. These messages
  configured the driver descriptor at `0xca38`. This sequence could not
  transfer table 3.
- The queue-4 test uses tools messages `0x3e` and `0x3f`.
- Both queues use message `0x22` to request a table transfer.

Queues 3 and 4 use the correct dispatch entries for messages `0x3e`, `0x3f`,
and `0x22`. Queue 4 gives more isolation from standard queue-3 overclocking
clients. The current runtime patch uses queue 3 with the kernel SMU message
lock.

The mailboxes are separate. However, both queues can change global SMU address
descriptors. Both queues also use the same table callback and DMA components.
Thus, concurrent kernel and user-space access can cause a race condition.

## Queue functions

First, the host publishes a 64-bit DMA destination. Then, the host requests
table 3. The firmware generates the snapshot and transfers it.

| Queue/message | SMU function | Purpose |
|---|---:|---|
| Queue 3, `0x7a` | `0x1b998` | Set the high half of the driver DMA address |
| Queue 3, `0x7b` | `0x1b9b4` | Set the low half of the driver DMA address |
| Queue 3 or 4, `0x3e` | `0x1b9f4` | Set the high half of the tools DMA address |
| Queue 3 or 4, `0x3f` | `0x1ba10` | Set the low half of the tools DMA address |
| Queue 3 or 4, `0x22` | `0x1ba5c` | Validate the request and call the table callback |

For table 3, transfer handler `0x1ba5c` starts this firmware sequence:

| Function | Function operation |
|---:|---|
| `0x276dc` | Export table 3 |
| `0x276cc` | Initialize the accumulator and install the sampler |
| `0x276b8` | Clear the accumulator state |
| `0x27528` | Collect CPU and L3 values at regular intervals |
| `0x3a850` | Transfer the completed `0x344`-byte snapshot to host memory |
| `0x286f8` | Do an optional hardware operation after the transfer |

The firmware uses these address and mailbox helper functions:

| Function | Function operation |
|---:|---|
| `0x0ffc` | Read the argument register of the active queue |
| `0x0fa8` | Write the response register of the active queue |
| `0x398d4` | Store the high word of the address |
| `0x398e8` | Store the low word of the address |
| `0x398fc` | Make sure that the two address words are valid |
| `0x1b9d0` | Publish the complete tools address |
| `0x39910` | Copy the staged address descriptor |

Use this sequence:

```text
Queue 3 (current runtime patch):
0x3e -> 0x1b9f4  set tools address high
0x3f -> 0x1ba10  set tools address low
0x22 -> 0x1ba5c  request table 3
                    -> 0x276dc export callback
                    -> 0x3a850 DMA
```

Queue 4 can use the same sequence through its separate mailbox registers.

## Table 3

Table 3 contains the Cyan Skillfish PM status data for tools. It is not the
standard table-6 `SmuMetrics_t` structure.

Table 3 has these properties:

- Its length is `0x344` bytes.
- Most values are little-endian IEEE-754 `float32` values.
- Callback `0x276dc` generates the table.
- The firmware averages the data during a sample interval.
- The firmware uses the tools DMA descriptor for the transfer.
- The table has data for all eight CPU cores.

### Confirmed CPU and L3 layout

| Byte range | Elements | Data | Unit |
|---|---:|---|---|
| `0x118-0x137` | 8 floats | Average power for each core | Watts |
| `0x158-0x177` | 8 floats | Average temperature for each core | Celsius |
| `0x198-0x1b7` | 8 floats | Average frequency for each core | GHz |
| `0x2a8-0x2af` | 2 floats | Average L3 temperature | Celsius |
| `0x2c0-0x2c7` | 2 floats | Average L3 frequency | GHz |

For core `n`, `n` is in the range `0-7`:

```text
core_power[n]       = float32(table + 0x118 + n*4)
core_temperature[n] = float32(table + 0x158 + n*4)
core_frequency[n]   = float32(table + 0x198 + n*4)
```

For L3 complex `n`, `n` is in the range `0-1`:

```text
l3_temperature[n] = float32(table + 0x2a8 + n*4)
l3_frequency[n]   = float32(table + 0x2c0 + n*4)
```

The driver converts these fields:

```text
power W       * 1000 -> milliwatts
temperature C * 100  -> centi-Celsius
frequency GHz * 1000 -> MHz
```

### Sample operation

Table 3 is not an immediate register snapshot. The firmware uses this sequence:

1. Sampler `0x27528` collects and adds values at regular intervals.
2. The firmware stores the sample count at accumulator offset `0x2f4`.
3. Export callback `0x276dc` divides the accumulated values by the sample
   count.
4. The callback builds the `0x344`-byte export buffer.
5. DMA helper `0x3a850` transfers the buffer to host memory.
6. The firmware resets the accumulator for the next interval.

If the accumulator has no samples, the first request initializes the
accumulator. The request also installs sampler `0x27528`. The firmware reports
mailbox success, but it does not do a DMA transfer.
