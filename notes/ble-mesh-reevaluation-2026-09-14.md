# Re-evaluating the BLE mesh approach

2026-09-14. Written after the bench work of 2026-09-13, after reading Ron's
`Node-Bridging` branch, and against the prior art surveyed in
[`ble-mesh-transport.md`](./ble-mesh-transport.md) (SIG Mesh, Knit, bitchat,
Bridgefy). Companions:
[`multi-transport-mesh.md`](./multi-transport-mesh.md) (the plan),
[`ble-mesh-capacity-and-bearer-config.md`](./ble-mesh-capacity-and-bearer-config.md)
(capacity, range, the bearer toggle).

The question re-opened here is not "advertisements or GATT". It is **what each
bearer is for**. There are three use cases and they do not have the same answer.

## The finding that reframes everything: the advertisement bearer is partial

Both the spike and Ron's branch encode the whole `meshtastic_MeshPacket` into
one unfragmented extended advertisement, and neither fragments.

```
BLE_MESH_ADV_TOTAL_MAX   251     HCI ext-adv data, minus the 4 parameter bytes
BLE_MESH_ADV_OVERHEAD      8     flags AD + mfr-data AD header + company + version
v1 budget                243     whole encoded MeshPacket
v2 budget                218     243 - 13-byte frame header - 12-byte PKC overhead
```

Against that, LoRa's own ceiling:

```
MAX_LORA_PAYLOAD_LEN     255
sizeof(PacketHeader)      16     to, from, id, flags, channel, next_hop, relay_node
MAX_RADIO_PAYLOAD_LEN    239     the largest `encrypted` a LoRa packet can carry
```

A 239-byte `encrypted` field alone costs 242 encoded bytes (tag + 2-byte length
+ payload). That leaves **one byte** of v1's budget for `from`, `to`, `id`,
`channel` and the hop fields, which need 24 (`from`, `to` and `id` are
`fixed32`, so 5 bytes each with the tag). Measured by binary search against
`buildAdvPayload` itself, and independently against Wire in node-kmp:

- **v1** carries ciphertext up to **219 bytes**, against LoRa's 239.
- **v1 relaying** carries **198**, see below.
- **v2** would carry roughly **194** (derived, not measured).

Everything above that is dropped by `buildAdvPayload` returning 0, logged as
`does not fit`, and goes out over LoRa only. Most traffic is far below the
ceiling and rides fine, so this has never shown up on the bench. It is still
true that **the connectionless bearer has never been a full bearer**: it is a
bearer for small packets, and the ~10% (v1) / ~20% (v2) of the payload range
nearest the top silently never crosses it.

That is not a bug to file against Ron. It is a property of putting a
LoRa-sized frame in a 251-byte PDU with no fragmentation, and it has been there
since the spike. It belongs at the top of any honest description of the bearer.

**node-kmp has the same ceiling**, deliberately: `BleMeshAdvert.MAX_PACKET_LEN`
is `251 - 8` and `BleMeshTransport.send` returns false above it. It at least
surfaces as a send failure rather than a log line, and `MeshFragment.split`
exists but lives in `node-transport-ble-gatt`, not here.

**And the envelope is bigger than it needs to be.** `buildAdvPayload` encodes
the packet as it stands, so a relayed packet carries `rx_rssi`, `rx_snr` and
`rx_time` over the air. `rx_rssi` is `int32` and negative, which nanopb encodes
as a 10-byte varint. Ron's ingress strips all of them on receipt, which is the
tell that they are on the wire. `UdpMulticastHandler::onSend` does the same
thing, so this is a pre-existing pattern rather than something the BLE spike
invented; it just costs nothing on a 1500-byte MTU and costs real budget here.

**Measured 2026-09-14** and pinned in both repos: firmware
`test_ble_mesh` (20/20 in the Docker native runner on james-pc) and node-kmp
`BleAdvertCeilingTest`. 219 for a locally-originated packet, 198 for a relay.

