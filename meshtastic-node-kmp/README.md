# meshtastic-node-kmp

A Kotlin Multiplatform library that lets an application be a Meshtastic **node**
— holding its own identity and keys, decrypting what it hears and originating
its own traffic — rather than being handed decoded packets by a radio over the
phone API.

Deliberately not part of [`meshtastic-sdk`](../meshtastic-sdk). That repo's
contract is *client talks to a radio*: `RadioClient`, and a `Transport` that
means ToRadio/FromRadio framing. Its `transport-ble` is a phone↔radio link, not
a mesh link, and its `core` holds no cipher — a node holds private key material
and does its own crypto, which is a different security surface for an artifact
whose audience today never touches one.

## Modules

| Module | | Status |
| --- | --- | --- |
| `node-core` | Identity, channels, AES-CTR, dedup, relay policy, the node itself. No I/O. | works |
| `node-transport-udp` | Multicast `239.0.0.69:4403` | works |
| `node-transport-ble-adv` | Connectionless extended advertising (Android, Linux) | planned |
| `node-transport-ble-gatt` | Dual-role GATT (Apple, Android fallback) | planned |
| `node-android` | Foreground service, permissions, Doze | planned |

**`node-core` depends only on `org.meshtastic:protobufs`, never on
`meshtastic-sdk`.** An app can then be both a client and a node with no
dependency cycle, and the SDK can later depend on this rather than the reverse.

## Using it

```kotlin
val node = MeshNode.build {
    identity(MeshIdentity.derive(installSeed, "my laptop", "LAP"))
    channel(MeshChannel("LongFast", psk))
    transport(UdpMulticastTransport())
    codec(ProtoPacketCodec())
    clock { System.currentTimeMillis() }
}

node.start { event ->
    when (event) {
        is MeshEvent.TextMessage -> println("${event.from}: ${event.text}")
        is MeshEvent.Opaque -> {}   // traffic we hold no key for
        is MeshEvent.Dropped -> {}
    }
}
node.sendText("hello mesh")
```

Persist the seed once per installation. A node whose address changes on restart
appears as a new node in every peer's NodeDB, and those hold 120 entries — 10 on
STM32WL.

## Safety

`RelayPolicy.Island` is the default and stamps `hop_limit = 0`.
`NextHopRouter::perhapsRebroadcast` relays only when `hop_limit > 0`, so an
island node **cannot** be flooded onto LoRa by any radio that hears it —
enforced by firmware that already ships, not by client good behaviour.

Not theoretical: a UDP-capable client node can already inject into the LoRa mesh
through any UDP-enabled radio on the same LAN, and `UdpMulticastHandler` does not
require the sender to be in its NodeDB. Widening the policy is a named choice.

`MeshNode` also does not relay what it receives. Dedup alone is not enough — a
node that rebroadcasts without the flood and next-hop policy amplifies every
frame it hears.

## What is proven

`CapturedFrameTest` runs the receive chain against a frame captured off the air:
a real packet relayed by a Heltec V3 running the BLE-mesh firmware, transmitted
as a BLE 5 extended advertisement, captured by a laptop scanning for company ID
0xFFFF.

```
BLE advertisement → AD walk → MeshPacket → AES-CTR decrypt → Data
```

It decrypts to a `POSITION_APP` message with a 36-byte payload. Nothing in that
test is synthetic, which is the point: a hand-built fixture would agree with a
wrong nonce byte order just as readily as a right one.

## Not yet here

- **PKI for direct messages** — X25519 → SHA-256 → AES-256-CCM, 8-byte MAC,
  12 bytes of wire overhead. Needed before a node can send or read a DM.
- **Flood / next-hop routing**, without which the node must not relay.
- **Targets beyond JVM.** The layout is already `commonMain`/`jvmMain` with a
  single platform seam (the AES provider in `Crypto.kt`), so adding
  `androidTarget()` and the apple targets is mechanical. Note Apple can *receive*
  on BLE advertisements and never transmit: CoreBluetooth cannot advertise
  arbitrary payload, and backgrounded it can only scan by service UUID.

## Building

    direnv exec ../meshtastic-sdk gradle build

See [`../notes/ble-mesh-transport.md`](../notes/ble-mesh-transport.md) for the
firmware side and how the two were brought up together.
