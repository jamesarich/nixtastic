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
`channel` and the hop fields, which need about 24 (`from`, `to` and `id` are
`fixed32`, so 5 bytes each with the tag). So:

- **v1** carries ciphertext up to roughly **219 bytes**, against LoRa's 239.
- **v2** carries roughly **194**.

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

**Unproven:** the exact cutoff in bytes. The 219/194 figures are computed from
the field sizes, not measured by encoding a maximal packet. Worth a native test
that encodes `MAX_RADIO_PAYLOAD_LEN` of ciphertext and asserts what happens.

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
| iOS / macOS | **no** | **no** (backgrounded, non-connectable) |

`CBPeripheralManager.startAdvertising` takes a local name and service UUIDs and
nothing else, and iOS suppresses non-connectable advertising in the background.
iOS can do **neither** connectionless direction. Whether a stock Raspberry Pi,
the most common `meshtasticd` host, can is **unverified**: the uConsole cannot,
and no other Pi-class adapter here has been checked.

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
- Packaging win, and it is a real one: `env:rak4631_blemesh` and
  `nrf52840_s140_v6_blemesh.ld` deleted, the opt-in moved into shared variant
  `.ini` files.

The packaging change should land regardless. The protocol change needs a
decision first, for three reasons.

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

## The other thing that is not true yet

`FloodingRouter::perhapsCancelDupe` is gated on
`transport_mechanism == TRANSPORT_LORA`, and `Router::cancelSending` reaches
only `iface`. **Overhear suppression is not active on BLE.** The advertisement
bearer's flood is an unsuppressed flood today. Knit's design (jittered,
overhear-suppressed flooding) is the reference for fixing it, and the fix is
cheap: widen the gate and give the BLE handler a cancel path into its TX queue.
Until then, "advertisements let us suppress duplicates later" is a plan, not a
property.

## Where this lands

1. **GATT is the primary BLE bearer.** It is the only BLE medium every platform
   in the fleet has, in both directions. Position the advertisement bearer as
   the BT5 fast path, not the baseline.
2. **Fragment, or document the ceiling.** The advertisement bearer drops large
   packets silently. Either add fragmentation (bitchat's ~469-byte scheme is the
   reference, and `node-transport-ble-gatt` already has `MeshFragment.split`) or
   state the cutoff in the protocol doc and log it as a counter, not a
   `LOG_WARN`.
3. **Take Ron's packaging change, hold the protocol change.** The variant `.ini`
   opt-in and the deleted linker script are unambiguously better. v2 needs the
   NetKey-vs-pairwise question answered first, and it breaks node-kmp's wire.
4. **Widen the dedup gate** before claiming overhear suppression.
5. **Neither bearer ships** while the company ID is `0xFFFF` and the service
   UUIDs are unregistered. Unchanged from the spike.

Worth stealing from the prior art, still: Knit's content-digest anti-entropy
sync and delay-tolerant store-and-forward, which are the two things that make a
sparse phone mesh useful and which neither bearer has. Bridgefy remains the
cautionary tale, its crypto and relay both taken apart academically, which is
the argument for a reviewed key model rather than an invented one.
