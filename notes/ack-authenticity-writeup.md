# Ack authenticity: what is actually protectable

Followed by [`ack-proof-pr1094.md`](./ack-proof-pr1094.md), the review of
protobufs #1094, which implements the `ack_proof` half with all four changes
below applied.

Context: #11422 signs explicit acks under Strict and binds `request_id`/`reply_id` into the XEdDSA signing buffer. Separately Jonathan sketched a cheaper shared-key alternative, `ack_proof = truncate(SHA256(shared_key || request_id || "ack"), 8)`. I went through both against develop @ 3468af94a. The short version is that the retransmission threat both of them are aimed at cannot be fixed from the ack side at all, and there is a smaller property that is worth having and that only the ack-side work buys.

## The retry loop already stops without a key

`ReliableRouter::perhapsGenerateImplicitAckForOwnOverheard` clears a pending retransmission whenever we overhear any rebroadcast of our own `(from, id)`. It matches on the header, so it needs no decryption, no channel key and no signature, and it fires on opaque PKI DMs we cannot read ourselves.

That is deliberate and it is most of why reliable delivery is cheap on this mesh. One honest neighbour rebroadcasting ends the originator's retry loop within a packet. But it also means an attacker who wants to stop someone retrying does not need to forge an ack. Replaying the originator's own ciphertext back at them does it, and that is cheaper than crafting anything.

Three inputs clear the originator's `pending` map and only one is an ack we could authenticate: the destination's explicit ack at `ReliableRouter::sniffReceived` under `isToUs(p)`, a relayer's legitimate 0-hop ack that any node may send and no pairwise key covers, and the echo above. Authenticating the first leaves the other two, and the third is the cheap one. Signing acks does not close this and neither does `ack_proof`.

Relayer-side suppression is worse than I first thought, incidentally. `NextHopRouter::sniffReceived` runs `cancelSending` and `stopRetransmission` for any overheard ack not addressed to it, with no relayer check and no authentication, and the retry does not rescue it: only nodes that hear the originator directly re-relay a retransmission (`isRepeated = getHopsAway(*p) == 0`), so a relayer two or more hops out that gets suppressed never forwards that packet id again. The unicast budget is five attempts.

## What is worth protecting

The client side is where a forged ack actually costs a user something. Android grants `MessageStatus.RECEIVED`, rendered as delivered to recipient, when the ack's `fromId` equals the message's `to`. That `from` is unauthenticated and the packet is encrypted under a channel PSK that on LongFast is public, so anyone can produce it.

The keyless echo attack above does not reach that status. A locally generated implicit ack carries `from` equal to our own node number, so it lands on `DELIVERED`, which renders as relayed but not confirmed by recipient. That is honest, and it is the right answer for what actually happened.

So there is exactly one property here that only an authenticated ack can provide, which is a delivery receipt that really came from the recipient. That matters for SAR and event traffic where people act on a delivery confirmation. It is worth roughly ten bytes. It is also the whole of what is on offer, and I think we should say so rather than describe this work as retransmission hardening.

## On #11422

The `request_id`/`reply_id` binding should land. Channel crypto is AES-CTR with no MAC on the default channels, so a signed tapback's `reply_id` is malleable in flight today and can be re-pointed at a different message. That is a real bug, it is independent of the ack question and it costs nothing on the wire. Worth splitting into its own PR.

One change to it while it is open. The current scheme picks between two buffer layouts depending on whether either field is nonzero, with no version byte, and the safety argument is that no signable portnum currently emits a zero-request packet with an attacker-useful payload prefix. That is true today and has to be re-derived every time a portnum is added. A format byte costs nothing on the wire since the buffer is never transmitted. XEdDSA shipped in `v2.8.0.47db0e3`, so alpha devices are signing with the base layout now and any change breaks cross-version verification. If we are going to change it, better once and cleanly before 2.8.0 leaves alpha.

The signing half I would drop. Using the firmware's own airtime model on LongFast, a 29 byte ack is 477 ms and the same ack carrying the 66 byte signature field is 969 ms, so it roughly doubles the cost of the highest-rate unicast class we have. It buys no retransmission protection for the reason above. It only applies under Strict, and Strict is not deployable, since a Strict node relays nothing unsigned on a channel it can decrypt and drops signed acks from peers whose key it lacks. And nothing in the ack path reads `xeddsa_signed` anyway, so the routers would not consult it even where it is set.

## On ack_proof

Right instinct and right size, aimed at the property that is actually achievable. Four changes.

