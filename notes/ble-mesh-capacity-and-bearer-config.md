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

## Measured delivery, 2026-09-15

First per-direction numbers for the advertisement bearer, taken with
`nix run .#blebench` between a RAK4631 on `spike/ble-mesh-transport` and a
node-kmp headless node on james-pc's BlueZ adapter, three inches apart, at
-51 dBm. "Delivered" is unique packets, not frames: node-kmp's `rx=` counter
counts advertising events, so it reads ~10x higher than packets at
`BLE_MESH_ADV_EVENTS=10`.

| `BLE_MESH_ADV_EVENTS` | airtime/frame | node-kmp -> radio | radio -> node-kmp |
| --- | --- | --- | --- |
| 3 (default) | ~90 ms | 90% | 20% |
| 10 | ~300 ms | 75% | 38% |

The trade is real and it is a single-radio trade. Each extra advertising event is
time the nRF52 is not scanning, so raising it buys reception on the far side and
costs reception on this one. node-kmp holds each frame up for
`DEFAULT_ADVERTISE_MS = 300`, which is why the radio, scanning at a 100% duty
cycle (`BLE_MESH_SCAN_INTERVAL == BLE_MESH_SCAN_WINDOW == 160`), hears it so much
better than the reverse.

**Unresolved: 38% is still poor for two devices this close.** The loss is on the
BlueZ side, not the radio's: an independent D-Bus scanner sees the radio's frames
that node-kmp's own scan misses, and BlueZ reports `Discovering: yes` throughout.
Candidate causes not yet separated: BlueZ throttling `PropertiesChanged` per
device despite `DuplicateData: true`, the adapter's scan duty cycle (BlueZ does
not expose interval/window through `SetDiscoveryFilter`), and contention with
node-kmp's own advertising on the same controller. An A/B with the node idle
versus sending moved delivery only 25 -> 21 frames, so contention is *not* the
dominant term.

Two traps cost a void experiment each, and both are now written down:
`PLATFORMIO_BUILD_FLAGS` overrides rather than appends, so tuning one constant
that way silently dropped `-DBLE_MESH_NRF52_CENTRAL=1` and produced a radio that
advertises but cannot scan at all (`NRF52Bluetooth.cpp:344`) - which read as a
clean 0% and looked like physics. And a bench run started before the radio
finished booting from a flash reads 0% in both directions.

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

1. ~~`MeshNode.setTransportEnabled(name, Boolean)` that stops collecting
   `incoming()`~~ - **done differently, and the audit was wrong here.** Firmware
   does not gate receive: `Router::send` tests the flag on every packet, while
   the receive path is wired inside `UdpMulticastHandler::start()` and never
   re-checks, so a radio whose flag is cleared keeps hearing the mesh until it
   reboots. Cancelling the receive flow would have been this library inventing a
   behaviour. `MeshNode.setBroadcastVia(name, on)` mutes transmit only, which is
   also why nothing rebuilds and the node DB survives a toggle.
2. **Done.** `enabled_protocols` now reports the gate rather than the wiring, and
   a phone's write drives it through `AdminService.applyConfig` - so `restore()`
   carries a stored flag to the node at startup, which is firmware's boot read.
   Only UDP has a flag until `feat/ble-mesh-protocol-flags` lands; `broadcastsVia`
   is keyed by bearer name, so each BLE flag is one line when it does.
3. Still open: `MeshNode.transportAvailability` as a `StateFlow<Map<String,
   TransportAvailability>>`, so hosts stop rewriting the fold.

**And the `MESH_TRANSPORTS` exception is gone, without a proto field.** The audit
treated the bearer list as a setting with no durable home, which made the unlanded
BLE flags look like a blocker. It was a machine description filed under settings.
On a radio the bearer set *is* the board variant, and the config only decides
whether each is used - two questions, one variable answering both. Split, each half
lands in a category the repo already had: what a host can build is hardware, so
`MESH_TRANSPORTS` joins `MESH_LORA_SPIDEV` and never persists; whether a built
bearer transmits is a setting, and `network.enabled_protocols` plus `lora.region`
already hold that. The bespoke bearer store is deleted.

