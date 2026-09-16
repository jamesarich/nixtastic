# ack_proof: review of protobufs #1094

Third note in the ack-security train. Read in order:

1. [`ack-authenticity-audit.md`](./ack-authenticity-audit.md) - the adversarial
   audit of firmware #11422 (XEdDSA signing) and Jonathan's `ack_proof` sketch,
   against firmware develop @ 3468af94a.
2. [`ack-authenticity-writeup.md`](./ack-authenticity-writeup.md) - the same
   material written for Jonathan.
3. this note - review of `meshtastic/protobufs#1094`, the proto half.

Reviewed 2026-09-16 at head `ac45f09`, branch `claude/routing-ack-proof`, base
`master`. Open, not a draft, 5 checks green, 1 unresolved CodeRabbit thread.
**Nothing posted.** James's call was to wait until Jonathan settles CodeRabbit.
Draft review text is at the end of this note.

## What the PR does

Adds `bytes ack_proof = 4;` to `Routing`, outside the `variant` oneof, with
`*Routing.ack_proof max_size:8` in `mesh.options`. Two files, one commit.

An explicit ack is a `ROUTING_APP` packet, `ROUTING_APP` is excluded from PKI,
so acks ride channel encryption only. Channel crypto is AES-CTR with no MAC and
the LongFast PSK is public, so any listener can forge an ack for a packet it
watched go past. Where the *acked* packet was PKI encrypted the two endpoints
already share a Curve25519 secret, so the receiver can MAC the ack for ~10
encoded bytes instead of 66 for an XEdDSA signature, and the ack stays
channel-readable so relayers keep reading `request_id`.

## He took all four audit corrections

The PR *body* still describes the original sketch,
`SHA256(shared_key | request_id | "mt-ack-v1")`. The committed field comment
does not. It is:

```
ack_proof = HMAC-SHA256(shared_key,
                        "ack" | LE32(from) | LE32(to) | LE32(request_id) | routing)[0..8)
```

Which is audit corrections 1-4: HMAC rather than `SHA256(key || msg)`, `from`
and `to` bound (X25519 is symmetric), the ack/nak distinction covered, and the
integer encoding pinned. Correction 1 was over-implemented: we asked for
`error_reason` to be covered, he covered the whole encoded `Routing` message,
which is where the one real bug comes from.

He also dropped the "require a proof forever once a peer sends one" rule, which
the audit argued against at length. Good.

## Verified this round, so nobody re-derives it

| Claim | Where | Verdict |
| --- | --- | --- |
| `shared_key = SHA256(X25519(priv, pub))` as the comment says | `CryptoEngine.cpp` `setDHPublicKey` runs `Curve25519::dh2`, then `hash(shared_key, 32)` is SHA256 in place | accurate |
| An ack encodes `error_reason = NONE` rather than omitting it | `MeshModule.cpp:57-58` sets `which_variant = meshtastic_Routing_error_reason_tag` explicitly, so the wire bytes are `18 00` | confirmed |
| nanopb rejects an oversized `bytes` field | `pb_decode.c:1566` `alloc_size > field->data_size` returns "bytes overflow", failing the **whole** `Routing` decode, not just the field | confirmed |
| android grants "delivered to recipient" on an unauthenticated `from` | `MeshDataHandlerImpl.kt:425` `isAck && (fromId == p?.to \|\| fromId == reaction?.to) -> MessageStatus.RECEIVED` | still true |
| There is a firmware-to-phone verified bit for signatures but none for this | `mesh.proto` `MeshPacket.xeddsa_signed = 22`; `Data.xeddsa_signature = 10`, `max_size:64` | confirmed |

## Verdict

It holds water, for a narrower thing than the PR says.

What it genuinely buys is one property: an authenticated delivery receipt to
the originator. That is worth having, and it applies exactly where it matters,
because the traffic that can compute a proof (PKI DMs) is the traffic where a
false "delivered to recipient" actually hurts someone.

What it does not buy is the thing the `Why` section leads with. Forged acks
suppressing retransmission is not fixable from the ack side at any price: the
originator's pending map is cleared by any overheard rebroadcast of its own
`(from, id)`, header match, no key and no decrypt, so an attacker replays your
own ciphertext back at you. See the audit, "input 3". His limits section half
concedes this; the framing should go rather than be retracted two sections on.

Scope is small and he documents it. No pairwise key means no proof, so
broadcast and plain channel traffic gain nothing, and the naks you would most
want authenticated (`PKI_UNKNOWN_PUBKEY`, `NO_CHANNEL`) are emitted precisely
because decryption failed.

## Five findings

1. **The `routing` input has no canonical form.** Hashing a re-encoded
   `Routing` makes the proof depend on serializer behaviour. The case that
   bites is an implementation leaving the oneof unset, producing empty `routing`
   bytes for an ack the firmware encodes as `18 00`. Fix: hash
   `LE32(error_reason)` and drop the dependency entirely.
2. **No consumer.** Firmware can verify but must not act (a missing proof has
   to stay non-fatal), and the phone holds no private key so it cannot verify
   itself. Without a bit on `MeshPacket` beside `xeddsa_signed = 22` the field
   is inert. Should land in the same PR, not a second wire bump.
3. **Failure semantics unstated.** The comment says unknown-field receivers
   ignore it, but never says a missing or invalid proof must not drop the ack.
   That is the contract every client depends on and it belongs in the proto.