The label `"ack"` is a constant, and `allocAckNak` puts `error_reason` in the payload while `request_id` and portnum are identical for an ack and a nak. So both hash to the same proof and an attacker can flip one into the other while the proof still verifies. Hashing the payload fixes it. The direction that works easily is turning a real ack into a fake failure; manufacturing a fake success is narrower because it needs a captured proofed nak, and `MAX_RETRANSMIT` is generated locally while `PKI_UNKNOWN_PUBKEY` comes from a node that by definition has no key.

Use HMAC rather than `SHA256(key || msg)`. Not because the sketch is breakable, the message format is fixed and the truncation denies the internal state, but because HMAC is the construction with the proof behind it and it costs one compression.

Bind `from` and `to`. X25519 is symmetric, so without them an A to B proof on a given `request_id` is the same as a B to A proof on it. Exploiting that needs both sides to have a pending packet with the same id to each other, so it is cheap insurance rather than a live hole, but it removes an argument we would otherwise have to keep making.

Pin the encoding of `request_id` explicitly.

Two cost notes. The key is already hashed before AES-CCM in `encryptCurve25519`, so deriving it separately is hygiene rather than a fix. And it is not free: there is no per-peer shared-secret cache, `setDHPublicKey` runs `Curve25519::dh2` per call, so this is one X25519 per verify, forced by the attacker on every forged ack. It wants the same global DH budget the decrypt path already has.

## Do not let firmware enforce it

The obvious next step is a rule where once a peer sends a valid proof we require one from them forever, modelled on `isKnownXeddsaSigner`. Worth flagging before anyone builds it: that makes a missing proof destroy the only delivery signal we have, on state the user cannot see. The proof needs the peer to hold our key, and peer-side NodeDB eviction is invisible to us, so ordinary churn would silently kill acks forever. A peer downgrading firmware does the same. `PKI_UNKNOWN_PUBKEY` naks are inherently unproofable either way.

Better to keep it advisory: a valid proof marks the ack verified, anything else behaves as today and is flagged unverified, and the client renders the difference.

## Why not just allow PKC on ROUTING_APP

Worth answering since it is the obvious question. It is about twelve bytes against ten, no protobuf change, no new primitive, and it authenticates the whole payload including `error_reason`.

The reason is that relayers read `request_id` out of channel-encrypted acks to run `cancelSending`, `stopRetransmission` and route learning, and the destination's 0-hop ack is what stops the last relayer's intermediate retries. An opaque ack costs last-hop duplicate airtime. A readable ack with a small proof keeps the mesh behaviour and adds the receipt on top. If someone has numbers suggesting the duplicate airtime is cheaper than the proof field, I would rather be shown that than guess.

## Three things that are not about crypto

These are availability bugs that exist now and are cheaper to fix than any of the above.

Forged acks work over MQTT with no radio at all. `MQTT::onReceiveProto` enqueues a downlinked ROUTING packet after `passesRoutingAuthGate`, which under the default Balanced policy accepts an unsigned ack, and `shouldDropMqttDownlink` filters ignore-lists and broadcast sources only. The only router-side exemption is `isFromUs(p) && TRANSPORT_MQTT`. So anyone on the public broker can stop retransmissions and write route state in any mesh running a LongFast downlink gateway. A `via_mqtt` ROUTING packet should never stop a retransmission or write route state.

The ack-driven cancel bypasses the role guard we already have. `roleAllowsCancelingDupe` deliberately refuses to cancel a rebroadcast on ROUTER, ROUTER_LATE and CLIENT_BASE for favorited nodes, and `perhapsCancelDupe` honors it, but the ack block in `NextHopRouter::sniffReceived` does not and neither does `Router::cancelSending`. So the backbone roles designed never to drop a rebroadcast are exactly the ones a forged ack drops. That looks like an oversight rather than a decision.

Route state gets written from unauthenticated acks. The `next_hop` write is reasonably gated by `checkRelayers` and `resolveUniqueLastByte`, but `noteRouteSuccess` is not gated at all, and there is no `!isToUs` guard on the learning block while the sender is in its own packet's `relayed_by`, so a forged ack can poison the originator's own route to the destination. Bounded by the thirty minute TTL and the failure threshold, but worth closing.

## Client side

`handleAckNak` takes `requestId`, `fromId`, `routingError` and `relayNode`, and does not consume `xeddsa_signed`, although android already maps, persists and renders that bit elsewhere and it is in scope at the call site. Firmware does not set it on acks today, so the client change is a precondition of any firmware change here rather than a separate gap.

Android already distinguishes a relayer ack from a destination ack correctly. What it needs is a verified dimension on `RECEIVED` so that delivered to recipient means the recipient proved it. Same on Apple, which I have not looked at.
