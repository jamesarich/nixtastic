# Meshtastic mesh protocol over a BLE transport

Feasibility work begun 2026-09-01, carried into a working implementation by
2026-09-02. Two tracks: a firmware node carrying mesh frames over BLE, and a
client app participating as a node with no radio attached.

> **Current status (2026-09-02).** Much of what the sections below frame as
> "planned", "untested", or "recommended" has since shipped — read this banner
> as authoritative where the body still speaks in the future tense.
>
> - **`meshtastic-node-kmp` is its own private org repo** now, not a workspace
>   directory (the "standalone first" recommendation was taken).
> - **Three transports, one interface:** UDP multicast, connectionless BLE
>   advertisements (`node-transport-ble`), and dual-role BLE GATT
>   (`node-transport-ble-gatt`).
> - **Apple transmits** — over GATT, proven on an iPad against a Mac in both
>   directions. The advertisement asymmetry is a limit of *that* transport, not
>   of iOS.
> - **The node is a full node:** PKI direct messages (X25519 → AES-256-CCM,
>   acked by a bench radio) and a proper relay (contention window, cancel on
>   overhear, `next_hop`) are built and verified on the air.
> - **iOS GATT survives a reconnect** now (2026-09-02). The "goes quiet" was a
>   dead reconnect path — the central reconnected a stale cached peripheral —
>   fixed by forgetting the peer on disconnect and rescanning, verified by
>   relaunching an iPad app instance under a connected Mac central and watching
>   the iPad receive again. The shared peer lifecycle now lives in commonMain
>   (`GattPeerTable` + `GattLinkBase`) so the two platform links cannot drift.
> - **Android ↔ iOS GATT is proven directly, no Mac in the path** (Pixel 6a ↔
>   iPad, both directions).
> - Still genuinely open: the on-air framing still uses the SIG test company ID;
>   a multi-minute iOS soak and the app backgrounded are unproven; and the
>   cross-platform interoperability question is answered in the next section —
>   the short version is that no single BLE medium spans every platform, and the
>   unification is at the frame layer, not the radio.

Short version: **it works.** Two boards of different families exchange mesh
frames over BLE 5 extended advertisements, a Kotlin library decodes and decrypts
them, and every platform pair on the bench has carried whole packets. Firmware
lives on `spike/ble-mesh-transport`; the client is the standalone repo
[`meshtastic/meshtastic-node-kmp`](../meshtastic-node-kmp/).

Firmware spike branch: `firmware` → `spike/ble-mesh-transport`
(worktree `firmware/.claude/worktrees/spike-ble-mesh-transport`).

---

## Complete cross-platform interoperability — the honest ceiling

The recurring ask is one BLE meshing approach that Android, iOS, macOS and the
esp32/nRF52 firmware nodes can all use together. The honest answer, grounded in
each platform's BLE stack:

**There is no single BLE medium every platform can transmit on. That is a
platform constraint, not a gap in this design.** BLE offers two meshing shapes
and each platform can only do a subset:

| Platform | Connectionless ext-adv (the firmware mesh) | Connection-oriented GATT dual-role (the phone mesh) |
| --- | --- | --- |
| esp32-C3/S3, nRF52840 firmware | TX + RX — this is what the spike does | not a mesh peer (see below) |
| Android | TX + RX (`startAdvertisingSet`, legacy off) | TX + RX (central *and* peripheral) |
| iOS / macOS | **neither, in practice** | TX + RX — proven, both directions |
| JVM/Linux | neither today (BlueZ would give both) | neither today |

The iOS row is the crux. `CBPeripheralManager.startAdvertising` accepts only a
local name and service UUIDs, so an iPhone **cannot put a `MeshPacket` on the air
as an advertisement at all** — no amount of library work lifts it. The only
connectionless iOS-to-iOS channel is the ~16-byte "overflow area" of hashed
service UUIDs, which no other platform can decode. And iOS **receive** of the
firmware mesh is no better than TX in the field: the spike's frames are
*non-connectable manufacturer-data* extended advertisements, and a backgrounded
iPhone suppresses non-connectable advertisements entirely and only surfaces
connectable ones that match a service-UUID filter. So iOS cannot join the
connectionless mesh even as a listener once the screen is off. Its only real BLE
mesh participation is GATT.

**So the unification lives at the frame layer, not the radio layer.** One
protocol — the encrypted `MeshPacket` and our framing — carried over two media,
with lossless bridging between them. That bridge already exists: `FrameAdapter`
is a per-medium `toCanonical`/`fromCanonical` seam, so a node carrying both
transports re-frames a packet from one medium onto the other without loss. Every
platform is a full node in the *protocol*; the *medium* each uses is dictated by
its BLE stack; the media meet at any dual-transport node. Read "a solution we all
can use" as **already-mostly-built at the frame layer**, not as a single radio
mode that does not and cannot exist.

### The options, and why the recommendation is the hybrid

> **Superseded 2026-09-03 — read
> [`multi-transport-mesh.md`](./multi-transport-mesh.md) for the current plan.**
> The A/B/C framing below is still accurate as *analysis*, but the strategy has
> since widened from "BLE bridge" to a holistic **one protocol, many bearers**
> model (LoRa · UDP · BLE-adv · BLE-GATT · Wi-Fi · MQTT), and option C's flat
> "rejected" is now nuanced: firmware-to-firmware GATT stays rejected for the
> reasons below, but **GATT as a first-class client transport plus a firmware
> mesh-peer GATT *edge*** (a refined option B) is the recommended direction. Four
> fresh investigations (2026-09-03) back the reframe; the plan doc carries them.

- **A — Hybrid + bridge (shipped, recommended).** Phones mesh over GATT
  (Android, iOS, macOS all full peers, proven). Firmware and long range use
  connectionless advertisements + LoRa. A dual-transport node — Android does
  both media natively — bridges the two via `FrameAdapter`. Every platform is a
  node; iOS reaches the firmware/LoRa mesh *through* a bridge. No firmware change.
  The end-to-end path iOS → GATT → Android-bridge → advertisement → firmware is
  now proven as one run on the bench (2026-09-02, see gate 2 below); what remains
  open is a sustained soak and the return path (firmware → bridge → iOS).

