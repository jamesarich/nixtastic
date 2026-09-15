# Ack authenticity: audit of firmware #11422 and the ack_proof proposal

Audited 2026-09-15 against `firmware` develop @ 3468af94a and `android` main.
Every claim below was checked against the code by two independent adversarial
passes. Claims I made earlier and had to withdraw are marked at the end.

PR #11422 is a draft, DIRTY, last touched 2026-08-12.

## State of play

XEdDSA signing shipped in `v2.8.0.47db0e3` (alpha pre-release, 2026-09-01) with the
base layout `[from|id|portnum|payload]`, signing unconditionally for
`!pki_encrypted && (is_licensed || isBroadcast)`. Latest non-prerelease is
`v2.7.26.54e0d8d`, which GitHub labels Beta and which has no xeddsa code at all. So
real alpha devices are emitting base-layout signatures today, and the window to
change the signing buffer closes when 2.8.0 leaves alpha.

Channel crypto is AES-CTR with no MAC on the default and on LongFast.
`ChannelSettings.use_aead` exists (`Channels::isAEADEnabled`) but defaults false.

## The thing that decides everything: three ways to stop a retransmission

The originator's `pending` map is cleared by three inputs, and only one of them is
an authenticatable ack:

1. **The destination's explicit ack.** `ReliableRouter::sniffReceived:172-188` under
   `isToUs(p)`. A MAC or signature can protect this.
2. **A relayer's 0-hop explicit ack.** `ReliableRouter.cpp:154-157`. Any node may
   legitimately send one. A MAC keyed to the destination pair cannot cover it.
3. **Any overheard rebroadcast of `(from, id)`.**
   `ReliableRouter::perhapsGenerateImplicitAckForOwnOverheard:58-88`. Header-only,
   no decryption, no key, and it works on opaque PKI DMs we cannot read ourselves.

**Input 3 is the killer.** An attacker replays the originator's own ciphertext, and
`stopRetransmission(key)` fires. No key, no forgery, cheaper than crafting an ack.
So **no amount of ack authentication protects the retransmission loop.** Not
ack_proof, not signatures. #11422 and the ack_proof proposal are both aimed at a
target that cannot be hit from this angle.

In normal operation input 3 is not an attack, it is the design: one honest
neighbour's rebroadcast ends the originator's retry loop within a packet. After
that, retransmission state lives only in relayers
(`NUM_INTERMEDIATE_RETX = 3`), which is exactly the state a forged ack kills and
which nothing endpoint-keyed can defend.

## What is still worth protecting

Android grants its strongest delivery claim, `MessageStatus.RECEIVED` rendered as
"delivered to recipient", when `fromId == p.to` (`MeshDataHandlerImpl.kt:423-427`).
`fromId` is the unauthenticated `from` of a ROUTING_APP packet encrypted under a
public PSK. Anyone on LongFast can forge that.

The keyless echo attack (input 3) does **not** reach it: the locally generated
implicit ack has `from = our own node num` (`Router::allocForSending:378`), so
`fromId == p.to` is false and it renders as `DELIVERED`, "Relayed, not confirmed by
recipient". Which is honest.

So there is exactly one property an ack MAC uniquely buys: **an authenticated
delivery receipt from the actual recipient.** That is real, it is safety-relevant
for SAR and event use, and it is cheap. It is also the whole of it.

## Verdict on #11422

**What is right and should land:** the `request_id`/`reply_id` binding in the
signing buffer. Signed tapbacks are retargetable today because channel crypto has no
MAC. Separate bug, real, free on the wire. Split it out. While doing it, replace the
conditional two-layout scheme with a format/version byte: the current version
depends on an argument about which portnums can currently emit a zero-request
signable packet, which has to be re-derived every time a portnum is added. Do it
before 2.8.0 leaves alpha.

The Balanced non-mirror reasoning is also correct, and the `to=0` and
Strict/Balanced asymmetry caveats are honestly disclosed.

**What should not land: signing acks.**

- Roughly doubles ack airtime. Measured with the firmware's own formula
  (SimRadio.cpp:407-423) on LongFast SF11/BW250/CR4-5: a 29-byte ack is 477 ms, with
  the 66-byte signature field it is 95 bytes and 969 ms. Ratio 2.03.
