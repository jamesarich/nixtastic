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
delivery, the NodeInfo/Position/telemetry broadcasts, PKI DMs, traceroute answering,
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
| **BLE-adv** (connectionless, ext-adv) | spike ✓ | spike ✓ (rak4631 RX) | ✓ | **RX only** (no TX) | ✓ BlueZ (Linux only; scan proven. Advertising works on a CM5 - `james-pc`'s adapter alone refuses it) |
| **BLE-GATT** (connection, dual-role) | spike ✓ mesh-peer service | spike ✓ mesh-peer service (rak4631_blemesh) | ✓ | ✓ | ✓ BlueZ (Linux only; central proven, **peripheral proven 2026-09-08** - but a central's subscribe to it is refused ATT `0x0E`) |
| **UDP multicast** (LAN) | ✓ (wifi/eth) | ~ (eth) | ✓ | ~ (entitlement) | ✓ |
| **Wi-Fi Aware** (Android↔Android) | - | - | ✓ proven 2026-09-09 | - | - |
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
  **Built and proven on hardware 2026-09-09** (Pixel 6a ↔ Pixel 9 Pro, both
  directions).
- **Apple Wi-Fi Aware - shelved 2026-09-09, researched 2026-09-09.** NAN is a
  Wi-Fi Alliance standard and Apple ships a `WiFiAware` framework, so the "Android
  only" line this workspace and node-kmp both carried was wrong. What is wrong with
  it is a **layer**, not a feature: NAN has a discovery layer (connectionless
  follow-up frames, which is all our bearer uses) and an NDP data path, and Apple
  exposes only the second, only to paired devices. There is no message or datagram
  symbol anywhere in the framework. A mesh bearer cannot prompt to pair each
  neighbour, so this is a **separate transport, not an `actual`** - the call GATT
  already made. Three corrections to what this note used to say: the platforms are
  **iOS 26, iPadOS 26 and Mac Catalyst 26**, there is **no macOS**; the Pixel 9 Pro
  **is** a 4.0 peer on this bench (`isNanPairingSupported=true`, measured
  2026-09-09, where the Pixel 6a on the same build is false); and the Android↔Apple
  NDP failures are sourced to Apple-forum radars FB18751572, FB19568037, FB19570341
  and FB19683706, all from 2025 and not re-verified since. Full research, prior art
  and the pending bench experiment in
  [`notes/wifi-aware-cross-platform.md`](./wifi-aware-cross-platform.md).
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

So today (2026-09-06): Android 4/4; iOS GATT + adv-rx + UDP-pending-entitlement;
Linux JVM 4/4 with adv-tx blocked on one adapter and both GATT roles now proven
against firmware; macOS JVM UDP + LoRa + **GATT**, over the in-process bridge in
[`desktop-ble-plan.md`](./desktop-ble-plan.md). The remaining desktop gap is
Windows, plus `ble-adv` on macOS, which is not a gap but a platform refusal.
Enablers, in cost order:

1. **Desktop LoRa** - done. `UsbBulkPipe` over libusb, JNA rather than usb4java
   (no `darwin-aarch64` native, last release 2018). The SPI/SX1262 layer is shared
   with Android. Proven with the Meshtadpole on the Mac.
2. **Desktop BLE (Linux)** - done, and proven on hardware 2026-09-06. BlueZ over
   D-Bus gives both GATT roles *and* extended advertising. Advertising is still
   refused by `james-pc`'s controller (`bluetoothctl` fails identically). The GATT
   roles took three fixes to actually work - a signal whose two paths dbus-java
   names backwards, a peer never retried once BlueZ had cached it, and inbound
   notifications arriving as `ArrayList<Byte>` and being dropped as "not a
   ByteArray" - and then reached the WisMesh Pocket's `rak4631_blemesh` firmware
   with `ready, notify=enabled, chunk=244` and live rx.
3. **Desktop BLE (macOS)** - done, and proven on hardware 2026-09-06. Our own
   CoreBluetooth compiled as a Kotlin/Native dylib and called in-process over JNI,
   because Compose Multiplatform's desktop target is Kotlin/JVM and a JVM class
   cannot be a `CBCentralManagerDelegate`. Windows still needs its own native
   code; `ble-adv` on macOS never can.
4. **iOS UDP** - written and in `commonMain`; the multicast entitlement is Apple's
   gate and this project does not hold it. External, not code.
5. **iOS background** - `bluetooth-central`/`peripheral` modes are declared; the
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
  is proven on that machine. **Settled 2026-09-08: it is that adapter and nothing
  else.** The uConsole's CM5 controller takes the same call - `bluetoothctl
  advertise on` answers `Advertising object registered`, `SupportedInstances 4` -
  where `james-pc` answers `org.bluez.Error.Failed`. Do not chase this in the code.
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

## The two-Linux sitting (2026-09-08, `james-pc` + the uConsole)

The first time the BlueZ **peripheral** role has run anywhere, and the first mesh
link with a Linux box at both ends. What made it possible: `:node-headless`, a
node with no UI whose jar carries no Skiko, so it runs on the uConsole's arm64.
Two commands, `MESH_GATT_ROLE=PERIPHERAL_ONLY` on one host and `CENTRAL_ONLY` on
the other.

### Proven

- **Linux advertising is an adapter problem, not a code problem.** The uConsole's
  CM5 controller accepts `RegisterAdvertisement`; `james-pc`'s refuses it. Both
  run BlueZ 5.82. Everything the peripheral role and the BLE-adv bearer could not
  do on this bench was that one adapter.
- **The BlueZ peripheral role works.** The uConsole registers its GATT
  application, advertises `4d657368-4e6f-6465-4741-545400000001`, and
  `bluetoothctl info` from `james-pc` lists the service. Its ATT database serves
  the mesh characteristic at `.…0002` with flags `write-without-response, write,
  notify`. A central connects and the link reaches `ready`.

### The one defect, and it is not what the note said it was

**A central's `StartNotify` against the Linux peripheral fails with ATT `0x0E`.**
Reproduced every time, both ends Linux, `LE.Paired: no` throughout.

Two corrections to what was written before:

- **`0x0E` is "Unlikely Error", not insufficient authentication.** Insufficient
  authentication is `0x05`. The earlier note filed this under the iOS bond-demand
  story on the strength of that mislabel, which is the wrong tree.
- **It is not a bond demand.** The MacBook on the same bench serves the same mesh
  characteristic over an equally unbonded link, and a `StartNotify` against *it*
  succeeds with `Paired: no`. So an Apple peripheral keeps serving unauthenticated
  after no bond is taken - which also answers the "does iOS keep serving after a
  refused bond" question for macOS - while ours refuses.

Where it fails: **not where this note said, and no longer a mystery needing root.**

The original reading was "inside the peripheral's `bluetoothd`, before our
application is called", on the evidence that the peripheral saw no subscriber, no
fault, and neither `StartNotify` nor `AcquireNotify` reaching the exported object.
That evidence was real but the conclusion did not follow, because only one central
had ever been tried against it.

**An Android central subscribes to the same peripheral without trouble.** Pixel 6a
running `GattLiveDeviceTest#sendsAsCentralAcrossAPeerLinkCycle` against the uConsole
peripheral: the peripheral logs `subscribers=[bluez-subscribers]` and then
`rx[gatt] opaque from !000a11ce` - `0xA11CE` being the test's own synthetic sender,
so the frames are unambiguously the Pixel's and not a stray peer's. 117 of 120
writes accepted across a link cycle. No fault, no refusal.

So the peripheral's `bluetoothd` dispatches `StartNotify` perfectly well, and our
GATT application serves it. **The `0x0E` belongs to the BlueZ central on
`james-pc`** - which is the same adapter that refuses `RegisterAdvertisement`. One
adapter is now the common factor in every "Linux BLE does not work" symptom on this
bench, rather than two unrelated bugs.

Running that isolation test made the case stronger still. `james-pc` as central
against the MacBook does not reach `StartNotify` at all - it cannot complete a
connect, failing `br-connection-key-missing` on every attempt, against the same Mac
the **uConsole** central connects to and drives to `:ready` unbonded.

So `james-pc`'s adapter now accounts for three separate symptoms that were filed as
unrelated bugs:

1. `RegisterAdvertisement` refused (`org.bluez.Error.Failed`), so no peripheral role
2. `StartNotify` answered ATT `0x0E` as a central
3. cannot connect at all to a Mac another Linux host connects to fine

It is a **Realtek USB controller, HCI 5.1 (0xa), revision `0xdfc6`**; the uConsole's
CM5 is not. Nothing here is a node-kmp defect, and no `btmon` run is needed to say
so. What would settle the last of it is a different USB adapter in `james-pc`.

The one thing still genuinely unproven about the peripheral role: a **BlueZ**
central subscribing to it. Android does, and that is what moved the fault off the
peripheral, but Linux-to-Linux notify has never once succeeded on this bench and
cannot until `james-pc` has a working adapter.

### The second defect: a connect storm nobody's guard caught

Driving the uConsole as a **central** against the MacBook to test the pairing
agent turned up a hot retry loop instead: **411 refused connects in 35 seconds**,
never reaching `ready`.

Both existing guards missed it. The permanent skip keys off `br-connection`, the
timed backoff off `abort-by-local`, and BlueZ was answering **`In Progress`** -
which falls through both and re-dials at whatever rate the peer is reported.
`No reply within specified time` and `br-connection-busy` fall through the same
hole.

Fixed in `f54dc50` by inverting the classification: only
`br-connection-key-missing` is permanent (a classic leg with no bond never becomes
an LE mesh route); every other refusal goes to the timed backoff, which a success
or the device leaving clears. The gates also moved into `reserve()`, because the
cached-object sweep and `InterfacesAdded` both reach a connect without passing
`reserveIfMesh`.

Re-run on the same pair: **8 refusals in 75 seconds, and the peer reaches
`:ready`.** `Paired: no`, `Bonded: no` throughout.

### The pairing agent: settled 2026-09-09, and it does not work

Tested against the iPad with `BluezPairingAgent` registered as the uConsole's default
agent. The pairing dialog appeared on the iPad, James tapped Pair, and BlueZ reported
`Pairing successful` with `Paired: yes, Bonded: yes` - **having called no agent method
at all.** Zero calls, both directions, every attempt.

`NoInputNoOutput` selects Just Works and BlueZ consults no agent for it. The dialog is
iOS's own, raised the moment an SMP exchange starts. So the agent neither suppresses
the dialog nor prevents the bond, and the KDoc claiming both was wrong. Corrected in
`2be0852`; the agent stays only for `AuthorizeService` scoping.

What actually kept the connect storm down is the retry backoff fixed earlier today.

Two side findings. An iPad keeps a half-bond after a failed pair and then offers only
"Forget This Device" while the Linux side has no record at all - that asymmetry, not
our code, is what produces "iPad can no longer connect to <mac>". And an outbound pair
from Linux fails `AuthenticationFailed` while that stale record stands.

### The old note, kept for the record

The same central run **declined nothing** - the MacBook demanded no bond at any
point. So the macOS half of the question is answered (an Apple peripheral serves
the mesh characteristic unbonded, and asks a Linux central for nothing), and the
half the agent was actually written for is not: `BluezPairingAgent` exists for an
**ANCS-advertising iOS** peer, and nothing in range advertised ANCS.

That run would previously have been unreadable either way - a silent refusal and a
peer that never asked look identical from outside. `f54dc50` gives the agent an
`onDeclined` callback wired to the link's fault channel, so each decline names its
request and the peer. The next run with an iPad present distinguishes the two.

### Not testable that sitting (closed the next morning)

The iPad was out of range on 2026-09-08. It came into range on 2026-09-09 and the
question is now answered above: the popups do not stop, because the agent is never
consulted.

### Wi-Fi Aware, on a radio at last (Pixel 6a, Android 17)

The bearer had only ever run against mocks. One Aware radio turns out to prove
most of it, and it failed twice before it worked - both times a `SecurityException`
thrown out of a flow rather than a refusal reported through `availability`:

- `WifiAwareManager.isAvailable` and `getCharacteristics` need **`ACCESS_WIFI_STATE`**
- `attach` needs **`CHANGE_WIFI_STATE`**

Neither is the runtime permission the transport names in `REQUIRED_PERMISSION`.
Both are normal permissions - no prompt, no scoping decision an app could make
differently - so the module declares them in its own manifest and a consumer picks
them up from the merge. Verified in `monitor-android`'s merged manifest. The three
Manager calls are guarded as well, so a host short a permission gets an
`Unavailable` naming the refusal instead of losing its collector.

**What the radio answered:** `aware_nmi0` activated, `enableAndConfigure` with a
real `ConfigRequest`, `onClusterChange clusterId=3685B53BC866`, `aware_data0`
created, `NAN_STATUS_SUCCESS`. So attach plus both discovery sessions are proven on
hardware. `maxFrameBytes` reads **255** - exactly the spec floor the transport falls
back to, so that constant was a correct guess.

**Discovery and send are proven too, 2026-09-09.** Pixel 6a and Pixel 9 Pro, both on
USB: `WifiAwarePairDeviceTest` runs on every attached device in parallel, so each side
publishes, subscribes, discovers the other and sends. Discovery took about twelve
seconds; each phone then heard around forty frames from the other, both directions.
Every frame carries the sender's `Build.MODEL`, so what proves the crossing is a frame
naming the *other* phone rather than bytes that could be our own.

That run also settled the exit-code question: `connectedAndroidTest` exited non-zero
with `failures="0"` on every earlier run, and the difference was **wireless adb**. Over
a cable the same task exits 0.

`connectedAndroidTest` exits non-zero with `failures="0"`. The last step it logs is
the additional-test-output collector, and `/sdcard/Android/media/<pkg>` does not
exist after the run's own uninstall. Read the XML, not the exit code.

Unrelated, found in passing: `node-transport-ble-gatt`'s
`reassemblesAWholePacketFromAPeer` fails on this bench with `expected 659918 but
was 811708462` - the test's synthetic `0xA11CE` sender lost to a **real** mesh node
in range delivering a frame into the link under test. Environmental, not a
regression.

## The Linux bench sitting (2026-09-06, `james-pc`)

The first sitting on the Linux box with the bench radios plugged in. What it
was for: the BlueZ GATT roles had never been exercised on hardware, desktop LoRa
had only run on the Mac, and the Mac network had been asymmetric for UDP. What
was in the room: solar RAK4631, XIAO S3, Cardputer and T-Deck, all stock 2.8.0 on
James's live channel; a T1000-E parked in DFU; the Meshtadpole at `1a86:5512`;
the Pixel 6a over TLS adb; and, unplanned, the WisMesh Pocket on battery a few
metres away, still running `rak4631_blemesh`, plus the MacBook still running
yesterday's desktop monitor. No Heltec V3, no iPad, no sudo (so no `btmon`).

### Proven

- **Desktop LoRa rx on Linux.** The Meshtadpole came up through libusb with no
  udev rule (the device node was already world-readable), tuned 906.875 MHz slot
  20, and heard the live mesh at once: 17 frames in the first two minutes, RSSI
  -17 to -53 dBm. Every frame is `opaque` because the monitor's channel is the
  default LongFast key, which is the right proof for a bearer: it carries what it
  cannot read.
- **The phone API on Linux.** `meshtastic --host 127.0.0.1` from the mcp venv
  connected to the desktop node, listed its node DB, and a `--sendtext` left over
  UDP and appeared on the Pixel as `rx[udp] text chan from !8ad3332e`.
- **BlueZ GATT central against firmware, both directions.** The Linux node holds
  the Pocket's mesh-peer service: `dev_EF_E2_0A_BE_95_6A(ready,notify=enabled,
  chunk=244)`. Outbound: a text from the Linux node over the phone API arrived at
  the Pixel as `rx[gatt] text chan from !8ad3332e: gatt probe from linux` (the
  write reached the Pixel over GATT; whether via the Pocket's relay or the direct
  Linux-Pixel central link was not isolated). Inbound took a fix: a subscribed
  notification arrives from dbus-java as an `ArrayList<Byte>`, not the `ByteArray`
  a method call returns, so `as? ByteArray ?: return` dropped every frame and the
  node received nothing while looking healthy (connected, subscribed, writing).
  That connect/subscribe/write half was proven first; a raw `bluetoothctl notify`
  on the characteristic caught a 157-byte frame, which is what showed the
  notifications were arriving at BlueZ but not at the node. After the coercion fix
  (`asBytes`), rx[gatt] appears on the Linux node: two frames the Pocket relayed
  from LoRa, deduped against the LoRa copy. Inbound is proven.
- **BlueZ GATT central against Android.** The Linux node also connected to the
  Pixel's peripheral (`dev_4D_F1_16_61_7C_1E(ready,notify=enabled,chunk=514)`)
  and the Pixel lists james-pc's adapter under `subscribers=[E8:48:B8:C8:20:00]`.
- **UDP is symmetric here.** Linux and the Pixel hear each other's frames; a
  LAN radio also bridges LoRa into UDP, so most LoRa frames arrive twice and the
  second is logged `dropped (DUPLICATE)`.

### Fixed, on `meshtastic-node-kmp` `main` (pushed)

- **`be23e28`** The BlueZ central read the wrong path off `InterfacesAdded`.
  dbus-java names the two fields backwards: `objectPath` is the emitter, which
  for BlueZ's ObjectManager is always `/`, and the added device is
  `signalSource`. Every peer discovered live was reserved as `/` and faulted
  `/: BlueZ refused the connection`; only the sweep of BlueZ's cached devices ever
  connected. The `/` in the fault line is what gave it away. Test builds the real
  dbus-java signals and fails on the old read.
- **`803b594`** The central never retried a peer. BlueZ raises `InterfacesAdded`
  once per device object, so a failed first connect was final. First connects
  fail often here: the Pocket keeps its device object but stops advertising while
  both its slots are held, and the connect times out as
  `le-connection-abort-by-local`. Now an RSSI change on a device the link does
  not hold reads its UUIDs and reserves it again. Both faults also carry BlueZ's
  own error text.
- **`ce75729`** The desktop monitor echoes its log to stdout. GNOME denies the
  screenshot D-Bus call, XTest clicks from xdotool land nowhere near the rail, and
  the Log tab was the only record of which bearer carried a frame.
- **`9be0393`** The phone API writer threw `SocketException: Broken pipe` to the
  thread's uncaught handler every time the CLI hung up mid-dump. Caught, logged,
  and the socket closed so the session leaves by the normal path. Real-socket
  test, mutation-checked.
- **(inbound GATT coercion)** dbus-java delivers a `Value` property change - every
  inbound notification - as an `ArrayList<Byte>`, so the central read every frame
  as "not a ByteArray" and dropped it silently. `asBytes` reads either shape. This
  is why "notification path end to end" was wrong when first written here: the
  central connected, subscribed and wrote, and received nothing. Found by grepping
  the Linux stdout for `rx[gatt]` across a whole run and finding zero while the
  Pixel logged the same LoRa-relayed frames over its own GATT link.

### Open, found here

- **SOLVED (2026-09-06 evening): the Linux central holds the Mac's mesh GATT over
  LE, alongside the Pocket.** `central=[dev_2C_CA...(ready,notify=enabled,
  chunk=514), dev_EF_E2...(ready,notify=enabled,chunk=244)]` - one BlueZ central,
  two GATT peers, one a macOS CoreBluetooth peripheral and one nRF52 firmware. The
  fix was **not** pairing: the LE link forms with `LE.Paired: no`, exactly as the
  unauthenticated mesh characteristic intends. The fix was forcing the bearer.
  `bluetoothd` needs `Experimental = true` in `/etc/bluetooth/main.conf` (a
  persistent edit on james-pc, survives reboot) and a restart; that exposes
  `Device1.PreferredBearer`, set to `le` with `bluetoothctl bearer <dev> le`. Then
  `Connect()` opens LE, BlueZ discovers the mesh characteristic, and the node
  subscribes. Without it BlueZ defaults `PreferredBearer` to `last-used` and opens
  a dual-mode Mac over BR/EDR (audio profiles, no GATT). A classic bond makes it
  worse, not better - remove any bond and force the bearer instead. The Mac
  exposed four copies of the mesh service (stale registrations from the day's node
  restarts); `meshCharacteristicPath` takes the first, and it worked.

- **The pre-fix history, kept because it is the diagnosis:** BlueZ routes the Mac
  over the classic bearer, and the mesh GATT is LE-only.
  Chased to a conclusion 2026-09-06 with James at the Mac. Unbonded,
  `Device1.Connect()` failed `br-connection-key-missing`: the call dials every
  profile including BR/EDR, the classic leg of a dual-mode Mac has no bond, and
  that failed the whole call even though the LE leg came up. Each attempt also
  raised a pairing prompt on the Mac, so the retry-on-sight was fixed to leave a
  classic-bearer refusal alone (`classicBearerRefused`, commit on `main`).
  Bonding then removed the refusal - but BlueZ, now holding a classic bond, opens
  the Mac over **BR/EDR**: its object shows only AVRCP and A2DP endpoints, no GATT,
  and the link faults "advertises the mesh service but serves no mesh
  characteristic" because the mesh characteristic lives on the LE bearer it never
  opened. `bluetoothctl bearer <dev> le` is `UnknownProperty` on 5.85 (behind
  `--experimental`, same as `PreferredBearer`). So a bonded dual-mode peer is
  unreachable over LE from this link without `bluetoothd --experimental`. The
  Pocket has no classic radio, which is why it works and the Mac does not. Options,
  none yet taken: `bluetoothd --experimental` plus the bearer property; an LE-only
  address for the mesh; or removing the classic bond and rediscovering LE-only.
- **The Pocket has two peripheral slots and stops advertising when both are
  held.** With the Mac and the Pixel connected it vanishes from scans and a
  cached connect aborts. Not a bug anywhere, but the reason the first Linux run
  looked like an adapter fault. Free a slot before diagnosing.
- **`transport[lora] unavailable: no CH341 stick attached` at 1.2 s, then
  `tuned 906.875 MHz` at 1.6 s.** The unavailable line is the poll's first miss,
  before the hot-plug scan finds the stick; harmless but a false alarm on every
  start. **Half-fixed 2026-09-07 (`0d7b007`)**: the *wording* was hardcoded and
  wrong on any host without a USB bridge, so it now comes from the device source
  (`LoraDeviceSource.detachedReason`) and the spidev source names its bus instead.
  The first-miss timing is untouched and still a false alarm.
- **The gate on a Linux host.** `:node-desktop-ble-macos:klibApiCheck` fails
  because the macOS target cannot dump here; run the gate with
  `-x :node-desktop-ble-macos:klibApiCheck` and without the iOS link tasks.
- **The uConsole** is `james@192.168.1.23` (the `uconsole` ssh alias still points
  at the unreachable `.247`). Reached and running 2026-09-07 - see "The uConsole
  sitting" below.

### Bench recipe for this box

Build with `just in meshtastic-node-kmp ~/.claude/bin/gradle-queue -- <tasks>
-Dorg.gradle.java.home=$HOME/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`
(`direnv exec` does not chdir; `just in` does). Run the jar with the Temurin
`java` outside the Nix shell, `env -i` plus `DISPLAY`, `WAYLAND_DISPLAY`,
`XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`, stdout to a file - that file is
the log. `import -window $(xdotool search --name "Mesh Monitor" | tail -1)` via
`nix shell nixpkgs#xdotool nixpkgs#imagemagick` captures the window; clicks do
not land. The Pixel is `adb connect 192.168.1.182:36201`; `adb exec-out screencap
-p` reads it, `adb shell input tap 897 2211` is Send test, and
`adb shell input swipe 540 1950 540 2150 400` scrolls its log box back.

## The mesh view, and the three things that know about the topology (2026-09-06/07)

A node's picture of the mesh had one fact in it - did we hear this peer - and every
originator whose traffic reached us was drawn as a spoke off the hub. A chain of relays
looked like a star: 62 peers around a node whose own log showed it relaying frames that
had already taken three and five hops.

There are exactly three sources, and they are not equally strong. Keeping them apart is
the whole design:

| source | what it proves | discipline |
| --- | --- | --- |
| `hop_start - hop_limit` | how far away a peer is | null when the sender stamped `hop_start = 0`, which a `hopLimit` of 0 does. Null is not a distance and is never drawn as one |
| `relay_node` (header byte 15) | **a direct neighbour**: a relayer is a node whose radio we received | one byte, so `NodeDb.resolveLastByte` mirrors `NodeDB::resolveLastByte` and returns nothing on two candidates. The wrong link is worse than no link |
| `NEIGHBORINFO_APP` | links **between other nodes** | another node's claim, not our observation. Drawn dashed. A report replaces that reporter's whole set, because a neighbour list is who it hears *now* |

`relay_node` is the one that matters most and was the one already on the wire and unused
for this: it is the only thing that can prove `hopsAway = 0` for a peer whose traffic
never decodes, which on the Mac node was ~600 frames a night from nodes it could not
read. Firmware's relevance gate requires `hops_away == 0` to resolve a relayer, which is
circular if you are using the relayer to *learn* who is at zero hops - so here, appearing
as `relay_node` is itself the evidence.

What is deliberately absent: any edge inferred from a packet merely arriving. Traffic
from five hops away says nothing about which links carried it.

## BLE meshing: what is saturating, and which standards actually help (2026-09-09)

Raised by James from Garth's observation: **current clients can already saturate the
GATT link through the phone API, over the one BLE phone-node connection production
supports** - and the phone and desktop platforms have their own ceilings on how many
mesh links they can hold. Open design question, nothing built.

### Bluetooth Mesh (the SIG standard) is the wrong tool, and should be ruled out loudly

It is what everyone reaches for, so the reasoning belongs on the record. It is managed
flooding over the advertising bearer with a GATT proxy, which sounds exactly right, and
then: it segments to roughly 11-byte chunks, carries its own addressing, its own
network/app key hierarchy, IV index and sequence-number state, and needs a provisioning
ceremony per node. Adopting it means running two mesh protocols that disagree about
identity and encryption while adding a pairing-style UX - the opposite of the seamless
requirement that motivated the question. It is built for lighting and sensors sending
small infrequent messages, not for carrying `MeshPacket`s.

### Lever 1 - L2CAP CoC, for the phone-node link

The direct answer to saturation. A credit-based **L2CAP Connection-Oriented Channel**
is a flow-controlled byte stream that skips ATT and GATT entirely.

**What is actually slow is a pull model, not the MTU.** An earlier draft of this section
said "chunking at MTU-3"; the real shape, read out of firmware's `NimbleBluetooth.cpp`,
is one ATT round trip *per packet*: `fromNum` notifies that something is waiting, the
phone then issues a read on `FromRadio`, and firmware serves exactly one queued message
per read. The cost is gated by connection interval, not by payload size, which is why a
bigger MTU alone would not fix it. Available on every
platform that matters: Android `createL2capChannel` (API 29+), iOS `CBL2CAPChannel`,
BlueZ L2CAP sockets. Firmware would need to publish a PSM. This is a **firmware +
client** change, not a node-kmp-only one.

### L2CAP CoC client-to-client: proven cross-platform and unpaired, 2026-09-09

Lever 1 above is about the phone-to-**firmware** link, and every cost in it -
firmware publishing a PSM, `CONFIG_BT_NIMBLE_L2CAP_COC_MAX_NUM`, a fork of Bluefruit's
init to re-derive the SoftDevice RAM base - is a firmware cost. **Client-to-client CoC
has none of them, and it is the one BLE shape both Android and CoreBluetooth can do
with no pairing at all.** That was never tested here. It is now.

Setup: a Mac running `notes/spikes/l2cap/l2cap-peripheral` (a ~100-line Swift CLI:
`CBPeripheralManager`, `publishL2CAPChannel(withEncryption: false)`, PSM exposed on a
characteristic under a custom advertised service, echoes what it receives) against the
Pixel 9 Pro running `L2capCocProbeDeviceTest` on branch `jamesarich/spike-l2cap-coc`.
CoreBluetooth is the same framework on macOS and iOS and `publishL2CAPChannel` needs no
entitlement, so the Mac stands in for the iPad and needs no signed app - which matters,
because the Wi-Fi Aware entitlement turned out to need a paid team.

**Both questions answered.** Android side:

    peer 2C:CA:16:30:A7:A2 bondState(before)=BOND_NONE
    PSM read over GATT = 192
    CONNECTED, isConnected=true
    wrote 22 B
    read 27 B: echo:hello from Pixel 9 Pro
    bondState(after)=BOND_NONE
    VERDICT: CoC carried bytes with bondState BOND_NONE - no pairing, no prompt

and the Mac agreeing from the other end: `L2CAP CHANNEL OPEN ... psm=192`, `rx 22 B`,
`echoed 27 B`.

- **No pairing, no bond, no prompt**, on either platform, across a channel that carried
  a full round trip. `withEncryption: false` really does skip Security Mode 1 Level 3.
  This is the thing GATT could not be made to do: this file spends pages on pairing
  popups that could not be suppressed, and a BlueZ agent that is never consulted.
- **PSM discovery is solved, not open.** The PSM is assigned at publish time and Apple
  cannot advertise arbitrary bytes, but it *can* advertise a service UUID, and a GATT
  read of a characteristic under that service carries the PSM fine. A
  `CBMutableCharacteristic` created with a value is served from CoreBluetooth's own
  cache without waking the delegate, so it costs the Apple side no code.

What this does **not** yet say:

- **Only one direction is proven**: Apple as peripheral/listener, Android as
  central/dialer. That is the deployable direction, since iOS backgrounding favours the
  peripheral role, but Android-as-listener (`listenUsingInsecureL2capChannel`) against a
  CoreBluetooth central is untested.
- **iOS is not macOS.** Same framework, and the entitlement-free path means an iPad test
  is cheap, but it has not been run.
- **Throughput, MTU and concurrent-channel limits are unmeasured**, and so is anything
  about backgrounding, which is where an iOS bearer usually dies.
- **API 29 floors the Android half** against a minSdk of 26, so this is capability-gated
  rather than universal. GATT stays as the fallback, which is what Lever 1 already said.

The shape this suggests, unbuilt: a `node-transport-ble-l2cap` sitting beside the GATT
transport rather than replacing it, streaming rather than one-write-per-packet, and
crucially **cross-platform without a pairing ceremony** - which is exactly the plane the
Wi-Fi Aware research says we need and cannot get from Aware.
[`notes/wifi-aware-cross-platform.md`](./wifi-aware-cross-platform.md) for why Aware
cannot be it. Knit ships this shape as its own cross-platform plane
(`docs/IOS_PORT_REVIEW.md` §1.1, `mesh/link/FramedLink.kt`).

### Lever 2 - extended advertising: already done, and this note was wrong

**Corrected within hours of writing it.** The first version of this section said
`node-transport-ble` is on legacy 31-byte manufacturer data. That is false, and it
contradicted this file's own earlier sections. The bearer has used BLE 5 **extended**
advertising since the first commit that added it: `BleMeshAdvert` is sized
`ADV_TOTAL_MAX = 251`, `ADV_OVERHEAD = 8`, so **243 bytes of encoded `MeshPacket`**,
and Android's radio calls `setLegacyMode(false)`. Firmware's `BLEMeshHandler` carries
byte-identical constants, and the pairing is proven on hardware both Android-to-Android
and ESP32-S3-to-nRF52840.

So there is no ceiling to raise here. What is actually left:

- **Apple can never transmit on this bearer, at any BLE version.** `startAdvertising`
  accepts a local name and service UUIDs only; a `MeshPacket` cannot be expressed as an
  Apple advertisement. That is OS policy, not a legacy-versus-extended gap, and extended
  advertising cannot lift it.
- **BlueZ TX is built but never proven.** `BluezAdvertisement` sets `SecondaryChannel`
  to request an extended instance, but no advertisement has ever succeeded on `james-pc`
  - the same Realtek adapter that fails everything else. RX over BlueZ *is* proven.
- **The on-air format decision is the real open item**, and it is *orthogonal* to
  extended-vs-legacy: that axis is about how many bytes fit, this one is about what iOS
  can filter on in the background. Overhead is near-identical either way (3 bytes for
  manufacturer data, 3 for service data under a 16-bit UUID, +14 for a 128-bit one), so
  the packet budget barely moves.
- **A new doubt worth resolving before that switch**, surfaced by the spike and not
  settled anywhere: a backgrounded iPhone may suppress *all non-connectable*
  advertisements, and our mesh frames are deliberately non-connectable. If so,
  service-data under an assigned UUID is **necessary but not sufficient** - the advert
  might also have to become connectable, which on firmware means a second connectable
  ext-adv GAP instance (the phone API already owns instance 0). UNVERIFIED.
- Also unknown: whether the org holds or wants a SIG-assigned 16-bit UUID (a paid
  membership process) versus a free 128-bit custom one at +14 bytes.

Two traps a future implementer should not re-learn, both already paid for on the
firmware side: enabling `CONFIG_BT_NIMBLE_EXT_ADV` compiles out NimBLE's legacy
`ble_gap_adv_start` host-globally, which the phone-API advertisement was using; and
gating code on `MYNEWT_VAL(BLE_EXT_ADV)` silently reads 0 because it resolves from the
prebuilt header rather than `custom_sdkconfig`, so the transport quietly falls back to a
branch that cannot carry a packet, with nothing in the log.

### What the L2CAP spike found that changes the estimate

- **NimBLE already has CoC** (`ble_l2cap_coc.c`, credit-based, with a ready throughput
  example) but it is **compiled out**: `CONFIG_BT_NIMBLE_L2CAP_COC_MAX_NUM=0` in the
  prebuilt shared sdkconfig. So ESP32 is a `custom_sdkconfig` bump - landing squarely in
  the shared-framework-sdkconfig trap the root `CLAUDE.md` documents, the same one the
  EXT_ADV spike paid for.
- **nRF52 is the expensive half.** The SoftDevice exposes the full CoC API, but
  Bluefruit's `begin()` never calls `sd_ble_cfg_set(BLE_CONN_CFG_L2CAP, ...)`, and that
  call must happen *before* `sd_ble_enable` and changes the RAM-base arithmetic every
  later config call depends on. That is a fork or patch of Bluefruit's init plus a
  re-derived RAM budget, not an addition alongside it.
- **CoC rides an existing ACL**, so it consumes no extra connection slot. The
  one-connection production ceiling (`CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1`) is untouched
  either way - CoC helps throughput, not fan-out.
- **Android needs API 29**, and both node-kmp and the app are minSdk 26. GATT therefore
  stays as a **permanent** fallback path, not a transitional one.
- **Linux is different plumbing entirely**: a raw `AF_BLUETOOTH` / `BTPROTO_L2CAP`
  socket, not the org.bluez D-Bus interfaces `BluezGattLink` uses throughout. A CoC
  bearer there is new I/O, not an extension of the existing code path.

### Measured 2026-09-09: what the mesh build actually costs on an S3

Two clean builds of the same tree (`spike/ble-mesh-transport`), stock built **first** so
the shared framework sdkconfig had not yet been rewritten:

| | stock `heltec-v3` | `heltec-v3_blemesh` | delta |
| --- | --- | --- | --- |
| RAM | 127,288 (38.8%) | 130,472 (39.8%) | **+3,184 B** |
| Flash | 2,286,371 (68.4%) | 2,301,755 (68.9%) | **+15,384 B** |

On the bench V3, running the mesh build - ext-adv, observer, GATT mesh-peer,
`MAX_ACT=6`, `MAX_CONNECTIONS=2`: total heap 267,948, **48,964 bytes free in steady
state** with BLE up, both advertising instances configured, scanning, and relaying LoRa.
No OOM, no failed allocation.

**So a runtime toggle is feasible, but not for the reason it was proposed.** From the
ESP-IDF source: `ROLE_OBSERVER`, `EXT_ADV`, `EXT_ADV_MAX_SIZE`,
`MAX_EXT_ADV_INSTANCES` and `MAX_CONNECTIONS` are Kconfig, **compile-time only**, sizing
a `ble_gap_vars_t` that `ble_gap_init()` callocs on *every* BLE bring-up whenever
Bluetooth is enabled at all. A runtime toggle inside a mesh-capable image cannot avoid
that. Only a separate build can. What a runtime toggle does free is scan duty cycle,
radio airtime and the power that goes with continuous scanning - which is real, and is
probably the point.

Two corrections to what this file said before:

- **`EXT_ADV_MAX_SIZE` sizes one buffer, not one per instance.** It is a member of
  `ble_gap_vars_t`, allocated once. The "3.3 KB across two instances" written here and
  in the spike's own sdkconfig comment overstates it; at 257 it is ~257 bytes.
- **`MAX_CONNECTIONS` above 1 is only needed for the GATT mesh-peer variant.** The
  adv-only spike commits never touched it; Phase 3 raised it to 2 and said so. A
  connectionless adv-only bearer needs no extra connection slot, so it is cheaper than
  the table above, which measures the expensive variant.

Not measured: stock **on-device** heap. The board kept booting its existing image through
both a flash and an otadata erase, so the heap delta is bounded by inference while the
static delta is measured. Also note the shared
`framework-arduinoespressif32-libs/esp32s3/sdkconfig` now carries the mesh settings - any
later stock S3 build needs the lib package moved out and reinstalled first, or it
silently links the rebuilt NimBLE.

### The shape to keep

Connection count is the reason not to scale by adding links: centrals hold only a
handful of concurrent GATT connections and the peripheral role is tighter. The current
architecture - **GATT for point-to-point, advertising for breadth** - is the right
shape and should stay. Exact per-platform ceilings are chipset- and stack-dependent
and are worth measuring rather than quoting.

## Transport toggles: opt-in, persisted, including LoRa (decided 2026-09-09)

Every bearer gets a user-visible toggle, persisted, **and that includes LoRa's armed
state**. This is the sentinel principle, not an exception to it: **a hardware radio
resumes its previous state on restart, so node-kmp does too.**

`AGENTS.md` has said a node must never transmit on LoRa from a remembered setting -
arming is a per-launch host act (`MESH_LORA_REGION`, the region chip). That rule was
node-kmp's own invention, and it suited a library being brought up on a bench where an
unattended transmit was a surprise. It is not what the firmware does, and
`firmware-is-the-sentinel-for-node-kmp` says to match the firmware rather than invent
node-kmp semantics. A node that forgets its region on restart is the anomaly.

**Built the same afternoon; this section is the decision, not an outstanding plan.**
`d39bf53` moved the assertions and took the clamps out, `3c98fd6` gave `node-headless`
a store and made it resume bearers and band, `01e0f6f` did the dashboard's half. A node
now logs which bearers it resumed and on what band.

Two things the plan did not anticipate. **The env vars ended up meaning different things
on the two hosts** and that is deliberate: the monitor has a chip, so a variable is a
one-run override there and is never written back; `node-headless` has no chip, so naming
one *is* the act of setting it and it persists. A headless node therefore has no one-run
override, which would need a second variable rather than a change of meaning. And the
open question about a phone-written region turned out not to be a question: firmware
arms on a phone write, so there was never a narrow reading to take.

### What the toggle spike found

The mechanics mostly exist; the work is **removing deliberate clamps in about ten
places**, not building persistence.

- The monitor already persists both a per-bearer enabled set and a LoRa region string
  (`TuningCodec`, keys `transports.enabled` and `lora.region`) - and `decode()`
  deliberately refuses to restore the region into an armed state, handing it back as
  `rememberedRegion` purely so it can be logged.
- The radio-shaped save file already carries the region too:
  `BackupPreferences.config.lora.region`. `AdminService.restore()` skips applying it on
  purpose, and `LocalRadio.configs()` overwrites it with whatever this launch armed. So
  the region is persisted **twice** today and read back into nothing.
- **`node-headless` has no store at all** - it is purely env-driven, and
  `TuningStore`/`TuningCodec` live inside `:monitor` and are not reusable without a
  module move.
- The rule is asserted in more places than `AGENTS.md`: **`SECURITY.md` names it as an
  in-scope security invariant**, `monitor/README.md` documents the user-facing behaviour,
  and it is encoded in tests that must be rewritten rather than deleted
  (`restoring_never_arms_the_lora_region`, `a_stored_region_never_arms_the_bearer`, and
  the `TuningCodec` round-trip assertions). Rewrite the docs first - other tests cite
  them by name.
- Two defaults currently disagree and a unified design has to pick: the monitor enables
  all bearers and stays quiet via `region = UNSET`, while `node-headless` defaults to a
  transport list that **excludes** LoRa outright.
- Small bug found in passing: `MESH_LORA_REGION=UNSET` currently passes the
  `LORA_REGIONS` check and logs "UNSET armed for this run ... this node will transmit",
  which is false. Under the new rule that spelling becomes the natural "stay quiet this
  run despite a stored region" escape hatch, so it needs a real case.

**The open question the decision does not settle:** a node resuming *its own* last state
is one thing; a **phone-written** region arming the node is a materially larger security
change, and `SECURITY.md` currently forbids both in one sentence. That needs an explicit
answer before the clamps come out.

## The uConsole LoRa fix (2026-09-09) - it was the reset line

LoRa worked on this uConsole before the CM4 to CM5 swap, which is the fact that
overturned the 2026-09-07 verdict below. A chip that is absent and a chip held in
reset both answer `0x00` to every transfer, and nothing had driven reset.

**Root cause: one missing line of `config.txt`.** ClockworkPi's
`clockworkpi-uconsole-cm5.dtbo` configures no GPIO for the module; the CM4 path did.
On CM5 GPIO25 came up `none` - floating - so the SX126x sat in reset with its
outputs high-Z. The fix is the CM5 equivalent of the `gpio=11=op,dh` the `[cm3+]`
section already carries:

    [cm5]
    dtoverlay=clockworkpi-uconsole-cm5
    gpio=25=op,dh

**Three things the old note got wrong.** `spidev1.0` was always the right bus - RP1
puts SPI1 on the same GPIOs as BCM2711 (18 CE0 / 19 MISO / 20 MOSI / 21 SCLK) and
`spi1-1cs` sits in `[all]`, so it applied on both. `spi-gpio35-39` is a pin
*relocation*, not bit-banged SPI, and it lives under `[cm3+]` which **CM4 skips
too**, so it was never what made CM4 work. And meshtasticd's `IRQ 26 / Busy 24 /
Reset 25` is now **proven, not intent**: pulling 24 and 26 up read high before a
reset pulse on 25 and driven low after, which is a powered chip taking hold of them.

**The diagnostic worth reusing.** A pull-up on a suspected status line separates
"floating" from "driven low by something": a chip holds it down, an unconnected pin
follows the pull. That is what turned a guess into a measurement.

**Then the TCXO.** With the bus alive the bearer still failed until DIO3 was told to
power the TCXO - meshtasticd's config says `DIO3_TCXO_VOLTAGE: true` and
`DIO2_AS_RF_SWITCH: true`, and both are SPI commands rather than host pins, so they
work with no GPIO backend. `MESH_LORA_TCXO_VOLTS` and `MESH_LORA_DIO2_RF_SWITCH`
now expose them (`4eade0c`). Also in that commit: `node-headless` never built a LoRa
transport at all - its KDoc described an arming variable whose positive branch did
not exist.

**Then two more bugs, both the same missing line.** The reset line got the chip
talking; it took two further fixes to make it work, and neither was on the board.

**One: the AGC reset slept a chip it could not safely wake** (`b1c4403`).
`agcResetIntervalMs` is 60 seconds and `resetAgc` opens `sleepWarm()` then `standby()`.
Waking is the one place `waitBusyLow`'s no-BUSY fallback does not hold, so `SetStandby`
landed on a busy chip and every command after it failed `0xaa` - which is exactly the
minute-later collapse observed. The periodic reset is now skipped when no BUSY line is
wired, trading the sensitivity drift it corrects against a bearer that stops. Found by
reading, not by watching: the interval and the fallback are eighty lines apart in
different files and neither reads wrong alone.

**Two: the no-BUSY settle was one millisecond** (`aa06750`). Copied from RadioLib's
`RADIOLIB_NC` default. `Calibrate` holds BUSY for milliseconds, so the commands after it
were *accepted and silently did nothing* - the chip answered status queries, reported a
good transmit, and never received a frame. **Ten milliseconds and the same node hears
the mesh.** This is the worst shape a failure can take: every indicator says working.

**Do not repeat the pin-poking.** The vendor documents the board, and the spec matches
what we configure pin for pin: SPI1, CS = **GPIO18** (SPI1-CE0), IRQ **26**, Busy **24**,
Reset **25**, **DIO2** drives the antenna switch and **DIO3** powers the TCXO. So
**there are no RXEN/TXEN lines to find** - an afternoon was spent sweeping GPIOs for
pins that do not exist. (AIO **V2** additionally gates LoRa behind GPIO16 pulled high;
tried here with no effect, so this board is a V1. The launcher sets it anyway, harmless.)
Guide: <https://hackergadgets.com/pages/hackergadgets-uconsole-rtl-sdr-lora-gps-rtc-usb-hub-all-in-one-extension-board-setup-guide>

### Proven on air, both directions (2026-09-09)

**The first node-kmp to node-kmp link over real LoRa.** uConsole on the kernel spidev
backend, `james-pc` on the CH341 USB bridge, so the transport is proven across both JVM
device sources against the same air:

    james-pc:  peer[lora] !54efe673 uconsole
    uconsole:  peer[lora] !71f22814 jamespc

Each side decoded the other's NodeInfo and resolved it to a named peer - frame, decrypt,
decode, node DB, not just bytes arriving. Both also hear the live mesh (`Solar`,
`T-1000e`, `wismesh pocket v3`, `Meshtastic 956a`). Left soaking.

**Done, later the same day.** The GPIO chardev backend below was built (`b110377`), so
the uConsole wires BUSY and gets neither the 10 ms settle nor the disabled AGC reset.
Both remain in place for a board that names no lines, which is the correct default and
is what `NO_BUSY_SETTLE_MS` is for.

### The GPIO chardev backend, spiked 2026-09-09

**Built the same day (`b110377`), so read this as the design record rather than a plan.**
`LinuxGpioChip` and `GpioV2` now serve BUSY/NRST/DIO1 through `GPIO_V2_GET_LINE_IOCTL`,
named by `MESH_LORA_GPIOCHIP` and `MESH_LORA_GPIO_{BUSY,RESET,DIO1}`. With them wired on
the uConsole the 10 ms settle and the AGC-reset skip no longer apply: it soaked 1 h 37 m
with 390 frames received, zero command failures and the AGC reset running every minute.
The spike also paid for itself before any of that, by diagnosing the AGC failure from a
read rather than a bench run.

Three of its predictions were corrected by hardware, all now covered by tests: the chip
index is **not contiguous** (a CM5 starts at 11, so counting up from zero and stopping at
the first gap finds nothing - list the directory), a logical pin is **not** its slot in
the line request, and an output line comes up low unless the request says otherwise.

What it mapped:

- **`Ch341Pins` cannot carry RP1 offsets.** Its `init` validates outputs to `0..5` and
  inputs to `0..23`, so `busy=24` and `reset=25` both fail `require`. That is the
  central design decision, and it suggests two steps rather than one: a local logical
  numbering to unblock the bench, then a `LoraPins` interface once GPIO is proven - so
  "does this work" and "is the type right" are not answered by the same commit.
- **`loraDevices()` silently discards the caller's pin profile** on the spidev path: it
  always passes `SPIDEV_UNKNOWN_BOARD`, ignoring its own `pins` parameter.
- **Do not hardcode `/dev/gpiochip15`.** The RP1 chardev index has moved across kernel
  releases (chip4, chip0, chip15 here). What is stable is the *line offset* - GPIO24 is
  offset 24 whatever the chip enumerates as - so resolve the chip by **label**
  (`pinctrl-rp1`) and keep offsets named, in the same family as `MESH_LORA_SPIDEV`.
- **DIO1 needs no edge interrupts.** The IRQ status latches until `ClearIrq`, so a level
  read is lossless, and the transport is already level-polled. Edge events would mean
  bridging a blocking fd into the coroutine world against the single-parallelism
  dispatcher that owns the radio - a later optimisation, not a blocker.
- **The chardev enforces exclusivity itself** (`EBUSY`), so no `/proc`-scanning
  `spidevHolder` twin is needed; `GET_LINEINFO` names the current consumer.
- **Testable with no radio** via the kernel's `gpio-sim` module - real chardev ioctls
  against a simulated chip. UNVERIFIED whether CI can load kernel modules.
- Hand-lay the v2 structs as `SpidevSpiBus` already hand-lays `spi_ioc_transfer`; the
  spike derived the sizes and ioctl numbers (`GPIO_V2_GET_LINE_IOCTL = 0xC250B407`).
  One trap: a mixed input/output request needs a per-line flags attr **and** an
  output-values attr giving RESET high at request time, or the fd holds the chip in
  reset from the moment it opens.

## The spidev LoRa backend, and the uConsole sitting (2026-09-07)

`node-transport-lora` had one way to reach an SX1262: a CH341A USB bridge over
libusb. A single-board host solders the module to a kernel SPI bus instead, so the
JVM source gained a second backend, chosen by the host naming it:

    MESH_LORA_SPIDEV=/dev/spidev1.0

Named rather than probed, and that is the design point. A machine can carry several
`spidev` nodes with a radio behind only one of them; clocking SX1262 commands at
whatever else is on the bus is not a guess worth making automatically. The env var
wins over libusb when set, because a board with a soldered module has no bridge to
find and libusb would report an empty bus for ever.

Three things the backend does that the USB one need not:

- **`spidevHolder`** looks for another process already holding the node, because
  spidev enforces no exclusivity - it will happily let us open a bus meshtasticd is
  driving and let both of us clock one chip. The bearer row names the holder.
- **`SpidevSpiBus`** lays `struct spi_ioc_transfer` out by hand, 32 bytes, rather
  than trusting a JNA mapper's alignment against a fixed kernel ABI. The trailing
  pad byte is part of the struct and the kernel rejects a short one. (Getting this
  wrong is silent: a 34-byte struct fails the ioctl with `ERANGE`, which reads as a
  bus problem.)
- **`NoGpioPins` errors rather than no-oping**, and `SPIDEV_UNKNOWN_BOARD` leaves
  every pin null with `dio2AsRfSwitch = false`. Every line is optional in the
  driver - no NRST skips the reset pulse, no BUSY uses RadioLib's fixed delays, no
  DIO1 polls `GetIrqStatus` over SPI - which is enough to read the version register
  and prove the bus. Proving the bus is the step that comes before guessing at a
  board's wiring, and `dio2AsRfSwitch` asserts nothing until a board is known
  because false costs transmit range and true is a command the wrong chip ignores.

**Corrected 2026-09-09: the chip was there all along, held in reset.** Everything
below this paragraph was written from real readings and the wrong conclusion; the
resolution is in "The uConsole LoRa fix" further down. Keep it for the reasoning,
not the verdict.

**What the uConsole then taught: a bus can be proven and still have no chip.** The
board is a Compute Module 5 Lite, and its HackerGadgets AIO answers on neither
`spidev1.0` (all `0x00`) nor `spidev10.0` (all `0xff`) - unchanged by an NRST pulse
or by holding GPIO11 high. **Two different stuck values are the useful signal**:
they prove both transfers really executed, so the ioctl path is sound and the chip
is simply absent. `config.txt` hides `spi-gpio35-39` and `gpio=11=op,dh` under
`[cm3+]`, the CM3+ *product* filter, which a CM5 skips; that overlay relocates
hardware SPI0 anyway and would create `spidev0.x`, never the `spidev1.0`
meshtasticd's yaml names. meshtasticd has never started there at all, aborting on a
`gpiochip0` this kernel does not have. So its `IRQ 26 / Busy 24 / Reset 25` is
**intent, never proof**, and no board profile or Linux GPIO chardev backend was
written - that would be untested code against unproven, self-contradicting wiring.
Details and the open question in
[`handoff-multi-transport.md`](./handoff-multi-transport.md) → The bench.

The sitting also produced `0d7b007`: a `Detached` bearer now takes its wording from
the device source, because "no CH341 stick attached" named a bridge a spidev host
does not have; and an init failure that never changes is logged once rather than
every retry, which on a bus with no chip was 73 identical lines in five minutes.

## The car sitting (2026-09-11, Pixel 9 Pro, on the road to VCF Midwest)

Kit in the car: the Meshtadpole, a WisMesh Pocket (still on its spike load), four
T1000-E/T-Beam-class radios on a private channel, one Pixel 9 Pro on Android 17
acting as hotspot. `:monitor-android` from `7bfab20`, later `e808296`.

### Proven

- **LoRa via the Meshtadpole on a Pixel 9 Pro**, USB-C OTG, 906.875 MHz at 10 dBm:
  all four car radios `lora direct` at -44 to -61 dBm within a minute of plugging
  in. One NodeInfo went out on LoRa; whether a radio listed `!9c724d03` was not
  checked from the car.
- **The Pocket bridges LoRa onto BLE-adv**, and the phone hears both: the same
  packet ids arrive `rx[lora]` and `rx[ble-adv]`, the second dropped `DUPLICATE`.
  Before the Tadpole was plugged in the phone already had four peers over
  `ble-adv` alone, from a radio it never touched.
- Every frame was `opaque (chan #50)`: the monitor's one channel is LongFast with
  the default key and the group is on a private one. Channel import in the
  monitor, or the radios on default LongFast, is the open decision for the show.
  Chicagoland Mesh is LongFast, US, slot 20, with a published secondary
  "Chicago" channel, so the default key reads the public local mesh as-is.
- **Wi-Fi Aware will not attach while the phone is the hotspot** - `would not
  attach (N in a row)`, NAN and SoftAP do not coexist on a Pixel. Phone-to-phone
  Aware at a venue means hotspot off.

### The defect: a pairing dialog every 30 s

The phone held a bond with the Pocket from the stock app; the Pocket had been
reflashed since and no longer had its half. The monitor's central connected (the
Pocket advertises the mesh-peer UUID), Android encrypted the bonded link on its
own, got `LE_ENCRYPT_FAILURE`, dropped the bond, began "autonomous repairing" -
the dialog - which timed out after 30 s, dropped the link, and the next
advertisement started it over. `dumpsys bluetooth_manager` shows it as one
connect per 32 s, disconnect reason 22, reconnect 300 ms later, from 15:48 until
the `gatt` chip was turned off. The same connect discovered against Android's
cached attribute table, so "no mesh characteristic among 6 services" was the
stale cache rather than the radio.

Fixed in `meshtastic-node-kmp` `e808296`: the Android central skips any radio the
device is bonded to (named once in the fault channel - a mesh-peer link is
unpaired by design, and a bonded radio belongs to the app that paired it), and a
peer dialled and dropped before it reached ready is held off by `RetryBackoff`,
5 s doubling to 60 s - the BlueZ gate from 2026-09-08, moved to commonMain with
its test so both centrals share it. Three minutes with GATT back on: no bond
events, no connections to the Pocket, no dialogs, LoRa and BLE-adv unaffected.
The bonded-skip branch was exercised on hardware; the Android backoff branch was
not - the only advertising peer was bonded - so that half is unit-tested and
wired, not proven live. Gate run: the module's jvmTest (122), `checkKotlinAbi`,
`spotlessCheck`, `detekt`, the APK; not the per-target `allTests` or Apple links.

Two follow-ups. The skip renders as `fault:` in the status header and stays there
as the last fault, which reads as a problem during a demo. And the trade-off is
deliberate but real: a phone can never mesh-peer with the radio its own stock
app is paired to; forgetting the Pocket in Bluetooth settings would also test the
cached-table theory, at the cost of re-pairing the stock app.

### The stock app on the phone's own node (2026-09-11, later the same drive)

James's call, made in the car: the monitor was re-implementing what
Meshtastic-Android already does, so the demo is the stock app with the phone as
the radio. Two paths were weighed - the phone API over loopback TCP (the node's
server is JVM-only today, `platformServe` on Android is a null stub) and an
in-process transport in the app - and the in-process one was chosen, with the
protobufs pin aligned by hand for the demo rather than solved.

**Built and proven on the Pixel 9 Pro, in the car:**

- `meshtastic-node-kmp` published to `~/.m2` as
  `0.1.0-pb2.8.0.35-g3b3df2a-SNAPSHOT` (`-PprotobufsVersion=` android's pin,
  from `e808296`); android's `core/network` resolves the six modules' Android
  variants from it with `-PuseMavenLocal=1`, one protobufs, one Wire runtime.
- android branch `feat/node-transport-demo` (pushed, not mergeable):
  `NodeRadioTransport` in `core/network` androidMain runs a `MeshNode` and
  speaks `PhoneApiSession` to the app; `InterfaceId.NODE('p')`, offered as
  "This device as a mesh node" behind the Demo Mode gate;
  `BLUETOOTH_ADVERTISE` added to the manifest and both runtime permission
  lists. `meshtastic://meshtastic/connections?address=p` selects it.
- The stock app connected to its own node - "Pixel 9 Pro node, firmware
  2.8.0-node-kmp" - and ran its handshake, telemetry and store-and-forward
  requests against it unmodified. Setting the region on the app's own LoRa
  screen wrote `set_config(lora)` into the node's `AdminService`; the transport
  rebuilt the node with a LoRa bearer (DeviceSleep then Connected, the radio
  reboot shape), the system asked USB permission for the Tadpole, and the SX1261
  came up. A car radio (`!da574db8`, "wiggie") appeared in the app's node list
  within a minute.

**Two library facts that bit, both in `LocalRadio`:** it reports the bearer's
region over the phone's write and `AdminService.persist()` stores that view, so
a region written to a node with no LoRa bearer is (a) invisible to
`preferences()` and (b) persisted as UNSET. The transport reads the written
section from the `NodeSettings` overlay instead, and after rebuilding re-issues
`setConfig(lora)` through the new node's radio view so the store carries the
region. Both belong in the library; recorded here, not fixed there.

**Also seen:** choosing a US region in the app's LoRa screen flips the preset
to LONG_TURBO (the 2.8 region default) - set LONG_FAST back by hand for the
group and Chicagoland. The node reported `hop_limit 0` to the app on first
read; set hops to 3 before saving or nothing relays the phone's packets. TX
power 0 from the app maps to the 10 dBm OTG cap. The monitor and the app must
not both run a node on one phone.

**Not done:** Wi-Fi Aware and UDP bearers in the app transport, a foreground
service of its own (the app's `MeshService` keeps the process alive for now),
channel import from the app side untested, the spec lifecycle skipped on
purpose.

**Later the same evening.** A text sent from the app's LongFast conversation
went out on LoRa (`tx ok len=45 toa=600ms`) and came back as an implicit ack
340 ms later, so a radio heard the phone node and relayed it; the app showed
"Delivered to mesh". Which bearer the radio heard us on is not knowable from
the log: the Pocket bridges LoRa onto BLE-adv, the LoRa bearer logs no receives
and `NodeRadioTransport` collects `node.events` without logging them, so the
"Hops Away 1" on every radio and the ack path stay unattributed. Logging
`MeshEvent.Sent/Received/Delivered` with their bearer names is the first thing
to add before a demo. Region persistence held: after a force-stop and
reinstall the node came up `on gatt, ble-adv, lora` with the SX1261 tuned to
906.875 MHz and nothing re-saved. The car radios have not been heard since
about 17:30; the Pocket's absence or the radios' private secondary are the two
guesses, neither checked.

**Polish pass, 18:30.** The transport now logs every `MeshEvent` (bearer named
on each) and sets `hopLimit = 3` at build time: the library's default is 0, so
a fresh install would have sent packets nothing relays - the "hops 0 on first
read" was the node's truth, not a display bug. With events visible: the phone's
NodeInfo goes out `via=[ble-adv, lora]` (GATT had no peer), wiggie's packets
arrive on both bearers and the copies drop `DUPLICATE`, all four car radios are
`Opaque(channelHash=50)` on LoRa at -42 dBm, so the group is chatting on its
private channel right now and only NodeInfo is readable. Radios are being heard
after the restart; the "58 min ago" Seeeds are the radios, not the receiver.
Two things found on the phone itself: the Play-store `com.geeksville.mesh` is
running its own `MeshService` alongside the debug build (it is the app that
bonded the Pocket), and the battery sits at 22 % and cannot charge with the
Tadpole on OTG - the stick draws from the phone. The main logcat buffer was
64 KB and rotated inside a minute; set to 16 MB (`logcat -G`), survives until
reboot. A stale "Pairing request" notification from 15:52 is still in the shade.

**Round trip, 18:45.** After importing the group's channel URL in the app
(olm3sh primary, IROMesh, LongFast; the URL's LoRa section also triggered a
needless bearer rebuild), the two apps on one phone exchanged texts on olm3sh:
demo node -> LoRa -> T1000-E -> BLE -> Play-store app ("PIXE: demo node to prod
1841" in its list, Sent `via=[ble-adv, lora]`, implicit ack `via=ble-adv`
within the second), and Play-store app -> T1000-E -> LoRa -> demo node
(`TextMessage(from=!5264ff52 ... rssi=-23, via=lora)`, shown in the demo app's
olm3sh conversation). First decoded text from a radio, both directions.