**These are fixture ceilings, not production ceilings.** Both tests build a
packet with `from`/`to`/`id`/`channel`/`hop_limit`/`hop_start` and nothing else.
A real packet leaving `Router::send` also carries `priority` (`fixPriority` at
`Router.cpp:562` runs before encryption and never leaves it UNSET) and
`relay_node` (`FloodingRouter.cpp:22`, set on everything we send), and a relay
carries `transport_mechanism` too. So production sits a few bytes below both
numbers. The fixtures should be re-shaped to carry them. The v2 figure is
derived, since nothing builds that branch here.

## What we proved on hardware, 2026-09-13

Proven:

- A BlueZ host (james-pc) advertising a **201-byte** body, heard by a Pixel 6a
  at -51 dBm. No firmware radio in the path.
- **Coded PHY** carries the same body, with a clean 1M control run after the
  two-advertiser mix-up was killed.
- Tx-power tuning is real and adapter-specific: the Pixel's controller grants
  -8 dBm at `TX_POWER_MEDIUM` and +1 at `TX_POWER_HIGH`, a 9 dB spread
  (the SDK constants predict 8).
- The adapter's `MaxTxPower` is not the advertising ceiling. james-pc reports
  23; HCI `Advertising_TX_Power` is int8 and spec-capped at +20, and handing
  BlueZ 23 gets the **whole** advertisement registration refused, taking the
  interval bounds down with it. Hence `advertisableTxPower`.
- A host can lack the capability entirely. The uConsole has no
  `CanSetTxPower`, which is what proved the guard.

Never proven: **a firmware radio hearing a node-kmp advertisement.** Both bench
boards run release firmware; nothing is flashed with the BLE-mesh spike.

## The platform matrix, updated

Transmit connectionless (extended advertising, >31-byte body):

| Platform | Can transmit | Can receive |
| --- | --- | --- |
| Android (BT5 phone) | yes, proven | yes, proven |
| Linux + BT5 adapter | yes, proven (james-pc) | yes |
| uConsole (tested) | **no** | no ext-adv |
| Other Pi-class hosts | unverified | unverified |
| ESP32-S3 / C3 | yes (NimBLE ext adv) | yes |
| nRF52840 | yes (SoftDevice ext adv) | yes |
| iOS / macOS | **no** | **yes, foreground only** |

`CBPeripheralManager.startAdvertising` takes a local name and service UUIDs and
nothing else, so iOS cannot transmit: node-kmp's `BleMeshRadio.apple.kt:112`
returns false unconditionally. **Correction to the first draft: it can receive.**
`advertisements()` at `:65-108` is a real `CBCentralManager` scan. Foreground
only, because a background iOS scan must filter on a service UUID and these
frames are manufacturer data, which is one more reason the 128-bit service-UUID
shape below is worth its 14 bytes. Never tested against a firmware radio.

Whether a stock Raspberry Pi, the most common `meshtasticd` host, can is
**unverified**: the uConsole cannot, and no other Pi-class adapter here has been
checked.

GATT's matrix is the whole table, both columns, every row.

That is the discriminating constraint. Coded PHY is a range lever, not a
platform lever: it applies to advertisements and to connections alike, and is
gated on the adapter either way.

## Ron's `Node-Bridging`, read as a proposal

`6fa3df0af` on top of the spike. What it does:

- Protocol v1 to v2. Frame becomes `[type 1][src 4][dst 4][id 4]` followed by
  the encoded `MeshPacket` **re-encrypted** under a per-peer Curve25519 shared
  key (`deriveSharedKey`, `BRIDGE_KEY_CONTEXT`), `MESHTASTIC_PKC_OVERHEAD 12`.
- Max 3 paired peers, 60-second pairing window with matching display codes.
- `onSend` loops **once per paired peer**, queueing a separate advertisement
  each.
- `env:rak4631_blemesh` and `nrf52840_s140_v6_blemesh.ld` deleted, the build
  settings moved into shared variant `.ini` files.

**Correction to the first draft of this note: the packaging change is not a
clean win, and it is not packaging.** Read properly, it changes what every board
builds:

