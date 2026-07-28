# Fix: `samples:parity-app` iOS Compose dependency resolution (meshtastic-sdk CI)

In `meshtastic-sdk` (github.com/meshtastic/meshtastic-sdk, branch `main`), the
`api-check` and `test-ios (iosSimulatorArm64)` CI jobs are red on every recent
`main` commit — confirmed broken at `f513fcd` (2026-06-14) and at the current
tip `dea6ac9`, so this predates and is unrelated to the last few merges
(Kotlin 2.3.21 pin, FromRadio handshake fix). It is **not a flake** — it
reproduces deterministically and locally on Linux (no Xcode/Mac needed — it
fails at Gradle dependency-graph resolution, before any actual
Swift/Kotlin-Native compilation):

```
./gradlew :samples:parity-app:compileKotlinIosX64 --no-daemon
```

Error: `"No matching variant of org.jetbrains.compose.runtime:runtime:1.11.1
was found"` (same for `compose.foundation`, `compose.ui`,
`compose.components.resources`) when resolving
`:samples:parity-app:iosX64CompileKlibraries`. Gradle's variant search lists
several Compose versions found in the graph — `1.11.1`, `1.9.1`, `1.9.3` —
for `ios_x64`/klib `kotlin-api`, none matching. This smells like a Compose
Multiplatform version conflict: the version catalog
(`gradle/libs.versions.toml`) pins `composeMultiplatform = "1.11.1"`, but
something in the dependency graph is pulling in conflicting older Compose
artifacts (1.9.x) for the iOS native targets specifically.

## Relevant files

- `gradle/libs.versions.toml` — `composeMultiplatform=1.11.1`, `kotlin`
  version, `composeCompiler` plugin (aliased to the Kotlin version).
- `samples/parity-app/build.gradle.kts` — the only module with iOS Compose
  targets (`iosX64`/`iosArm64`/`iosSimulatorArm64` framework + JVM desktop).
  Note it already has a workaround comment: *"The SDK modules currently emit
  metadata flagged as pre-release under AGP 9 + Kotlin 2.3.x"* and adds
  `-Xskip-prerelease-check` to all compile tasks — that's a related but
  evidently insufficient mitigation for the same AGP9/Kotlin2.3.x tooling
  generation, not this variant-resolution failure.

This only affects `samples:parity-app`'s iOS targets — `test-jvm`,
`test-android`, and `arch-consistency` all pass, so the SDK core/transports
are unaffected.

## Goal

Get `api-check` and `test-ios (iosSimulatorArm64)` green on `main`. Likely
fixes to investigate, in rough order of likelihood:

1. A Compose BOM/version mismatch — check if some other dependency (e.g. a
   transitive Compose-Multiplatform plugin default, or AGP's own Compose
   version) is injecting 1.9.x and conflicting with the 1.11.1 catalog pin;
   may need an explicit `resolutionStrategy.force` or a `constraints { }`
   block in `samples/parity-app/build.gradle.kts`, or bumping the
   AGP/Kotlin/Compose-compiler trio to mutually compatible versions.
2. Check whether the Kotlin 2.3.21 pin (PR #47,
   `build-logic/convention/src/main/kotlin/MeshtasticIosFrameworkPlugin.kt`
   or wherever Kotlin Native framework config lives) requires a corresponding
   Compose Multiplatform bump — Compose 1.11.1 may not yet have stable
   `ios_x64` klib variants for this Kotlin version on Gradle 9.5.1, and an
   older/newer Compose release may resolve cleanly.
3. As a last resort, scope the iOS targets out of `samples:parity-app` (or
   out of CI) until a clean Compose/Kotlin/AGP combination is found — but
   prefer an actual version fix since this sample's whole point is
   demonstrating the iOS framework.

Verify with:

```
./gradlew :samples:parity-app:compileKotlinIosX64 \
  :samples:parity-app:compileKotlinIosArm64 \
  :samples:parity-app:compileKotlinIosSimulatorArm64 --no-daemon
```

locally (reproduces on Linux), then push and confirm `api-check` +
`test-ios` go green in CI on the PR.

## Workflow

Branch off latest `main`, DCO-signed commits (`git commit -s`), focused PR,
do not force-push or rewrite published history.
