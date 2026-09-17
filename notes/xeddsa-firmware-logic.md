# XEdDSA packet signing, as firmware implements it

Read out of `firmware` at `develop` on 2026-09-17, for replication in
`meshtastic-node-kmp`. Sources: `src/mesh/CryptoEngine.cpp`, `src/mesh/Router.cpp`,
`src/mesh/NodeDB.cpp`, and the `Crypto` library's `XEdDSA.cpp` (a PlatformIO lib
dep, not in the firmware tree).

`security.packet_signature_policy` **is** this feature. There is no separate
"enforce the policy" - the policy is the receive half of XEdDSA, and a node that
reports the field without verifying signatures is reporting a setting it does not
have.

## 1. What gets signed

`buildSigningBuffer` (`CryptoEngine.cpp`) - three little-endian `uint32`s then the
payload, with no separators and no length prefix:

    from (4) ‖ packet id (4) ‖ portnum (4) ‖ payload

12-byte header, buffer capped at `MAX_BLOCKSIZE` 256, so a payload over 244 bytes
cannot be signed and signing returns false. The signature is 64 bytes
(`XEDDSA_SIGNATURE_SIZE`), carried in `Data.xeddsa_signature`.

Note what is *not* covered: `to`, `channel`, `hop_limit`, `want_ack`. A signature
binds sender, packet id and portnum to the payload, not the routing envelope.

## 2. XEdDSA, not Ed25519

The node has one X25519 keypair, used for both ECDH (PKI messages) and signatures.
XEdDSA is what makes one key do both.

**Private side** (`XEdDSA::priv_curve_to_ed_keys`): clamp the Curve25519 private
key - `[0] &= 0xF8`, `[31] &= 0x7F`, `[31] |= 0x40` - treat the result as an
Ed25519 *scalar* directly, and compute `A = aB`. If `A`'s sign bit is set, negate
the scalar (`a = -a mod q`, via `sc_muladd` with `MINUS_ONE`) and recompute, so the
public point is always sign-normalised.

**This is the hard part for node-kmp.** The scalar is used *as* the scalar; it is
not a 32-byte seed hashed into one, which is what a standard Ed25519 API accepts.
A library that only exposes "Ed25519 private key from seed" cannot express XEdDSA
signing.

**Public side** (`CryptoEngine::curve_to_ed_pub`): the RFC 7748 §4.1 birational
map, `y = (u - 1) / (u + 1)`, with the sign bit cleared because XEdDSA normalises
it. Verification is then plain Ed25519 against that key. Firmware caches the
converted key against the last Curve25519 key it saw, because the field inversion
is expensive.

**Hedged nonce.** `XEdDSA::sign` reads `signature[0..31]` as the spec's random `Z`
and hashes prefix ‖ message ‖ Z to derive `r`. The caller must seed those 32 bytes
first - hardware RNG, else the seeded CSPRNG - and firmware deliberately never
fails signing over a weak `Z`, treating it as defence in depth against nonce reuse
rather than a correctness requirement.

## 3. Send side

`perhapsEncode`, for packets we originate:

    if (!pki_encrypted && (owner.is_licensed || isBroadcast(to)) && signedDataFits(decoded))
        sign

- **PKI-encrypted packets are never signed** - the AEAD already authenticates them.
- **Broadcasts are signed**; unicasts are not, *except* in licensed mode, where
  everything is plaintext so everything is signed.
- `signedDataFits` sets the signature size to 64, asks nanopb for the exact encoded
  size, and requires `encoded + 16 <= 255`. Exact, not a heuristic: signing then
  failing `TOO_LARGE` would break packets that were deliverable unsigned.
- Any signature a client preset is **cleared first**, outside the XEdDSA compile
  guard, so a non-signing build cannot transmit a stale signature that every
  signature-aware receiver would then hard-fail.

## 4. Receive side - `checkXeddsaReceivePolicy`

Returns false to drop. Three policies: `COMPATIBLE`, `BALANCED` (default),
`STRICT`.

First, unconditionally: `p->xeddsa_signed = false`. An inbound flag is never
trusted; only local verification sets it.