- **B — Firmware gains a connectable mesh-peer GATT mode (future, gated).** Not
  "add a GATT server" — the firmware already runs a connectable GATT server (the
  PhoneAPI, service `6ba1b218-…`), and iOS already exchanges `MeshPacket`s with a
  radio over it. But that path is a *star*: one phone as the radio's owner
  (ToRadio/FromRadio), not a neighbour in the mesh. Turning it into a mesh-peer
  mode — the radio relays for a connected phone instead of serving it — is the
  only thing that would let iOS reach a radio *directly* over BLE. It is gated on
  two hard firmware ceilings, so it is not a near-term answer:
  - **One concurrent connection.** Both stacks are built for a single peripheral
    link (ESP32 `CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1`; nRF52 Bluefruit default
    `(1,0)`). A phone on a mesh service excludes the control-app phone, and a
    radio could serve exactly one mesh phone at a time.
  - **No advertisement space, and a host-global ext-adv collision.** The
    connectable advert is already full with one 128-bit UUID (the device name is
    displaced to the scan response), so a second mesh UUID does not fit without
    extended advertising — and enabling ext-adv on NimBLE is host-global, which
    drags the whole phone-facing stack onto the extended API (documented at
    `NimbleBluetooth.cpp:850-861`). iOS background discovery needs that service
    UUID, so this is a real blocker, not cosmetic.

- **C — Everyone on GATT, firmware included (rejected).** Firmware-to-firmware
  GATT meshing throws away the two properties the advertisement mesh exists for:
  the one-to-many shape (one TX reaches every neighbour, versus N connection
  writes) and the overhear that makes flood suppression *possible*
  (`FloodingRouter.cpp:133`). Plus the one-connection cap above. It does not
  scale and defeats the reason firmware broadcasts.

**Recommendation.** Ship A. The protocol is already unified, the bridge seam
already exists, and **the full iOS→bridge→firmware chain is now proven on the
bench** (2026-09-02, see below) — the remaining work is picking the bridge role
deliberately (any Android node, or a dedicated one) and a soak. Treat B as a
genuine enhancement for direct iOS↔radio, but only
worth taking to the firmware once the single-connection limit and the ext-adv
collision are addressed there — and even then it serves one phone per radio, so
it complements the bridge rather than replacing it. This is an org/firmware
decision, not something more client-side work settles.

### Concrete gates before any of this is called "done"

1. **iOS advertisement RX is foreground-only and macOS-class.** The earlier
   receive proof was a *Mac* decrypting a firmware advert; a backgrounded iPhone
   will not see non-connectable manufacturer-data frames. If iOS is ever meant to
   listen to the firmware mesh directly, the firmware frames must become
   connectable and carry a service UUID — which collides with the advertisement
   budget above.
2. **The bridge chain is proven end-to-end** (2026-09-02, no Mac in the path).
   iPad (GATT central) wrote `GattProbePacket` to a Pixel 6a running both
   transports — GATT peripheral in, connectionless advertisement out, the bridge
   — which re-advertised each whole reassembled frame, and the v3 firmware
   (BLE-mesh mode, wifi off) logged `BLE mesh RX from=0x000a11ce id=0x0badf00d
   len=85` 19 times. The `len=85` is the proof it came through the chain: a
   direct Pixel advertisement in the same rig is `len=31` (a hand-built probe),
   and 85 bytes is `GattProbePacket`, which only the iPad sends and only over
   GATT. Nothing advertised directly during the run, so an 85-byte frame at the
   radio can only have arrived iPad-GATT → Pixel-reassemble → Pixel-advertise →
   firmware. Harness: `node-transport-ble`'s `BridgeChainTest` (the Pixel
   bridge), `tools/gatt-probe-ios` (the iPad central), and a pyserial capture of
   the v3 console. What is still unproven is a sustained soak and a return path
   (firmware → bridge → iOS), and the bridge here is an explicit `collect →
   advertise` loop standing in for `MeshNode.broadcast`'s fan-out.
3. **ESP32 mesh RX stability.** The spike documents `BLE_MESH_TX_ONLY` as an
   isolation switch for an ESP32 receive-path fault; treat esp32 mesh receive as
   not-yet-proven-stable.
4. **RX reach by chip.** nRF52 mesh *receive* is gated behind a central link that
   only the rak4631 variant enables (a re-based linker script); other nRF52
   boards are advertise-only. Classic ESP32 (BLE 4.2) cannot carry a mesh frame
   at all — ext-adv is C3/S3/nRF52840-class only.
5. **The SIG test company ID (`0xFFFF`) is still the framing** on the
   advertisement side, unresolved on both firmware and client.

### Prior art, and the ideas worth stealing

Surveyed 2026-09-03. The headline: **nobody has an iOS-transmit trick we are
missing.** Every cross-platform app that includes iOS transmits over
connection-oriented GATT, exactly as we do — there is no advertisement-based path
for an iOS sender, and the survey only confirmed it. The fresh ideas are all on
the *efficiency and reach* side, and three are worth taking.

- **The Bluetooth SIG Mesh "GATT Proxy" role is the standardized name for our
  bridge.** SIG mesh defines two bearers — an advertising bearer and a GATT
  bearer — where the GATT bearer exists so "a device lacking mesh support can
  indirectly communicate with the mesh." A *proxy node* relays GATT-connected
  clients into the advertising mesh. That is precisely the bridge proven above:
  iOS cannot do the advertising bearer, so it connects over GATT to a proxy
  (our Android node) that relays it in. We reinvented it from first principles;
  worth citing so the design reads as a known pattern, not an improvisation. SIG
  mesh's *directed forwarding* is also a relay strategy to compare against our
  managed flood if the mesh ever gets large.
