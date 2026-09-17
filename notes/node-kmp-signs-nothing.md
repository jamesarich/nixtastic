# node-kmp verifies signatures and produces none

Found 2026-09-17 on `meshtastic-node-kmp` `main` at `e9cb99e`, while looking for
what parity work is left after AEAD.

## The finding

**The node enforces `security.packet_signature_policy` on everything it receives
and never signs anything it sends.**

- Receive: `MeshNode.kt:829` runs `signatureVerdictFor(config.signaturePolicy, …)`
  on each inbound packet and drops what the policy refuses.
- Send: `ProtoPacketCodec` never writes `Data.xeddsa_signature`. The field is read
  exactly once in the whole repo - `SignaturePolicy.kt:158`, on the verify path -
  and written nowhere.
- `signOriginated`, the function that would attach one, has **no call site outside
  its own tests**. Same for `shouldSign`, which it wraps.

Measured rather than inferred: encoding a broadcast through
`ProtoPacketCodec.encodeData` and decoding the result yields
`xeddsa_signature.size == 0`.

## Why it matters

Firmware 2.8 signs its broadcasts, and a peer's policy decides what to do with an
unsigned one. Against a **STRICT** peer every packet this node sends is refused.
Against **BALANCED** it survives only by accident - that policy refuses an unsigned
broadcast from a node that *has signed before*, and this node never signs, so it is
never marked a signer and never trips the rule. The node is invisible to the
strictest peers and its own policy reporting is half true.

It also means licensed mode cannot work. Licensed traffic is plaintext and
attribution is the whole point, and `shouldSign` already has the
`isLicensed` branch written for it - unreached.

## Why it was invisible

Everything around it is built and tested. `curve25519` implements XEdDSA,
`PacketSignature` signs and verifies, `SigningPolicy` decides correctly and even
self-verifies before transmitting, `SignaturePolicyTest` and `SigningPolicyTest`
pass. The one thing missing is the call, so the suite is green and the behaviour is
absent - the repo's own "tests that lie" class, in the layer that faces strangers.

Two documents assert the opposite and need correcting with the fix:

- `CHANGELOG.md` under Unreleased: "**XEdDSA packet signing and verification** …
  A node signs its own broadcasts and checks the signatures on what it receives."
  The second half is true.
- `ProtoPacketCodec.kt:327`: "firmware's plaintext XEdDSA signing under licensed
  mode is not implemented here." Stale in a misleading direction - it implies the
  *only* gap is licensed mode, when no signing happens at all.

## The fix

Wire `signOriginated` into the seal path, which needs three things it does not
have there: the node's key pair, 32 fresh random bytes per packet, and the
`isPkiEncrypted` / `isBroadcast` / `isLicensed` facts. `PkiSend` already carries an
`extraNonce` from the host by the same argument, so the nonce seam has a precedent
to copy.

The test that would have caught it, and should land with the fix: originate a
broadcast and assert the packet a *peer* receives verifies - not that the signing
function works.

Related: [`node-kmp-audit-2026-09-16.md`](./node-kmp-audit-2026-09-16.md),
`packet-authenticity-policy-design121`.
