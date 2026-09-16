# iOS does not receive the BLE mesh advertisement

Proven on the bench 2026-09-15: an iPad never sees a firmware mesh
advertisement that an independent receiver catches from the same radio, in the
same window, at the same moment.

## The measurement

Transmitter: Cardputer `28:84:85:78:4E:ED` (`🃏_4eec`), spike firmware,
`network.enabled_protocols: 6` (BLE_BROADCAST | BLE_GATT_PEER).

Witnesses, both listening continuously across the same window:

- `james-pc` BlueZ, via `meshnode-headless` with `MESH_TRANSPORTS=ble-adv`.
- The iPad, via `pymobiledevice3 syslog live -pn bluetoothd` - the stack's own
  log, below CoreBluetooth, which records every discovered device including
  non-connectable ones and dumps their manufacturer data.

| run | sends | BlueZ `rx[ble-adv]` | iPad `MFR Data: FF FF 01` | iPad sightings of the same radio |
| --- | --- | --- | --- | --- |
| A | 1 | 1 | 0 | 151 |
| B | 3 | 3 | 0 | 219 |

The last column is what makes it conclusive rather than a range or duty-cycle
artifact: across both runs the iPad logged that radio hundreds of times at
-68 dBm - its *legacy* connectable GATT advertisement - while never once
logging the extended advertisement the same radio emitted between those
sightings.

## Why

The mesh advertisement is an extended (non-legacy) PDU:
`ESP32BLEMesh.cpp` sets `params.legacy_pdu = 0`, `connectable = 0`,
`scannable = 0`, both PHYs 1M. iOS reports legacy advertisements to the stack
and does not surface extended ones. The uConsole's CM5 controller fails the
same way for a different reason (legacy-only, `MaxAdvLen 31`), so
"legacy-only receiver" is a shape this bearer meets more than once.

## What it means

- The BLE advertisement bearer cannot reach an Apple device **at all**, not
  even receive-only, which is the only direction `AppleBleMeshRadio` claims.
- An Apple node reaches this mesh over the GATT bearer alone - proven 4/4 the
  same day on the same iPad.
- Adding a service UUID to the advertisement to give CoreBluetooth something to
  filter on is moot. It would cost 18 bytes of the 243-byte budget and iOS
  still would not see the advertisement.

## Open

Measured on iPadOS 26.6 only. `appleMain` is shared with macOS, and whether
macOS CoreBluetooth receives extended advertisements is untested.

## Confirmed on the wire

An HCI capture on the uConsole 2026-09-16 shows the other half of this:
the iPad subscribing to the mesh characteristic on a **legacy** `ADV_IND`
peripheral and exchanging frames both ways, three connections in a row -
[`bluez-mesh-link-torn-down-by-profile-probes.md`](./bluez-mesh-link-torn-down-by-profile-probes.md).
Legacy advertising is the discriminator, not the GATT bearer.