- `-DHAS_BLE_MESH=1`, `CONFIG_BT_NIMBLE_EXT_ADV=y` and `EXT_SCAN=y` move into
  `[ble_mesh_esp32]`, which `esp32s3.ini`, `esp32c3.ini` and `esp32c6.ini` now
  all reference. Every S3/C3/C6 build compiles the transport in and rebuilds
  NimBLE with extended advertising and extended scanning. Runtime opt-in still
  gates it (`isEnabled()` reads `enabled_protocols`, default off), so this is a
  legitimate shipping shape, but the flash and RAM cost is real and
  **unmeasured**.
- `nrf52840_s140_v6.ld` and `_v7.ld` go from `ORIGIN = 0x20004000` back to
  `0x20006000`, and `-DBLE_MESH_NRF52_CENTRAL=1` moves into `nrf52840.ini`.
  `develop` is at `0x20004000`, so this is not restoring a baseline: it takes
  **8 KB of RAM from every nRF52840 build** to buy the central link one opt-in
  feature needs.
- `-DHAS_BLE_GATT_MESH=1` is removed from the ESP32 block and from
  `rak4631/platformio.ini`, and **no variant on the branch sets it**. The
  `BLEGattMeshHandler` source is still there; nothing compiles it. The GATT
  proxy role is gone from every build.

So the branch moves opposite to the recommendation below on both axes at once:
advertisements in every build, GATT in none. That is most likely scope (a branch
called `Node-Bridging` is about radio-to-radio) rather than a rejection, but it
is a question for Ron, not something to cherry-pick.

The protocol change needs a decision first, for three reasons.

**1. It gives up the one property that justified advertisements over GATT.**
The spike chose connectionless because one transmission reaches every listener.
`onSend` looping over peers is N unicasts on a broadcast medium: it pays the
broadcast medium's costs (no reliability, no MTU negotiation, no fragmentation,
no flow control, no link-layer retry) and keeps none of its benefit. Once you
are sending per-peer, GATT wins on every axis. The ESP32 spike sets
`CONFIG_BT_NIMBLE_ROLE_CENTRAL=n` (`variants/esp32/esp32-common.ini:286`),
which is a config flag, and nRF52 has central already.

**2. Three peers and an 8-deep TX queue interact badly.** One broadcast becomes
3 slots of an 8-slot queue before repeats. The queue-full path drops the
remaining peer copies of a packet already accepted for others, so a packet can
reach peer 1 and not peer 2 with no record beyond a `LOG_WARN`.

**3. Pairing is pairwise only.** `deriveSharedKey` takes a remote public key.
There is no group key, no NetKey, nothing shareable. A node with zero pairs has
a dead bearer: `onSend` returns false with `approvedCount == 0` and nothing is
transmitted at all. The bearer went from mesh to opt-in-per-link in one commit.

SIG Mesh's answer to exactly this problem is a shared **NetKey** with per-device
AppKeys above it: authenticated broadcast, one transmission, no per-peer fan-out.
That is the option the branch skips, and it is the one that keeps both
authentication and one-to-many.

The fix keeps most of Ron's work. The pairing ceremony he built, display codes
and a 60-second window, is exactly how a group key gets provisioned. Have it
distribute **one shared bridge key** instead of deriving a pairwise one, and
`onSend` goes back to a single advertisement. The ceremony survives; only the
key model changes. (Deriving the key from the channel PSK instead is not the
answer: the default LongFast PSK is public, and a bridge relays packets on
channels it cannot decrypt, so there is no one PSK to derive from.)

**Wire break for node-kmp:** v1 and v2 frames are not interoperable, and the
version byte is at a fixed offset so the break is at least detectable. node-kmp
speaks v1. Nothing should be implemented on the node side until the firmware
design settles.

## What each bearer is for

**1. A phone or desktop joins the mesh with no radio.** node-kmp's founding
purpose. Every shipped app in the survey does this over GATT: Knit, bitchat,
Bridgefy. iOS can do nothing else. The SIG's name for the role is **GATT Proxy**,
which is worth adopting because it is the standard name for what we built.
Settled by prior art and by the platform matrix. **GATT is the primary bearer.**

**2. Radio to radio bridging** (Ron's case: linking two meshes through paired
radios). Per-peer encryption over a broadcast medium is the worst of both. This
is a GATT case, or a shared-bridge-key case, not a per-peer advertisement case.

