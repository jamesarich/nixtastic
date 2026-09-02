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
| `node-transport-ble` | Connectionless BLE advertisements, our own CoreBluetooth and Android implementations | receive everywhere; transmit on Android |
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

The hardware tests go further and run the whole node against real radios. All of
them are skipped unless `MESH_INTEROP_CHANNEL_URL` names the radio's channel;
see each file's header for the invocation.

| Path | Test | Proven by |
| --- | --- | --- |
| **UDP** in and out | `FirmwareInteropTest` | Decrypts live traffic; appears in the radio's NodeDB; sends a PKI direct message and gets the radio's `ROUTING_APP` ack. |
| **BLE** in | `BleMeshLiveTest` | Scans BLE 5 extended advertisements through Kable and decrypts one — a position report that had arrived at the radio over LoRa. |
| **BLE** out | — | Implemented for Android (`startAdvertisingSet`, non-legacy) but **compile-verified only** — it has never met a radio. Impossible on Apple, see below. |
| **LoRa** in | `FirmwareInteropTest` | The traffic decrypted over UDP and BLE *originated* on LoRa; a bridging radio republished it. |
| **LoRa** out | `FirmwareInteropTest`, opt-in | Our packet was relayed onto the air and came back 29 times, rebroadcast by **nine distinct radios** at −112..−52 dBm. |

Two things that matrix is careful about. **LoRa is not a node transport** and
cannot be — there is no LoRa radio on a laptop. What is proven is that the LoRa
mesh is reachable in both directions through a bridging radio, which is the
useful property. And **BLE and UDP cannot be proven at the same time on an
ESP32**: `main-esp32.cpp` brings up NimBLE only when
`bluetooth.enabled && !network.wifi_enabled`, and the mesh handler waits on
`nimbleBluetooth->isActive()` before touching GAP — so with WiFi up the BLE
mesh arms and never advertises. They were proven in sequence, with a reboot
between.

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

One about BLE testing rather than the protocol: a radio advertises only when it
has a packet to send, so an idle mesh is genuinely silent and a short scan window
proves nothing. Bound a scan by *time*, never by advertisement count — in a
populated room a `take(n)` fills from nearby phones and beacons within seconds,
long before the next mesh frame, and then reports zero as though none existed.
`BleScanDiagnosticTest` exists to tell those two apart.

And one that is about the host rather than the protocol: a `MulticastSocket`
with no interface set does not necessarily transmit on the route that reaches
the group. On macOS it does not, while the loopback copy still shows the right
source address — so a local capture shows packets leaving that no other host
ever sees. `UdpMulticastTransport` resolves the interface by running the route
lookup itself.

## Not yet here

- **Flood / next-hop routing**, without which the node must not relay.
- **A verified BLE transmit.** The Android implementation exists and compiles,
  but no Android device has run it. `canTransmit` is the platform's answer, and
  on Apple it is permanently false: `CBPeripheralManager.startAdvertising`
  accepts only `CBAdvertisementDataLocalNameKey` and
  `CBAdvertisementDataServiceUUIDsKey`, so a `MeshPacket` is not expressible as
  an Apple advertisement at all. No library can lift that.
- **Linux BLE.** BlueZ over D-Bus would give the JVM both directions —
  `org.bluez.Adapter1.StartDiscovery` to receive, a registered
  `org.bluez.LEAdvertisement1` to transmit. The JVM radio today hears nothing
  and says so.
- **The UDP transport on Android**, which needs a `WifiManager.MulticastLock` —
  without one the socket silently receives nothing.

## Building

    direnv exec ../meshtastic-sdk gradle build

See [`../notes/ble-mesh-transport.md`](../notes/ble-mesh-transport.md) for the
firmware side and how the two were brought up together.
