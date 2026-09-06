# One protocol, many bearers - the multi-transport mesh plan

Written 2026-09-03. Supersedes the "BLE bridge" framing in
[`ble-mesh-transport.md`](./ble-mesh-transport.md) (still good as analysis).
Grounded in four investigations run 2026-09-03: firmware BLE-connection limits,
firmware multi-transport model, the `node-transport-ble-gatt` state, and external
research on connection-oriented meshing.

The ask that started this: *"holistically leverage / interoperate / bridge
between all transports available on each device - LoRa, UDP, BLE-adv, BLE-GATT,
Wi-Fi, MQTT - extend the mesh via as many transports as possible."*

## Implementation status (updated 2026-09-05, end of day)

**The "Parity and coverage plan" below is implemented end to end**, on
`meshtastic-node-kmp` `main`, pushed. Identity and keypair persistence, reliable
delivery, the NodeInfo/Position/telemetry beacons, PKI DMs, traceroute answering,
desktop LoRa, desktop BLE over BlueZ, iOS UDP, the MQTT bridge, and the
availability seam that made a dead bearer distinguishable from an idle one. Every
slice, what hardware proved, and what is still blocked on something outside the
code: "Tier-1 parity implemented end to end" at the end of this file.

**Then a feature-wide adversarial review, 2026-09-06**, and seventeen commits of
fixes off it. All 18 high-severity findings are addressed, along with every
medium and low that a second, properly adversarial verification wave confirmed.
The load-bearing ones: reliable delivery only retried when an unrelated frame
arrived, so a silent mesh never retried at all; the phone API was an
unauthenticated write interface on every interface and never sent a delivery
receipt, so every message a stock app sent sat at "Sending..."; every
phone-facing timestamp came from an uptime clock, so an app rendered 1970; a
region that cannot carry a preset transmitted it anyway, off-band; and a blank
channel name hashed as "" rather than "LongFast", so an imported default channel
was silent both ways. Full list, method and the parts that stayed unaudited:
[`review-multi-transport-2026-09-06.md`](./review-multi-transport-2026-09-06.md).

Left standing from the parity plan: the cross-peer fan-out inside a single GATT
send (needs three connected peers), step 0's remaining app-side adapters, and
per-bearer rates over time in the monitor. The commonization pass and the
Material 3 pass are done.

Caught in the same sitting: the `api/` binary-compatibility dumps had gone stale
because the gate documented in node-kmp's `AGENTS.md` never named `apiCheck`,
even though BCV was wired for klib and JVM all along. Dumps regenerated and
`apiCheck` now leads the gate.

`meshtastic-node-kmp` `main` is **pushed**. The `firmware`
`spike/ble-mesh-transport` branch is **pushed** through `ca0a39c51` (the audit fixes
are in that head, not in the earlier `df1ae63bf` these notes used to name), and its
`protobufs` submodule pointer (`8db5d3e`) is on `meshtastic/protobufs`
`spike/ble-mesh-transport`, so a fresh clone of the spike resolves. Landing those
protos on `master` and publishing the artifact is still owed.
Since the 2026-09-04 status below: the Apple-central controller assert is fixed on
ESP32-S3/C3 (1M-only PHY); **nRF52 is a full peer** (BLE-adv both ways, mesh-peer
GATT both ways with Android and iOS, two phones at once, on a WisMesh Pocket);
ESP32-C3 links build-only; Android's 5-minute scan downgrade is worked around.

- **Phase 1 (client) - done, green, and since 2026-09-04 a four-bearer node with
  per-bearer instrumentation.** Everything is on `meshtastic-node-kmp` `main`.
  The 2026-09-04 layer: `ed37488` LoRa transport merged; `5a0d690` BLE-adv wired
  into every platform; `c31095b` UDP given an Android target; `755e346`
  per-transport rx/tx/relayed counters, `via`-tagged events, transport on/off
  toggles and a tuning panel for every lever (relay policy included - the
  monitor node had been an island until then); `1b1d68a` the
  `ACCESS_LOCAL_NETWORK` grant (whose commit message calls it the fix for a dead
  UDP bearer - **wrong**, see the correction at the end); `8427db6` the desktop
  uber jar; `393384b` the corrections. Details in the 2026-09-04 section at the end. The
  original GATT work, on `feat/ble-gatt-transport` (since merged):
  - `fb5a3ab` - don't echo a relay back to the sending peer (origin token
    threaded `InboundFrame.source` → `exclude`); validate-before-relay confirmed.
  - `4009b05` - per-peer whole-packet delivery accounting.
  - `4159bd7` - reframed the "split-horizon" misnomer to plain wording
    (test class → `RelayDoesNotEchoToSenderTest`).
  - *Pending, bench-gated:* DUAL-role connection arbitration + a low (2–3)
    connection cap, and per-peer send-queue concurrency (Android's device-wide
    GATT-op behaviour must be verified on hardware).
- **Cross-platform GATT interop PROVEN on hardware, 2026-09-03** - Android
  (Pixel 6a) ↔ iOS (iPad), **bidirectional, decoding at the mesh layer** (not
  just transport bytes): Pixel `!6337995d` ↔ iPad `!b28c3748` exchanged text both
  ways over BLE GATT, each side running full packet processing (reassembly →
  decode → channel decrypt → dedup). Proven via the new `:monitor` CMP app on
  dual dashboards. Two bugs found + fixed on `feat/monitor-app`:
  - `17b0bd1` - **the bug that hid interop for hours:** `MonitorController`
    derived its NodeNum from a *constant* seed, so every device was `!2c2926ac`;
    two same-id nodes drop each other's frames as "heard myself" (silent, no
    event) over a live link. Fixed with a `platformNodeSeed()` seam (Android
    `ANDROID_ID`, iOS `identifierForVendor`, desktop user@host). **Any client
    node needs a per-install identity, never a hardcoded seed.**
  - `1010c12` - `gattLog` used K/N `NSLog` (unusable: `%s` silent, `%@` crashes);
    switched to `println` read via `devicectl … process launch --console`.
  - **KNOWN ISSUE (tuning backlog): the iOS-*central* outbound path is flaky.**
    The iPad-peripheral ← Pixel-central *inbound* link forms reliably (every one
    of 6 captures) and is bidirectional on its own (central writes, peripheral
    notifies), so the mesh has a dependable link. The iPad-central → Pixel-
    peripheral direction is unreliable at the *discovery* step: `didDiscover­
    Peripheral` sometimes fires + connects, sometimes fires + stalls (no
    connect-timeout / no failure recovery), sometimes never fires - a
    CoreBluetooth central scan-delivery/lifecycle issue upstream of the connect,
    not a missing timeout. A `didFailToConnectPeripheral` handler was added
    (forgets the dead peer + rescans) as a standalone correctness fix. The full
    fix (why the central scan stops delivering; DUAL-role arbitration so only one
    side dials) is deferred to the tuning stage. Evidence in
    `ble-mesh-interop-bench` memory.
- **Phase 2 (firmware transport registry) - complete, green.** On `firmware`
  `spike/ble-mesh-transport` (native suite 1392/1392, 0 failures):
  - `009127773` - `MeshTransportBase` registry (MeshModule-style); UDP + BLE-adv
    taps routed through the post-encode hook; LoRa's `iface->send` untouched.
  - `d8ea49801` - MQTT moved onto the registry via a second **pre-encode** hook
    (it needs the decoded packet + chIndex, fires only for `isFromUs`
    originations, never for relays).
  - *Deliberately out of scope:* the receive-path MQTT tap (`Router.cpp:1631`,
    `!isFromUs`) stays a hardcoded `mqtt->onSend`; a no-LoRa transports-only node
    (would need relaxing `assert(iface)` - LoRa stays first-class, so opt-in only).
- **Phase 3 (firmware BLE-GATT mesh-peer edge) - service WRITTEN + committed,
  hardware bring-up proven on the ESP32-S3; cross-device frame exchange still
  bench-gated. 2026-09-03.** Committed on `firmware` `spike/ble-mesh-transport`
  as `3022a3776` (14 files, +1725): `BLEGattMeshHandler` (platform-neutral -
  framing shared byte-for-byte with the node-kmp client, bounded reassembly, the
  UDP/adv ingress guards, per-peer TX ring, no-echo-to-arrival-peer) and
  `ESP32BLEGattMesh` (NimBLE - own connectable adv set on **instance 2**,
  per-connection notifies, MTU-derived chunk, a GAP handler chained ahead of the
  Arduino wrapper's, PhoneAPI-disconnect gating). Registry-gated on the new
  `BLE_GATT_PEER` protocol flag. The sdkconfig bump landed **with** the service:
  `CONFIG_BT_NIMBLE_MAX_CONNECTIONS=2` / `CONFIG_BT_CTRL_BLE_MAX_ACT=6`
  (ROLE_CENTRAL stays off - phones connect *inward*). Proto pointer bumped for
  the `TRANSPORT_BLE_GATT` + `BLE_GATT_PEER` enums; generated headers regenerated.
  - **Proven:** native suite **1418/1418** (26 new cases for this transport);
    heltec-v3 built + flashed, and with **WiFi off** (`network.wifi_enabled=false`
    at runtime, PSK never written) it brings the service up clean -
    `BLE GATT mesh: mesh-peer service registered`,
    `advertising the mesh-peer service on instance 2`, full node operation, zero
    OOM / `Memory Capacity Exceeded` / crash at the 2-connection config.
  - **PROVEN end to end 2026-09-04.** An Android client (`node-kmp monitor`)
    subscribed to the mesh-peer service **receives mesh frames over BLE GATT** -
    the app's rx counter advanced with a frame from the v3's own node number
    (`!d1d90f21`) plus relayed LoRa traffic. Getting there fixed five real bugs,
    all committed on `spike/ble-mesh-transport`:
    1. `6c1c7feba` - the node initiated BLE bonding even in NO_PIN, which failed
       and tore the link down before subscribe. Fixed with
       `setAuthenticationMode(false,false,false)` in the NO_PIN branch.
    2. Peers were registered only from `onSubscribe`/`onWrite`, which never fire
       for a central that connects via the phone-API advertising instance.
       Register every link from the server's `onConnect` (fires for all
       instances). (`668645fde`)
    3. The characteristic value handle never resolved (`getHandle()==0xFFFF`): the
       wrapper resolves handles only inside `BLEServer::start()`, triggered by its
       `BLEAdvertising::start()`, which this firmware bypasses (raw
       `ble_gap_ext_adv`). Fixed by forcing `server->start()` after registering
       the service. (`668645fde`)
    4. Notifications used raw NimBLE `ble_gatts_notify_custom` with an esp_gatts
       handle - returns success, delivers nothing. Switched to the wrapper's
       `BLECharacteristic::notify()` (the phone-API `fromNum` path). (`668645fde`)
    5. Stale central-side bonds (Mac `Peer removed pairing info`, Pixel bond loop)
       must be cleared on the central; a BT toggle / RPA rotation does it.
    - Bench note: bleak on macOS is a **false negative** here (subscribes fine,
      never surfaces the notification); the real Android client receives.
  - **Remaining (spike → production):** the diag-log revert and per-peer notify
    targeting are **done** in `ea24b26d5` (notifies go per connection with
    `ble_gatts_notify_custom`, skipping the arrival peer; the spike diagnostics
    dropped). Still open: a subscribe watchdog + DUAL-role arbitration per the
    research note.

    **Superseded 2026-09-04 evening.** What follows described the notify direction
    as not delivering, with the Pixel's `gatt` rx stuck at 0. That was root-caused
    the same evening and was not the notify path at all - the V3 had had its WiFi
    turned on that morning, and on ESP32 WiFi on means NimBLE never starts. GATT
    is proven both ways since. DUAL-role arbitration is done and proven on three
    nodes. Kept for the reasoning it records, not as live status:

    the Pixel's `gatt` rx stays 0 while its writes
    (originations and relays) are accepted (2026-09-04). The
    `tackle-monitor-findings` workflow is root-causing it: CCCD/subscribe on the
    Android client, the firmware's per-peer `subscribed` gate, BLE-adv coexistence
    on one adapter, NO_PIN encryption on the CCCD, and the monitor's
    rebuild-on-tune lifecycle are the hypotheses.
  - **Gated 2026-09-05:** nRF52 on the WisMesh Pocket - links (RAM 41.1%, flash
    92.0% with GATT), BLE-adv and GATT proven both ways with Android and iOS.
    ESP32-C3 links build-only (`heltec-ht62-esp32c3-sx1262`: RAM 34.2%, flash
    87.2%); no C3 on the bench.
  - **v3 bench state:** unplugged since 2026-09-05 morning, and erased before
    that, so the 2026-09-04 config above no longer describes it. The handoff's
    bench section carries what it was left holding.
