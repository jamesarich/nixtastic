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

### Why the ack column reads near zero on a gatt-only run - settled

These sends are **broadcasts**, and firmware raises no routing ack for a
broadcast. So every `Delivered` the bench counts comes from
`MeshNode.implicitAck`: our own packet heard back with `hop_limit` decremented,
which means some neighbour relayed it.

`BLEGattMeshHandler::onSend` sets

```cpp
// A relay must never go back to the peer that delivered it; an origination matches nothing.
slot.exclude = arrivalPeer(mp->from, mp->id);
```

so the radio deliberately never relays a packet back to the peer that handed it
over. Split-horizon. With gatt as the only bearer the relay cannot reach us,
`implicitAck` cannot fire, and the figure reads near zero for a link passing
everything: 1/15 and 3/15 against 15/15 and 13/15 decoded at the firmware in the
same runs, with the return direction at 93-100%.

**Correct firmware behaviour, and a defective metric.** It had been read as a
fault twice, once by the script's own comments. `mesh-bench-remote.sh` now
suppresses the number on a gatt-only run and says why. Verified live: a 4-send
gatt-only run printed `n/a on gatt alone` beside `4/4 (100%)` both directions.

What remains open is not a measurement problem: on a connection-oriented bearer
this node has **no delivery evidence at all**, because the only mechanism it has
is the implicit ack that split-horizon forecloses. Link-level acceptance by the
peer is evidence GATT actually has and the mesh layer currently discards.
