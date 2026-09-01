# Meshtastic mesh protocol over a BLE transport

Feasibility work, 2026-09-01. Two tracks: a firmware node carrying mesh frames
over BLE, and a client app participating as a node with no radio attached.

Firmware spike branch: `firmware` → `spike/ble-mesh-transport`
(worktree `firmware/.claude/worktrees/spike-ble-mesh-transport`).

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

GATT is point-to-point. Reaching N peers means N writes, nobody overhears
anybody, nothing cancels. A connection-oriented BLE mesh transport does not
merely perform worse — it defeats the algorithm that makes flooding survivable.

BLE 5 connectionless extended advertising restores the overhear property. That
is the whole reason the spike is built on `ble_gap_ext_adv_*` rather than the
GATT server already in `src/nimble/`.

## Firmware spike — what was built

New `src/mesh/ble/BleMeshHandler.{h,cpp}`, modelled on `UdpMulticastHandler`,
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

**LoRa wire framing, not an encoded MeshPacket.** UDP puts a serialised
`meshtastic_MeshPacket` on the wire; it has a 1500-byte MTU and can afford it.
BLE cannot. Sending `PacketHeader` + ciphertext is ~40% smaller and makes a
BLE-heard frame byte-identical to a LoRa-heard one, so a future BLE↔LoRa bridge
is a memcpy rather than a translation. `encodeAdvPayload` mirrors
`RadioInterface::beginSending`; the scan path mirrors `RadioLibInterface`'s RX
block including the `hop_start == 0 → next_hop/relay_node invalid` rule.

**Capped at one PDU (254 bytes), no chaining.** Chaining is possible (ESP32
allows 1650) but `ble_gap_ext_disc_desc.length_data` is a `uint8_t`, so chained
adverts arrive as several INCOMPLETE reports needing per-advertiser reassembly.
Not worth it. The cost: 254 − 5 (AD wrapper) − 16 (PacketHeader) = 233 bytes of
ciphertext against a `DATA_PAYLOAD_LEN` of 237. The largest ~4 bytes' worth of
packets cannot ride BLE. They still go out over LoRa.

**Company ID 0xFFFF.** SIG-reserved for internal/test use — correct for a spike,
wrong for a release. Shipping needs a member company ID or an assigned 16-bit
service UUID.

**`filter_duplicates = 0` on the scanner, and it must stay 0.** The controller
de-duplicates on *advertiser address*, not payload. Enabling it would deliver
one report per neighbour and then go silent — every subsequent mesh frame from
that node filtered away as a "duplicate advertisement". This is the trap in the
whole design.

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

Everything below the link step is unverified: no two nodes have exchanged a
frame, and the 60-90 ms/packet throughput ceiling is arithmetic, not a
measurement. First hardware test should be two C3 boards with LoRa disabled and
`BLE_BROADCAST` set, checking that a text sent on one arrives on the other with
`transport_mechanism == TRANSPORT_BLE_ADV`.

---

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
policy. A room full of iPhones is a room full of passive listeners.

Consequence: there is no single BLE transport that works everywhere. Two-way
Apple participation requires GATT dual-role — which reintroduces exactly the
flood-suppression problem above, and is why Bitchat (the closest prior art)
is built on GATT connections rather than adverts.

The honest shape is a **two-mode transport behind one interface**:

- **Mode A — advertisement.** Android, Linux. Broadcast; flood suppression works
  as designed; the firmware spike is a peer on this mode.
- **Mode B — GATT dual-role.** Required for Apple. Point-to-point; overhear
  cancellation is unavailable, so it needs an explicit forwarding policy with a
  bounded peer count, leaning on `PacketHistory` dedup to stop loops rather than
  on overhearing.

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

Therefore: phone-nodes should default to **BLE-island mode**, meshing only with
each other, and bridging to LoRa should be an explicit, rate-limited, opt-in
role rather than a default. Design that in from the start; it is much harder to
retrofit once islands and bridges are indistinguishable on the wire.

### Prior art

`meshtastic/firmware#8152` — "More control of bridging between protocols: a sort
of oktomqtt++ for UDP, BLE, rs485, rs232, IrDA" — open since 2025-09-28, nothing
landed. Adjacent recurring asks: #10897 (serial cross-link), #8798 (multi-radio
serial bridge), #9280 (wired clusters). All four want the same missing thing, so
the `Router` multi-interface refactor has four consumers besides this one.