- **Phase 4 - future** (Wi-Fi Aware, anti-entropy sync).

---

## The one idea

**Every device runs one mesh node that carries every transport it physically
has, and nodes bridge automatically at the frame layer.** There is no "the BLE
mesh" or "the UDP mesh" - there is *the mesh*, and a bearer is just how two
adjacent nodes happen to be able to reach each other.

This is not a new architecture. Both sides already do it; they just do it at
different maturity:

- **Client (`meshtastic-node-kmp`) - has the clean version already.** `MeshNode`
  holds a *collection* of `MeshTransport`s; `broadcast()` loops every transport
  whose `canTransmit` is true and re-frames per medium via `FrameAdapter`; dedup
  is `PacketHistory.wasSeenRecently(from, id)`, transport-agnostic. Adding a new
  transport = implementing one interface. The registry the firmware lacks already
  exists here.

- **Firmware - has an emergent version.** `Router::send()` is a single funnel:
  MQTT tap, then UDP tap, then the one hardcoded LoRa `iface->send`. A packet
  received on any transport re-enters that funnel via the flood router and so
  re-emits on all the others - **bridging is a free side effect**, not designed.
  The only loop guard is `PacketHistory` keyed on `(from, id)` alone - no
  `transport_mechanism` in the key. (`Router.cpp:470-616`, `PacketHistory.cpp:82-105`.)

**The keystone both sides share: global `(from, id)` dedup.** It is what lets the
same packet arrive over LoRa *and* UDP *and* BLE *and* MQTT and be processed
once. Every part of this plan preserves it; nothing may key dedup on the bearer.

---

## Device × transport matrix

What each platform can actually carry (TX + RX unless noted). This is the map the
whole plan is drawn on.

| Bearer | FW ESP32-S3/C3 | FW nRF52840 | Android | iOS / macOS | JVM / Linux |
| --- | --- | --- | --- | --- | --- |
| **LoRa** (RF backbone, km) | ✓ backbone | ✓ backbone | - | - | - |
| **BLE-adv** (connectionless, ext-adv) | spike ✓ | spike ✓ (rak4631 RX) | ✓ | **RX only** (no TX) | ✓ BlueZ (Linux only; scan proven, advertise refused by the bench adapter) |
| **BLE-GATT** (connection, dual-role) | spike ✓ mesh-peer service | spike ✓ mesh-peer service (rak4631_blemesh) | ✓ | ✓ | ✓ BlueZ (Linux only; built, not yet run on Linux hardware) |
| **UDP multicast** (LAN) | ✓ (wifi/eth) | ~ (eth) | ✓ | ~ (entitlement) | ✓ |
| **Wi-Fi Aware** (Android↔Android) | - | - | ✓ (future) | - | - |
| **MQTT** (internet, infra-backed) | ✓ (wifi/eth) | ~ | ✓ | ✓ | ✓ |

¹ Firmware today runs a GATT *server* for the phone control app only
(`TRANSPORT_API`, service `6ba1b218-…`) - not a mesh bearer. No firmware target
compiles the GATT *client/central* role at all.

**Three tiers, by reach - the useful mental model:**

- **Backbone - LoRa.** Kilometres, firmware-only, duty-cycle limited. The
  long-haul spine. Unchanged by this plan.
- **Local - BLE (adv + GATT), UDP, Wi-Fi Aware.** Metres to a room/LAN. This is
  where phones join, and where iOS becomes a native peer.
- **Global - MQTT.** The internet bridge; already how the mesh spans continents.
  Infra-backed, so it is a *policy* bearer (uplink/downlink per channel, gateway
  identity) more than an RF one.

**Why GATT is special:** it is the *only* bearer every client platform can both
transmit and receive on. iOS cannot transmit BLE advertisements at all
(`CBPeripheralManager` accepts only name + service UUIDs). So GATT is the bearer
that makes iOS a first-class node without a bridge - which is the real prize
behind "everyone on GATT."

---

## Design invariants (true today; must stay true)

Any new bearer, on either side, must hold all five:

1. **One canonical `MeshPacket`** on the wire, or a `FrameAdapter` that
   translates to/from it. (Firmware LoRa is the sole non-canonical framing today;
   every other bearer carries a whole encoded packet.)
2. **Dedup keyed on `(from, id)` only** - never on the bearer. This is the loop
   guard for the whole multi-bearer mesh.
3. **Re-emit on every bearer except the one it arrived on.** Today this is ad hoc
   (MQTT's `via_mqtt` flag; the BLE spike's `return`; a *broken, log-only* check
   in UDP that re-emits UDP→UDP; nothing at all on the client GATT path). It must
   become uniform: compare arrival `transport_mechanism` against each egress
   bearer.
4. **Validate before relay.** Bridgefy's real-world failure: nodes forwarded
   payloads before parsing, so one malformed "zip bomb" packet took down the
   whole mesh. Relay must be gated on successful decode, not just a header read.
5. **Rebroadcast policy is one decision, applied to all bearers.** Firmware's
   `role`/`rebroadcast_mode` already funnels through `Router::send`, so it governs
   every bearer at once - keep it that way rather than per-bearer relay rules.

---

## Where the effort actually is

Ranked by value-per-risk, from the four investigations.

### Phase 1 - Client N-transport mesh node (`node-transport-ble-gatt` + `node-core`)

**Risk: low. Value: high. Client-only. ~70% already built and hardened.**

The GATT transport is already dual-role with a real multi-peer table,
connect-to-all discovery, per-peer keyed reassembly, per-peer MTU, and fan-out
broadcast. The node's flood logic (dedup, hop-limit, contention-window relay) is
already bearer-agnostic and already relays over GATT. Net-new, all scoped:

- **Don't echo a relay back to the sending peer.** Today a relay writes to *all*
  GATT peers including the one that just handed it the frame; only `(from,id)` dedup
  saves it (correct, but a wasted point-to-point write every hop). Not routing -
  just skipping a unicast to a peer that provably already has the packet. Structural
  blocker: the transport drops the sending `peerId` before the node sees the frame.
  Fix = thread the sending-peer token up through `InboundFrame` and an `exclude`
  down through `send`/`broadcast`. Cross-cutting but small.
- **Per-peer backpressure.** One global `txLock` serialises all sends; a departed
  peer can stall every peer for the ~20 s Android supervision timeout. Needs
  per-peer send queues / failure isolation.
- **Connection arbitration + a *low* cap.** The dual-role connect race collapses
  two nodes onto one one-directional link. And Android's ~7-connection ceiling is
  **device-wide** - shared with the user's watch, earbuds, car. A greedy mesh
  breaks the user's other devices and gets uninstalled. So: default degree **2–3**
  with multi-hop, not link-maximising, and per-pair arbitration (bitchat-style).
- **Relay-before-validate guard** (invariant 4) and **per-peer whole-packet
  delivery accounting** (currently reports success on partial fan-out).
- **Confirm cross-bearer behaviour end-to-end:** the client can already carry
  UDP + BLE-adv + GATT at once; verify dedup holds across them and the
  don't-echo-to-the-sender skip is applied per-bearer.

**Outcome:** iOS / Android / macOS are native GATT mesh peers, no bridge device.
This is worth shipping on its own merits regardless of what firmware does.

### Phase 2 - Firmware transport registry (issue #8152, already open, member-authored)

**Risk: moderate. Value: high leverage - everything else rides on it.**

The firmware has *no* transport abstraction: `Router` holds exactly one `iface`
(`Router.h:50`), `RadioInterface` models LoRa *chips* not bearers, and every
non-LoRa transport is a hand-added tap. Issue #8152 ("UDP bridging hasn't got the
same control as MQTT") is the live tracking issue for exactly this. The work:

- Introduce a real transport interface (distinct from the LoRa-chip-bound
  `RadioInterface`): `onSend(packet)` + an ingress callback, held by `Router` in a
  **collection**, egress iterating it.
- Give every bearer the per-bearer control MQTT already has (enable, uplink/
  downlink, filter) - UDP has a single global bit today.
