# A curve25519 module for node-kmp: design constraints

Findings from an adversarial review of the first plan, 2026-09-17, with the parts
that were checked against a compiler or an artifact marked as such. The algorithm
being implemented is in
[`xeddsa-firmware-logic.md`](./xeddsa-firmware-logic.md).

## Settled by evidence

**A `@JvmInline value class` over `ULongArray` is the wrong representation.**
Compiled on Kotlin 2.4.20: the generated `equals` delegates to the array, so `==`
is reference equality and `a + b == expected` in a test silently compares
pointers. It cannot be repaired in place - a value class overriding `equals` or
`hashCode` fails to compile, both names being reserved. `ULongArray` also carries
`@ExperimentalUnsignedTypes` through every public signature, and a public value
class is name-mangled in the JVM ABI dump and boxed in the klib dump, so the
choice lands in `api/` permanently.

Use plain `internal` classes over `LongArray`, no `equals` override, comparison
through `encode().contentEquals` or an explicit constant-time helper - and make
the **public surface bytes-only**: sign, verify, and the Montgomery-to-Edwards
map. Three public functions; everything else `internal`, which `commonTest` still
sees.

**Immutable values are affordable; the allocation hazard is a layer lower.** One
scalar multiplication is roughly 4,300 field multiplications and 3,000 add/subs,
so about half a megabyte of short-lived garbage. At a handful of signatures per
second that does not matter on either JVM or Native. What does matter is a
64x64->128 helper that returns a container per product: called ~25 times per field
multiply, that is ~100,000 allocations per scalar multiplication. Return the high
word as a scalar, or avoid 128-bit arithmetic entirely.

**`CryptographyProvider.Default` throws when nothing is registered** -
`IllegalStateException("No providers registered...")`, present in both the JVM
class and the native klib. Registration is a JVM `ServiceLoader` entry or a native
`@EagerInitialization`, so it happens only when a provider artifact is on the
classpath. A module depending on `cryptography-core` alone therefore fails at the
first hash, and `commonTest` cannot supply a provider because the JDK one is
JVM-only and openssl3 native-only.

Worse for correctness of intent: **node-core never uses `Default`.** It picks
`CryptographyProvider.JDK(BouncyCastleProvider())` on JVM and Android and
`Openssl3` on native. A module resolving `Default` would quietly select a second,
differently chosen provider beside it.

So SHA-512 is either injected (`fun interface Sha512`) or owned outright, which
also makes `cryptography-core` a test-only dependency and the module genuinely
standalone. `Hasher.hashBlocking` is a default method on the common interface and
works on every target here, so a synchronous API is available either way.

## The test plan has to be differential, not exemplary

RFC 8032 has five vectors. They exercise five scalars and never put a saturated
limb, a non-canonical encoding or the top-carry path in front of the multiplier, so
a carry bug that fires on rare inputs walks straight past them. Self-verification
does not help: a symmetric error - wrong curve constant, wrong basepoint, a carry
fault - passes its own verifier and fails at every peer.

What the gate needs instead:

- **A BigInteger differential** for field and scalar arithmetic in `jvmTest`, over
  random inputs and an explicit edge list (0, 1, p-1, p, p+1, all limbs saturated,
  L-1, L, L+1, 2^512-1). The arithmetic is common code, so proving it on the JVM
  covers every target.
- **A foreign-verifier differential for the raw signing equation.** BouncyCastle
  exposes public static `Ed25519.sign` and `Ed25519.verify`; cryptography-kotlin's
  `EdDSA` signs from a seed on every target. Feeding a derived scalar and prefix
  with an **empty hedge** makes our signer RFC 8032-deterministic, so both must
  agree bit for bit over thousands of random seeds.
- **kotest-property 6.2.4**, which publishes for every target here.
- **Wycheproof `ed25519_test.json`** - 151 cases, all `EddsaVerify`, so
  verify-only by construction. KMP has no common resource API and this repo has no
  `resources/` directory at all, so it must be **generated into a Kotlin source
  file** in `commonTest` rather than read at runtime.

**Strict verification is safe against firmware, and here is the argument** rather
than the assumption. Firmware's Barrett reduction keeps `s < q` even though
`XEdDSA::deriveKeys` feeds it an unreduced clamped scalar that violates its stated
precondition by about 16x, and `Curve25519::reduce`'s contract makes `y`
canonical. So firmware cannot emit a signature that a strict verifier rejects, and
node-kmp may reject `s >= L`, non-canonical `y` and garbage without dropping
legitimate traffic.

## Hazards beyond the four already recorded

- **Mask bit 255 of `u` and reduce mod p before the map**, as firmware's
  `fe_frombytes` does. Disagreeing here means two nodes disagree about who is a
  signer, which under `BALANCED` changes what gets dropped.
- **Reject degenerate mapped keys.** `u = p-1` gives `u+1 = 0`, and inverting zero
  yields zero, so `y = 0` - a valid order-4 point. Reject `u` in `{0, 1, p-1}`
  explicitly.
- **Decompression failure returns false, never throws.** It sits in front of
  attacker-supplied bytes.
- **The nonce must be mandatory in production.** Two signatures over different
  messages with the same `Z` and a constant prefix leak the private scalar. Derive
  the prefix from the secret, require 32 fresh random bytes, and let only the raw
  layer accept an empty hedge - which is what makes the deterministic differential
  above possible.
- **Decide the self-verify failure policy before wiring it in.** Falling back to
  sending unsigned is worse than failing loudly: every peer that already recorded
  this node as a signer drops its unsigned broadcasts under `BALANCED`.

## Two decisions that must be made before the first commit

**Where verification runs in production.** The stronger design keeps hand-written
code off the hostile-input path: use this module only for the birational map, and
verify through cryptography-kotlin's audited BouncyCastle or OpenSSL backend,
which is already present on every target. Our own verifier then exists for tests
and the send-side self-check. That halves the surface of new cryptography exposed
to packets from strangers.

**The licence.** Spotless's `licenseHeader` step *replaces* a file's leading
comment block with the GPL-3.0-or-later header, which will strip the attribution
from any ported MIT source. The reference arithmetic is ref10 (public domain) and
`Ed25519.cpp` (MIT). The header choice also decides whether this module can ever
be offered to the wider Kotlin ecosystem, which was part of the reason for
building it standalone.

## Build-side items a new module must carry

`settings.gradle.kts` include, the root `libraryModules` set (which drives Kover
and Dokka aggregation), `androidKmpLibrary` with `namespace`, `compileSdk`,
`minSdk` and `withHostTest {}` - without the last, `testAndroidHostTest` silently
skips the module - and `api/` dumps generated by `updateKotlinAbi` **on a Mac**,
because only there does `macosArm64` actually compile.

Unrelated correction found on the way: `AGENTS.md` states "No module declares
`linuxX64`", and `node-core` declares `linuxX64()` and `linuxArm64()`.
