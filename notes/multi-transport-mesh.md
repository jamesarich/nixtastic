# One protocol, many bearers — the multi-transport mesh plan

Written 2026-09-03. Supersedes the "BLE bridge" framing in
[`ble-mesh-transport.md`](./ble-mesh-transport.md) (still good as analysis).
Grounded in four investigations run 2026-09-03: firmware BLE-connection limits,
firmware multi-transport model, the `node-transport-ble-gatt` state, and external
research on connection-oriented meshing.

The ask that started this: *"holistically leverage / interoperate / bridge
between all transports available on each device — LoRa, UDP, BLE-adv, BLE-GATT,
Wi-Fi, MQTT — extend the mesh via as many transports as possible."*

## Implementation status (updated 2026-09-03)

All commits below are **local, not pushed**.

- **Phase 1 (client) — the automatable part is done, green.** On
  `meshtastic-node-kmp` `feat/ble-gatt-transport`:
  - `fb5a3ab` — don't echo a relay back to the sending peer (origin token
    threaded `InboundFrame.source` → `exclude`); validate-before-relay confirmed.
  - `4009b05` — per-peer whole-packet delivery accounting.
  - `4159bd7` — reframed the "split-horizon" misnomer to plain wording
    (test class → `RelayDoesNotEchoToSenderTest`).
  - *Pending, bench-gated:* DUAL-role connection arbitration + a low (2–3)
    connection cap, and per-peer send-queue concurrency (Android's device-wide
    GATT-op behaviour must be verified on hardware).
- **Cross-platform GATT interop PROVEN on hardware, 2026-09-03** — Android
  (Pixel 6a) ↔ iOS (iPad), **bidirectional, decoding at the mesh layer** (not
  just transport bytes): Pixel `!6337995d` ↔ iPad `!b28c3748` exchanged text both
  ways over BLE GATT, each side running full packet processing (reassembly →
  decode → channel decrypt → dedup). Proven via the new `:monitor` CMP app on
  dual dashboards. Two bugs found + fixed on `feat/monitor-app`:
  - `17b0bd1` — **the bug that hid interop for hours:** `MonitorController`
    derived its NodeNum from a *constant* seed, so every device was `!2c2926ac`;
    two same-id nodes drop each other's frames as "heard myself" (silent, no
    event) over a live link. Fixed with a `platformNodeSeed()` seam (Android
    `ANDROID_ID`, iOS `identifierForVendor`, desktop user@host). **Any client
    node needs a per-install identity, never a hardcoded seed.**
  - `1010c12` — `gattLog` used K/N `NSLog` (unusable: `%s` silent, `%@` crashes);
    switched to `println` read via `devicectl … process launch --console`.
  - **KNOWN ISSUE (tuning backlog): the iOS-*central* outbound path is flaky.**
    The iPad-peripheral ← Pixel-central *inbound* link forms reliably (every one
    of 6 captures) and is bidirectional on its own (central writes, peripheral
    notifies), so the mesh has a dependable link. The iPad-central → Pixel-
    peripheral direction is unreliable at the *discovery* step: `didDiscover­
    Peripheral` sometimes fires + connects, sometimes fires + stalls (no
    connect-timeout / no failure recovery), sometimes never fires — a
    CoreBluetooth central scan-delivery/lifecycle issue upstream of the connect,
    not a missing timeout. A `didFailToConnectPeripheral` handler was added
    (forgets the dead peer + rescans) as a standalone correctness fix. The full
    fix (why the central scan stops delivering; DUAL-role arbitration so only one
    side dials) is deferred to the tuning stage. Evidence in
    `ble-mesh-interop-bench` memory.
- **Phase 2 (firmware transport registry) — complete, green.** On `firmware`
  `spike/ble-mesh-transport` (native suite 1392/1392, 0 failures):
  - `009127773` — `MeshTransportBase` registry (MeshModule-style); UDP + BLE-adv
    taps routed through the post-encode hook; LoRa's `iface->send` untouched.
  - `d8ea49801` — MQTT moved onto the registry via a second **pre-encode** hook
    (it needs the decoded packet + chIndex, fires only for `isFromUs`
    originations, never for relays).
  - *Deliberately out of scope:* the receive-path MQTT tap (`Router.cpp:1631`,
    `!isFromUs`) stays a hardcoded `mqtt->onSend`; a no-LoRa transports-only node
    (would need relaxing `assert(iface)` — LoRa stays first-class, so opt-in only).
