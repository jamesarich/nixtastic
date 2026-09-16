# What each bearer actually delivers

Measured 2026-09-16 on `james-pc` with `nix run .#meshbench`, node-kmp against a
RAK4631 on `rak4631_blemesh` (and, for UDP, a `meshtasticd` container). Read the
caveats before quoting a number - three of the four figures here replaced an
earlier one that was an artefact of the measurement rather than the bearer.

| bearer | outbound | inbound | n | notes |
| --- | --- | --- | --- | --- |
| udp | **15/15 (100%)** | **15/15 (100%)** | 15 | vs meshtasticd, on its own group |
| lora | **15/15 (100%)** | 14/15 (93%) | 15 | meshtadpole (CH341 + SX1262) |
| ble-adv | 10/15 (67%) | 12/15 (80%) | 15 | connectionless; see compounding |
| gatt | **14/15 (93%)** | **15/15 (100%)** | 15 | 3 drops in 106 arrivals at the firmware |

## How to read the two outbound numbers

`meshbench` prints two, and they bound the truth from opposite sides:

- **`kmp->radio (min)`** counts the firmware's own `decoded message` log line,
  which arrives as a sparse `LogRecord` stream captured only during the outbound
  phase. It has under-reported every single time - `4/15` for a bearer measured
  at `15/15`. It is a floor, never a rate.
- **`acknowledged by the radio`** counts the node's own `Delivered` events. An
  ACK cannot exist unless the radio decoded the packet, so this is ground truth
  for delivery - *provided the return path is good*.

**They compound on a lossy bearer.** ble-adv's ACK figure is 10/15, but the ACK
comes back over ble-adv too, at 80%. So the real outbound rate is nearer
`0.67 / 0.80 ≈ 83%`, not 67%. On LoRa the return path is 93% and the ACK figure
is already 100%, so nothing is hidden there.

## What each number cost to get right

- **lora** first read `1/6 (16%)`. That was the log-stream floor; the ACKs said
  6/6 at the same moment.
- **ble-adv** first read `0%` inbound, then `33%`. Both were the radio having
  `network.enabled_protocols = 0` - its BLE transmitters were off. With
  `BLE_BROADCAST` on it went to 100% on the small sample.
- **gatt** first read `0/6` with `rx=0 tx=0`. Two causes: `BLE_GATT_PEER` also
  off, and then a fixed 25-second settle against a link that took 93 s to come up.
- **udp** read `0%` both ways for the whole session until the group mismatch
  surfaced - see [`udp-group-and-preset-parity.md`](./udp-group-and-preset-parity.md).
  On a named channel and the peer's own group it is the cleanest bearer here:
  15/15 each way, no loss at all. It is also the only one whose peer is firmware
  code rather than a radio, so nothing on that path is over the air.

Every one of those was the rig, not the bearer. Check `enabled_protocols`, the
channel, and what holds `tcp 4403` before reading anything into a zero.

## Re-measured 2026-09-16 after the BlueZ extraction

`:node-bluez` took the D-Bus session and the adapter probe out of both Linux
bearers (`ea8cb3d`), so both were re-run against the same RAK4631 to show the
refactor cost nothing. Same script, same radio, n=15, and the jar's md5 was
checked on the bench against the one built here - `de2a3394ea71` both ends.

| bearer | outbound | inbound | before |
| --- | --- | --- | --- |
| gatt, run 1 | 15/15 (100%) | 14/15 (93%) | 14/15 · 15/15 |
| gatt, run 2 | 13/15 (86%) | 15/15 (100%) | " |
| ble-adv | 13/15 (86%) | 15/15 (100%) | 10/15 · 12/15 |
| both together | **15/15 ACK** | 15/15 | - |

Both bearers are at or above where they were. Nothing regressed.

### Why the ack column read near zero on a gatt-only run - found and fixed

These sends are **broadcasts**, and firmware raises no routing ack for one. So
every `Delivered` the bench counts came from `MeshNode.implicitAck`: our own
packet heard back with `hop_limit` decremented, meaning a neighbour relayed it.

`BLEGattMeshHandler::onSend` excluded the peer that delivered a packet from the
relay - correct while carrying somebody else's packet onward, wrong when that
peer wrote it. On LoRa an author hears its own packet relayed and takes that as
the ack; a point-to-point link has no such echo. GATT was the **only** bearer
with an exclusion at all - `BLEMeshHandler` and UDP are broadcast media and have
none - which is why it was the only one where the implicit ack never arrived.

Fixed in both repos, same rule on each side so they cannot drift:

- firmware `BLEGattMeshHandler::relayExclusion` - the arrival records whether
  `hop_start` still equalled `hop_limit`, read before the Router decrements.
- node-kmp `MeshNode.scheduleRelay` - `header.hopsAway == 0`. Null is "the frame
  did not say", which is not evidence of authorship, so the exclusion stands.

Measured on the RAK4631, gatt alone, n=15:

| | acknowledged |
| --- | --- |
| before, run 1 | 1/15 |
| before, run 2 | 3/15 |
| **after, run 1** | **15/15** |
| **after, run 2** | **15/15** |

The data path was never the problem and did not move: 15/15 inbound in both runs
after, against 14/15 and 15/15 before.

One thing the pair of runs shows plainly: the `kmp->radio (min)` column read
15/15 then 0/15 across the two runs after the fix. It is the sparse LogRecord
floor and it is not a rate, exactly as the header says. The ack figure is now the
stable one on this bearer, where before the fix it was the unreliable one.