- Generalise invariant 3 (don't-echo-arrival-bearer) uniformly; fix the UDP→UDP
  re-emit bug (`UdpMulticastHandler.h:123-125`) as a side effect.
- Let the registry hold peers *alongside* LoRa - **without demoting it**. LoRa
  stays the first-class, default interface with its place in the send order; the
  registry is additive (today `Router` holds exactly one `iface`). Relaxing the
  hard `assert(iface)` (`Router.cpp:614`) to allow an optional transports-only
  node (a Wi-Fi/BLE-only indoor node) is a *later, opt-in* capability, not a
  change to LoRa's status - pursue it only if such a node is actually wanted.
- Fold the **BLE-adv spike into this registry** rather than as another
  special-case tap - that retires the spike's copy-paste and is the natural home
  for it.

**Outcome:** adding *any* bearer (GATT, another radio, a future one) becomes
implementing an interface, not editing `Router::send`. This is the structural
unlock for "as many transports as possible."

#### Blockers, identified up front (firmware deep-read 2026-09-03)

Ranked by severity. The headline: **every HARD/MODERATE blocker is avoided by the
same rule - keep LoRa on its own `iface`, make the registry a *parallel* fan-out,
never route LoRa through it.**

1. **HARD - `RadioInterface` is the wrong base for non-LoRa transports.**
   `RadioInterface.h` has ~30 LoRa-*physical* members (airtime, RSSI/SNR, TX
   power, region/modem config, CAD, contention window) vs ~6 generic ones, and
   two are pure-virtual and LoRa-bound (`send`, and `getPacketTime(uint32_t,bool)`
   at `:240`); the base ctor even derives `slotTimeMsec` from LoRa params
   (`:104`). A UDP/BLE transport cannot honestly implement it.
   *Mitigation:* introduce a **new thin interface** (~4 members: `onSend`, a
   transport-owned ingress ending in `enqueueReceivedMessage`, `enable/disable`,
   optional `retransmitDelayMsec`). LoRa stays a `RadioInterface`, *adapted* into
   the registry - never reparented.

2. **MODERATE - tap policy is per-transport and rich; naive unification breaks
   it.** MQTT egress needs the encrypted *and* decoded packet + `chIndex` and
   gates on `isFromUs` + `via_mqtt` loop-prevention + per-channel uplink
   (`Router.cpp:592`, `MQTT.h:44`, `MQTT.cpp:701-751`); UDP egress is ungated and
   runs *post-encode* (`Router.cpp:600`). Ingress sanitising differs too (UDP
   drops spoofed `isFromUs`, clamps hops, zeroes RSSI/SNR, clears PKI -
   `UdpMulticastHandler.h:78-100`; MQTT sets `via_mqtt` + downlink checks -
   `MQTT.cpp:122-179`). *Mitigation:* the interface contract must carry
   (encrypted, decoded, chIndex) and a pre/post-encode hook choice, and ingress is
   a transport-owned sanitise step. Enumerate these as the transport's policy -
   do not collapse to a bare `onSend(p)`.

3. **MODERATE - relay/retransmit timing references the LoRa `iface`
   unconditionally.** `ReliableRouter.cpp:44,100`, `NextHopRouter.cpp:555`,
   `FloodingRouter.cpp:146,150` compute backoff/late-rebroadcast against LoRa
   airtime regardless of arrival bearer. *Degrades gracefully* (a LoRa airtime
   figure used as the estimate - conservative, not corrupting). Precedent in our
   favour: `perhapsCancelDupe` is *already* gated on `TRANSPORT_LORA`
   (`FloodingRouter.cpp:139`) - the flood code already anticipates mixed
   transports. *Mitigation:* let a transport supply its own retransmit delay;
   LoRa-as-default keeps behaviour identical.

4. **MODERATE - LoRa singletons + single-slot `iface`.** `addInterface` replaces
   one `unique_ptr` (`Router.h:62`), and `RadioLibInterface::instance` / `airTime`
   / `SimRadio::instance` are consulted directly across UI/power/RNG. *Mitigation:*
   additive registry alongside LoRa touches none of these - they keep pointing at
   LoRa. (Only *routing LoRa through* the registry would hit them. Don't.)

5. **MODERATE - `BLE_BROADCAST` needs a cross-repo proto bump.** Absent from
   `ProtocolFlags` on develop (only `NO_BROADCAST`, `UDP_BROADCAST` -
   `config.proto:584-594`); adding it regenerates the protobufs submodule consumed
   by firmware + python + apps + SDK (additive, non-breaking). *Mitigation:* the
   reserved `TransportMechanism` slots `TRANSPORT_LORA_ALT1..3` (`mesh.proto:1729`)
   and `TRANSPORT_UNICAST_UDP=8` need **no** bump; only the BLE enable *bit* does,
   so sequence the proto change with Phase 3, not Phase 2.

**Confirmed non-issues (assets, not blockers):**

- **`MeshModule` is a ready-made registry template** - `static std::vector<MeshModule*>`,
  ctor self-registration, `callModules` iteration, `CONTINUE/STOP` + `wantPacket`
  (`MeshModule.h:65,71,79,161,168`). Copy it verbatim; match its raw-`new`-and-leak
  boot-singleton idiom, don't add ownership churn.
- **Dedup is transport-agnostic** - `PacketHistory` keys on `getFrom(p)` + id only
  (`PacketHistory.cpp:83`), no LoRa/RSSI/airtime reference. Invariant 2 holds free.
- **Router is already unit-tested natively via mock interfaces** - `test_nexthop_routing`
  installs a `MockRadioInterface` through `addInterface` (`test_main.cpp:165,333`).
  A `test_transport_registry` follows the same shim. Cheapest thing in the plan.
- **No flash-size CI gate**, and each transport is already behind
  `HAS_*`/`MESHTASTIC_EXCLUDE_*` guards, so constrained variants (C3, non-rak
  nRF52) compile them out. Size risk: MINOR.

#### The de-risking first PR (zero behaviour change)

Prove the registry carries real, divergent transports **before** adding any new
one: introduce the thin `MeshTransport` interface + a `MeshModule`-style
`TransportRegistry`, then wrap the *existing* `udpHandler` and `mqtt` egress/
ingress as two registry entries - replacing the hardcoded taps at
`Router.cpp:592,600` with a registry iteration that preserves each tap's exact
gating (isFromUs + pre-encode for MQTT, `enabled_protocols` + post-encode for
UDP). LoRa's `iface->send` (`Router.cpp:615`) is left untouched. Ship with a
native `test_transport_registry` asserting MQTT loop-prevention and UDP spoof-drop
still hold. This changes zero behaviour, adds no wire/proto surface, and cannot
destabilise LoRa - the LoRa path is not modified. Only *after* it lands do BLE-adv
(fold in the spike) and BLE-GATT (Phase 3) become "implement the interface."

### Phase 3 - Firmware BLE-GATT mesh-peer edge

**Risk: moderate, gated on one empirical number. Value: iOS reaches a radio
directly, no bridge device.**

Add a mesh-peer GATT service so a phone (crucially iOS) connects to a firmware
node as a mesh *edge client*, and the firmware relays between its LoRa mesh and
the connected phone(s). Each firmware node becomes its own proxy - this is the
SIG-Mesh "GATT Proxy" role, the standard name for what the bridge chain proved by
hand. Firmware-to-firmware stays LoRa; **no firmware central role, no backbone
formation, no degree-constrained topology, no self-heal** - this deliberately
dodges every hard scatternet problem.

**The gate - one cheap bench experiment, decisive:** the firmware is peripheral-
only, capped at one connection, with NimBLE buffers *deliberately trimmed to
exactly one link* to dodge a contiguous-heap OOM at bring-up
(`esp32-common.ini:289-294`). So the whole phase turns on: **does raising
`CONFIG_BT_NIMBLE_MAX_CONNECTIONS` 1→2 still let `BLEDevice::init()` return on the
S3 and the C3?** Bump it in a spike build, flash the bench v3, watch for host
sync. If yes on S3 but no on C3, the plan goes chip-tiered. The nRF52 mirror:
`Bluefruit.begin(2, 0)` re-runs SoftDevice RAM sizing and moves the linker ORIGIN
(`NRF52Bluetooth.cpp:284`, `nrf52840_s140_v6.ld:29`) - also cheap, also decisive.
And the ext-adv discovery collision (`NimbleBluetooth.cpp:850-861`, already solved
in the spike) applies: the connectable advert is full with one 128-bit UUID, and
enabling ext-adv is host-global.

Serves a small number of phones per radio (the one-connection cap only widens to a
few). That is fine - it complements, never replaces, the LoRa backbone.

### Phase 4 - New bearers on the unified seam (opportunistic / future)

Once Phases 1–2 exist, these are "implement one interface":

- **Wi-Fi Aware** as a client transport (`node-transport-wifi-aware`), Android↔
  Android - far more bandwidth than BLE, on the existing seam (Knit ships this).
- **Content-digest anti-entropy sync** (Knit / IPFS Bitswap / range-based set
  reconciliation): an idle mesh does zero data-path work; a new message triggers a
  *targeted* sync only with peers that need it. Directly answers the "N writes per
  packet" cost of flooding a connection-oriented bearer.
- **Firmware↔firmware BLE-GATT backbone** - the FruityMesh-style connection mesh.
  Only if a real need emerges (LoRa duty-cycle limits, no-LoRa nodes, dense
  indoor, throughput). This is where the *known-hard* problems live: BLE has no
  mid-link role switch (central/peripheral elected permanently per link),
  degree-constrained formation is NP-hard, and self-heal under churn is a
  literature gap - the very things that kept scatternets in simulation for 20
  years. High risk; treat as research, not roadmap.

---

## Retiring the advertisement transport

The original prompt was "drop the advertisement transport." The nuanced answer:
**yes, eventually - but not first.** Sequencing matters:

- The BLE-adv transport (`node-transport-ble` + firmware `BLEMeshHandler`) is what
  the proven bridge chain runs on. Deleting it at the end of Phase 1 would strand
  phones with no path to a radio until Phase 3 lands.
- Keep it as the fallback until its replacement (Phase 3 GATT edge) is proven on
  the bench. **Then** decide: BLE-adv is one-to-many (one TX reaches every
  neighbour) where GATT is N writes, so it may still earn its keep as the Android↔
  firmware local path even after GATT exists. Retire it only if that advantage
  turns out not to matter in practice.
- It was never merged to firmware `develop` (spike only), so retiring the firmware
  half costs nothing shipped.

---

## Decisions & open questions

1. **RESOLVED 2026-09-03 - LoRa is the first-class transport; it owns the firmware
   backbone.** BLE is for phones (Phases 1–3). Firmware↔firmware BLE-GATT (Phase 4)
   is *not* a goal - LoRa carries firmware↔firmware. The multi-transport registry
   (Phase 2) is additive and must never demote LoRa or displace it from the send
   order.
2. **Bench bring-up test** - approved to run Phase 3's gate (flash the shared v3
   with `MAX_CONNECTIONS=2`) whenever you want the firmware phase de-risked.
3. **Where does the firmware transport-registry work land** - a fresh spike branch
   off `develop`, or fold into the existing `spike/ble-mesh-transport`?

---

## Prior art carried in

- **SIG Mesh GATT Proxy** - the standard name for the Phase-3 edge. SIG Mesh runs
  data on the *advertising* bearer and uses GATT only as a one-client-to-one-proxy
  edge; a pure connection-oriented GATT data mesh is non-standard there (but not
  novel - it is the scatternet lineage, and it *ships*: FruityMesh/BlueRange on
  nRF52, Bridgefy on phones at protest scale).
- **Managed flooding + explicit dedup** is the right routing model on point-to-
  point links (you cannot overhear, so implicit suppression is gone): `(source,
  seq)`/message-id cache + TTL + not re-sending to the peer it arrived from, moving
  toward gossip/anti-entropy.
- **Bridgefy's lesson** (invariant 4): never relay before validate.
- **Power, counterintuitive:** a well-tuned persistent BLE link (<10 µA at long
  interval) is cheaper than scanning for beacons (~5–6 mA), but that interval
  costs ~one connection-interval of latency per hop (≤6 s facing Apple centrals).
  Throughput is the real win of connections over advertisements: a negotiated MTU
  (247 B+) with LL retransmit on 37 hopped channels vs blind unacked rebroadcast
  on 3 advertising channels.

Full research with citations: `scratchpad/ble-gatt-mesh-findings.md` (session
2026-09-03).

## LoRa transport spike (parallel, `meshtastic-node-kmp` `feat/lora-transport`)

Kicked off 2026-09-03 as a background workflow (research → design → adversary →
implement → verify): a `node-transport-lora` KMP module (CH341A USB-SPI bridge →
SX1262, Android + JVM), one protocol shared with every bearer. **State: COMMITTED
on `feat/lora-transport`, tests green.** 10 commits on top of `main` (`8520a42`),
tip `17c6444`, 56 files +5333/−38, tree clean, **not pushed**; primary checkout
`main` untouched.

- **Independently re-verified 2026-09-04** (forced `--rerun-tasks`, not cached):
  `:node-transport-lora:jvmTest` **83/83**, `:node-transport-lora:testAndroidHostTest`
  **83/83**, 0 failures; `detekt` + `apiCheck` clean; `:monitor-android` debug APK
  built (~16 MB). The 4 failures seen in a mid-flight snapshot were the ones this
  note previously listed - the implementer fixed all four exactly as diagnosed
  (the SX1262 DIO1 mask stays `0x0201` = TX_DONE|TIMEOUT per RadioLib, the test
  vector was corrected; the airtime test now judges at t=61 s and a new test pins
  that our own TX counts toward channel-util).
- Module shape: commonMain (`spi/SpiBus`, `ch341/*`, `sx1262/*`, framing, modem
  presets, region table, channel-slot plan, airtime gates, config, transport
  actor loop), androidMain (USB-host backend + `usb_device_filter.xml`), jvmMain
  stub, commonTest (byte-exact CH341/SX1262/framing/preset/airtime/transport),
  androidDeviceTest (on-device bring-up tests, not run), monitor wiring + docs.

**Caveats (do not overstate):**
- The workflow's **independent code-review agent never ran** (`verify:review-1`
  hit the session limit). Tests + lint are green and I re-ran them, but no
  adversarial second-pass review of the code has happened - worth one before a PR.
