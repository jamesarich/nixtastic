# A firmware node cannot take an implicit ack over GATT

**Closed 2026-09-16: the guard stays, following firmware.** Everything below is
read from source, not inferred.

## The interaction

`ReliableRouter::sniffReceived` raises an implicit ack for a rebroadcast of a
packet it has pending, on **any** transport - it checks the transport only to
decide whether to also retire the retransmit:

```cpp
sendAckNak(meshtastic_Routing_Error_NONE, getFrom(p), p->id, old->packet->channel, 0, false, p);
// Only stop retransmissions if the rebroadcast came via LoRa
if (p->transport_mechanism == meshtastic_MeshPacket_TransportMechanism_TRANSPORT_LORA) {
```

So upstream expects non-LoRa echoes to arrive. `BLEGattMeshHandler::deliverToRouter`
drops them first:

```cpp
if (mp.from == nodeDB->getNodeNum()) {
    LOG_WARN("BLE GATT mesh: peer %u claims our own node number, dropping", peer);
    return;
}
```

A node's own packet relayed back carries its own `from`, so it never reaches
`sniffReceived` and no ack is raised. Our node-kmp fix makes those echoes happen
- a relay now goes back to the peer that wrote the packet, proven on the bench -
so firmware is the half that still cannot use them.

## Why the guard is not simply wrong

Its comment names the reason: a spoofed local origin reaches paths that trust
`isFromUs`. Removing it to admit the echo would widen that trust to any peer on
the link, which on a bearer with no link-layer authentication is the whole mesh.

## Decided: follow firmware, keep the guard

James's call, 2026-09-16: follow firmware's lead. The guard stays.

Upstream argues the same way in its own code. `Router.cpp` keeps a forged sender
off exactly this path -

```cpp
// instead of blackholing; isFromUs stays REJECT to keep forged senders off the ACK path.
```

- and the blast radius is concrete: `Router.cpp:598` gates the **MQTT uplink** on
`isFromUs(p)`, so a packet forged with our node number that reached the Router
decoded would be published to the broker under our identity. On a bearer with no
link-layer authentication, that is the whole mesh.

The alternative considered and rejected was to hand the echo to the ack path
alone, never to routing. That is precisely the case upstream's comment names.

**What it costs:** a firmware node takes no implicit ack over GATT, so a
`want_ack` packet retransmits where a LoRa-adjacent node would have retired it.
Nothing else. node-kmp is unaffected - it takes its implicit ack normally, which
the relay-back fix proved on the bench.

AEAD would change the calculus, since a forgery cannot decrypt on an AEAD
channel - but it is opt-in, off by default, and not yet in a released proto. See
[`upstream-drift-aead-and-opaque-relay.md`](./upstream-drift-aead-and-opaque-relay.md).