- **Phase 3 (firmware BLE-GATT mesh-peer edge) — service WRITTEN + committed,
  hardware bring-up proven on the ESP32-S3; cross-device frame exchange still
  bench-gated. 2026-09-03.** Committed on `firmware` `spike/ble-mesh-transport`
  as `3022a3776` (14 files, +1725): `BLEGattMeshHandler` (platform-neutral —
  framing shared byte-for-byte with the node-kmp client, bounded reassembly, the
  UDP/adv ingress guards, per-peer TX ring, no-echo-to-arrival-peer) and
  `ESP32BLEGattMesh` (NimBLE — own connectable adv set on **instance 2**,
  per-connection notifies, MTU-derived chunk, a GAP handler chained ahead of the
  Arduino wrapper's, PhoneAPI-disconnect gating). Registry-gated on the new
  `BLE_GATT_PEER` protocol flag. The sdkconfig bump landed **with** the service:
  `CONFIG_BT_NIMBLE_MAX_CONNECTIONS=2` / `CONFIG_BT_CTRL_BLE_MAX_ACT=6`
  (ROLE_CENTRAL stays off — phones connect *inward*). Proto pointer bumped for
  the `TRANSPORT_BLE_GATT` + `BLE_GATT_PEER` enums; generated headers regenerated.
  - **Proven:** native suite **1418/1418** (26 new cases for this transport);
    heltec-v3 built + flashed, and with **WiFi off** (`network.wifi_enabled=false`
    at runtime, PSK never written) it brings the service up clean —
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
  - **Remaining (spike → production):** revert the verbose diag logs; `notify()`
    currently broadcasts to all subscribers rather than excluding the arrival peer
    (dedup covers it, but per-peer targeting is the correct fix); a subscribe
    watchdog + DUAL-role arbitration per the research note.
  - **Still to gate:**  - **Still to gate:** ESP32-C3 (single-core, tighter RAM — the likely-fail
    candidate) and nRF52 (`Bluefruit.begin(2,0)` + linker RAM); neither board is
    on the bench, both unbuilt.
  - **Current v3 bench state (left test-ready 2026-09-04):**
    `enabled_protocols=7`, `network.wifi_enabled=false`, `bluetooth.mode=NO_PIN`
    (user's original was `RANDOM_PIN`). **Cleanup owed once done:** restore
    `wifi_enabled=true`, `enabled_protocols=3`, `bluetooth.mode=RANDOM_PIN`, reboot.
- **Phase 4 — future** (Wi-Fi Aware, anti-entropy sync).

---

## The one idea

**Every device runs one mesh node that carries every transport it physically
has, and nodes bridge automatically at the frame layer.** There is no "the BLE
mesh" or "the UDP mesh" — there is *the mesh*, and a bearer is just how two
adjacent nodes happen to be able to reach each other.

This is not a new architecture. Both sides already do it; they just do it at
different maturity:

- **Client (`meshtastic-node-kmp`) — has the clean version already.** `MeshNode`
  holds a *collection* of `MeshTransport`s; `broadcast()` loops every transport
  whose `canTransmit` is true and re-frames per medium via `FrameAdapter`; dedup
  is `PacketHistory.wasSeenRecently(from, id)`, transport-agnostic. Adding a new
  transport = implementing one interface. The registry the firmware lacks already
  exists here.

- **Firmware — has an emergent version.** `Router::send()` is a single funnel:
  MQTT tap, then UDP tap, then the one hardcoded LoRa `iface->send`. A packet
  received on any transport re-enters that funnel via the flood router and so
  re-emits on all the others — **bridging is a free side effect**, not designed.
  The only loop guard is `PacketHistory` keyed on `(from, id)` alone — no
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
| **LoRa** (RF backbone, km) | ✓ backbone | ✓ backbone | — | — | — |
| **BLE-adv** (connectionless, ext-adv) | spike ✓ | spike ✓ (rak4631 RX) | ✓ | **RX only** (no TX) | BlueZ (future) |
| **BLE-GATT** (connection, dual-role) | phone-API only¹ | phone-API only¹ | ✓ | ✓ | BlueZ (future) |
| **UDP multicast** (LAN) | ✓ (wifi/eth) | ~ (eth) | ✓ | ~ (entitlement) | ✓ |
| **Wi-Fi Aware** (Android↔Android) | — | — | ✓ (future) | — | — |
| **MQTT** (internet, infra-backed) | ✓ (wifi/eth) | ~ | ✓ | ✓ | ✓ |

¹ Firmware today runs a GATT *server* for the phone control app only
(`TRANSPORT_API`, service `6ba1b218-…`) — not a mesh bearer. No firmware target
compiles the GATT *client/central* role at all.

**Three tiers, by reach — the useful mental model:**

- **Backbone — LoRa.** Kilometres, firmware-only, duty-cycle limited. The
  long-haul spine. Unchanged by this plan.
- **Local — BLE (adv + GATT), UDP, Wi-Fi Aware.** Metres to a room/LAN. This is
  where phones join, and where iOS becomes a native peer.
- **Global — MQTT.** The internet bridge; already how the mesh spans continents.
  Infra-backed, so it is a *policy* bearer (uplink/downlink per channel, gateway
  identity) more than an RF one.

**Why GATT is special:** it is the *only* bearer every client platform can both
transmit and receive on. iOS cannot transmit BLE advertisements at all
(`CBPeripheralManager` accepts only name + service UUIDs). So GATT is the bearer
that makes iOS a first-class node without a bridge — which is the real prize
behind "everyone on GATT."

---

## Design invariants (true today; must stay true)

Any new bearer, on either side, must hold all five:

1. **One canonical `MeshPacket`** on the wire, or a `FrameAdapter` that
   translates to/from it. (Firmware LoRa is the sole non-canonical framing today;
   every other bearer carries a whole encoded packet.)
2. **Dedup keyed on `(from, id)` only** — never on the bearer. This is the loop
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
   every bearer at once — keep it that way rather than per-bearer relay rules.

---

## Where the effort actually is

Ranked by value-per-risk, from the four investigations.

### Phase 1 — Client N-transport mesh node (`node-transport-ble-gatt` + `node-core`)

**Risk: low. Value: high. Client-only. ~70% already built and hardened.**

The GATT transport is already dual-role with a real multi-peer table,
connect-to-all discovery, per-peer keyed reassembly, per-peer MTU, and fan-out
broadcast. The node's flood logic (dedup, hop-limit, contention-window relay) is
already bearer-agnostic and already relays over GATT. Net-new, all scoped:

- **Don't echo a relay back to the sending peer.** Today a relay writes to *all*
  GATT peers including the one that just handed it the frame; only `(from,id)` dedup
  saves it (correct, but a wasted point-to-point write every hop). Not routing —
  just skipping a unicast to a peer that provably already has the packet. Structural
  blocker: the transport drops the sending `peerId` before the node sees the frame.
  Fix = thread the sending-peer token up through `InboundFrame` and an `exclude`
  down through `send`/`broadcast`. Cross-cutting but small.
- **Per-peer backpressure.** One global `txLock` serialises all sends; a departed
  peer can stall every peer for the ~20 s Android supervision timeout. Needs
  per-peer send queues / failure isolation.
- **Connection arbitration + a *low* cap.** The dual-role connect race collapses
  two nodes onto one one-directional link. And Android's ~7-connection ceiling is
  **device-wide** — shared with the user's watch, earbuds, car. A greedy mesh
  breaks the user's other devices and gets uninstalled. So: default degree **2–3**
  with multi-hop, not link-maximising, and per-pair arbitration (bitchat-style).
- **Relay-before-validate guard** (invariant 4) and **per-peer whole-packet
  delivery accounting** (currently reports success on partial fan-out).
- **Confirm cross-bearer behaviour end-to-end:** the client can already carry
  UDP + BLE-adv + GATT at once; verify dedup holds across them and the
  don't-echo-to-the-sender skip is applied per-bearer.

**Outcome:** iOS / Android / macOS are native GATT mesh peers, no bridge device.
This is worth shipping on its own merits regardless of what firmware does.

### Phase 2 — Firmware transport registry (issue #8152, already open, member-authored)

**Risk: moderate. Value: high leverage — everything else rides on it.**

The firmware has *no* transport abstraction: `Router` holds exactly one `iface`
(`Router.h:50`), `RadioInterface` models LoRa *chips* not bearers, and every
non-LoRa transport is a hand-added tap. Issue #8152 ("UDP bridging hasn't got the
same control as MQTT") is the live tracking issue for exactly this. The work:

- Introduce a real transport interface (distinct from the LoRa-chip-bound
  `RadioInterface`): `onSend(packet)` + an ingress callback, held by `Router` in a
  **collection**, egress iterating it.
- Give every bearer the per-bearer control MQTT already has (enable, uplink/
  downlink, filter) — UDP has a single global bit today.
- Generalise invariant 3 (don't-echo-arrival-bearer) uniformly; fix the UDP→UDP
  re-emit bug (`UdpMulticastHandler.h:123-125`) as a side effect.
- Let the registry hold peers *alongside* LoRa — **without demoting it**. LoRa
  stays the first-class, default interface with its place in the send order; the
  registry is additive (today `Router` holds exactly one `iface`). Relaxing the
  hard `assert(iface)` (`Router.cpp:614`) to allow an optional transports-only
  node (a Wi-Fi/BLE-only indoor node) is a *later, opt-in* capability, not a
  change to LoRa's status — pursue it only if such a node is actually wanted.
- Fold the **BLE-adv spike into this registry** rather than as another
  special-case tap — that retires the spike's copy-paste and is the natural home
  for it.

**Outcome:** adding *any* bearer (GATT, another radio, a future one) becomes
implementing an interface, not editing `Router::send`. This is the structural
unlock for "as many transports as possible."

#### Blockers, identified up front (firmware deep-read 2026-09-03)

Ranked by severity. The headline: **every HARD/MODERATE blocker is avoided by the
same rule — keep LoRa on its own `iface`, make the registry a *parallel* fan-out,
never route LoRa through it.**

1. **HARD — `RadioInterface` is the wrong base for non-LoRa transports.**
   `RadioInterface.h` has ~30 LoRa-*physical* members (airtime, RSSI/SNR, TX
   power, region/modem config, CAD, contention window) vs ~6 generic ones, and
   two are pure-virtual and LoRa-bound (`send`, and `getPacketTime(uint32_t,bool)`
   at `:240`); the base ctor even derives `slotTimeMsec` from LoRa params
   (`:104`). A UDP/BLE transport cannot honestly implement it.
   *Mitigation:* introduce a **new thin interface** (~4 members: `onSend`, a
   transport-owned ingress ending in `enqueueReceivedMessage`, `enable/disable`,
   optional `retransmitDelayMsec`). LoRa stays a `RadioInterface`, *adapted* into
   the registry — never reparented.

2. **MODERATE — tap policy is per-transport and rich; naive unification breaks
   it.** MQTT egress needs the encrypted *and* decoded packet + `chIndex` and
   gates on `isFromUs` + `via_mqtt` loop-prevention + per-channel uplink
   (`Router.cpp:592`, `MQTT.h:44`, `MQTT.cpp:701-751`); UDP egress is ungated and
   runs *post-encode* (`Router.cpp:600`). Ingress sanitising differs too (UDP
   drops spoofed `isFromUs`, clamps hops, zeroes RSSI/SNR, clears PKI —
   `UdpMulticastHandler.h:78-100`; MQTT sets `via_mqtt` + downlink checks —
   `MQTT.cpp:122-179`). *Mitigation:* the interface contract must carry
   (encrypted, decoded, chIndex) and a pre/post-encode hook choice, and ingress is
   a transport-owned sanitise step. Enumerate these as the transport's policy —
   do not collapse to a bare `onSend(p)`.

3. **MODERATE — relay/retransmit timing references the LoRa `iface`
   unconditionally.** `ReliableRouter.cpp:44,100`, `NextHopRouter.cpp:555`,
   `FloodingRouter.cpp:146,150` compute backoff/late-rebroadcast against LoRa
   airtime regardless of arrival bearer. *Degrades gracefully* (a LoRa airtime
   figure used as the estimate — conservative, not corrupting). Precedent in our
   favour: `perhapsCancelDupe` is *already* gated on `TRANSPORT_LORA`
   (`FloodingRouter.cpp:139`) — the flood code already anticipates mixed
   transports. *Mitigation:* let a transport supply its own retransmit delay;
   LoRa-as-default keeps behaviour identical.

4. **MODERATE — LoRa singletons + single-slot `iface`.** `addInterface` replaces
   one `unique_ptr` (`Router.h:62`), and `RadioLibInterface::instance` / `airTime`
   / `SimRadio::instance` are consulted directly across UI/power/RNG. *Mitigation:*
   additive registry alongside LoRa touches none of these — they keep pointing at
   LoRa. (Only *routing LoRa through* the registry would hit them. Don't.)

5. **MODERATE — `BLE_BROADCAST` needs a cross-repo proto bump.** Absent from
   `ProtocolFlags` on develop (only `NO_BROADCAST`, `UDP_BROADCAST` —
   `config.proto:584-594`); adding it regenerates the protobufs submodule consumed
   by firmware + python + apps + SDK (additive, non-breaking). *Mitigation:* the
   reserved `TransportMechanism` slots `TRANSPORT_LORA_ALT1..3` (`mesh.proto:1729`)
   and `TRANSPORT_UNICAST_UDP=8` need **no** bump; only the BLE enable *bit* does,
   so sequence the proto change with Phase 3, not Phase 2.

**Confirmed non-issues (assets, not blockers):**

- **`MeshModule` is a ready-made registry template** — `static std::vector<MeshModule*>`,
  ctor self-registration, `callModules` iteration, `CONTINUE/STOP` + `wantPacket`
  (`MeshModule.h:65,71,79,161,168`). Copy it verbatim; match its raw-`new`-and-leak
  boot-singleton idiom, don't add ownership churn.
- **Dedup is transport-agnostic** — `PacketHistory` keys on `getFrom(p)` + id only
  (`PacketHistory.cpp:83`), no LoRa/RSSI/airtime reference. Invariant 2 holds free.
- **Router is already unit-tested natively via mock interfaces** — `test_nexthop_routing`
  installs a `MockRadioInterface` through `addInterface` (`test_main.cpp:165,333`).
  A `test_transport_registry` follows the same shim. Cheapest thing in the plan.
- **No flash-size CI gate**, and each transport is already behind
  `HAS_*`/`MESHTASTIC_EXCLUDE_*` guards, so constrained variants (C3, non-rak
  nRF52) compile them out. Size risk: MINOR.

#### The de-risking first PR (zero behaviour change)

Prove the registry carries real, divergent transports **before** adding any new
one: introduce the thin `MeshTransport` interface + a `MeshModule`-style
`TransportRegistry`, then wrap the *existing* `udpHandler` and `mqtt` egress/
ingress as two registry entries — replacing the hardcoded taps at
`Router.cpp:592,600` with a registry iteration that preserves each tap's exact
gating (isFromUs + pre-encode for MQTT, `enabled_protocols` + post-encode for
UDP). LoRa's `iface->send` (`Router.cpp:615`) is left untouched. Ship with a
native `test_transport_registry` asserting MQTT loop-prevention and UDP spoof-drop
still hold. This changes zero behaviour, adds no wire/proto surface, and cannot
destabilise LoRa — the LoRa path is not modified. Only *after* it lands do BLE-adv
(fold in the spike) and BLE-GATT (Phase 3) become "implement the interface."

### Phase 3 — Firmware BLE-GATT mesh-peer edge

**Risk: moderate, gated on one empirical number. Value: iOS reaches a radio
directly, no bridge device.**

Add a mesh-peer GATT service so a phone (crucially iOS) connects to a firmware
node as a mesh *edge client*, and the firmware relays between its LoRa mesh and
the connected phone(s). Each firmware node becomes its own proxy — this is the
SIG-Mesh "GATT Proxy" role, the standard name for what the bridge chain proved by
hand. Firmware-to-firmware stays LoRa; **no firmware central role, no backbone
formation, no degree-constrained topology, no self-heal** — this deliberately
dodges every hard scatternet problem.

**The gate — one cheap bench experiment, decisive:** the firmware is peripheral-
only, capped at one connection, with NimBLE buffers *deliberately trimmed to
exactly one link* to dodge a contiguous-heap OOM at bring-up
(`esp32-common.ini:289-294`). So the whole phase turns on: **does raising
`CONFIG_BT_NIMBLE_MAX_CONNECTIONS` 1→2 still let `BLEDevice::init()` return on the
S3 and the C3?** Bump it in a spike build, flash the bench v3, watch for host
sync. If yes on S3 but no on C3, the plan goes chip-tiered. The nRF52 mirror:
`Bluefruit.begin(2, 0)` re-runs SoftDevice RAM sizing and moves the linker ORIGIN
(`NRF52Bluetooth.cpp:284`, `nrf52840_s140_v6.ld:29`) — also cheap, also decisive.
And the ext-adv discovery collision (`NimbleBluetooth.cpp:850-861`, already solved
in the spike) applies: the connectable advert is full with one 128-bit UUID, and
enabling ext-adv is host-global.

Serves a small number of phones per radio (the one-connection cap only widens to a
few). That is fine — it complements, never replaces, the LoRa backbone.

### Phase 4 — New bearers on the unified seam (opportunistic / future)

Once Phases 1–2 exist, these are "implement one interface":

- **Wi-Fi Aware** as a client transport (`node-transport-wifi-aware`), Android↔
  Android — far more bandwidth than BLE, on the existing seam (Knit ships this).
- **Content-digest anti-entropy sync** (Knit / IPFS Bitswap / range-based set
  reconciliation): an idle mesh does zero data-path work; a new message triggers a
  *targeted* sync only with peers that need it. Directly answers the "N writes per
  packet" cost of flooding a connection-oriented bearer.
- **Firmware↔firmware BLE-GATT backbone** — the FruityMesh-style connection mesh.
  Only if a real need emerges (LoRa duty-cycle limits, no-LoRa nodes, dense
  indoor, throughput). This is where the *known-hard* problems live: BLE has no
  mid-link role switch (central/peripheral elected permanently per link),
  degree-constrained formation is NP-hard, and self-heal under churn is a
  literature gap — the very things that kept scatternets in simulation for 20
  years. High risk; treat as research, not roadmap.

---

## Retiring the advertisement transport

The original prompt was "drop the advertisement transport." The nuanced answer:
**yes, eventually — but not first.** Sequencing matters:

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

1. **RESOLVED 2026-09-03 — LoRa is the first-class transport; it owns the firmware
   backbone.** BLE is for phones (Phases 1–3). Firmware↔firmware BLE-GATT (Phase 4)
   is *not* a goal — LoRa carries firmware↔firmware. The multi-transport registry
   (Phase 2) is additive and must never demote LoRa or displace it from the send
   order.
2. **Bench bring-up test** — approved to run Phase 3's gate (flash the shared v3
   with `MAX_CONNECTIONS=2`) whenever you want the firmware phase de-risked.
3. **Where does the firmware transport-registry work land** — a fresh spike branch
   off `develop`, or fold into the existing `spike/ble-mesh-transport`?

---

## Prior art carried in

- **SIG Mesh GATT Proxy** — the standard name for the Phase-3 edge. SIG Mesh runs
  data on the *advertising* bearer and uses GATT only as a one-client-to-one-proxy
  edge; a pure connection-oriented GATT data mesh is non-standard there (but not
  novel — it is the scatternet lineage, and it *ships*: FruityMesh/BlueRange on
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
  note previously listed — the implementer fixed all four exactly as diagnosed
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
  adversarial second-pass review of the code has happened — worth one before a PR.
- **No hardware.** Nothing has touched a Meshtadpole; the Android USB path compiles
  into the APK but is unexercised. Pin map, TCXO/DIO2 switch, CH341 SPI clock, and
  whether a Pixel 6a OTG port sustains 10/22 dBm are the open on-device checks.
- Two small node-core deferrals noted by the implementer: `InboundFrame.snr`
  (needs a native klib dump regen; SNR currently on `LoraTransport.lastReception`)
  and `:monitor:detekt` not in the gate.

Resume: an adversarial code review, then the on-device bring-up (Pixel 6a +
Meshtadpole stick), then push / PR.

## Full bench test — all working transports (2026-09-04)

heltec-v3 running the cleaned per-peer firmware (`ea24b26d5`), verified live on
the bench (LoRa + a Pixel 6a `node-kmp monitor` GATT peer):

- **LoRa (transport 0):** RX + TX. Receives packets and relays them (`Lora RX …`
  → `Started Tx …`).
- **BLE advertisement (transport 9, `[BLEMesh]`):** RX. Hears the same nodes over
  BLE advertisements with RSSI (`BLE mesh RX from=… rssi=-76`).
- **BLE-GATT mesh-peer (transport 10):** egress to phone PROVEN. The Pixel app's
  rx counter advanced (2 → 6) and it **decoded** frames at the mesh layer — a
  position from a LoRa node and a **text** "probe from !b28c3748", plus opaque
  channel-50 frames from the v3 itself (`!d1d90f21`).
- **Cross-transport dedup:** one packet id arriving via LoRa **and** BLE-adv is
  deduped by (from,id) — the multi-bearer mesh working as designed.
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

## Desktop UDP monitor added — four bearers meshing (2026-09-04)

Started the `:monitor` Compose desktop app on the Mac (`direnv exec
meshtastic-node-kmp gradle-queue -- :monitor:run`). Its transport is
`UdpMulticastTransport` (239.0.0.69:4403, matching the firmware's
`UdpMulticastHandler`). Enabled the v3's WiFi (`network.wifi_enabled=true`, stored
PSK untouched); it came up on 192.168.1.180 with `UDP multicast already running`,
same /24 as the Mac (192.168.1.138), so multicast bridges.

Live result — the v3 bridges **LoRa + BLE-advertisement + BLE-GATT + UDP** at once:
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