- **No hardware.** Nothing has touched a Meshtadpole; the Android USB path compiles
  into the APK but is unexercised. Pin map, TCXO/DIO2 switch, CH341 SPI clock, and
  whether a Pixel 6a OTG port sustains 10/22 dBm are the open on-device checks.
- Two small node-core deferrals noted by the implementer: `InboundFrame.snr`
  (needs a native klib dump regen; SNR currently on `LoraTransport.lastReception`)
  and `:monitor:detekt` not in the gate.

Resume: an adversarial code review, then the on-device bring-up (Pixel 6a +
Meshtadpole stick), then push / PR.

## Full bench test - all working transports (2026-09-04)

heltec-v3 running the cleaned per-peer firmware (`ea24b26d5`), verified live on
the bench (LoRa + a Pixel 6a `node-kmp monitor` GATT peer):

- **LoRa (transport 0):** RX + TX. Receives packets and relays them (`Lora RX …`
  → `Started Tx …`).
- **BLE advertisement (transport 9, `[BLEMesh]`):** RX. Hears the same nodes over
  BLE advertisements with RSSI (`BLE mesh RX from=… rssi=-76`).
- **BLE-GATT mesh-peer (transport 10):** egress to phone PROVEN. The Pixel app's
  rx counter advanced (2 → 6) and it **decoded** frames at the mesh layer - a
  position from a LoRa node and a **text** "probe from !b28c3748", plus opaque
  channel-50 frames from the v3 itself (`!d1d90f21`).
- **Cross-transport dedup:** one packet id arriving via LoRa **and** BLE-adv is
  deduped by (from,id) - the multi-bearer mesh working as designed.
- **Bridging:** LoRa / BLE-adv → phone over GATT, proven (the phone receives
  frames that originated on LoRa). Stable, no crashes across the windows.

**Not verified on-device (harness limits, not transport bugs):**
- **BLE-GATT ingress (phone → mesh):** the monitor app's Compose "Send test"
  button does not register adb/synthetic taps (app tx stayed 0 through
  android_tap / `input tap` / `input swipe`), and the Mac (bleak) accumulated a
  stale BLE bond (`CBError Code=14 Peer removed pairing information`) that blocks
  reconnect to the v3's stable identity address across RPA rotations and reboots.
  The ingress path (reassembly, ingress guards, router enqueue) is covered by the
  26 passing native tests.
- **UDP / MQTT:** enabled in the registry (`enabled_protocols=7`) but WiFi is off
  and there is no second UDP peer on the bench to bridge against.

**Bench cleanup still owed on the v3:** `network.wifi_enabled=true`,
`enabled_protocols` 7→3, `bluetooth.mode=RANDOM_PIN`, reboot.

## Desktop UDP monitor added - four bearers meshing (2026-09-04)

Started the `:monitor` Compose desktop app on the Mac (`direnv exec
meshtastic-node-kmp gradle-queue -- :monitor:run`). Its transport is
`UdpMulticastTransport` (239.0.0.69:4403, matching the firmware's
`UdpMulticastHandler`). Enabled the v3's WiFi (`network.wifi_enabled=true`, stored
PSK untouched); it came up on 192.168.1.180 with `UDP multicast already running`,
same /24 as the Mac (192.168.1.138), so multicast bridges.

Live result - the v3 bridges **LoRa + BLE-advertisement + BLE-GATT + UDP** at once:
- **Desktop (UDP node `!a6e88506`):** rx 7, tx 5, **peers(1) `!d1d90f21` (the v3)**.
  Receives the LoRa node `!3061b02e` bridged onto UDP and the v3's own frames;
  sends its own probes (the Send-test button works via cliclick at logical
  1500,971 - the desktop app can transmit where Android's Compose button ignores
  synthetic taps).
- **Pixel (BLE-GATT node `!6337995d`):** rx 11, tx 3. Decodes a position and a
  text ("probe from !b28c3748") plus opaque channel-50 frames; auto-sends its own
  probes (BLE-GATT **ingress** confirmed - tx advances).
- A LoRa node's frame (hop>0) reaches **both** monitors across two different
  bearers - the "one protocol, many bearers" bridge, with (from,id) dedup.
- The monitors do not relay each other's own probes: those carry hop_limit 0
  (RelayPolicy.Island), so the v3 accepts them locally but does not re-flood -
  correct mesh behaviour, not a transport failure.

**Follow-up finding:** the Pixel logs `rx: dropped !00000000 id=0 (MALFORMED)`
paired with each valid LoRa-bridged frame - a spurious empty/duplicate frame
reaches the GATT peer alongside the good one (likely the same packet arriving via
two internal paths). The valid frames get through; worth chasing before PR.

**Bench cleanup still owed on the v3:** `enabled_protocols` 7→3,
`bluetooth.mode=RANDOM_PIN`, reboot. (WiFi now intentionally on for the UDP node.)


## LoRa via Meshtadpole on Android - PROVEN on hardware (2026-09-04)

A Meshtadpole (WCH CH341A `1a86:5512` + Semtech SX1262) plugged into the Pixel 6a
over USB-C OTG, `:node-transport-lora:connectedAndroidDeviceTest` run against it:

- **`LoraListenDeviceTest.hearsTheAirForSixtySeconds` PASSES.** The Kotlin SX1262
  driver claimed the CH341 over the Android USB host API, read the chip
  (`SX1261 V2D 2D02`), brought the radio up on **US LongFast, 906.875 MHz, slot
  19/104, 10 dBm**, and **decoded three real over-the-air packets** from node
  `!3061b02e` (the same node the bench v3 hears): `rx=3, rxCrcBad=0, rxTooShort=0,
  rxDropped=0, usbErrors=0`, RSSI -56..-10, SNR ~6. So the whole stack - CH341
  bulk SPI, SX1262 config + RX, the 16-byte header decode - works on device.
- The USB permission is a one-time system dialog (tap Allow); after that the
  grant persists.
- **Not yet exercised:** transmit. It is gated behind
  `-Pandroid.testInstrumentationRunnerArguments.meshLoraTx=1` (a regulatory
  safety gate - a test run must never key up by accident). `Ch341ProbeDeviceTest`
  failed only with `claimInterface refused` - a stale USB claim left by the listen
  test / earlier attempts, not a transport bug (the listen test claimed fine).
- One-line fix landed to make the device tests compile at all (`ed37488`): the
  never-built `androidDeviceTest` used `.onEach{}.collect()` with the no-arg
  terminal unresolved.

So the answer to "does the LoRa transport work via Meshtadpole on Android": **yes,
receive is proven on hardware.** Transmit is the remaining on-air check, behind
its safety flag.

### Transmit also PROVEN - round-trip on the air (2026-09-04)

Ran the transmit test with its safety flag:
`connectedAndroidDeviceTest -Pandroid.testInstrumentationRunnerArguments.class=…LoraTransmitDeviceTest
-P…meshLoraTx=1 -P…meshLoraRegion=US`.

- Meshtadpole (Android node `!0a11ce`) **keyed up and sent** one frame:
  `lora: tx ok len=41 toa=559ms`, `sendText -> true`, `tx=1 txTimeouts=0 txRefused=0`,
  US LongFast 906.875 MHz, 10 dBm.
- The **bench v3 received it over the air and decoded it**:
  `[RadioIf] Lora RX (id=0x3f9f04e6 fr=0x000a11ce … len=41 rxSNR=6.75)` →
  `[Router] Received text msg from=0x000a11ce, msg=node-kmp lora probe` →
  `Forwarding to phone`. Exact text the test sent.
- So `node-transport-lora` on Android is **bidirectional on real hardware**:
  RX (3 packets) and TX (a decoded text landed on a separate LoRa node). One
  cosmetic hiccup: a single `USB error, bulk IN failed (-1); retrying in 3000 ms`
  right after TX (the RX poll immediately after keying up), self-recovers - worth
  a look but not a functional fault.

**Net: the LoRa-via-Meshtadpole transport works on Android hardware, both
directions.** Since then: merged to `main` (`ed37488`) and wired into the monitor
(`9bdb634`), where its status line reads e.g. `906.875 MHz rx-only 23/0 -8 dBm
6.0 dB` and it carried 29 rx in one bench sitting. Still open: the probe test's
stale claim (`claimInterface refused` when run after the listen test - the same
wedge shows in the monitor as `SX1262 command 0x80 failed, status 0xf7` retrying
forever until a reinstall/replug) and the post-TX bulk-IN retry.

## Monitor instrumentation: per-bearer stats, tagged traffic, toggles, tuning (2026-09-04)

With four bearers in one node, `opaque from !3061b02e` said nothing useful - the
same frame arrives on several media and nothing showed which. `755e346` makes the
bearer visible end to end:

- `MeshTransport.name` (`udp`, `ble-adv`, `gatt`, `lora`); every rx-derived
  `MeshEvent` carries `via`; `Relayed.via` lists the bearers a relay went back out
  on; `MeshNode.transportStats` is a `StateFlow` of rx/tx/relayed per bearer, rx
  counted **before** dedup (three media = three rx, one event). `broadcast()`
  returns the carrying bearers' names instead of a Boolean.
- The monitor: a transports card - one row per bearer the platform can build, an
  on/off chip, live counters; an unticked transport is never handed to the node.
  A collapsible tuning panel behind one `TransportTuning` bundle: relay on/off +
  hop limit + contention slot; GATT role and PHY (1M/2M - Android asks, iOS
  negotiates 2M itself, the firmware answers 1M on S3/C3 by design); LoRa region / preset / tx power /
  relay-on-air / rx-only / rx-boost / airtime / slot# / MHz override; UDP group /
  port. Chips apply at once; typed values stage, then apply together (a rebuild
  per keystroke would churn the LoRa USB claim). Log lines lead with direction and
  bearer: `rx[lora] …`, `tx[gatt,ble-adv,udp] …`, `relay[gatt,ble-adv] …`.
