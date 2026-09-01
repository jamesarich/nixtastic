# meshnode-spike

A Kotlin proof that a client app can act as a Meshtastic **node** — decoding and
decrypting mesh frames itself, rather than being handed decoded packets by a
radio over the phone API.

Deliberately *not* in `meshtastic-sdk`. That repo's contract is "client talks to
a radio" (`RadioClient`, and a `Transport` that means ToRadio/FromRadio framing),
it is Spec Kit-governed, and its `core` holds no cipher. This is the spike that
should exist before that governance conversation, not instead of it.

## What is proven

`ClientNodeReceiveTest` runs the whole receive chain against a frame captured
off the air — a real packet relayed by a Heltec V3 running the BLE-mesh spike
firmware, transmitted as a BLE 5 extended advertisement, and captured by a
laptop scanning for company ID 0xFFFF:

    BLE advertisement -> AD walk -> MeshPacket -> AES-CTR decrypt -> Data

It decrypts to a `POSITION_APP` message with a 36-byte payload. Nothing in the
test is synthetic.

## What is here

| File | |
| --- | --- |
| `ChannelCrypto.kt` | AES-CTR channel encryption: PSK size semantics (including the 1-byte default-PSK index form) and the `packet_id ‖ from ‖ counter` nonce |
| `BleMeshAdvert.kt` | The advertisement framing the firmware emits, both directions |

## What is not here yet

- **PKI for DMs** — X25519 -> SHA-256 -> AES-256-CCM, 8-byte MAC, 12 bytes of
  wire overhead. Needed before a client node can send or read a direct message.
- **`PacketHistory` dedup and the flood/next-hop policy.** Without these a
  client node can listen but must not relay.
- **Transports.** UDP multicast is the one to build first: `UdpMulticastHandler`
  already ships in firmware, so a client can be a peer against released firmware
  with nothing to merge. BLE is the end state because it needs no infrastructure,
  but Apple platforms can only receive on it — CoreBluetooth cannot advertise
  arbitrary payload at all, and backgrounded it cannot even scan for
  manufacturer data.

See [`../notes/ble-mesh-transport.md`](../notes/ble-mesh-transport.md).

## Running

    direnv exec ../meshtastic-sdk gradle test