- **[Knit](https://github.com/getknit/knit) is our architecture already shipping,
  and has three ideas to take.** It runs Wi-Fi Aware (NAN) and BLE at once behind
  one `CompositeMeshTransport` seam — the same multi-transport node as our
  `MeshTransport` + `FrameAdapter` — with jittered, overhear-suppressed flooding,
  the same shape as our contention window and cancel-on-overhear. Take:
  1. **Wi-Fi Aware as a fourth transport** (`node-transport-wifi-aware`). Vastly
     more bandwidth than BLE for Android↔Android, on the existing seam. Android
     only — iOS does not expose NAN to apps — so it rides the same bridge model,
     but it is a large throughput win wherever two Android nodes meet.
  2. **Content-digest anti-entropy sync**, so "an idle mesh does zero data-path
     work; a new message triggers a targeted sync only with the peers that need
     it." This is the direct answer to the cost problem this note already flags
     for GATT (§ *Why connectionless advertising, not GATT*): flooding a
     connection-oriented medium is N writes per packet. Syncing deltas against a
     digest instead of flooding could make the phone-GATT mesh far cheaper, and
     it composes with, rather than replaces, the advertisement flood on the LoRa
     side.
  3. **A delay-tolerant store-and-forward layer** that holds messages for peers
     out of range and re-offers when a path appears. We have none, and BLE links
     come and go — this is what carries traffic a single flood does not reach.
  Knit's crypto (X3DH forward secrecy, hardware-backed keys, TOFU + safety
  numbers) is nicer than Meshtastic's channel-PSK/PKI, but we are pinned to the
  Meshtastic wire format for firmware interop, so it is aspirational, not
  adoptable here.