4. **Version label regressed** from `"mt-ack-v1"` to `"ack"`. Keep the version
   so a future construction change cannot cross-verify by accident.
5. **`max_size:8` freezes the length forever** (see the nanopb row above). Say
   so; a stronger proof wants a new field number.

Plus: the body describes the superseded construction, and says it was opened as
a draft when it is not.

Not raised, deliberately. The same `shared_key` serves AES-CCM and HMAC-SHA256,
which is hygiene and the audit already called it that. Placement in `Routing`
rather than `Data` is right and his repeater argument holds, so don't
relitigate it. The audit's carry-forwards (X25519 per verify with no
shared-secret cache, the `roleAllowsCancelingDupe` bypass in the ack path,
MQTT-forged acks) are not this PR's problem.

## CodeRabbit overlap: one of five

It genuinely reviewed (`Actionable comments posted: 1`, CHILL profile, no
collapsed nitpick section, re-ran 2026-09-16 at the same head), so this is not
one of the quiet-CodeRabbit misreads.

Its one finding is our finding 1, at `mesh.proto:1223`, still unresolved. Same
underlying problem, wrong instance: it reasons from `RouteDiscovery`'s repeated
scalar fields, which never carry a proof, and never reaches the oneof-unset
case that actually breaks acks. Its two remedies are both weaker than dropping
the message hash: "define a canonical encoding" pushes a spec burden onto every
binding, and "strip field 4 from the received wire bytes" is legitimate but
forces wire-level surgery instead of letting implementations work from a
decoded struct.

Findings 3 and 4 were visible from inside this repo and it missed them, which
reads as the CHILL profile plus a `.proto` offering a reviewer no logic. 2 and
5 it had no way to see: they need `MeshDataHandlerImpl.kt` and nanopb's
`pb_decode.c`, neither of which is in protobufs. One actionable comment on a
security-relevant wire-format change is a thin review, not a clean bill.

If Jonathan fixes it by hashing `error_reason` directly, our finding 1 is
absorbed and we are down to four.

## Draft review, unposted

Vehicle when it goes: one `gh api repos/meshtastic/protobufs/pulls/1094/reviews`
with `event=COMMENT`, a body and a `comments[]` array, so the inline comments
land as a single notification, plus a GraphQL
`addPullRequestReviewThreadReply` for CodeRabbit's thread. No session-link
footer.

### Top-level body

> much better than signing - right size, and aimed at the one property that's
> actually reachable. few things.
>
> the `Why` still lists retransmission suppression.
> `perhapsGenerateImplicitAckForOwnOverheard` clears our pending map on any
> overheard rebroadcast of our own `(from, id)`, header match only, no key and
> no decrypt, so replaying our own ciphertext back at us stops the retry loop
> cheaper than forging an ack does. what this buys is the receipt to the
> originator, and that's the whole of it.
>
> second, nothing can consume it yet. firmware can verify but shouldn't act (a
> missing proof has to stay non-fatal), and the phone renders the delivery
> claim but holds no private key, so it can't verify. android grants
> `RECEIVED` / "delivered to recipient" on `fromId == p.to`, which is the
> forgeable bit. wants a bit on `MeshPacket` next to `xeddsa_signed = 22`, bool
> or a small authenticity enum. would rather that land here than as a second
> wire bump.
>
> body still shows the old `SHA256(shared_key | request_id | "mt-ack-v1")`
> construction, and the design's marked up for discussion but it's out of
> draft.

### Reply in CodeRabbit's thread, `mesh.proto:1223`

> this one's right, and it bites acks before it bites `RouteDiscovery`. an ack
> is `Routing` with `which_variant` set to `error_reason_tag` and
> `error_reason = NONE` (`MeshModule.cpp:57`), which encodes as `18 00`. an
> implementation that just leaves the oneof unset sends a semantically
> identical ack whose `routing` bytes are empty, and the proof won't verify.
> route_request/route_reply never carry a proof, so the repeated-field case is
> the theoretical one.
>
> simplest fix is to not hash the encoded message at all. `LE32(error_reason)`
> is the entire semantic content of a `Routing` ack and it drops the
> canonical-encoding dependency entirely. worth pushing the firmware prototype
> as a draft too, an implementation is what settles an encoding question.

### Inline, `mesh.proto:1220`

> the label went from `"mt-ack-v1"` in the description to `"ack"` here - keep
> the version in it, so a future construction change can't cross-verify by
> accident. also worth saying explicitly that `from` and `to` are the header
> fields of the `MeshPacket` carrying this `Routing`.

### Inline, `mesh.proto:1231-1234`

> worth stating the failure behaviour here, since every client ends up
> depending on it. a missing or invalid proof must not drop the ack or turn it
> into an error - it just leaves the delivery claim unverified. the
> self-bootstrapping version (once a peer proves, require it from them forever)
> looks tempting and breaks badly: the proof needs the peer to hold our key,
> peer-side nodedb eviction is invisible to us, and a firmware downgrade
> silently kills acks forever.

### Inline, `mesh.options:61`

> worth a note that 8 is frozen. nanopb fails the whole `Routing` decode on a
> longer value (`pb_dec_bytes`, "bytes overflow"), not just the field, so
> bumping this later stops old firmware parsing any ack at all. a stronger
> proof wants a new field number.
