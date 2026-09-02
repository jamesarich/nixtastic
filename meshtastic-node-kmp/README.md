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
| `node-core` | Identity, channels, AES-CTR, PKI, acks, dedup, relay policy, the node itself. No I/O. | works |
| `node-transport-udp` | Multicast `239.0.0.69:4403` | works, verified against a radio |
| `node-transport-ble` | Scanning for mesh advertisements (Kable) | receive only |
| `node-transport-ble-adv` | Transmitting extended advertisements (Android, Linux) | planned |
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

`FirmwareInteropTest` goes further and runs the whole node against a radio. Given
a channel URL it joins `239.0.0.69:4403` and, against a stock Heltec V3 on
2.8.0 with `enabled_protocols` including `UDP_BROADCAST`:

- decrypts live traffic, including LoRa packets the radio relays onto UDP;
- gets itself into the radio's NodeDB as an ordinary node;
- sends a PKI direct message and receives the radio's `ROUTING_APP`
  acknowledgement.

It is skipped unless `MESH_INTEROP_CHANNEL_URL` is set, because it needs
hardware. See the file header for the invocation.

### Three rules a radio enforces that talking to yourself will not reveal

Each of these was found by watching a bench radio decrypt our packets, log them,
and throw them away. All three are covered by `FirmwareWireRulesTest`.

- **`Data.bitfield` must be present on every packet.** `classifyHopStart` uses
  its presence to tell a modern zero-hop broadcast from firmware older than
  2.3.0. Without it, `RelayPolicy.Island` — which sets `hop_start = 0`
  deliberately — makes every packet look ancient, and the radio drops it after
  decrypting it. The drop log is rate-limited, so most leave no trace.
- **A PKI packet must carry `channel = 0`.** `Router::perhapsDecode` gates its
  entire PKI branch on it. Stamp the channel hash and the radio never attempts
  X25519: it tries the channel key, gets noise, and reports "bad psk".
- **Persist the address and the keypair together.** A radio pins the first
  public key it sees for a node number and answers every later one with
  "Public Key mismatch, drop NodeInfo". A node that keeps its address but
  regenerates its key is permanently unreachable to every peer that
  remembers it.

And one that is about the host rather than the protocol: a `MulticastSocket`
with no interface set does not necessarily transmit on the route that reaches
the group. On macOS it does not, while the loopback copy still shows the right
source address — so a local capture shows packets leaving that no other host
ever sees. `UdpMulticastTransport` resolves the interface by running the route
lookup itself.

## Not yet here

- **Flood / next-hop routing**, without which the node must not relay.
- **Transmitting on BLE.** `node-transport-ble` scans; it declares
  `canTransmit = false` because Kable is central-role only and CoreBluetooth
  cannot advertise arbitrary payload at all. Android and Linux can, and that is
  a separate module.
- **Android.** No `androidTarget()` yet, and the UDP transport needs a
  `WifiManager.MulticastLock` there — without one the socket silently receives
  nothing.

## Building

    direnv exec ../meshtastic-sdk gradle build

See [`../notes/ble-mesh-transport.md`](../notes/ble-mesh-transport.md) for the
firmware side and how the two were brought up together.