**3. One-to-many discovery and small-packet flood on BT5 hosts.** This is what
connectionless advertising is actually good at, and the only case where it beats
GATT. It is also the case Ron's change removes the justification for.

## Overhear suppression: fixed 2026-09-14

`FloodingRouter::perhapsCancelDupe` was gated on `TRANSPORT_LORA`, so a node
that overheard a neighbour relaying over BLE advertised its own copy anyway.
Fixed on `spike/ble-mesh-transport` in `42e64cfa5`.

The gate is now per medium, which is the part that matters. Cancelling across
media is wrong in the other direction: hearing a neighbour on BLE is no evidence
about who heard us on LoRa, so a BLE dupe must not stand a LoRa rebroadcast down.
`MeshTransportBase::cancelTransportsOn` carries the medium; `AdvSlot` carries
`from`/`id`; `runOnce` remembers the identity of the burst it started, so a
cancel reaches a payload already repeating on air as well as the queued ones.

**node-kmp cannot take the same fix as a flag.** It already has the machinery -
`MeshTransport.floods` and `MeshNode.cancelSending` - but it keeps **one** relay
job covering every bearer, so setting `floods = true` on the advertisement
transport would let a BLE dupe cancel the LoRa leg too. Its own KDoc says so.
Same-medium suppression there is a design change (per-bearer relay legs), not a
property flip.

## Where this lands

1. **GATT is the primary BLE bearer.** It is the only BLE medium every platform
   in the fleet has, in both directions. Position the advertisement bearer as
   the BT5 fast path, not the baseline.
2. **Document and count the ceiling. Chaining is not available.**
   *Superseded 2026-09-15:* the first draft offered fragmentation as the
   alternative. It is not one. The nRF52 SoftDevice caps an advertising set's
   data at 255 bytes (`BLE_GAP_ADV_SET_DATA_SIZE_EXTENDED_MAX_SUPPORTED`,
   `ble_gap.h:293`), so the S140 cannot **transmit** a chained extended
   advertisement at all. Reception is not the constraint: the scan buffer goes to
   1650 (`BLE_GAP_SCAN_BUFFER_EXTENDED_MAX`, `:402`), so the adversarial audit's
   "capped at 255 in both directions" was wrong in the receive column.
   An application-level scheme across several independent advertisements is still
   theoretically open, but it needs reassembly state, ordering and a timeout over
   a lossy connectionless medium with no acknowledgements, and nothing has been
   built. So: state the cutoff and count it. Done in firmware `8d85416fc`, which
   also recovered the 21 bytes a relay was wasting on reception metadata.
3. **Ask Ron before taking anything from `Node-Bridging`.** It is not a
   packaging change: it compiles the advertisement bearer into every S3/C3/C6
   build, gives back the spike's 8 KB of nRF52840 RAM, and leaves
   `HAS_BLE_GATT_MESH` set by no variant, so the GATT proxy role is compiled out
   everywhere. v2 also needs the shared-key-vs-pairwise question answered, and
   it breaks node-kmp's wire.
4. **Widen the dedup gate** before claiming overhear suppression.
5. **Neither bearer ships** while the company ID is `0xFFFF`. Costed
   2026-09-14: SIG Adopter membership is **$0/yr**, a Company Identifier is
   **$1,250**, a 16-bit UUID is **$3,750** (one-off, no renewal). The free option
   is the one the project already uses: the phone API advertises a random 128-bit
   UUID (`6ba1b218-15a8-461f-9fa8-5dcae273eafd`), and service data under a
   128-bit UUID costs nothing and is the only form a backgrounded iOS scan can
   filter on. It costs 14 more bytes of budget than manufacturer data (18 vs 4),
   which on a bearer with 219 usable bytes is about 6%. That is the trade to
   decide, not whether to keep `0xFFFF`.

Worth stealing from the prior art, still: Knit's content-digest anti-entropy
sync and delay-tolerant store-and-forward, which are the two things that make a
sparse phone mesh useful and which neither bearer has. Bridgefy remains the
cautionary tale, its crypto and relay both taken apart academically, which is
the argument for a reviewed key model rather than an invented one.