**Signature present and exactly 64 bytes:**

- Look up the sender's key with `copyPublicKeyAuthoritative` - the hot NodeDB entry
  or the warm store, **never an opportunistic cache key**. That is the trust loop
  #11116 closed: verifying against a planted key would let an attacker mark their
  own node a signer.
- Key found and signature verifies → set the node's
  `NODEINFO_BITFIELD_HAS_XEDDSA_SIGNED_MASK` bit (creating the node if needed, so
  eviction from the hot tier cannot silently forget it) and accept.
- Key found and verification fails → **drop, under every policy.**
- No key → try `verifyFirstContactNodeInfo` (§5). `INVALID` drops; `VERIFIED`
  accepts; otherwise accept, except under `STRICT`, which drops.

**Signature present but not 64 bytes** → drop, under every policy. Honest senders
emit only 0 or 64. A crafted partial signature would otherwise fall through to the
unsigned branch while its bytes inflated the size estimate, letting a forged
broadcast dodge the downgrade drop below.

**No signature:**

- `pki_encrypted` → accept (already authenticated).
- `STRICT` → drop.
- `COMPATIBLE` → accept.
- `BALANCED` → drop only what a signer always signs: the sender is a known signer,
  the packet is a broadcast (or we are licensed), and `canonicalSignableSize` says
  a signed copy would have fitted in
  `canonical + 66 + 16 <= 255`. A sizing failure never drops.

`canonicalSignableSize` re-encodes the payload through the message type the portnum
implies - `Position`, `Telemetry`, `Waypoint`, `User` - so a sender padding its
payload cannot inflate its way under the limit and pass as "too big to sign".

## 5. First contact

`verifyFirstContactNodeInfo` admits a key-bearing `NODEINFO_APP` packet from a node
we have no key for, and is the only path by which a key is learned from a signed
packet. It requires all of:

- the payload decodes as `User` with a 32-byte `public_key`;
- `crc32(public_key) == p->from` - the address *is* the key hash;
- the XEdDSA signature verifies against that key.

Then it stores the key, sets the signer bit, and marks the packet signed. Any
failure is `INVALID` and drops.

## 6. Downgrade protection

Two places, both keyed on the signer bit:

- the `BALANCED` unsigned-broadcast rule above;
- `NodeDB.cpp:3728` - an unsigned identity update for a node that previously signed
  is refused outright, checked *before* `getOrCreateMeshNode` so a refusal cannot
  evict the node it is protecting.

## 7. What this needs in node-kmp

Not proto-blocked: `Data.xeddsa_signature` and
`Config.SecurityConfig.PacketSignaturePolicy` are both in the pinned
`org.meshtastic:protobufs` 2.8.0.

**Verification is reachable today.** cryptography-kotlin 0.6.0 exposes `EdDSA` in
its common API, and both providers node-kmp uses implement it - 8 classes in
`cryptography-provider-jdk`, `Openssl3EdDsa` / `EdDsaSignatureGenerator` /
`EdDsaSignatureVerifier` in the openssl3 native klib. Verification needs only the
birational map (field arithmetic mod 2^255-19, one inversion) plus a standard
Ed25519 verify.

**Signing is the open question.** It needs Ed25519 signing from a *given scalar*,
not from a seed. If cryptography-kotlin's `EdDSA.PrivateKey` decoders only accept
seed or PKCS#8 forms, XEdDSA signing cannot be expressed through it, and the
options are a different dependency or implementing the scalar-mult and `sc_muladd`
directly. Settle that before committing to a plan.

**Suggested order.** Receive-side verification and the three policies first: that
is the half that makes `security.packet_signature_policy` a real setting rather
than an `ECHOED` one, it is the half that protects this node, and it does not need
the scalar question answered. Signing follows, and only signing makes this node a
good citizen for others' `BALANCED` mode.

A caveat worth carrying: node-kmp's NodeDb has no hot/warm tiering and no
opportunistic key cache, so "authoritative key" has no analogue yet. The rule to
preserve is the intent - verify only against a key this node has a reason to
trust, never one learned from the packet being verified, except through the
first-contact path that checks `crc32(key) == from`.
