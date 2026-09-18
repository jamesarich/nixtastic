> **DO NOT FILE — duplicate.** Verified 2026-09-18 via the YouTrack REST API: this is **KT-87466**
> ("JvmExposeBoxed: Cannot generate code for delegating constructor of data class in IJ"), State Fixed,
> Available in 2.5.0-Beta1. Its description contains the identical `Unexpected IR element … RICH_FUNCTION_REFERENCE`
> text and `$boxingMarker: kotlin.jvm.internal.BoxingConstructorMarker?`. Searching KT for
> `RICH_FUNCTION_REFERENCE` missed it because the title names neither symptom.
>
> The trigger is not a default 2.4.20 change - it requires `-Xjvm-expose-boxed`, which
> `meshtastic-sdk/build-logic/convention/src/main/kotlin/KmpLibraryConventionPlugin.kt:118` sets for jvm/androidJvm.
> The larger consequence of that flag on 2.4.20 is **KT-87664** (binary-compat break of every default-args
> constructor with a value-class parameter, also Fixed / 2.5.0-Beta1). The useful upstream action is a comment on
> KT-87664 asking for a 2.4.x backport - both fixes are otherwise unshipped, with 2.5.0 slated for Dec 2026.
>
> Kept for the reproducer and the Native-vs-JVM observation, which are still accurate.

# Draft: Kotlin YouTrack report — RICH_FUNCTION_REFERENCE codegen failure on a constructor lambda default

Target: https://youtrack.jetbrains.com/newIssue?project=KT
Subproject: Backend. JVM. Suggested type: Bug. Priority: Major (blocks a toolchain upgrade, no source-level fix
without changing an API).

Check before filing: search KT for `RICH_FUNCTION_REFERENCE` — rich function references are a newer IR node and
there may already be an issue for the same lowering gap under a different trigger. If one exists, add this repro
as a comment instead of opening a duplicate.

---

## Title

`AssertionError: Unexpected IR element found during code generation: RICH_FUNCTION_REFERENCE` for a lambda default
value on a constructor parameter (JVM, 2.4.20)

## Description

Compiling a class whose **constructor parameter has a lambda literal as its default value** fails in the JVM
backend on Kotlin 2.4.20. The same code compiles on 2.4.10.

The frontend emits a `RICH_FUNCTION_REFERENCE` IR node into the synthetic default-argument constructor, and
`ExpressionCodegen` has no handler for it — the assertion text itself says it "should have been lowered", so a
lowering pass appears not to run for this position.

### Reproducer

```kotlin
import kotlin.time.Clock
import kotlin.time.Instant

class Repro(
    private val nowProvider: () -> Instant = { Clock.System.now() },
)
```

Compile for the JVM target. No compiler plugins are required.

### Expected

Compiles, as on 2.4.10.

### Actual

```
Exception while generating code for public constructor <init> (
  nowProvider: kotlin.Function0<kotlin.time.Instant>?,
  $boxingMarker: kotlin.jvm.internal.BoxingConstructorMarker?,
  $mask0: kotlin.Int,
  $marker: kotlin.jvm.internal.DefaultConstructorMarker?) declared in Repro

Caused by: java.lang.AssertionError: Unexpected IR element found during code generation. Either code generation
for it is not implemented, or it should have been lowered:
RICH_FUNCTION_REFERENCE type=kotlin.Function0<kotlin.time.Instant> origin=LAMBDA reflectionTarget='null'
    at org.jetbrains.kotlin.backend.jvm.codegen.ExpressionCodegen.visitElement(ExpressionCodegen.kt:940)
    at org.jetbrains.kotlin.backend.jvm.codegen.ExpressionCodegen.visitRichFunctionReference(IrVisitor.kt:167)
```

### Environment

- Kotlin 2.4.20 (fails) / 2.4.10 (works)
- Kotlin Multiplatform, failure is on the JVM target; the same declaration compiles for Kotlin/Native
  (`iosSimulatorArm64`) without error, so this looks specific to the JVM backend
- Gradle 9.7.1, JDK 21 (Temurin)
- No compiler plugins involved — the stack trace is entirely `org.jetbrains.kotlin.backend.jvm`

### Notes

The `$boxingMarker` / `BoxingConstructorMarker` parameter in the synthetic signature is not incidental. On 2.4.20
**every** synthetic default-arguments constructor in the project gains it - the binary-compatibility-validator
dump shows the old `(..., I, DefaultConstructorMarker)` shape replaced by
`(..., BoxingConstructorMarker, I, DefaultConstructorMarker)` across 48 declarations that have nothing to do with
lambdas. So the trigger is the new boxing-constructor lowering applied to default-argument constructors, and this
crash is the one case it does not handle: a default value whose IR is a rich function reference. Constructors with
non-lambda defaults lower and generate fine.

The `.klib.api` dumps for the same modules are byte-identical between 2.4.10 and 2.4.20, consistent with the
change being confined to the JVM backend.

Observed in a real project on two declarations of the same shape (an injectable clock, `() -> Instant` defaulted
to `{ Clock.System.now() }`). Workaround was to drop the default and require the parameter — viable only because
every call site already passed it.