- **The monitor node had been `RelayPolicy.Island` (the library default) since it
  was written and never relayed anything.** The relay chip is the first time it
  bridges.

**Proven live on the Pixel (Android 17):**

```
tx[gatt,ble-adv,udp]  probe from !6337995d
rx[lora]              opaque from !3061b02e (chan #50)
relay[gatt,ble-adv]   !3061b02e id=1188083055 hops=3
rx[ble-adv] / rx[udp] / rx[lora]  dropped !3061b02e id=… (DUPLICATE)   ← one frame, three bearers
relay suppressed !d1d90f21 (beaten by 101)                             ← cancel-on-overhear
```

Counters at one point: `lora 23/0/0 · ble-adv 15/1/0 · udp 9/1/0 · gatt 0/1/0`
(LoRa rx-only under `UNSET`). A real over-air peer was learned (`!d1d90f21 🌵`).
`relayed` mostly stays 0 alongside `relay suppressed` lines - that is correct: a
nearer node wins the contention race; the `relay[gatt,ble-adv]` line is one the
Pixel won.

**Three nodes, three bearers:** the desktop monitor (`!a6e88506`, UDP only)
logged `rx[udp] text chan from !6337995d: probe from !6337995d` - the Pixel's
probe - while the Pixel's own `udp` tx was 0, so the only path was Pixel
→GATT/BLE-adv→ V3 →UDP→ desktop.

**The bug the instrumentation found, and a claim retracted:** "Android runs all
four transports" was wired-but-dead for UDP - `udp 0/0` on the Pixel while the
desktop on the same /24 heard everything, and a probe left as `tx[gatt,ble-adv]`.
I attributed that to Android 17 local-network protection and added the
`ACCESS_LOCAL_NETWORK` grant (`1b1d68a`), after which `udp` went 0/0 → 9 rx / 1
tx. **That attribution was wrong** - see the correction at the end of this
document; the permission is right to hold but is not what fixed it, and what did
is still unexplained. It hid for hours because `MeshNode.events` does
`transport.incoming().catch { }`, so a transport that fails to open is
indistinguishable from an idle one - which the next section makes visible, though
less than it first appeared.

**Desktop launch:** `:monitor:run` never exits and pins a shared gradle-queue
slot; `createDistributable` needs jpackage and fails under the Nix shell. The
uber jar (`:monitor:packageUberJarForCurrentOS` → `java -jar …/MeshMonitor-*.jar`)
is the one-command launch - once BouncyCastle's signed `META-INF/*.SF|DSA` are
stripped (`8427db6`). That exclude first did nothing because under Gradle 9
`org.gradle.jvm.tasks.Jar` is not a subtype of `org.gradle.api.tasks.bundling.Jar`
(memory `gradle9-jar-task-type-split`).

## The `gatt` rx = 0 hunt, and what the reviews found (2026-09-04, late)

Run as a workflow: a read-only diagnosis ∥ an event-model implementer → a GATT
fix → three review lenses. All of it is committed to node-kmp `main` and the
spike branch; **nothing is pushed and nothing is flashed**.

**The answer was not the notify path.** The Pixel's GATT central had connected to
three peers across the whole window - **all of them the iPad** (random addresses,
the 10-service Apple GATT database, two name-resolved as "iPad") and **never to
the V3's public address**. Subscribe worked on every one of them
(`setCharacteristicNotification` → `gattc_inform_notification_handle handle:
0x65`). So "gatt tx accepted by a peer" was writes into the iPad's monitor, which
originates nothing - hence rx 0 - and the V3 simply was not a GATT peer at all.
Its connectionless set (instance 1) was on the air, its connectable mesh-peer set
(instance 2) was not.

Radio-side cause, inferred from the code (**medium confidence - the V3's console
was never read**): `BLE_GATT_MESH_MAX_LINKS` is 1, and `onSubscribe()` flagged
*any* link that wrote the mesh CCCD as `viaMeshAdv`. That flag does two jobs -
the slot count `startAdvertising()` gates on, and the early return in
`NimbleBluetoothServerCallback::onDisconnect` that skips the phone-API re-arm.
Both sets advertise the same public address, so a central that finds instance 2
can land its CONNECT_IND on instance 0. Once the iPad took the slot and the
Pixel's link dropped on a monitor rebuild, instance 2 was "slots full" (at
LOG_DEBUG, the only trace) and instance 0 was never re-armed: both dark until
reboot.

Fixed in firmware `9f54363` + `7153c78`: `onSubscribe` sets `subscribed` only,
`viaMeshAdv` means solely "arrived on instance 2"; re-arm on every drop with
`startAdvertising()` deciding; the slot-full line is LOG_INFO and names the
holder. Then the reviews found the re-arm change had made a pre-existing
check-then-act race matter more - the count is read under lock, the `ble_gap`
calls are made outside it (holding the lock across them deadlocks against the
host task), so a CONNECT can take the slot after the count said it was free and
leave the set advertising with no room. The slot-full branch now stops such a
set and the CONNECT path asks for the re-arm that reaches it, so the state
converges on "slot held, set off". `onDisconnect` also no longer logs or re-arms
for a handle the table never held.

Client side, `3e49c60`: `GattLink.status` - the peers we are a central to with a
`PENDING | ENABLED | REFUSED` verdict on our subscription to each, who is
subscribed to us, and the link's `lastFault`; Android stopped ignoring the CCCD
write result and gained `onScanFailed`; the dashboard shows a `GATT:` line and
logs `gatt links: …`. That line is what would have answered this in a minute
instead of a session: the peer list is by node id, so it showed the V3 as a peer
whose frames all arrived on other bearers.

**The two event-model gaps, from the same run:** `602e8db`
`MeshEvent.TransportFailed` + a `failures` counter (a dead bearer can no longer
pass as idle - the red `! n` column), and `74d1281` `MeshEvent.Sent(id, to, via,
kind)` from one `originate()` path shared by `sendText` / `announce` /
`acknowledge`, replacing the before/after stats diff behind `tx[…]`.

**What the reviews caught in that work** (all fixed: `7264d9e`, `d00c246`,
`69423cc`):

- **The hardware proof tests had been silently broken by the new event kinds.**
  `FirmwareInteropTest`'s "decrypts live traffic" and `BleMeshLiveTest` waited
  for the first event that was *not* `Dropped` or `Opaque` - a negative predicate
  now satisfied by the node's own `announce()` reporting itself every 10 s, or by
  a `TransportFailed` from the very dead bearer the event was added for. Both
  would have passed on zero bytes from the radio. They are env-gated and never
  run in the gate, which is how it slipped. Positive predicates now.