Two things that made the wrong answer look right for two rounds. `AGENTS.md` itself
named `bluetooth.enabled` as a candidate home, and it is not one - in firmware that
field gates the phone-API BLE interface, not any mesh bearer. And "the list has no
durable home" is true and irrelevant, because the list is not the thing that needed
one.

One finding from fixing it, worth more than the fix. `ConfigFieldParityTest`
could not have caught this. It proves a `NODE`-classified field *varies* between
two probe nodes, and `enabled_protocols` did vary - by bearer presence. **It
cannot prove a field is complete.** That is a limit of the harness, not a missing
line in the field's derivation, and the same blind spot covers any field that
reports a subset of something.

The UX shape is one row per bearer: a switch and a state line. The state line is
the valuable half, and node-kmp is the only client that could fill it honestly -
"BLE off", "no permission", "no CH341 attached" - because the reason comes from
the transport itself.

## The alignment pass, 2026-09-13

Done in the same sitting as the audit above, on `meshtastic-node-kmp` `main`.

**The advertisement pattern now matches the firmware's on both platforms.** The
numbers in the table above were the *before*. Android moves from
`INTERVAL_MEDIUM`/`TX_POWER_MEDIUM` and a blind `delay` to `INTERVAL_LOW`,
`TX_POWER_HIGH` and `maxExtendedAdvertisingEvents = 3`, awaiting
`onAdvertisingEnabled(set, false, _)` - the same shape as
`ble_gap_ext_adv_start(inst, 0, BLE_MESH_ADV_EVENTS)`, which passes duration 0 and
bounds on events. `durationMs` stays the ceiling rather than becoming a second
bound, so the signature does not change and BlueZ, which has no event knob, is
unaffected by it.

Three constants settled the design, read out of the Android 37 sources rather
than the docs:

- `TX_POWER_MEDIUM = -7` and `TX_POWER_HIGH = 1` are **dBm**, so the gap was a fact
  and not an estimate. **Measured on a Pixel 6a it is 9 dB, not 8**: that controller
  grants -8 at MEDIUM and +1 at HIGH, because the constant is a request and the grant
  is the controller's answer. `TX_POWER_MAX_AVAILABLE = 20` is the nearer match to the
  firmware's "controller picks its maximum" and is deliberately unused: it is a flagged
  API, and the builder range-checks against `TX_POWER_MAX`, which is +1.
- `INTERVAL_LOW = 160` units = 100 ms, and equals `INTERVAL_MIN`. **The firmware's
  30 ms is below Android's public floor**, so 100 ms is as close as the platform
  allows. That residual asymmetry is not closable from the client.
- Three events at 100 ms fit inside the 300 ms budget one advertisement already
  held, so this costs no airtime. Same ceiling, three times the repeats, 8 dB more
  power.

`onAdvertisingSetStarted` reports the power the controller actually granted. This
library has no log, so reading it is the device test's job.

**BlueZ gets the same two knobs, guarded.** `MinInterval`/`MaxInterval` at the
same 100 ms, both bounds pinned to one value as the firmware pins
`itvl_min == itvl_max`; and `TxPower` set from the adapter's own `MaxTxPower`,
which is BlueZ's nearest equivalent of `tx_power = 127`. Two traps, both handled:
`CanSetTxPower` lives on `SupportedFeatures` (an array) while the value lives on
`SupportedCapabilities` (a dict), and `MaxTxPower` is a signed `int16` that
`capabilityByte`'s unsigned mask would have read -7 dBm as 249. BlueZ validates
both properties at parse time and fails the whole `RegisterAdvertisement` rather
than ignoring one field, so the register path tries tuned and falls back to bare:
a Linux node that went silent would be worse than one advertising at the default.

**The Android half ran on hardware on 2026-09-14** - a Pixel 6a on Android 17,
`:node-transport-ble:connectedAndroidDeviceTest`. What that settled:

- The new parameters are accepted rather than rejected at the builder: `INTERVAL_LOW`,
  `TX_POWER_HIGH` and an event bound all take.
