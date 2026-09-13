# BLE mesh: capacity, range, and how a bearer gets turned on

Audit of 2026-09-13, answering five questions about the BLE bearers in
`meshtastic-node-kmp` and the firmware they talk to. Companion to
[`ble-mesh-transport.md`](./ble-mesh-transport.md), which is the design history;
this one is the current state, the numbers behind it, and what is worth changing.

**Every number here is read out of the source.** Where something is a measurement
it says so, and where nothing has been measured it says that instead. Two of the
five answers are "unmeasured, here is what the parameters imply" - do not let
them harden into claims.

The firmware side is the `spike/ble-mesh-transport` branch unless a line says
`develop`. None of it has shipped.

## How many BLE mesh connections

Our own cap is **3**, and it is a design choice rather than a ceiling we hit:
`MAX_LINKS` in `node-transport-ble-gatt/.../GattArbitration.kt:23`. The reasoning
in its KDoc still holds. A GATT mesh is point-to-point, so a broadcast is one
write per peer, and the tenth peer costs ten times the airtime of the first while
adding almost no reach that a relay through the first three does not already give.

The hard limits are on the radio, and they are tighter than the client's:

| where | limit | source |
| --- | --- | --- |
| shipped ESP32 firmware | `CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1` | `variants/esp32/esp32-common.ini:298`, develop |
| spike ESP32 | `=2`, one of them the phone-API link | `[ble_mesh_esp32]` in the same file, spike |
| GATT mesh handler | `BLE_GATT_MESH_MAX_PEERS 2` | `src/mesh/BLEGattMeshHandler.h:34` |
| nRF52 | its own build env and linker script | `env:rak4631_blemesh`, `nrf52840_s140_v6_blemesh.ld` |

So a **stock radio holds zero** GATT mesh peers, and a **spike radio holds exactly
one**, because the controller budget is two and the phone API already has one.
`CONFIG_BT_NIMBLE_ROLE_CENTRAL=n` means a radio never dials out either, so GATT is
phone-to-radio spokes and never radio-to-radio. On nRF52 the central link is what
pushes SoftDevice RAM past the shared linker script's origin, which is why it is a
separate env rather than a build flag.

Phone and desktop ceilings are **unmeasured**. `AGENTS.md` says both stacks sit
well above 3 and neither reports hitting one usefully. The limiter on a phone
running both BLE bearers is not connection count anyway, it is the advertising-set
budget: `ADVERTISE_FAILED_TOO_MANY_ADVERTISERS` is the ordinary failure, called
out in `BleMeshRadio.android.kt`, because the GATT transport in the same library
takes a set too. The advertisement bearer is connectionless and has no connection
count at all.

Three is the right number for a phone. Raising it is not the lever.

## Range

**Nothing has been measured.** The only figure on record is `rssi=-81` from
`AndroidBleRadioTest`, at a distance nobody wrote down.

What the parameters imply, as physics and not as a bench result: both ends run the
1M PHY, and node-kmp advertises at `TX_POWER_MEDIUM` while the firmware passes
`tx_power = 127`, which asks the controller for its maximum
(`ESP32BLEMesh.cpp:87`). Android documents MEDIUM at about -7 dBm and HIGH at
about +1 dBm. If those constants hold, **we transmit roughly 8 dB below what the
same phone is capable of**, for no reason and no protocol change. Confirm against
a controller rather than the docs before treating the 8 dB as real.

## Throughput against range

Two bearers, two answers.

**The advertisement bearer** carries 243 bytes and no more: `ADV_TOTAL_MAX` 251
minus `ADV_OVERHEAD` 8, in `BleMeshAdvert`. An over-long packet is refused rather
than fragmented, deliberately, because the firmware offers no reassembly there.
Sends are serialised at 300 ms each (`DEFAULT_ADVERTISE_MS`), so the ceiling is
about 3.3 frames per second.

There is an asymmetry in the advertising pattern worth fixing on its own:

| | events per frame | interval | airtime per frame | power |
| --- | --- | --- | --- | --- |
| firmware | 3 (`BLE_MESH_ADV_EVENTS`) | 30 ms (`BLE_MESH_ADV_INTERVAL`) | ~90 ms | controller max |
| node-kmp | 1 to 2 | 250 ms (`INTERVAL_MEDIUM`) | 300 ms | `TX_POWER_MEDIUM` |

Fewer repeats over three times the airtime, at lower power. Matching the
firmware's shape - short interval, bounded event count - buys throughput and
reliability in the same change.

