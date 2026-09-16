# What each bearer actually delivers

Measured 2026-09-16 on `james-pc` with `nix run .#meshbench`, node-kmp against a
RAK4631 on `rak4631_blemesh` (and, for UDP, a `meshtasticd` container). Read the
caveats before quoting a number - three of the four figures here replaced an
earlier one that was an artefact of the measurement rather than the bearer.

| bearer | outbound | inbound | n | notes |
| --- | --- | --- | --- | --- |
| lora | **15/15 (100%)** | 14/15 (93%) | 15 | meshtadpole (CH341 + SX1262) |
| ble-adv | 10/15 (67%) | 12/15 (80%) | 15 | connectionless; see compounding |
| udp | 3/3 | 6/6 | small | vs meshtasticd, old multicast group |
| gatt | 4/6 | 3/6 | 6 | needs a central; not yet re-run at n=15 |

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

Every one of those was the rig, not the bearer. Check `enabled_protocols`, the
channel, and what holds `tcp 4403` before reading anything into a zero.