- **`TransportFailed` could be lost at open** - the failure is emitted *through*
  `deferredEvents` (replay 0), and `merge()` launches the transports side and the
  deferred collector concurrently: a transport that throws immediately takes
  three dispatches to reach its catch, the collector one to register, so on a
  multi-threaded scope the event vanishes and only the counter survives. FIFO
  dispatchers (the test, the monitor's UI scope) made it deterministic, which is
  why nothing saw it. The transports side now waits on
  `deferredEvents.subscriptionCount > 0`.
- **Two vacuous tests.** `expectNoEvents()` is a synchronous `tryReceive`, and
  `MeshNode.events` crosses a `shareIn` hop, so "a send nothing carried raises no
  event" would have passed with an empty-`via` `Sent` going out, and "ignores its
  own frame" with the own-frame guard deleted. `runCurrent()` before each, the
  idiom the relay tests already use. The `failures` assertions now also pin that
  *unsubscribing is not a failure* - a catch that counted the collector's own
  cancellation would mark every bearer failed on every rebuild.
- Diagnostics that could mislead: a not-ready central rendered as `discovering`
  when both platforms record a peer at *connect-issued*, so a connect that never
  completes was described as being in service discovery (`opening` now, and its
  summary test caught the change); and `GattPeerTable`'s "a writer never blocks a
  callback thread", no longer literally true since the `AtomicReference` became a
  `MutableStateFlow`.

**Recorded, deliberately not fixed:** the reviews named a pre-existing firmware
edge in `NimbleBluetooth.cpp`'s disconnect path - a real phone whose CONNECT_IND
lands on instance 2 is flagged `viaMeshAdv`, so its drop takes the early return
and never runs `resetBleSessionState()`, leaving `BluetoothStatus` CONNECTED and
a later phone-API re-arm discarded. The mirror (a mesh client on instance 0
resetting a live phone session) is the residual the fix's own author named. The
suggested guard keys the early return on `nimbleBluetoothConnHandle` too - but
that handle is only set in `onAuthenticationComplete`, so under the bench's
`NO_PIN` with bonding disabled it is never set and the guard would be inert
exactly where it could be tested. Both directions were **narrowed** by `9f54363`;
fixing them properly needs conn-handle-aware session tracking and a PIN-mode
bench, so it is written down rather than changed blind.

## On-device verification, and two claims retracted (2026-09-04, Pixel unlocked)

With the Pixel unlocked, the new diagnostics answered the GATT question in one
reading - and then contradicted two things this document previously asserted.

**Verified on the Pixel (Android 17, node `!6337995d`):**

- **`GattLinkStatus`, and with it the diagnosis.** The status strip read
  `GATT: central=[5C:88:1F:79:AB:E1(ready,notify=enabled,chunk=20)] connecting=[]
  subscribers=[]` while `gatt` rx stayed 0. So **the subscribe succeeded** and the
  peer simply sends nothing - and `5C` has top bits `01`, a *resolvable private
  address*, which the V3 cannot have (it advertises `BLE_OWN_ADDR_PUBLIC`).
  logcat showed **zero** public-address connections and an `iPad` in the
  environment. That is the diagnosis confirmed from the client side without
  flashing anything: the Pixel's GATT peer is the iPad, not the radio.
- **Scan-failure reporting.** With Bluetooth switched off the line became
  `fault: scan failed: SCAN_FAILED_APPLICATION_REGISTRATION_FAILED (2)` - silent
  before `3e49c60`.
- **`MeshEvent.Sent`.** `tx queued: probe from !6337995d` then
  `tx[gatt,ble-adv,udp] text id=3283296145 to=!ffffffff`, tx counter 1. Note
  `gatt` is in the carried list: the write to the iPad is accepted while rx is 0.

**Retracted - `ACCESS_LOCAL_NETWORK` was not the UDP fix.** `dumpsys
platform_compat` on this Pixel reports `ChangeId(365139289;
name=RESTRICT_LOCAL_NETWORK; disabled)`: local-network protection **is not
enforced here**. With the permission revoked and the app relaunched, `udp` still
showed rx 1 / tx 1 and appeared in `tx[gatt,ble-adv,udp]`. So the grant is
forward-looking correctness for when that compat change flips on, and the udp 0/0
this morning remains **unexplained** - the reinstall-and-relaunch that came with
the permission is the untested confound. Check enforcement before blaming it:
`adb shell dumpsys platform_compat | grep RESTRICT_LOCAL_NETWORK`.

**Retracted - `TransportFailed` covers much less than claimed.** It fires only on
an exception out of a bearer's flow. With Bluetooth off, neither BLE bearer threw
(the failure arrived as `onScanFailed`), so `failures` stayed 0 and both rows read
`rx 0 tx 0` - indistinguishable from idle, the very confusion it was added to
remove. Android reports most bearer failures through callbacks, so there it is a
backstop, not the signal; the transport's own `lastFault` is what caught this.
`failures == 0` must not be read as healthy. Corrected in `393384b`.

## The bench session that answered it (2026-09-04, evening) - and three wrong turns

With the V3 on USB, the iPad plugged in and the Pixel on wifi-adb, the whole GATT
question resolved. Read the wrong turns as well as the result: each one was a
confident conclusion from partial evidence, and the bench refuted all three.

### PROVEN: Android ↔ the firmware's mesh-peer service, both directions

- **Radio → phone.** `rx[gatt] dropped !3061b02e id=31180880 (DUPLICATE)` landing
  210 ms after the same frame arrived on LoRa - the V3 relaying the WisMesh
  Pocket's traffic to the phone over the mesh-peer notify path, deduped against
  the other bearers. Counter reached `gatt 15 rx`.
- **Phone → radio.** `BLE GATT mesh RX from=0x6337995d to=0xffffffff len=45` then
  `Received text msg from=0x6337995d, msg=probe from !6337995d`, for **six
  consecutive sends** with the node reaching 93 s uptime.
- The client's own new link line proves the peer is the radio and not another
  phone: `GATT: central=[34:B7:DA:62:18:C5(ready,notify=enabled,chunk=514)]` -
  `34:B7:DA` is an Espressif OUI, top address bits `00` = public.
- Firmware-side, `9f54363`'s fix is visible working: `conn 3 subscribed (via
  mesh-peer advertisement)` and, on a link that landed on instance 0 instead,
  `conn 1 subscribed (via phone-API advertisement)` - `subscribed` set,
  `viaMeshAdv` left alone, which is exactly the conflation that commit removed.

### FIXED: the Apple-central controller assert (`fcc3c0582`)

The iPad, on a fresh build, could not connect at all: **the V3's BLE controller
asserted ~200 ms after an Apple central connected**, before service discovery or
the CCCD write, and rebooted - 0 of ~170 connects survived. Decoded from 22
captured backtraces (`addr2line` against the flashed ELF), 11 sharing one
signature:

```
r_llc_rem_phy_upd_proc_continue_eco
f_ll_phy_update_ind_handler / ll_phy_update_ind_handler_hack
r_lld_llcp_rx_ind_handler_hack / r_ke_task_schedule_hack
```

That is the controller's **remote-PHY-update** procedure, inside Espressif's own
errata routines, and it matches the `BLE assert lld_con.c 3397` printed alongside
- Espressif's open **esp-idf#15311**, same assert string, same PC. It reproduces
on **stock develop and the nightly** with the stock iOS app, so it was never the
spike's doing. Everything else was eliminated on the bench, one held-open serial
port as the witness: the serial link itself (crashes with the port closed too),
the mesh-peer service (the phone-API set crashes), the host's
`LL_CFG_FEAT_LE_2M_PHY`/`CODED_PHY` flags (host-only; the S3's link layer is the
binary controller), the controller's `BT_CTRL_BLE_LLCP_*` "terminate on Instant
Passed" flags (1 survivor in 27), and a newer controller blob (the
`lib_esp32c3_family` commit is identical through IDF v6.1). A Pixel calling
`setPreferredPhy(2M)` negotiates 2M and never crashes it, so the trigger is what
the A16 does inside the procedure - the Link-Layer quirks esp-idf#18884 lists for
this iPad - not the procedure itself.

**The fix is Apple's own guidance for accessories: indicate 1M-only PHY
preferences.** iOS negotiates 2M at the controller level and apps cannot change
it. NimBLE's `ble_gap_set_default_le_phy()` is compiled out of the prebuilt host,
but `ble_hs_hci_cmd_tx` is exported, so `NimbleBluetooth::setup()` now sends HCI
`LE Set Default PHY` (1M/1M) once `ble_hs_synced()`. Result: 9/9 iPad connects
survive, subscribe, and carry frames (`BLE GATT mesh RX from=0x9ebca8df`); the
boot counter did not move. iPadOS 26 stays on 1M rather than dropping the link.
Cost: iOS phone-API links run at 1M on S3/C3. Owed: cherry-pick to a develop PR,
nudge esp-idf#15311 with the peer-initiated variant and the stock repro.

### NOT POSSIBLE: the desktop monitor over GATT

**Superseded on Linux (2026-09-05):** `GattLink.jvm.kt` now picks `BluezGattLink`
there, so a Linux desktop has both GATT roles. The `UnsupportedGattLink` claim
below still holds for macOS and Windows JVMs; its last sentence does not, since
the desktop gained LoRa and no longer depends on the V3 for a testable bearer.

`GattLink.jvm.kt` is `UnsupportedGattLink` - `canTransmit = false`, an empty
inbound flow. The JVM has no BLE, so the desktop dashboard shows a `gatt` row that
can never move. macOS *does* have a real CoreBluetooth path through
`appleMain`/`macosArm64` (what `GattLiveTest` uses), but the Compose desktop app
is a JVM target and never reaches it. Desktop's testable bearer is UDP, which
needs the V3's WiFi on - and that turns BLE off, so the two cannot be tested in
one sitting.

### The three wrong turns

1. **"gatt rx = 0 is a firmware slot-conflation bug."** The client-side evidence
   was right (the Pixel's only GATT peer was the iPad; zero public-address
   connections) but the cause was mine: **I had turned the V3's WiFi on that
   morning to make it a UDP peer, and on ESP32 that disables BLE entirely.** The
   V3 had had no BLE for hours. This document had asserted "on this S3 build WiFi,
   BLE and LoRa run together" as fact; the README documents the exclusivity.
2. **"The fragment burst at chunk=20 is crashing the radio."** The MTU findings
   are real - Android never called `requestMtu`, and `GattPeerTable.ready()`
   clobbered the negotiated value back to the floor, so every packet fragmented to
   20 bytes; fixed and verified as `chunk 20 → 514`. But it is a *throughput* fix.
   Six clean writes afterwards looked like proof it had fixed the crash; the iPad
   then crashed the radio with **zero** writes.
3. **"`TransmitHistory::setLastSentToMesh` does flash I/O and starves the BLE
   controller."** Built on decoding exactly **one** of 22 backtraces - a
   littlefs/flash stack that appeared once and was a coincidence. The board also
   stayed up 75 s past its first-save window and still crashed on the next Apple
   connect. Upstream `TransmitHistory` is not implicated.

The lesson worth keeping: decode **every** backtrace and count the signatures
before naming a cause. One stack out of 22 produced a whole false narrative, and
`addr2line` against the flashed ELF settled in minutes what three rounds of
hypothesising could not.

### Bench state left behind

V3 on spike `c7fa0e2` (`7153c78` reverted - it was never the cause), WiFi **off**
so BLE is up, no BLE peer connected, stable. The iPad's MeshMonitor and the
Pixel's monitor are both stopped. Still owed: `enabled_protocols` 7→3,
`bluetooth.mode` back to `RANDOM_PIN`, and a decision on WiFi (BLE **or** WiFi,
never both on this build). `BLE_GATT_MESH_MAX_LINKS` is 1, so only one phone can
hold the mesh slot at a time - the radio now says so at LOG_INFO
(`peer slot held by conn N (1/1), not advertising`).

## Parity and coverage plan (2026-09-05)

The bearers are proven; the node behind them is not yet a peer of the firmware
in what it *does*. Two gap sets, kept separate because they are fixed by
different work: **which bearers each platform can carry**, and **what the node
does with a packet once it has one**. Sources: the module source sets and
`README.md` "Not yet here" in `meshtastic-node-kmp`, `src/modules/` and
`src/mesh/` in `firmware`, checked 2026-09-05.

### A. Bearer coverage by platform

Updated 2026-09-05, after the parity sitting closed most of it. The JVM desktop
is now two platforms, not one, so it gets two columns.

| Bearer | Android | iOS | macOS (native) | Linux JVM | macOS/Windows JVM | Firmware |
| --- | --- | --- | --- | --- | --- | --- |
| BLE-adv rx | ✓ | ✓ | ✓ (`appleMain`, test-bench only) | ✓ BlueZ, **proven** | none (BlueZ is Linux-only) | ✓ |
| BLE-adv tx | ✓ | **impossible** (CoreBluetooth cannot advertise arbitrary data) | impossible | ✓ built, **blocked by the adapter** | none | ✓ |
| GATT mesh-peer (dual role) | ✓ | ✓ | ✓ (`appleMain`) | ✓ built, **not yet run** | none | ✓ S3, ✓ nRF52 |
| UDP multicast | ✓ | ✓ built, **needs entitlement** (`com.apple.developer.networking.multicast`) | ✓ | ✓ | ✓ | ✓ (WiFi/eth) |
| LoRa (USB SX1262 stick) | ✓ | impossible (no USB serial) | ✓ (libusb, **proven**) | ✓ (libusb) | ✓ (libusb, **proven** on macOS) | native |

So today: Android 4/4; iOS GATT + adv-rx + UDP-pending-entitlement; Linux JVM
4/4 by construction with adv-tx blocked on one adapter; macOS/Windows JVM UDP +
LoRa. The remaining desktop gap is BLE on the two JVMs BlueZ cannot serve, and
that is what [`desktop-ble-plan.md`](./desktop-ble-plan.md) is for. Enablers, in
cost order:

1. **Desktop LoRa** - done. `UsbBulkPipe` over libusb, JNA rather than usb4java
   (no `darwin-aarch64` native, last release 2018). The SPI/SX1262 layer is shared
   with Android. Proven with the Meshtadpole on the Mac.
2. **Desktop BLE (Linux)** - done in code. BlueZ over D-Bus gives both GATT roles
   *and* extended advertising. Scanning is proven on `james-pc`; advertising is
   refused by that host's controller (`bluetoothctl` fails identically), and the
   GATT roles have not been exercised on Linux hardware yet. macOS and Windows
   need a different path entirely, since BlueZ is Linux-only.
3. **iOS UDP** - written and in `commonMain`; the multicast entitlement is Apple's
   gate and this project does not hold it. External, not code.
4. **iOS background** - `bluetooth-central`/`peripheral` modes are declared; the
   node has never been exercised backgrounded. Test, then fix what stops.

### B. Node-logic parity with the firmware

**This is the gap survey taken *before* the work, kept as the record of what was
missing.** Every Tier-1 row and the Tier-2 traceroute, waypoint, neighbour-info
and MQTT rows were closed the same day; the "node-kmp today" column below
describes the morning, not now. What actually landed: "Tier-1 parity implemented
end to end" at the end of this file. Still open from this table: next-hop relay
semantics (Tier 2), and all of Tier 3.

What `node-core` did that morning: protobuf codec; channel AES with PSK and channel
URLs; PKI **nonce only** (no PKI DM encrypt/decrypt); dedup (`PacketHistory`);
hop-limit relay with contention window and cancel-on-overhear (`RelayPolicy`);
a `NextHopTable`; ACK **sending** (`acknowledge`) but no retransmission; an
in-memory bounded `NodeDirectory` (num, names, key, last heard, rssi);
identity derived from a host-persisted seed; decode of TEXT_MESSAGE, ROUTING,
NODEINFO, POSITION; manual `announce()`. Events: TextMessage, PositionReport,
PeerUpdated, Opaque, Dropped, Relayed, RelaySuppressed, Sent, Delivered,
TransportFailed.

| Capability | Firmware | node-kmp today | Gap | Tier |
| --- | --- | --- | --- | --- |
| Persistent NodeDB | `NodeDB` + `WarmNodeStore`, migrations | in-memory `NodeDirectory` | a persistence seam (host-supplied store), load/save, expiry | **1** |
| Persistent config (channels, region, node settings) | protobuf prefs on flash | `Config(channels, transports)` in memory | same seam; the monitor's `TransportTuning` is the prototype | **1** |
| Reliable delivery (`want_ack` retransmit, NAK) | `ReliableRouter` | ACKs sent, none retransmitted | retransmit queue with backoff, `Delivered`/failed events | **1** |
| Periodic NodeInfo / Position broadcast | `NodeInfoModule`, `PositionModule` (smart position) | manual `announce()`, no position source | schedulers + a host position seam | **1** |
| Telemetry (device/env metrics) | `TelemetryModule` family | not decoded | decode + `PeerUpdated` fields; send device metrics (battery) | **1** |
| PKI direct messages | `CryptoEngine` X25519/AES-CCM | nonce only | full encrypt/decrypt, key verification event | **1** |
| Routing errors / NAK surfacing | `RoutingModule` | partial | `RoutingError` event with reason | 1 |
| Next-hop / directed relay | `NextHopRouter` (`relay_node`, `next_hop`) | table exists, use unclear | audit against firmware semantics; parity test vs a radio | 2 |
| Traceroute | `TraceRouteModule` | none | request + reply, per-hop SNR | 2 |
| Waypoints | `WaypointModule` | none | decode/encode + event | 2 |
| Neighbor info | `NeighborInfoModule` | none | decode + directory neighbours | 2 |
| Remote admin (session keys) | `AdminModule` | none | large; needed only if a phone node administers radios directly | 3 |
| MQTT bridge | `MQTT.cpp` (uplink/downlink, JSON) | none | the phone as an internet bridge - a bearer in its own right (Phase 4 material) | 2 |
| Store & forward (client) | `StoreForwardModule` | none | history request on join | 3 |
| Hop scaling / traffic management | `HopScaling`, `TrafficManagement` | none | follow firmware behaviour once relay is used in the field | 3 |
| Canned messages, range test, detection sensor, remote hardware, screen, ATAK plugin | modules | n/a | UI or hardware concerns; not node logic | - |

**Tier 1 is "a node you could leave running"**: it remembers who it heard and
what it is, keeps its config, tells the mesh it exists on a schedule, delivers
reliably, and can DM. Everything in Tier 1 is verifiable on the bench today:
Pocket + Pixel + iPad, with the radio as the oracle for every wire behaviour.

### C. Sequence

1. **Persistence seam** (NodeDB + config): interface in `node-core`, host
   implementations in the monitor (Android files / desktop files / iOS files).
   Unblocks everything that must survive a restart.
2. **Reliable delivery**: retransmit with the firmware's backoff, `Delivered`
   already exists, add the failure event. Verified: DM to the Pocket with the
   iPad link dropped mid-way must retry and land.
3. **Scheduled NodeInfo + Position + device Telemetry**: the node appears in the
   stock app's node list with a battery and a position, like a radio does.
4. **PKI DMs**: encrypt/decrypt + a key-verification event. Verified against the
   Pocket both ways.
5. **Desktop LoRa** (libusb), then **desktop BLE** (BlueZ) - the Linux gateway.
6. **Traceroute, waypoints, neighbor info** - decode parity.
7. **MQTT bridge** and **iOS UDP** - Phase 4 bearers.

### D. Integration: the node is a radio

Every consumer that could host the node already talks to a radio through one
contract, the phone API (`ToRadio`/`FromRadio` protobuf stream):

| Consumer | Seam today | State |
| --- | --- | --- |
| Android app | `IRadioInterface` implementations (BLE/TCP/serial/mock) feeding `RadioTransportCallback.handleFromRadio(bytes)` | imports nothing from `meshtastic-sdk` |
| Apple app | `Accessory/Protocols/Transport.swift` (discover → connect) and `Connection.swift` (`send(ToRadio)`, `AsyncStream<ConnectionEvent>` of `FromRadio`) | no SDK dependency |
| `meshtastic-sdk` | `RadioTransport` (`send(Frame)`, `frames(): Flow<Frame>`, identity, state) chosen with `RadioClient { transport(...) storage(...) }`; its `MeshNode` wraps the wire `NodeInfo` | not consumed by either app yet |

**Status (2026-09-05).** The server exists: `node-phone-api` (`StreamFrame`,
`LocalRadio`, `PhoneApiSession`, JVM `PhoneApiTcpServer` on 4403), served by
the desktop monitor whenever its node runs. Proven with the Python CLI
(`--host`) and the stock Android app over TCP: both handshake stages, a held
link, a typed message on the air. Not yet: the three adapters below and
`AdminMessage`. Lessons: the dump must be shaped by the nonce (69420 omits
other nodes, 69421 sends only node infos - a `my_info` there resets the
Android app to stage 1); and the node must never be silent for 90 s, so the
session answers heartbeats and emits a `queueStatus` every 30 s.

So the integration primitive is **a phone-API server inside `node-kmp`**: one
`commonMain` `LocalPhoneApi` that implements the firmware's `PhoneAPI`/`StreamAPI`
state machine - `want_config` → `MyNodeInfo`, `DeviceMetadata`, one `NodeInfo`
per entry of the node's NodeDB, `Config`/`ModuleConfig`/`Channel`,
`config_complete`; inbound `MeshPacket`s as `FromRadio`; `ToRadio.packet` →
`MeshNode.send`; `AdminMessage` for local settings (owner, channels, region) →
the node's `Config`; `queueStatus`, `rebooted`, `logRecord`. Three thin adapters
around it, each a few hundred lines:

- Android: an `IRadioInterface` ("local node") beside BLE/TCP/serial, selectable
  like any radio. The app's Room NodeDB, messaging, channels and settings UI work
  unchanged, because to the app this *is* a radio.
- Apple: a `Transport` + `Connection` pair backed by the node-kmp iOS framework
  the monitor already builds.
- SDK: a `transport-local-node` module implementing `RadioTransport`, for when an
  app adopts the SDK.

**What this settles.** The two NodeDBs are not copies. The node's own DB is the
mesh-layer record of what *it* heard, exactly the firmware's `NodeDB`; the app's
is the client-layer mirror fed over the phone API, exactly as it is fed by a radio
today. Same relationship, same code paths, no new sync. And the node's record
shape should be the wire `NodeInfo` (as the SDK's `MeshNode.raw` already is), so
parity with the firmware's `NodeInfoLite` fields (user, position, snr,
last_heard, device_metrics, hops_away, via_mqtt, is_favorite…) is by
construction, and the phone-API dump is a straight copy.

**What it gives the plan.** The firmware's `PhoneAPI.cpp` becomes the parity
yardstick for Tier 1: everything the config dump must contain is exactly the
state the node must persist (step 1), and every `FromRadio` a stock app expects
(NodeInfo on schedule, position, telemetry, routing ACK/NAK) is a Tier 1 item.
The stock app's own screens become the test oracle: connect the stock Android
app to the local node and it must show the same node list, battery and messages
it shows against the Pocket.

**Two radios.** An app connects to one radio. With the local node as its radio,
a physical radio is reached as a *mesh peer* of the node (GATT mesh-peer or
BLE-adv), giving the app LoRa through the phone node - but the app then no
longer administers that radio directly; that goes over the mesh (remote admin,
Tier 3) or by switching connections. Interim: both paths exist, the user picks
the radio as today. End state to aim for, not to build first.

**Persistence.** The seam from step 1 stays host-supplied (Room on Android,
SwiftData/files on Apple, files on desktop); when the SDK is the host, its
`storage-sqldelight` already persists `NodeInfo` and can hold the node's DB
keyed by the node's identity. `meshtastic-node-kmp` must not depend on the SDK:
the node is the lower layer.

**Sequence change.** Step 0, before the persistence seam: the phone-API server
plus the Android `IRadioInterface` adapter, proven by the stock Android app
connecting to the local node and completing its config handshake. It fixes the
record shape (`NodeInfo`) and the persistence contents at once, and it is the
first moment a stock app can *use* the phone node.

## Tier-1 parity implemented end to end (2026-09-05, `meshtastic-node-kmp` `main`)

The "Parity and coverage plan" above, worked through in one sitting. Every
constant is cited from firmware source rather than remembered; research ran as a
7-agent fan-out over firmware module semantics and node-kmp's own gaps.

### Gate holes closed first (`c14c4b4`, `a8c2afe`, `08f6bfd`, `bf4f4cd`)

Three, each of which had already let a real defect through:

- The `api/` dumps had been stale for four commits. Binary-compatibility
  validation was wired for klib **and** JVM all along; the documented gate never
  named `apiCheck`.
- **Spotless does not read `.editorconfig`.** The 120-column limit it appeared to
  honour is ktlint's own `intellij_idea` default, so every override in that file,
  including two per-file exemptions already sitting there, had never bound.
  Settings that must bind are now an explicit `editorConfigOverride` map.
- The gate ran `jvmTest` and only *compiled* the native targets, which is the
  org's named KMP anti-pattern verbatim. It hid four comma-bearing test names that
  Kotlin/Native rejects, so `gradle build` was broken on `main` for four commits
  while everything read green.

Gate is now `spotlessCheck detekt apiCheck allTests testAndroidHostTest`.

### Slices

- **Identity and keypair persistence** (`ef264e5`, `894bc39`). `NodeIdentityRecord`
  holds the address seed and the X25519 pair as one record written in a single
  save, so "persist the address and the keypair together" is structural rather
  than advisory. The node had **no keypair in production at all**:
  `Config.privateKey` had no caller outside tests, so `LocalRadio` told every
  phone `hasPKC=false`. A failed load is fatal to the node on purpose, because
  minting a replacement discards the address every peer has pinned.
- **Keyless-first eviction** (`ef264e5`). `BoundedLru` evicted strict-LRU, so
  keyless chatter evicted the peers whose keys we hold, the inverse of firmware.
- **`pki_encrypted` derived, not trusted** (`9da2e8e`). `toMeshPacket` copied the
  wire's bit through and never set `public_key`, so anyone holding the channel PSK
  could hand a phone a channel message wearing a private message's lock icon.
- **Telemetry, traceroute, waypoints, neighbour info decoded** (`522e76b`,
  `ccf3677`). All four surfaced as `Opaque`, "could not be read", having in fact
  been read. Nullable fields throughout, because the wire's `optional` exists to
  separate "not measured" from "measured zero".
- **Reliable delivery** (`e9ca481`, broadcasts `5cc41af`). Firmware budgets, 5
  unicast and 3 broadcast total attempts. The hard part is not retrying but
  refusing to stop wrongly: a neighbour's rebroadcast is an implicit ack, our own
  UDP-multicast loopback is not, and `hopsAway` separates them. The broadcast
  budget was unreachable until `5cc41af`, because both senders stripped `want_ack`
  from a broadcast on a rationale that described `want_response`: nothing acks a
  broadcast, in this library or the firmware, so what the flag buys there is the
  retry budget and the implicit ack.
- **Beacon scheduler and `want_response` replies** (`b2dd0fd`). The node never
  announced, so it was invisible in every stock app and its public key never
  travelled. The reply path also stops a radio NAKing us with `NO_RESPONSE`.
- **Self-telemetry over the phone API** (`ccf3677`), bounded by what the node can
  honestly measure: uptime always; battery and voltage only from a host that can
  read them; `channel_utilization` and `air_util_tx` **never**, because they
  describe a shared radio medium and a node on GATT/BLE-adv/UDP occupies no air.
  0.0 there is a claim about someone else's channel being idle.
- **Position beacon with a host seam** (`8814a85`). `PositionSource` is a pull, so
  a phone is never obliged to keep GPS warm. Smart position measures movement from
  the last position **sent**, not the last read: against the last read a slow walk
  never crosses the threshold and 300 m goes unreported. Precision rounds to the
  cell **centre**, so the error is symmetric and the true point cannot be
  recovered from the rounding direction. Off by default.
- **NAKs decoded** (`1edbeef`). A Routing packet carrying an error fell through to
  `Other`, so a rejection was invisible *and* did not stop the retransmit queue.
  Latent bug fixed alongside: the ack test read `error_reason == NONE`, but the
  field is nullable and a plain ack leaves it **unset**, so testing only for NONE
  loses every real acknowledgement.
- **Traceroute answered** (`d74c263`), not just decoded. Follows the firmware's own
  distinctions: append our SNR but **not** our node id (a destination is not a hop
  on the way to itself), the SNR is the reserved "not known" sentinel because most
  bearers measure none, a multi-hop **broadcast** request is ignored, and a reply
  is never answered. Not done, and said so: appending ourselves to a traceroute we
  *relay*, which would need a relayed packet decrypted, rewritten and re-sealed.
  This node relays opaquely by design.
- **Desktop LoRa over libusb** (`393a527`). JNA straight to libusb, chosen by
  running usb4java and watching it die on Apple silicon (no `darwin-aarch64`
  native, last release 2018). Hot-plug is a 1 s poll, not libusb's callback.
- **DUAL-role GATT arbitration** (`393a527`). The obvious "lower nodeNum is
  central" cannot work: a `GattLink` sits below the mesh layer and its peer ids
  are per-connection tokens, not identities. Settled by an in-band HELLO on the
  characteristic the link already has, intercepted in `GattLinkBase` (commonMain),
  so neither platform file changed. Advertising the id was rejected because Apple
  cannot advertise arbitrary payload and a stable advertised id is passively
  trackable.
- **MQTT bridge** (`5b10a80`, `6d33342`), on the org's own MQTTastic-Client-KMP.
  Topic `<root>/2/e/<channelId>/<gatewayId>` read from `MQTT.cpp`; there is **no
  region segment**, `msh/US` is an operator setting `root`, which is the detail
  reimplementations get wrong. The `via_mqtt` anti-loop pair is exact. JSON topics
  deliberately unsupported: firmware PR #10152 removed the JSON libraries.
- **Desktop BLE over BlueZ** (`5b10a80`). Linux gets both GATT roles *and*
  extended advertising. Linux-only and cannot be otherwise; the platform check
  runs **before any BlueZ type is touched**, since dbus-java is on every desktop's
  classpath.
- **iOS UDP** (`5b10a80`). The transport moved to `commonMain` behind a
  `UdpMulticastSocket` seam, with the JVM/Android socket code **moved rather than
  rewritten** and a POSIX actual for Apple. The multicast entitlement is Apple's
  gate and this project does not hold it, so a refused join surfaces as an
  unavailable bearer naming the entitlement rather than a silently dead one.

### Availability seam (`0885f03`, `30d12c4`, `d2d0baa`)

Every bearer published the same thing dead as idle, `rx 0 tx 0 failed 0`, so the
desktop offered four live toggles while only UDP had a backend and an Android node
with Bluetooth off looked untouched rather than broken.

- `MeshTransport.availability: Flow<TransportAvailability>`: `Unavailable(reason)`,
  `NeedsPermission(permission)`, `Ready`, `Active`. Defaulted on the interface,
  the additive shape `name` took.
- Platform seams supply the base. `TransportActivity` in `node-core` adds the one
  fact no platform knows, whether anything is collecting the cold flow, and is the
  only place `Active` is decided. Only a `Ready` base becomes `Active`.
- The two `bluetoothAvailability` helpers live in `node-core` for the reason
  `BleMeshAdvert` does: both BLE modules need them and share no other module.
  Apple's is narrower on purpose, because `CBPeripheralManager.authorization` is a
  class property and reads authorization *without* constructing a manager, and
  constructing one is what raises the prompt. The cost is that Apple cannot see
  the power state, which only a live manager carries.
- `absentTransports()` names bearers a platform never builds. A transport can only
  speak for itself, so iOS silently omitted UDP and LoRa, making "iOS refuses
  this" and "nobody wrote it yet" look identical.
- `MeshTransport.receiveOnly` is a **constant**, for a bearer that can never
  transmit (Apple's advertisement radio). Explicitly *not* `canTransmit`, which is
  a live sample: an Apple GATT link answers false until CoreBluetooth powers on,
  and the Apple availability flow emits once, at start, so sampling `canTransmit`
  cached that transient false and labelled the iPad's healthy `gatt` row "rx only".
  A commonTest holds the line.

### What hardware proved, 2026-09-05

**The beacon, end to end.** Pixel and desktop, both on UDP:
`0:46.657 rx[udp] peer !a6e88506 MON`, and the Pixel's peer list shows
`!a6e88506 MON`. One node announced on its schedule and another listed it by name.

**Desktop LoRa, first run**, Meshtadpole plugged into the Mac:

```
lora: 13374234: SX1261 V2D 2D02 tuned 906.875 MHz LongFast UNSET slot 19/104 power 10 dBm
rx[lora] opaque from !3061b02e (chan #50)
rx[lora] peer !7263cc65 956a
```

The whole chain: libusb load, CH341 enumeration and claim (kernel detach plus
`claim_interface(0)`), the SPI bridge, and the SX1262 driver reading the chip's
version registers and getting real silicon back before tuning it. The endpoint
numbers 0x02/0x82, taken from flashrom rather than measured, are therefore right
in practice. The desktop then held a three-node, two-bearer mesh: the Pixel over
UDP and the WisMesh Pocket over the air.

**LoRa transmit**, region armed to US at James's request, power left at the 10 dBm
default because the stick is bus-powered and 22 dBm browns out an OTG port:

```
tx[udp,lora] data id=3818401404 to=!a6e88506
lora: tx ok len=24 toa=436ms
rx[lora] delivered: !a6e88506 ack req=3818401404
```

Real computed airtime (436-477 ms at LongFast) and **acknowledgements back over
LoRa**, so a real radio received our transmission and answered it. Those
`delivered:` lines are `MeshEvent.Delivered` out of the retransmit queue written
the same day, so reliable delivery is exercised on hardware and not only under
virtual time. `tx[udp,lora]` on one line is a single frame going out on two
bearers at once.

**PKI DM round-trip** to the Pocket, acknowledged by real firmware:

```
lora: tx ok len=56 toa=681ms
dm to !7263cc65 queued: dm probe from node-kmp
rx[lora] delivered: !7263cc65 ack req=3640905761
```

The Pocket could only ack it by decrypting it, so the persisted keypair is real
and usable and PKI DM sealing matches the firmware in practice, not only in a unit
test. 56 bytes against 24-29 for the broadcasts is the PKI overhead.

**GATT arbitration, three DUAL nodes at once.** Mac (Kotlin/Native), Pixel and
iPad, all node-kmp DUAL, all meshing over GATT:

```
Pixel:  central=[5D:9E:6F:0C:22:EB(chunk=514), EF:E2:0A:BE:95:6A(chunk=244)]
        subscribers=[2C:CA:16:30:A7:A2]        <- the Mac won that pair
Mac:    notify state BADA1045 on=true chunk=512
        notify state 6B496E38 on=true chunk=512  <- central to both of its peers
```

Mixed roles, **exactly one per pair**, which is what a per-pair election produces
and what a race cannot: without arbitration the same peer appears in both
`central` and `subscribers`. `gatt rx 11` on the Pixel, so the triangle carries
traffic rather than just roles.

**MQTT against a real broker**, `tools/mqtt-broker` (a loopback-bound mosquitto in
compose, committed, because the public broker feeds the project map and a node
under development should not publish into it). The broker's own log:

```
New client connected as !000a11ce (p5, c1, k30)
Received PUBLISH from !00000b0b, 'msh/2/e/LongFast/!00000b0b', 59 bytes
Sending PUBLISH to !000a11ce,   'msh/2/e/LongFast/!00000b0b', 59 bytes
```

Firmware topic layout exactly, `!%08x` client ids, MQTT 5, a 59-byte
ServiceEnvelope from one bridge to another. `MqttBrokerInteropTest` is env-guarded
(`MESH_MQTT_BROKER`) like the other hardware tests.

**Availability seam on hardware.** The desktop greys three bearers with reasons
and drops the `GATT:` header line; the Pixel's BLE rows flipped from carrying real
frames off `!3061b02e` to `needs permission: Bluetooth to be switched on` the
instant Bluetooth went off, and back on return, which is the live
`ACTION_STATE_CHANGED` path.

**macOS TCC spike.** The `macosArm64` CoreBluetooth binary spawned from a plain
JVM `ProcessBuilder` reaches `state=5` (poweredOn, not the `unauthorized` 3 a
denial gives), advertises, connects and subscribes, in both GATT roles. So the
helper-process bridge for macOS desktop BLE is viable rather than speculative.
Unsettled: it ran from a terminal-launched JVM, so TCC attributed to the terminal,
and a bundled `.app` needs its own `Info.plist` key. Plan:
[`desktop-ble-plan.md`](./desktop-ble-plan.md).

### Still blocked, each on something outside the code

- **BlueZ advertising on `james-pc`.** The adapter refuses every
  `RegisterAdvertisement` with `Invalid Parameters (0x0d)` at any payload size and
  with `SecondaryChannel` removed, and `bluetoothctl` fails identically on the
  same host, so it is the controller or its driver rather than this code. Scanning
  is proven on that machine.
- **iOS UDP without the multicast entitlement.** Apple grants it by application.
  The socket itself is proven on macOS native (11 tests, including a real
  multicast round trip); what is unread is what the iPad's `udp` row says, because
  iOS 26 has no working screenshot path.

### Bench condition worth knowing, not a code defect

UDP multicast is **asymmetric on this network**: the Pixel receives the desktop's
frames, the desktop receives none of the Pixel's (`udp tx 6 rx 0` while the Pixel
reads them fine). Classic wired-to-wireless AP behaviour. It worked on 2026-09-04,
so it is the network and not the transport. Do not diagnose a dead UDP bearer from
it.