The listening side is not the weak leg. The firmware scans at `itvl == window ==
100 ms`, a 100 % duty cycle (`ESP32BLEMesh.h:20,23`). Phone-to-phone is weaker and
already mitigated: `SCAN_REFRESH_MS` works around Android's five-minute downgrade
of a `LOW_LATENCY` scan. iOS in the background cannot see manufacturer data at
all, which is the on-air format question `AGENTS.md` already has queued.

**Coded PHY is the real range lever and it is exposed nowhere.** `GattPhy` is
`{LE_1M, LE_2M}` (`GattLink.kt:204`), honoured on Android only - Apple ignores it
by design (`GattLink.apple.kt:67`) and BlueZ has no PHY code at all - and the
firmware hardcodes both `primary_phy` and `secondary_phy` to `BLE_HCI_LE_PHY_1M`.
S=8 coded is roughly four times the range at a quarter of the rate, which is
exactly the resilience trade worth having. It is a both-ends change. The client
half is small: `TransportTuning.gattPhy` is already a chip in the monitor, so the
UI pattern exists and the enum grows by one.

## Turning a bearer on

**Today it is host-side only.** `TransportTuning.enabled` is a `Set<String>`,
persisted to `TuningStore` - the dashboard's own file, not the node's settings -
and applied by rebuilding the whole node, because `MeshNode`'s transport list is
fixed at construction (`MeshNode.kt:101`).

The cost is not the rebuild latency. **A rebuild drops the `NodeDb`**, which is
not carried across: `MonitorController.stop()` preserves `BackupPreferences`
(owner, channels, config) and nothing else, and no `MeshNode.Config` seeds peers.
So flipping a bearer blanks the peer list until every peer re-announces, which on
firmware defaults is hours. That is the UX problem, not the switch.

**The wire flag already exists, and we designed it.** The spike's `config.proto`
carries three:

```
UDP_BROADCAST  = 0x0001;
BLE_BROADCAST  = 0x0002;   // connectionless BLE extended advertisements
BLE_GATT_PEER  = 0x0004;   // serve BLE GATT mesh peers
```

Upstream `protobufs` master has only `UDP_BROADCAST`, so shipping needs a
protobufs PR. But the design question is settled and **no new config module is
needed** - `network.enabled_protocols` is the home.

Two gaps on our side right now:

- `enabledProtocols()` only checks `UDP_TRANSPORT` (`LocalRadio.kt:407`), so both
  BLE bearers are under-reported.
- A phone's write is inert. `applyConfig` stores the network section, then the
  read back overrides `enabled_protocols` with reality (`LocalRadio.kt:282`). The
  switch springs back.

Per-bearer **state** already exists where it should: `MeshTransport.availability`
publishes Ready / Unavailable / Active with a reason. `MeshNode` does not
aggregate it, so the monitor folds the map by hand (`MonitorController` ~534) and
every other host would have to as well. There is no wire representation at all.

What to build, in order:

1. `MeshNode.setTransportEnabled(name, Boolean)` that stops collecting
   `incoming()` and skips fan-out. `TransportActivity` already knows whether
   anything is collecting, so the plumbing is there. Kills the rebuild and keeps
   the peer table.
2. Widen `enabledProtocols()` to the three flags and make the write live. The
   toggle stops springing back.
3. `MeshNode.transportAvailability` as a `StateFlow<Map<String,
   TransportAvailability>>`, so hosts stop rewriting the fold.

The UX shape is one row per bearer: a switch and a state line. The state line is
the valuable half, and node-kmp is the only client that could fill it honestly -
"BLE off", "no permission", "no CH341 attached" - because the reason comes from
the transport itself.

## Configuration patterns worth revisiting

- **A section the node reports must be one it honours, or one `excluded_modules`
  hides.** That is the rule the 2026-09-13 round-3 fixes kept landing on.
  `enabled_protocols` is currently neither, which makes it the same class of
  defect as the telemetry and `position_flags` gaps. Auditing the remaining
  sections against that rule is cheap, and worth doing before adding anything.
- **Two persistence stores with two schemas.** The LoRa region already migrated
  from `TuningStore` to `NodeSettings` and got better for it. The bearer set is
  the obvious next one, and it cannot migrate until it has a wire field. So this
  and the section above are one piece of work.
- **Bundle the proto asks.** Three things need agreeing with the firmware before
  anything depends on them, and all three break deployed nodes if they change
  later: company ID `0xFFFF` needs a member ID or an assigned service UUID, the
  private GATT service UUIDs need coordinating, and `ProtocolFlags` needs the two
  BLE values. One conversation, not three.
