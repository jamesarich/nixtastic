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

**Signing cannot go through cryptography-kotlin, but that does not mean hand-rolling
curve arithmetic. Corrected 2026-09-17 after an adversarial review.**

No route exists through any library already on the classpath, verified in the
artifacts rather than assumed from RFC 8032:

- `EdDSA.PrivateKey` offers only `signatureGenerator()`; its formats are
  `RAW`/`DER`/`PEM`/`JWK`, and the JDK provider's RAW decoder wraps the bytes in an
  RFC 8410 `CurvePrivateKey` and hands them to JCA - the seed, not the scalar.
- **BouncyCastle 1.83 is already on `node-core`'s `jvmAndroidMain` classpath** and
  does not help either: `Ed25519.scalarMultBaseEncoded` and `implSign` are private,
  and `scalarMultBaseYZ` is gated behind a package-private `X25519.Friend`. Only
  `X25519Field` is public, which is useful for the birational map on the JVM and
  nothing more.
- `cryptography-bigint` is a serialisation container with no arithmetic.

**What makes signing small is a raw-scalar primitive, and one exists for every
target this library builds for.** `io.github.andreypfau:curve25519-kotlin:0.0.8`
(pure Kotlin, MIT, a curve25519-dalek port) publishes jvm, iosArm64,
iosSimulatorArm64, iosX64, linuxX64, linuxArm64, macosArm64 among others -
confirmed from its `.module` on Maven Central. It exposes `Scalar`,
`EdwardsPoint.mulBasepoint`, `CompressedEdwardsY`, `FieldElement.invert` and
`MontgomeryPoint.toEdwards(sign)` - the birational map included. On those
primitives the XEdDSA wrapper is about forty lines:

    a = reduce(clamp(x25519Priv));  A = aB
    if (encode(A)[31] and 0x80) { a = -a; A = -A }
    prefix = SHA512(a)[32..64]
    r = reduce(SHA512(prefix ‖ M ‖ Z));  R = encode(rB)
    k = reduce(SHA512(R ‖ encode(A) ‖ M));  s = k·a + r
    signature = R ‖ s

The alternatives are vendoring that library's field/scalar/edwards subset under
MIT, or `com.ionspin.kotlin:multiplatform-crypto-libsodium-bindings` - the only
constant-time option, at the cost of JNA and per-platform natives beside the two
crypto stacks already here. Hand-porting ref10 is ~1500-2500 lines of Kotlin and is
the option to avoid.

### Four things that will bite a naive replication

1. **Firmware is not Signal-spec XEdDSA, and libsignal is a third variant.**
   Firmware derives `prefix = SHA512(a)[32..64]` and hashes `prefix ‖ M ‖ Z`; the
   Signal spec hashes `0xFE ‖ 0xFF*31 ‖ a ‖ M ‖ Z`; libsignal does not negate the
   scalar at all and carries the sign bit in `s[63]`. Two consequences: node-kmp
   need not match firmware's nonce derivation, because firmware *verifies* with
   plain Ed25519, so any valid signature under `(a, A)` passes - and **libsignal or
   curve25519-java test vectors are unusable here**, failing whenever a key's sign
   bit is 1.
2. **The negation must reach both `a` and the `A` that goes into `k`.** Derive `A`
   from the public key by the birational map (always sign 0) while signing with an
   un-negated `a`, and about half of all keys produce permanently invalid
   signatures - deterministic per key, and firmware hard-drops a failed
   verification under every policy. Design the tests around this case.
3. **Reduce the scalar first.** A clamped key has bit 254 set, so `a > L`; reduce
   mod L up front. Check `(-1)·a + a == 0`.
4. **There are no fixed vectors in firmware** - its `test_XEdDSA` generates a
   keypair per run and asserts only a round trip. Layer the code as a raw Ed25519
   signing equation taking `(a, A, nonce)`, testable bit-exactly against RFC 8032,
   plus the XEdDSA wrapper above it, testable by round trip cross-verified with
   cryptography-kotlin's audited verifier.

**Verify every signature before sending it.** One extra verification per broadcast
costs nothing at LoRa rates and converts the whole class of always-invalid-key bugs
from silent disappearance at every peer into a loud local failure.

### Smaller divergences to expect

- Firmware's verify is lenient - no `s < L` check, no canonical-y check on decode -
  so node-kmp will drop some malformed signatures firmware accepts. Safe direction.
- `canonicalSignableSize` measures with nanopb; Wire's encoded size can differ by a
  byte or two, so the `BALANCED` downgrade threshold may not match exactly at the
  edge.
- The signature lives *inside* the encrypted `Data`: sign before channel encryption,
  verify after decryption, and a relay must pass the bytes through untouched.
- First contact needs `nodeNum == crc32(publicKey)`, which `MeshIdentity` and
  `MeshNode` already enforce, so that path needs no new invariant.