- Buys no retransmission protection, per input 3 above.
- Only ever applied under Strict, and Strict is not deployable: a Strict node relays
  nothing unsigned on a channel it can decrypt (`DECODE_POLICY_REJECT` →
  `RoutingAuthVerdict::REJECT` → released before `handleReceived`), and drops signed
  acks from peers whose key it lacks (`if (strict) return false`). It still relays
  what it cannot decrypt, so it is not a total blackhole, but on LongFast it is.
- Amplification: an attacker sends want_ack unicasts and forces an Ed25519 sign plus
  doubled airtime per ack.

The PR's own framing, that a forged ack makes honest relayers
`stopRetransmission()`, is true and is not fixed by the PR: nothing in the ack path
reads `xeddsa_signed`. Its consumers are MessageStore, TrafficManagementModule,
NodeInfoModule, TypeConversions. No router reads it. A Strict node is protected only
by the pre-existing blanket unsigned drop.

## Verdict on ack_proof

`ack_proof = truncate(SHA256(shared_key || request_id || "ack"), 8)`

Right instinct, right size, aimed at the one property that is actually achievable.
Four changes:

1. **Cover `error_reason`.** `"ack"` is a constant and `MeshModule::allocAckNak`
   puts `error_reason` in the payload while `request_id` and `portnum` are identical
   for ack and nak. So an ack and a nak on the same request_id have the same proof.
   Direction matters: ack→nak (fake failure) is the easy one, and its firmware
   effect is identical to a real ack since both branches call `stopRetransmission`,
   so the harm is UI plus a failed in-flight android request
   (`completeDispatchedResponse`). nak→ack (fake success) is narrow, because it needs
   a captured *proofed* nak and `MAX_RETRANSMIT` is local while `PKI_UNKNOWN_PUBKEY`
   comes from a node that by definition has no key. Fix it anyway: hash the payload.
   The XEdDSA signature does not have this flaw because it covers `payload`.
2. **HMAC rather than `SHA256(key || msg)`.** Hygiene, not a vulnerability: the
   message format is fixed and the 8-byte truncation independently denies the
   internal state, so length extension is not exploitable here. Use HMAC because it
   is the construction with the proof, not because this one is broken.
3. **Bind `from` and `to`.** X25519 is symmetric, so the same shared secret serves
   both directions and without this an A→B proof on request_id R equals a B→A proof
   on R. Exploiting it needs both sides to have a pending packet with the same id to
   each other, so this is cheap insurance rather than a live hole.
4. **Pin the encoding of `request_id`** (fixed32 LE).

Two cost corrections to my own earlier write-up: the key is **not** the raw ECDH
output, `encryptCurve25519` already runs `hash(shared_key, 32)` before AES-CCM, so
HKDF is hygiene rather than a fix. And it is **not** free: there is no per-peer
shared-secret cache (`shared_key[32]` is a single member, `setDHPublicKey` runs
`Curve25519::dh2` per call), so this is one X25519 per ack verify, forced by the
attacker on every forged ack. Cheaper than Ed25519 sign+verify, not zero, and it
needs the same global DH budget the decrypt path already has (Router.cpp:863-864).

8 bytes matches the existing PKC CCM tag length. Fine.

### Drop the "require it forever" rule

I proposed a self-bootstrapping per-peer rule modelled on `isKnownXeddsaSigner`:
once a peer sends one valid proof, require it from them always. That was wrong, for
a reason that generalises: **it makes a missing proof destroy the only delivery
signal**, on heuristic state the victim cannot see. Failure modes, all silent and
permanent:

- The proof needs the **peer** to hold **your** key. Peer-side NodeDB eviction is
  invisible to you. Natural churn on a large mesh then kills acks forever.
- Peer downgrades firmware: keys persist, proofs stop, every ack dropped forever.
- `PKI_UNKNOWN_PUBKEY` naks are inherently unproofable. Exempt them and they stay
  forgeable (and a forged one also triggers a NodeInfo broadcast); don't exempt them
  and a peer who factory-reset can never re-bootstrap with you.
- Key substitution sets the require-bit under a planted key, after which the real
  peer never validates.

The fix is to stop trying to make firmware enforce it: **proof valid → mark
verified; anything else → behave exactly as today, flagged unverified.** The client
renders the difference. That deletes every failure mode above at zero cost and is
what the property was for in the first place.

## Why not just un-exclude ROUTING_APP from PKC?

The first question any reviewer will ask. It is +12 bytes against ~10, no protobuf
change, no new crypto, and it authenticates the whole payload including
`error_reason`.