- **[bitchat](https://github.com/permissionlesstech/bitchat) stays the reference
  for the GATT half.** Dual-role central+peripheral controlled flood across iOS,
  macOS and Android, Noise/XX sessions, ~469-byte fragmentation — its whitepaper
  is the best external read on the fragmentation and flood specifics we
  implement.
- **Cautionary, not to copy: Bridgefy.** The commercial BLE-mesh SDK is
  GATT-based and cross-platform, which confirms the approach, but its crypto and
  relay were taken apart in academic analysis — a reminder that the connection
  and framing being right does not make the protocol on top of them safe.
- **Not a transport, but good client prior art: [pdxlocations](https://github.com/pdxlocations).**
  `contact` (console client), `meshconfig` (Web Bluetooth/Web Serial config),
  `firefly`/`connect` (UDP/MQTT sharing) all talk *to* a radio over the existing
  phone-API GATT or MQTT rather than meshing phone-to-phone. Useful for client
  protocol and UX, and `meshconfig` is a working proof the Web Bluetooth →
  radio-GATT path holds across browsers; not a source for the mesh transport.

Net for our roadmap: the GATT proxy framing is free and clarifying; Wi-Fi Aware,
anti-entropy sync and store-and-forward are the three concrete features to weigh
once the bridge itself is production (currently an explicit loop, see gate 2).

---

## The structural finding

`Router::send` ends in an unconditional `iface->send(p)` against a single
`std::unique_ptr<RadioInterface> iface` (`Router.h:50`; `addInterface` replaces
rather than appends). But that is not the only egress path. `Router.cpp:593-601`
already fans a copy out to MQTT and to `UdpMulticastHandler`, gated on
`config.network.enabled_protocols`. And the proto already carries
`MeshPacket.TransportMechanism` with `TRANSPORT_LORA_ALT1/2/3` reserved for
secondary radios.

So a second broadcast transport does **not** need a multi-interface router.
`UdpMulticastHandler` is a working template for exactly this, and the spike
copies it.

What a Router refactor *is* still needed for: a node with no LoRa radio at all.
`Router::send` asserts `iface` before transmitting, so BLE is an additional copy
path, never a replacement. Out of scope here, deliberately.

## Why connectionless advertising, not GATT

`FloodingRouter.cpp:133` — a CLIENT-role node cancels its pending rebroadcast
when it overhears another node relaying the same packet. That cancellation is
the mechanism that stops a flood from exploding, and it only works on a medium
where every neighbour hears every transmission.

GATT is point-to-point. Reaching N peers means N writes and nobody overhears
anybody, so one advertisement per packet becomes N connection writes per packet.
BLE 5 connectionless extended advertising keeps the one-to-many shape LoRa has,
which is why the spike is built on `ble_gap_ext_adv_*` rather than on the GATT
server already in `src/nimble/`.

**But be precise about suppression, because the first draft of this note was
wrong.** The overhear *property* belongs to the medium; the *code* that acts on
it is LoRa-only today. `FloodingRouter::perhapsCancelDupe` is gated
`transport_mechanism == TRANSPORT_LORA`, with the comment "But only LoRa packets
should be able to trigger this", and `Router::cancelSending` reaches only `iface`
— the LoRa TX queue — which cannot see `BleMeshHandler`'s own TX ring.

So on BLE today: every node that hears a packet re-advertises it, and nothing
cancels. Dedup still terminates the flood (`PacketHistory` drops a packet seen
recently, `hop_limit` decrements per relay), but the redundant copies are paid
for. Advertising is still the right choice — it costs one TX instead of N
regardless, and it makes suppression *possible* later. But "flood suppression
works as designed over BLE" is not true, and the first draft of this note said
it did.

Making it true is two changes, not one: extend the `perhapsCancelDupe` gate, and
give `BleMeshHandler` a cancel path keyed on `(from, id)` over its ring. Neither
is in the spike.

## Firmware spike — what was built

New `src/mesh/BLEMeshHandler.{h,cpp}` (the abstract base) plus the platform layers
`src/platform/esp32/ESP32BLEMesh.{h,cpp}` and `src/platform/nrf52/NRF52BLEMesh.{h,cpp}`,
modelled on `UdpMulticastHandler`,
including all four of its ingress guards (each is a bug someone already hit):

1. spoofed local origin (`from == 0`, or `from == our nodenum`) — dropped
2. `hop_limit`/`hop_start > HOP_MAX` — dropped, not clamped
3. `pki_encrypted = false` + `public_key.size = 0` — auth metadata is local-only,
   re-established by the Router after a successful PKI decrypt
4. `rx_snr`/`rx_rssi` reset — *differs* from UDP: BLE RSSI is a real measurement
   of this hop, so `has_rx_rssi` is set rather than cleared

Wiring: egress hook beside the UDP one at `Router.cpp:600`; ingress via
`router->enqueueReceivedMessage`; construction in `main.cpp` next to
`udpHandler`. Gated on `-DHAS_BLE_MESH=1`.

Proto additions: `TRANSPORT_BLE_ADV = 9` on `MeshPacket.TransportMechanism`,
`BLE_BROADCAST = 0x0002` on `NetworkConfig.ProtocolFlags`.

### Design decisions worth arguing about

**An encoded `MeshPacket`, not the LoRa wire frame — settled, not inherited.**
The spike originally sent `PacketHeader` + ciphertext: ~40% smaller, and
byte-identical to a LoRa-heard frame so a future BLE↔LoRa bridge would be a
memcpy. The merge in `dd9a01c90` took Ben's choice instead — a serialised
`meshtastic_MeshPacket`, the same shape UDP multicast puts on the wire — and the
client library follows it (`ProtoPacketCodec` carries a whole encoded packet).
The trade is real: a larger frame for one uniform on-air shape across UDP and
BLE, and a `FrameAdapter` seam in the client so a future LoRa transport, whose
framing genuinely differs, translates at the edge rather than everywhere.

**Capped at one PDU, and that PDU is 251 bytes, not 254.** `BLE_HCI_MAX_EXT_ADV_DATA_LEN`
is 251: the HCI *LE Set Extended Advertising Data* command spends four of its 255
parameter bytes on handle, operation, fragment preference and length, so an
unfragmented payload never reaches the 254 an AUX_ADV_IND could hold. The spike had
254 and was three bytes optimistic — Ben's branch had 251 and was right. A
`static_assert` now pins it to NimBLE's constant.

Chaining past one PDU is possible (ESP32 allows 1650) but
`ble_gap_ext_disc_desc.length_data` is a `uint8_t`, so chained adverts arrive as
several INCOMPLETE reports needing per-advertiser reassembly. Not worth it. The
cost: 251 — 5 (AD wrapper) — 16 (PacketHeader) = 230 bytes of ciphertext against a
`DATA_PAYLOAD_LEN` of 237. The largest handful of packets cannot ride BLE. They
still go out over LoRa.

**Company ID 0xFFFF, and it is probably the wrong AD type entirely.** 0xFFFF is
SIG-reserved for internal/test use — fine for a spike, wrong for a release. But
the choice of *manufacturer data* over *service data* is the bigger mistake, and
it is the client track that reveals why: iOS can only scan in the background when
filtering by service UUID, so a manufacturer-data advertisement is invisible to a
backgrounded iPhone. Advertising under an assigned service UUID instead costs a
couple of bytes and buys iOS background receive. Change this before anyone builds
on the format.

**`filter_duplicates = 0` on the scanner, and it must stay 0.** The controller
de-duplicates on *advertiser address*, not payload. Enabling it would deliver
one report per neighbour and then go silent — every subsequent mesh frame from
that node filtered away as a "duplicate advertisement". This is the trap in the
whole design.

**The egress guard is deliberately NOT UDP's.** `UdpMulticastHandler::onSend`
logs "Attempt to send UDP sourced packet over UDP" as an error. Copying that
straight across was a bug, and it was in the first commit: a packet that
arrived over BLE and comes back through `Router::send` is a *rebroadcast*.
`NextHopRouter::perhapsRebroadcast` does `allocCopy(*p)`, and nothing on the TX
path rewrites `transport_mechanism` — `RadioInterface` stamps `TRANSPORT_LORA`
in `deliverToReceiver`, which is RX-only. So the copy still says
`TRANSPORT_BLE_ADV`, the guard refused it, and the BLE mesh was silently capped
at one hop. Now it logs and proceeds. Loop protection is LoRa's: `PacketHistory`
drops a packet seen recently, `hop_limit` decrements, and `onScanReport` ignores
frames whose sender is us.

**A TX ring, because ext adv is set-and-repeat.** The instance holds one payload
and repeats it; it is not a packet queue. `runOnce` clocks queued frames through
the single instance, `BLE_MESH_ADV_EVENTS` repeats each. Throughput ceiling is
therefore (events × interval) per packet — roughly 60-90 ms per frame at the
20-30 ms interval configured. Fine for text, not for bulk.

### The integration risk

Enabling `CONFIG_BT_NIMBLE_EXT_ADV=y` compiles out NimBLE's legacy
`ble_gap_adv_start()`. The existing PhoneAPI advertising goes through the
Arduino `BLEAdvertising`/`BLEDevice` wrapper, which uses that legacy path. If
they collide, the PhoneAPI advertisement has to migrate to a connectable ext-adv
instance (instance 0; the spike deliberately puts the mesh transport on instance
1 to leave room for exactly that).

Encouragingly, `variants/esp32c3/esp32c3.ini:17-19` already carried the three
required sdkconfig lines, commented out — someone has been here before.
`src/nimble/NimbleBluetooth.cpp` already includes the raw `host/ble_gap.h`, so
the NimBLE host API is reachable without a dependency bump.

**Result: it links.** `pio run -e heltec-ht62-esp32c3-sx1262` is green with
`CONFIG_BT_NIMBLE_EXT_ADV=y` and the PhoneAPI GATT server both in the image, so
the feared `ble_gap_adv_start` collision does not happen on the ESP-IDF NimBLE
port — that gating is Mynewt-upstream, not what Espressif ships.

Careful about what that proves: it is a **link-time** result. Whether the
controller will actually run a legacy connectable advertisement and an extended
non-connectable one at the same time is a runtime question, and untested — no
device has run this. If it does turn out to conflict, the fix is to move the
PhoneAPI advertisement onto ext-adv instance 0, which is why the mesh transport
deliberately sits on instance 1.

A second target (`tbeam`, where `HAS_UDP_MULTICAST` is set and `HAS_BLE_MESH` is
not) also builds green, so the `#if` guards and the `main.h` include
restructuring hold on targets the transport does not touch.

**The native test suite is green.** `bin/test-native-docker.sh` — 1372 test cases,
1372 succeeded, exit 0. That matters because the two generated-header edits are
unconditional and reach every target, including the suites that touch this code
(`test_nexthop_routing`, `test_packet_history`, `test_traffic_management`,
`test_mqtt`, `test_event_channel_router`). Docker is required on macOS: the
`coverage` env passes GCC-only `-fprofile-abs-path` and the `native` env's
LovyanGFX fonts do not compile under Apple clang, both even after stripping the
Nix `CC`/`CXX`/`DEVELOPER_DIR` pollution.

One wrinkle worth knowing: running the harness from a git *worktree* prints
`fatal: not a git repository` twice, because `.git` is a file pointing at an
absolute host path the container does not mount. It is cosmetic — version stamping
only — and the suites run fine.

## It works — node-to-node, cross-platform, on hardware

A Heltec V3 (ESP32-S3) and a RAK4631 (nRF52840) exchange mesh frames over BLE 5
extended advertisements. The proof is a frame the Heltec originated, seen
advertised by the RAK:

```
from=0xd1d90f21 id=0xce0513cf  via=RAK  transport=9
```

`transport=9` is `TRANSPORT_BLE_ADV`, which `deliverToRouter` stamps only on BLE
receive, and the RAK's region is UNSET so its LoRa RX is disabled. There is no
path that packet could have taken but BLE. Two further frames from other mesh
nodes relayed the same way.

### The three settings that were actually in the way

None of them is in the transport's own code, and each failed differently:

| Setting | Failure without it |
| --- | --- |
| `CONFIG_BT_NIMBLE_ROLE_OBSERVER=y` | Scanning is a NimBLE *role*, compiled out of the stock Arduino build (`ROLE_BROADCASTER=y`, observer not set). `ble_gap_ext_disc` returns `BLE_HS_ENOTSUP`, so the transport advertises and never receives. |
| `CONFIG_BT_NIMBLE_EXT_ADV_MAX_SIZE=257` | The default 1650 is the chained ceiling, reserved *per instance* — 3.3 KB across two, for a transport capped at one 251-byte PDU. |
| `CONFIG_BT_CTRL_BLE_MAX_ACT=4` | The controller counts advertising sets, scans and connections as "activities" and budgets 2 by default: one advertisement plus one connection. This needs three. Both the scan enable and the second `ext_adv_configure` return HCI 0x07, Memory Capacity Exceeded (NimBLE 519). |

The nRF52 needed its own analogue: scanning requires a central link,
`Bluefruit.begin()` defaults to zero, and asking for one raises the SoftDevice's
RAM requirement past the linker ORIGIN — hence
`nrf52840_s140_v6_blemesh.ld` at `0x20006000` and the `rak4631_blemesh` env.
Three platforms, one shape of bug: **scanning is a capability the default build
does not include, and it fails as "unsupported" rather than "misconfigured".**

### The PhoneAPI advertisement had to move to extended advertising

IDF's NimBLE guards legacy advertising with
`#if NIMBLE_BLE_ADVERTISE && !MYNEWT_VAL(BLE_EXT_ADV)`, so under ext-adv every
`ble_gap_adv_*` call returns ENOTSUP — and the Arduino BLE wrapper's NimBLE path
calls exactly those, with no extended equivalent (its `BLEMultiAdvertising` is
Bluedroid-only). `NimbleBluetooth::startAdvertising()` now drives ext-adv
instance 0 with `legacy_pdu = 1`, so the on-air PDU stays an ordinary `ADV_IND`
and pre-BLE-5 phones discover the node exactly as before.

It **reuses** the wrapper's own GAP callback rather than replacing it. NimBLE
stores the advertising instance's callback on every connection made through it
(`ble_gap.c`: `conn->bhc_cb = ble_gap_slave[instance].cb`), so SUBSCRIBE, MTU and
pairing keep reaching `BLEServer` and `fromNum` notifications are untouched.
Reaching that private member uses the explicit-instantiation access idiom.
One residual edge: a *failed* connect makes the stock handler call
`BLEDevice::startAdvertising()`, now the ENOTSUP path, so the forwarder re-arms
instance 0 itself.

### The mistake worth remembering

The transport worked before Ben's platform layer was merged and stopped
afterwards, and I spent a long time hunting device state. It was the merge. His
code gates the extended path on `MYNEWT_VAL(BLE_EXT_ADV)`, which resolves from
the **prebuilt** `esp_nimble_cfg.h` and reads 0 regardless of `custom_sdkconfig`
— so the extended path compiled out and the transport fell back to the legacy
31-byte branch, which cannot carry a mesh frame. The original spike worked
precisely because it called `ble_gap_ext_adv_*` unguarded. Gate on a flag the
repo sets in `build_flags`; a `MYNEWT_VAL` guard removes your feature and leaves
nothing in the log.

Two of my own measurements were also wrong and produced confident nulls: I
scanned for service UUID `...eab5` when Meshtastic's is `...eafd`, and checked
`firmware.elf` when the build emits `firmware-<env>-<version>.elf`. Both said
"nothing there" about things that were there.

### Why it took so long: boot logs

Nearly every wrong turn traces to not being able to see the boot.
`pio device monitor` cannot run with stdout redirected — miniterm calls
`termios.tcgetattr` and dies on a non-tty — and `debug_log_api` routes firmware
logs to protobuf, silencing the UART. So the one time the monitor path was
disabled, the thing that would have printed was off too. Reading the port with
pyserial and pulsing DTR/RTS to reset the board made the boot visible, and every
real finding landed within minutes of that. Both traps are now in the workspace
`CLAUDE.md`, and `meshtastic-mcp` grew `serial_open(reset=True)` plus a hint on
empty reads.

### What is still open

- **No dedupe suppression over BLE.** `perhapsCancelDupe` is gated on
  `TRANSPORT_LORA` and `Router::cancelSending` reaches only `iface`'s TX queue.
  Redundant relays are paid for; dedup still terminates the flood.
- **Company ID 0xFFFF** is the SIG test identifier. Shipping wants an assigned
  16-bit service UUID with the payload as *service data*, which also buys iOS
  background receive — it can only scan by service UUID.
- **The generated nanopb headers are hand-edited** for `TRANSPORT_BLE_ADV` and
  `BLE_BROADCAST`; the matching `.proto` change is on protobufs'
  `spike/ble-mesh-transport` branch and needs a real regen plus a submodule bump.


## The client library: `meshtastic-node-kmp`

[`meshtastic-node-kmp/`](../meshtastic-node-kmp/) (was `meshnode-spike`), 34
tests green.

`node-core` holds the protocol and no I/O, so it is testable on any target:

| | |
| --- | --- |
| `ChannelCrypto` | AES-CTR, PSK size semantics including the 1-byte default-index form, `packet_id ‖ from ‖ counter` nonce |
| `Crypto.kt` | the one platform seam — expect/actual over AES-CTR |
| `MeshIdentity` | NodeNum + names, derived stably from a per-install seed |
| `MeshChannel` | name + PSK, and the channel hash the wire carries |
| `PacketHistory` | `(from, id)` dedup, bounded and expiring |
| `RelayPolicy` | `Island` by default |
| `MeshNode` | identity, keys, dedup, policy; drives the transports |
| `ProtoPacketCodec` | encoded-`MeshPacket` framing, as UDP and BLE adverts use |

Three transports, one interface. `node-transport-udp` speaks `239.0.0.69:4403`,
matching `UdpMulticastHandler`. `node-transport-ble` is connectionless BLE 5
advertisements over our own CoreBluetooth and Android implementations — receive
everywhere, transmit on Android. `node-transport-ble-gatt` is dual-role GATT, the
Apple transmit path.

The receive chain is proven against a frame captured off the air rather than a
fixture — a real packet relayed by the Heltec, advertised over BLE, captured by
a laptop:

```
BLE advertisement -> AD walk -> MeshPacket -> AES-CTR decrypt -> Data
```

It decrypts to a `POSITION_APP` message with a 36-byte payload. That matters
more than a synthetic test would: a hand-built fixture agrees with a wrong nonce
byte order just as readily as a right one.

**`node-core` depends only on `org.meshtastic:protobufs`, never on
`meshtastic-sdk`.** An app can then be both a client and a node with no cycle,
and the SDK can later depend on this rather than the reverse. That direction is
the one structural choice that would be expensive to undo.

Both of those have since been built. PKI for DMs is `PkiCrypto` (X25519 →
SHA-256 → AES-256-CCM, 8-byte MAC, 13-byte nonce), proven by a direct message a
bench radio acked with `ROUTING_APP`. And `MeshNode` is now a proper relay under
`RelayPolicy.Meshed` — a contention window inverted against signal strength,
cancel-on-overhear keyed on the relayer, and `next_hop` honoured and set — while
the default `Island` policy still relays nothing, so a node never amplifies what
it hears unless asked to.

It lives outside `meshtastic-sdk` deliberately, for the reasons under
*Standalone library, or an SDK module?* below.

## Client apps as nodes, with no radio

### Not reachable through the existing PhoneAPI

`MeshService.cpp:298` is explicit:

```cpp
p.from = 0;  // We don't let clients assign nodenums to their sent messages
```

A client cannot present a distinct node identity through a radio; it borrows the
radio's. There is a path that preserves a client-supplied sender —
`MESHTASTIC_ENABLE_FRAME_INJECTION` (`MeshService.cpp:288-297`) — but its own
comment says "it lets anything with a wired connection forge over-the-air
traffic, so it must never ship enabled". Useful on the bench, not a product.

So a phone-as-node is a **second implementation of the mesh protocol**, not an
extension of the client API.

### Platform capability matrix — the decisive finding

| Platform | Broadcast (TX) | Scan (RX) |
| --- | --- | --- |
| Android 8+ (API 26) | `startAdvertisingSet`, non-legacy, non-connectable; capped by `getLeMaximumAdvertisingDataLength()`, gated on `isLeExtendedAdvertisingSupported()` | `ScanSettings.setLegacy(false)` + `setPhy(PHY_LE_ALL_SUPPORTED)` |
| iOS / iPadOS / macOS | **No.** CoreBluetooth accepts only `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`; 28 bytes foreground; backgrounded the local name is dropped and service UUIDs move to the overflow area | Yes — `CBAdvertisementDataManufacturerDataKey` is readable on the scan side |
| Desktop JVM / Linux | BlueZ `LEAdvertisingManager1`, needs a D-Bus/JNI binding | Yes, same binding |

**Apple platforms can hear the mesh but cannot speak to it over
advertisements.** That is not a limitation to engineer around; it is an OS
policy. It is a limit of *this transport*, though, not of iOS: Apple transmits
fine over GATT, and `node-transport-ble-gatt` now proves it on device.

Consequence: there is no single BLE transport that works everywhere. Two-way
Apple participation requires GATT dual-role, which brings back the one-write-per-
peer fan-out that advertising avoids, and forecloses ever adding overhear-based
suppression on that path. It is why Bitchat, the closest prior art, is built on
GATT connections rather than advertisements.

### Background operation is a second, separate constraint

A node that only meshes while its app is on screen is a different product from a
node. Both platforms throttle this, in different ways:

- **Android.** `BLUETOOTH_SCAN` and `BLUETOOTH_ADVERTISE` are runtime permissions
  from API 31; `BLUETOOTH_SCAN` can carry `neverForLocation` to avoid dragging in
  location. Sustained background scanning needs a foreground service with its
  persistent notification, and Doze/App Standby throttle what is left.
- **iOS.** Needs the `bluetooth-central` background mode, and background scanning
  **must filter by service UUID** — `scanForPeripherals(withServices: nil)`
  returns nothing once backgrounded. The spike's manufacturer-data framing has no
  service UUID at all, so a backgrounded iPhone would not even hear the mesh. That
  is fixable in the AD format (use service data), and it is the strongest single
  argument for changing it.

So the capability matrix above is the foreground story. Backgrounded, iOS drops to
nothing unless the AD format carries a service UUID, and Android costs a
persistent notification.

The honest shape is a **multi-mode transport behind one interface**:

- **Mode A — advertisement.** Android, Linux. One TX reaches every neighbour;
  the firmware spike is a peer on this mode. Suppression is not active (see
  above), so redundant relays are paid for; dedup still terminates the flood.
- **Mode B — GATT dual-role.** Required for Apple. Point-to-point; overhear
  cancellation is unavailable, so it needs an explicit forwarding policy with a
  bounded peer count, leaning on `PacketHistory` dedup to stop loops rather than
  on overhearing.
- **Mode C — UDP multicast.** Every platform, no firmware change, but needs an AP
  or hotspot. The right one to build first — see below.

Mode B is a different routing policy, not a different socket. Do not let it be
specified as "the same thing but over GATT".

`android/config.properties` has `MIN_SDK=26`, which is exactly the API level
`startAdvertisingSet` and `isLeExtendedAdvertisingSupported` arrived in — the
floor is not a constraint.

### What the library actually has to contain

Confirmed greenfield: no client in this workspace implements the mesh wire
crypto. `meshtastic-sdk/core` has `ChannelUrls`/`ChannelHelpers` but no cipher;
`WireFraming.kt` is STREAM_API (`0x94 0xC3 len len`), a different layer
entirely. The AES-GCM uses in `android` are local key-backup storage, and
`apple`'s CryptoKit uses are backup and UF2 hashing. None of it is the mesh.

Layers required, smallest first:

1. **Frame codec** — 16-byte `PacketHeader` (`to`, `from`, `id` as u32 LE;
   `flags` packing `hop_limit` in bits 0-2, `want_ack` 0x08, `via_mqtt` 0x10,
   `hop_start` in bits 5-7; `channel`, `next_hop`, `relay_node`) + ciphertext.
2. **Channel crypto** — AES-CTR, key from `ChannelSettings.psk` with its size
   semantics (0 = cleartext; 1 byte = index into `defaultpsk[]` where index 0 is
   cleartext, 1 is unchanged, 2..255 increment the last byte by index−1; 16 =
   AES-128; 32 = AES-256). Nonce is `packet_id` (u64 LE) ‖ `from` (u32 LE) ‖
   `block_counter` (u32). No AEAD — the channel hash is a PSK-selection hint,
   not integrity.
3. **PacketHistory dedup** on `(from, id)`.
4. **PKI for DMs** — X25519 ECDH → SHA-256 → AES-256-CCM, MAC length 8, 13-byte
   CCM nonce (bytes 0-3 `packet_id`, 4-7 transmitted `extraNonce`, 8-11 `from`,
   byte 12 zero), 12 bytes of wire overhead (8 MAC ‖ 4 extraNonce).
5. **Router policy** — flood/next-hop, hop accounting, rebroadcast rules.
6. **NodeDB + identity** — own NodeNum, persisted X25519 keypair.

1-3 are small and unit-testable against firmware fixtures. 4-6 are where the
design risk sits. The full spec for 2 and 4 is in the firmware's
`.github/copilot-instructions.md` under "Encryption & Key Management" — precise
enough to implement from, and the only place it is written down.

### UDP multicast is the faster first milestone, and needs no firmware change

BLE is the interesting transport but it is not the shortest path to a working
client node. `UdpMulticastHandler` already ships: group `239.0.0.69`, port `4403`,
a serialised `meshtastic_MeshPacket` on the wire, gated on
`ProtocolFlags_UDP_BROADCAST`, and compiled in wherever `HAS_UDP_MULTICAST=1` is
set — which is `variants/esp32/esp32-common.ini`, so most ESP32 boards, plus
portduino, the Pico W variants, `rak4631_eth_gw`, `esp32p4` and several S3 boards.

A Kotlin node can join that group and be a peer **today, against released
firmware, with nothing to merge**. That is a far better way to find out whether
the protocol implementation is right than debugging it over advertisements.

It is also easier on the wire: UDP carries the encoded `MeshPacket`, so the
published `org.meshtastic:protobufs` artifact does the parsing and the 16-byte
`PacketHeader` codec is not needed at all. What it does **not** dodge is the hard
part — `UdpMulticastHandler::onReceive` only accepts
`which_payload_variant == encrypted_tag`, so the AES-CTR and PKI layers are
required exactly as before. Good: the crypto gets validated against real firmware
before any BLE work starts.

What it costs:

- **It needs infrastructure.** UDP multicast wants a shared L2 segment — an AP or
  a hotspot. BLE needs nothing at all, which is the entire point of BLE for the
  crowd-in-a-field case. These are complements, not alternatives.
- **Android.** A `WifiManager.MulticastLock` is mandatory or the socket receives
  nothing. And `ACCESS_LOCAL_NETWORK` covers UDP multicast, not just discovery:
  see [`local-network-permission-gap.md`](./local-network-permission-gap.md), which
  traced the same restriction for the app's TCP path. It becomes mandatory at
  targetSdk 37 and its failure mode is a timeout, not an error.
- **iOS.** Needs `com.apple.developer.networking.multicast`, a restricted
  entitlement granted by request through Apple's form (state the group address and
  port; roughly two weeks). It works in the simulator without it and fails on
  device, which is a nasty way to find out.

So the sequencing is: **implement the node over UDP first**, prove the crypto and
routing against a real radio, then add BLE mode A as a second transport behind the
same interface. The firmware spike is what mode A talks to when you get there.

### Standalone library, or an SDK module?

**Recommendation: standalone repo first, upstream into `meshtastic-sdk` later.**

Against putting it in the SDK immediately:

- The SDK's contract is *client talks to a radio* — `RadioClient`, and a
  `Transport` that means ToRadio/FromRadio framing. Its existing
  `transport-ble` module is a PhoneAPI link, not a mesh link; naming a mesh
  transport alongside it would make two very different things look like
  siblings.
- It would move mesh key material into an artifact whose current audience is
  apps that never hold any, changing its security surface.
- It is a governed repo — `GOVERNANCE.md`, `CODEOWNERS`, Spec Kit. That is the
  right process for shipping this and the wrong process for finding out whether
  it works.

For it, later: shared `build-logic`, the published `org.meshtastic:protobufs`
artifact, KMP publishing and the BOM are all already there, and `transport-ble`
proves the per-platform BLE plumbing pattern in that repo.

So: spike as its own KMP repo, reuse the SDK's build conventions, and propose
`mesh-node` + `mesh-transport-*` modules once mode A and mode B both carry
traffic against the firmware spike.

### The part that should give pause

A phone holding a real NodeNum is a real node, with real consequences:

- **NodeDB pressure.** `MAX_NUM_NODES` is 120 on nRF52840/ESP32 and **10** on
  STM32WL. Two hundred phones in a venue evict every actual radio from the
  NodeDB of anything that hears them.
- **LoRa injection.** If phone-nodes bridge to LoRa — or a nearby radio bridges
  BLE↔LoRa — crowd chatter lands on a duty-cycle-limited shared channel that
  cannot absorb it. This is the harm vector, and it is a property of the feature
  working, not of it failing.

**And the LoRa injection path is already open.** This is not a future risk gated
behind the BLE work. `FloodingRouter::shouldFilterReceived` hands any non-duplicate
packet to `perhapsRebroadcast`, which is not transport-gated, and `Router::send`
ends at `iface->send` — LoRa. So a UDP-multicast packet from an unknown NodeNum
is relayed onto the air by any UDP-enabled radio on the same LAN, using released
firmware. `UdpMulticastHandler::onReceive` only rejects `isFromUs`; it does not
require the sender to be in the NodeDB. A Kotlin node built on the mode C path
above exercises this on its first packet.

Therefore: client nodes should default to an **island mode**, meshing only with
each other, and bridging to LoRa should be an explicit, rate-limited, opt-in
role rather than a default. Design that in from the start; it is much harder to
retrofit once islands and bridges are indistinguishable on the wire.

### Ben's branch — `meshtastic/firmware` `ble-mesh-working`

`d84355d15a`, Ben Meadors, 2026-03-07, one commit, now 1128 behind develop. Not a
fork — it is a branch on the org repo. It carries a 625-line
`docs/ble-mesh-implementation-plan.md` (written before the docs/ purge), an
abstract `src/mesh/BLEMeshHandler.h`, and two platform implementations:
`ESP32BLEMesh` (NimBLE) and `NRF52BLEMesh` (Bluefruit).

**The two designs converged independently**, which is reassuring about both:
same `onSend` hook in `Router::send`, same `HAS_BLE_MESH` flag, same
`UdpMulticastHandler` template, same 0xFFFF company ID with the same "until a real
SIG ID is assigned" note, same `pki_encrypted`/`public_key`/RSSI resets, and the
same advertising-instance split (his plan —3.3: "extended adv set 0 for phone,
set 1 for mesh"; the spike puts mesh on instance 1 for exactly that reason).

**What his branch has that the spike does not:** a platform abstraction, nRF52/
Bluefruit support, and both a legacy and an extended advertising path
(`ble_gap_adv_*` alongside `ble_gap_ext_adv_*`) so pre-BLE-5 parts get a 31-byte
fallback. It is advertising throughout — no GATT server or client anywhere in it,
despite his plan sketching a GATT mode in —3.2. That is the better architecture and
covers a platform this spike does not touch. Take it.

**Four things to fix before building on it**, all found by the spike:

1. **`TRANSPORT_BLE_MESH = 8` is now taken.** He reserved 8 with a `#ifndef`
   placeholder pending a proto change that never landed; `TRANSPORT_UNICAST_UDP = 8`
   shipped since. Anything rebased off that branch mislabels UDP packets as BLE.
   The spike uses 9.
2. **The echo guard caps the mesh at one hop** — confirmed in his committed code, not
   just the plan: `ESP32BLEMesh.cpp` has `// Don't echo packets that arrived via BLE
   mesh` then `return false` on a packet whose `transport_mechanism` is the BLE one.
   As traced above, a rebroadcast is an `allocCopy` that still carries that value,
   so every relay is refused. The spike had this bug too, from copying the same UDP
   line; it is fixed in `39999f581`.
3. **Ext-adv is enabled the pre-pioarduino way.** He sets
   `-DCONFIG_BT_NIMBLE_EXT_ADV=1` as a build flag. The Arduino 3.x/pioarduino
   migration (`a54195748`) converted those into `custom_sdkconfig` entries and left
   them commented out in `variants/esp32c3/esp32c3.ini` — which is where the
   commented lines the spike found came from. Under the current build system a `-D`
   does not reconfigure the prebuilt IDF NimBLE, so the flags have to move to
   `custom_sdkconfig`. The spike does that, and it links.
4. **Missing UDP's ingress guards.** No `isFromUs`/`from == 0` spoof drop and no
   `hop_limit`/`hop_start > HOP_MAX` clamp. Both are in `UdpMulticastHandler` and
   both are in the spike.

**One open disagreement: the wire format.** He encodes a whole `MeshPacket`, as UDP
does (`uint8_t buffer[meshtastic_MeshPacket_size]`, and that constant is 450); the
spike sends the LoRa frame. Proto framing spends more bytes per packet than the
16-byte `PacketHeader`, so it hits the 251-byte ceiling sooner, and neither format
covers the full 237-byte payload range in one PDU. LoRa framing also makes a
BLE-heard frame byte-identical to a LoRa-heard one. Worth settling deliberately
rather than by inheritance from the UDP handler.

Suggested shape: his platform abstraction and nRF52 implementation, the spike's
guards, enum value, sdkconfig enablement and rebroadcast fix, and an explicit
decision on framing.

### Prior art

`meshtastic/firmware#8152` — "More control of bridging between protocols: a sort
of oktomqtt++ for UDP, BLE, rs485, rs232, IrDA" — open since 2025-09-28, nothing
landed. Adjacent recurring asks: #10897 (serial cross-link), #8798 (multi-radio
serial bridge), #9280 (wired clusters). All four want the same missing thing, so
the `Router` multi-interface refactor has four consumers besides this one.
