# A firmware node cannot take an implicit ack over GATT

Open, and deliberately not patched: the fix touches a security guard and an
upstream ack contract, so it is James's call. Everything below is read from
source, not inferred.

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

## The three options, as they stand

1. **Leave it.** Firmware gets no implicit ack over GATT; node-kmp does. Costs a
   retransmit that a LoRa-adjacent node would have retired, and nothing else.
2. **Admit the echo into the Router.** Smallest diff, widest blast radius - it is
   exactly what the guard exists to stop.
3. **Account for it without routing it.** Keep the drop, and before returning,
   hand the packet to the ack path alone when it matches a pending retransmission
   by `(from, id)` and carries `hop_limit < hop_start`. A forger would have to
   guess a packet id currently in flight, and the only thing they could buy is an
   ack the sender was already expecting - not a routing decision.

Option 3 is the one worth building. It is a change to ack semantics on a bearer
upstream has not shipped, so it wants a PR of its own rather than riding along.