The answer, which needs to be stated explicitly or the proposal looks like it
reinvented CCM: **relayers read `request_id` out of channel-encrypted acks** to run
`cancelSending`, `stopRetransmission` and route learning
(`NextHopRouter.cpp:216-221`), and the destination's 0-hop ack is what stops the
last relayer's `NUM_INTERMEDIATE_RETX` retries (`ReliableRouter.cpp:138-143`). A
PKC-opaque ack costs last-hop duplicate airtime. Readable ack plus a small proof
keeps the mesh behaviour and adds the receipt.

## Separate, and worth more than the ack crypto

These are the real availability problems. None needs a wire change.

1. **MQTT forges acks with no radio.** `MQTT::onReceiveProto` builds a downlink
   packet and enqueues it after `passesRoutingAuthGate`, which under default Balanced
   accepts an unsigned ROUTING ack. `shouldDropMqttDownlink` filters ignore-lists and
   broadcast-source only. The single router exemption is `isFromUs(p) &&
   TRANSPORT_MQTT`. So anyone on the public broker can stop retransmissions and write
   route state in any mesh with a LongFast downlink gateway. Fix: never let a
   `via_mqtt` ROUTING packet `stopRetransmission` or write route state.
2. **The ack-driven cancel bypasses the role guard.**
   `FloodingRouter::roleAllowsCancelingDupe:117-135` deliberately refuses to cancel
   on ROUTER, ROUTER_LATE, and CLIENT_BASE for favourited nodes. `perhapsCancelDupe`
   honours it; the ack block at `NextHopRouter.cpp:216-220` does not, and neither
   does `Router::cancelSending`. The backbone routers designed never to drop a
   rebroadcast are exactly the ones a forged ack drops. Few lines to fix.
3. **Route state written from unauthenticated acks.**
   `NextHopRouter::sniffReceived:176-215` writes `origTx->next_hop`,
   `noteRouteLearned` and the TMM overflow cache. Gated by `checkRelayers` and
   `resolveUniqueLastByte`, so a fabricated `relay_node` must still have been a
   recorded relayer of the original. The genuinely unguarded one is
   `noteRouteSuccess(getFrom(p))` at `ReliableRouter.cpp:181-183`, which pins route
   health from a forgeable ack. There is also no `!isToUs` guard on the learning
   block, and the sender is in its own packet's `relayed_by[]`, so a forged ack can
   poison the **originator's** route to the destination. Bounded by a 30-minute TTL,
   a failure threshold of 3, and the last attempt flooding.

## Client work, and it is the primary deliverable

`handleAckNak` (`MeshDataHandlerImpl.kt:400-445`) takes `requestId, fromId,
routingError, relayNode, session` and does not consume `xeddsa_signed`, though it is
in scope in `handleRouting` and android already maps, persists and renders the bit
elsewhere (`MeshDataMapper.kt:54`, `Packet.kt:75`, `MessageItem.kt:477`). Firmware
does not set it on acks today, so the client change is a precondition of the
firmware change, not a standalone omission.

Android already gets the relayer-versus-destination distinction right. What it needs
is a verified dimension on `RECEIVED` so "delivered to recipient" means the
recipient proved it. Apple not checked.

## Claims I withdrew

- **"Third-party verifiability is decisive."** Overstated. Relayers frequently lack
  the acker's key, so signatures do not protect relayer suppression in general
  either.
- **"A forged ack at a relay only costs a retry round."** Wrong. I cited
  `FloodingRouter::shouldFilterReceived`; unicast DMs go through
  `NextHopRouter::shouldFilterReceived` (`isRepeated = getHopsAway(*p) == 0`) and
  PKI DMs through `relayOpaquePacket`. All three only fire at hop 1, so a
  suppressed hop-2+ relayer never re-relays that id. The budget is
  `NUM_RELIABLE_UNICAST_ATTEMPTS = 5`. And input 3 means the originator has usually
  stopped retrying anyway.
- **"The sender's stopRetransmission is the one gate that matters."** Wrong, there
  are three inputs and the keyless one dominates.
- **"Leave relayer suppression unverified, do not pay to fix it."** Withdrawn, but
  the conclusion "do not sign acks" survives on the airtime and input-3 grounds.
- **"Raw ECDH output" and "no asymmetric op."** Both wrong, see above.