- **9 dB, not 8.** The controller grants -8 dBm at MEDIUM and +1 at HIGH.
- **The event bound really ends the advertisement.** I had flagged that I had not
  verified Android fires `onAdvertisingEnabled(set, false, _)` on self-termination.
  It does: 380 ms measured against a 10 s ceiling, which is three events at the 100 ms
  interval plus callback latency. The 10 s ceiling is the point - at the 300 ms default,
  "the bound worked" and "the callback never came" are milliseconds apart.

**The BlueZ half has no host in this fleet that can run it**, measured on the uConsole
the same day. That controller is HCI version 9 (BT 5.0, Broadcom) on bluez 5.82, and
`LEAdvertisingManager1.SupportedCapabilities` still reports `MaxAdvLen 31`: BlueZ sees
no extended advertising, so a `MeshPacket` cannot leave the host and `canTransmit`
correctly reads false. `james-pc`'s Realtek adapter refuses advertising outright. So
the tuned `RegisterAdvertisement` is never reached on either box.

It did settle the half that matters most, though. `SupportedFeatures` is **empty** -
no `CanSetTxPower` - so `maxTxPower()` returns null and no `TxPower` property is sent.
That guard is load-bearing rather than defensive: BlueZ fails the whole registration on
a `TxPower` the controller cannot honour, and this is a real adapter that cannot. The
tuned-then-bare fallback was written blind and the first hardware it met would have
needed it.

**Still not on the air:** that anything *hears* the Pixel's advertisement. The uConsole
cannot - a controller with no extended advertising cannot receive one either, and a
scan there sees ordinary devices and never company ID 0xFFFF. That needs a bench board
running the BLE-mesh spike in range of the Pixel.

### Asymmetries found while looking

- **GATT chunk size: a latent ceiling mismatch, clamped.** Android grants an MTU
  of 517, so `mtu - 3` is 514 and the bench log reads `chunk=514` against an
  Espressif address, while the firmware caps at `BLE_GATT_MESH_MAX_CHUNK` (512).
  `GattPeerTable`'s `maxChunkSize` now clamps to `MIN_CHUNK..MAX_CHUNK`, mirroring
  the firmware's pair rather than only its minimum, which was already mirrored.

  Two corrections to the first version of this entry, both from reading further.
  The **mechanism** is not truncation: `onWrite` is
  `if (len == 0 || len > BLE_GATT_MESH_MAX_CHUNK) return;`, so an oversize chunk
  is dropped whole and silently, and the `min(r.len, cap)` in `platformPollInbound`
  is a second guard that never fires. There is no overflow. And the **reach** is
  smaller than it looks: `MeshFragment.split` sizes each chunk to its own payload
  rather than padding to `maxChunkSize`, so a 514-byte write needs a packet over
  509 bytes, and `DATA_PAYLOAD_LEN` is 233. Nothing this library originates today
  gets near it. What is proven is that the two ceilings disagreed and the client
  was the side free to pick the wrong one.
- **BlueZ duplicate filtering: already correct.** `SetDiscoveryFilter` passes
  `DuplicateData: true`, matching Android's `CALLBACK_TYPE_ALL_MATCHES`, Apple's
  `allowDuplicates` and the firmware's `filter_duplicates = 0`. Checked because
  a mesh node's payload changes every frame, so first-report-only would look
  exactly like an idle mesh. Not a gap.
- **nRF52 and ESP32 agree.** `NRF52BLEMesh.cpp` uses the same
  `BLE_MESH_ADV_EVENTS`, `BLE_MESH_ADV_INTERVAL`, `BLE_MESH_SCAN_INTERVAL` and
  `BLE_MESH_SCAN_WINDOW` macros, so aligning to ESP32 aligned to both radios.
- **In-flight fragments: no gap.** The firmware holds 2 assemblies per peer, the
  client's reassembler allows 4 - receiver generosity, which is fine. On the
  sending side `GattLinkBase` holds one lock per peer for a whole packet, so at
  most one assembly is ever in flight toward a peer.
- **Still open, and not closable from the client:** Apple cannot set a PHY or
  transmit an advertisement at all, BlueZ has no PHY API, and both firmware
  advertisement PHYs are hardcoded 1M. Coded PHY stays a both-ends change.

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
