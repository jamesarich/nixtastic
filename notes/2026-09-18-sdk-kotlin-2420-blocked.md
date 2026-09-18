# meshtastic-sdk cannot take Kotlin 2.4.20 until a release carries the KT-87664 fix

Checked 2026-09-18. Three blockers sat behind the one-line `kotlin = "2.4.20"` bump (sdk #124 and #122, which
are the **same** catalog change - merging either no-ops the other). Two were cleared; the third is not clearable
in this repo, and it is the one that matters for a published library.

## 1. SKIE - cleared, but moot

SKIE 0.10.14 hard-refuses 2.4.20 ("SKIE 0.10.14 does not support Kotlin 2.4.20") and is the newest release.
Nothing here consumes SKIE output today: no `skie { }` block, no annotation, the sample CI links does not apply the
plugin, and the published `sdk-core-iosarm64` POM carries no SKIE dependency. A one-line gate behind
`meshtastic.skie.enabled` (default off) in `MeshtasticIosFrameworkPlugin.kt` makes iOS compile on 2.4.20 with no
published-artifact change. `skie.kgpVersion` is **not** an alternative: read from the 0.10.14 jar, it "override[s]
automatic Kotlin version resolution", i.e. it picks which per-KGP shim (`shim/impl_2_0_0/ActualKgpShim`…) to load,
so under 2.4.20 it binds the 2.4.10 shim to a 2.4.20 KGP and fails inside Native compilation instead of legibly at
configure time. Upstream support is touchlab/SKIE#202 (community PR, live); maintainer policy is to add versions
only after a Kotlin release (touchlab/SKIE#205); measured lag 13-61 days.

## 2. RICH_FUNCTION_REFERENCE crash - cleared, and known

2.4.20's JVM backend asserts `Unexpected IR element found during code generation … RICH_FUNCTION_REFERENCE` on a
lambda default value on a constructor parameter. Two sites (`AdminApiImpl`, `StoreForwardApiImpl`,
`nowProvider: () -> Instant = { Clock.System.now() }`); every construction site already passed it, so dropping the
default is behaviour-neutral. Verified: `compileKotlinJvm` passes, `jvmTest` 611/0. The same source compiles for
Kotlin/Native, so it is JVM-only. It is **KT-87466**, Fixed, Available in 2.5.0-Beta1. Do not file the draft in
`notes/drafts/kotlin-2.4.20-rich-function-reference-report.md`.

## 3. BoxingConstructorMarker - NOT clearable: a binary break, twice

`checkKotlinAbi` (KGP's built-in `abiValidation`, `PublishingConventionPlugin.kt:30` - so the Kotlin bump bumped
the validator too) fails with 48 lines, all the same shape:

    -  public synthetic fun <init> (…IILkotlin/jvm/internal/DefaultConstructorMarker;)V
    +  public synthetic fun <init> (…ILkotlin/jvm/internal/BoxingConstructorMarker;ILkotlin/jvm/internal/DefaultConstructorMarker;)V

The old signature is **removed**, not kept alongside. This is not default 2.4.20 behaviour: it requires
`-Xjvm-expose-boxed`, set at `KmpLibraryConventionPlugin.kt:118` for jvm/androidJvm only (hence only `api/jvm/*.api`
moved; `*.klib.api` is byte-identical), and it hits every default-args constructor taking one of the four public
value classes (`NodeId`, `ChannelIndex`, `MessageId`, `TransportIdentity`). The behaviour change is JetBrains commit
4a7a6f89e2 (2026-05-12, in 2.4.20, not 2.4.10), with no KT ticket, no changelog line, and no mention in What's New.

JetBrains classifies it as a bug: **KT-87664**, "JvmExposeBoxed: exposing constructor of ordinary class changes
behavior" - "the change breaks binary compatibility", repro `NoSuchMethodError: 'void Test.<init>(String,
DefaultConstructorMarker)'`. Fixed by 8d6f85eff2, Available in 2.5.0-Beta1. No 2.4.21/2.4.30 exists; releases.html
puts 2.5.0 at Dec 2026. The fix **restores the pre-2.4.20 shape**, so a 2.4.20-built artifact breaks consumers
once now and again on 2.5.0.

No flag preserves the old shape: the lowering gates on `implicitJvmExposeBoxed`, read straight from the `-X` flag or
`@JvmExposeBoxed`. Dropping the flag restores the constructors but deletes the exposed `<init>(TransportIdentity,…)`
and unmangled getters - a different ABI break. `updateKotlinAbi` would "pass" by ratifying a real break; the dump
is correct and the failure is the validator doing its job.

## Decision

Stay on 2.4.10. sdk #124/#122 cannot land; consider closing them with this note linked, so Renovate stops
rebasing them into the runner backlog. Branch `deps/kotlin-2.4.20-skie-gate` (`6b1e530`) holds the verified gate
and workaround for when a release with 8d6f85eff2 exists; it is not to be merged as-is. The one useful upstream
action is a comment on KT-87664 asking for a 2.4.x backport.

## How this was found, for next time

Three separate passes each stopped at the first blocker they hit. The first named SKIE and recommended waiting;
an adversarial recheck reversed that (SKIE is gateable and unused) and found the compiler crash; a third pass
dismissed the ABI failure as "unrelated to this change" - it was the only one that could not be worked around.
"Unrelated to my change" is not the same as "not blocking", and a blocker being clearable says nothing about the one
behind it.
