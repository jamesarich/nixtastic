# meshtastic-node-kmp

A Kotlin Multiplatform library that lets a client application act as a Meshtastic
**node** — decoding, decrypting and originating mesh traffic itself — rather than
being handed decoded packets by a radio over the phone API.

Deliberately not part of [`meshtastic-sdk`](../meshtastic-sdk). That repo's
contract is *client talks to a radio*: `RadioClient`, and a `Transport` that
means ToRadio/FromRadio framing. Its `transport-ble` is a phone↔radio link, not
a mesh link, and its `core` holds no cipher — a node holds private key material
and does its own crypto, which is a different security surface for an artifact
whose audience today never touches one. See
[`../notes/ble-mesh-transport.md`](../notes/ble-mesh-transport.md).

## Modules

| Module | | Status |
| --- | --- | --- |
| `node-core` | Frame codec, channel AES-CTR, dedup, relay policy. No I/O. | scaffolded |
| `node-transport-udp` | Multicast `239.0.0.69:4403` | scaffolded |
| `node-transport-ble-adv` | Connectionless extended advertising (Android, Linux) | planned |
| `node-transport-ble-gatt` | Dual-role GATT (Apple, Android fallback) | planned |
| `node-android` | Foreground service, permissions, Doze | planned |

`node-core` depends only on `org.meshtastic:protobufs` — **not** on
`meshtastic-sdk`. An app can then be both a client and a node with no dependency
cycle, and the SDK can later depend on this rather than the reverse.

## What is proven

`CapturedFrameTest` runs the full receive chain against a frame captured off the
air — a real packet relayed by a Heltec V3 running the BLE-mesh spike firmware,
sent as a BLE 5 extended advertisement, captured by a laptop scanning for company
ID 0xFFFF:

    BLE advertisement → AD walk → MeshPacket → AES-CTR decrypt → Data

It decrypts to a `POSITION_APP` message with a 36-byte payload. Nothing in the
test is synthetic, which matters: a hand-built fixture would have agreed with a
wrong nonce byte order just as readily as a right one.

## Safety

`RelayPolicy.Island` is the default and stamps `hop_limit = 0`.
`NextHopRouter::perhapsRebroadcast` relays only when `hop_limit > 0`, so an
island node **cannot** be flooded onto LoRa by any radio that hears it — enforced
by firmware that already ships, not by client good behaviour.

This is not theoretical caution. A UDP-capable client node can already inject
into the LoRa mesh through any UDP-enabled radio on the same LAN, and a radio's
NodeDB holds 120 entries (10 on STM32WL), so a room full of phone-nodes can evict
every real radio from the tables of anything that hears them. Widening the policy
is a deliberate, named choice.

## Not yet here

- **PKI for direct messages** — X25519 → SHA-256 → AES-256-CCM, 8-byte MAC,
  12 bytes of wire overhead. Needed before a node can send or read a DM.
- **Flood / next-hop routing.** With `PacketHistory` present but no relay logic,
  a node can listen and originate but must not relay.
- **Targets beyond JVM.** The layout is already `commonMain`/`jvmMain` with a
  single platform seam (the AES provider in `Crypto.kt`), so adding
  `androidTarget()` and the apple targets is mechanical.

## Building

    direnv exec ../meshtastic-sdk gradle build
