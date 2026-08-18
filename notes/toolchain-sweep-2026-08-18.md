# Toolchain sweep — Kotlin / KMP / Compose / Android (2026-08-18)

Sweep of official Kotlin, KMP, Compose Multiplatform, androidx-Compose, AGP and
Gradle sources against what the six Gradle repos in this workspace actually pin.
Verified against upstream on 2026-08-18. Structure: (1) dated/breaking,
(2) version gaps not already covered by an open PR, (3) adoptable in versions we
already pin, (4) verified-correct (no action).

## Baseline as pinned

| Repo | Kotlin | AGP | Gradle wrapper | CMP | detekt | spotless |
| --- | --- | --- | --- | --- | --- | --- |
| `android` | 2.4.10 | 9.3.1 | 9.6.1 | 1.12.0-rc01 (m3 1.12.0-alpha03) | 2.0.0-alpha.6 (`dev.detekt`) | 8.10.0 |
| `meshtastic-sdk` | 2.4.10 | 9.3.1 | 9.6.1 | 1.11.1 | 2.0.0-alpha.5 (`dev.detekt`) | 8.8.0 |
| `MQTTastic-Client-KMP` | 2.4.10 | 9.3.1 | 9.7.0 | 1.11.1 | 1.23.8 (`io.gitlab.arturbosch`) | 8.10.0 |
| `kzstd` | 2.4.10 | — | 9.7.0 | — | 1.23.8 (`io.gitlab.arturbosch`) | 8.10.0 |
| `TAKPacket-SDK` (`kotlin/`) | 2.4.10 | — | 9.6.1 | — | 1.23.8 (`io.gitlab.arturbosch`) | 8.9.0 |
| `gradle-flatpak-sources` | — | — | 9.7.0 | — | 1.23.8 (`io.gitlab.arturbosch`) | — |

`android`: MIN_SDK 26, TARGET_SDK 37, COMPILE_SDK 37, versionName base 2.8.1.

Upstream latest as of today: Kotlin **2.4.10** (2026-07-14; 2.4.20 planned Sept
2026, 2.5.0 Dec 2026) · Gradle **9.7.0** (2026-08-06) · AGP **9.3.1** stable
(9.4.0 in preview) · CMP **1.11.1** stable / **1.12.0-rc01** latest · androidx
Compose **1.12** stable, BOM `2026.08.00`, **1.13.0-alpha01** already out
(2026-08-12) · SKIE **0.10.14** · detekt
**2.0.0-alpha.6** (2026-08-04) / **1.23.8** (2025-02-21) · kotlinx-datetime
**0.8.0** stable.

## 1. Dated / breaking

- **Google Play target-API deadline 2026-08-31 (13 days out): satisfied.** New
  apps and updates must target API 36+; `android` is on 37. Existing-app floor
  is 35. No action, no extension needed.
- **Android 17 (API 37) local-network protection: PARTLY handled — a real gap.** targetSdk
  37 blocks local-network access by default — this would have broken TCP/IP
  radio connections, NSD/mDNS discovery on the Connections screen, and the
  built-in TAK server's loopback bind. `androidApp/src/main/AndroidManifest.xml`
  declares `ACCESS_LOCAL_NETWORK` with a comment citing the platform doc, and
  it is runtime-requested via `rememberLocalNetworkPermissionState`
  (`core/ui/.../PlatformUtils.kt`), with a denial path covered by
  `TAKConfigPermissionDeniedTest`.
  **Traced 2026-08-18 — the gap is real. See
  [`local-network-permission-gap.md`](./local-network-permission-gap.md).**
  Discovery is covered; *connecting* is not. `ConnectionsScreen` only ever
  requests the permission from the network-scan toggle, so the manual-IP path,
  the recent-address path and the service's startup reconnect all reach a
  socket without it. Per Google's own doc a blocked TCP connect "will typically
  result in a timeout error" — no fast failure, no diagnostic, just a hang. And
  the legacy implicit grant is keyed on **targetSdk, not install history**, so
  shipping targetSdk 37 breaks existing TCP users on app update.
- **`usesCleartextTraffic` deprecated at targetSdk 37: already handled.** The
  app ships `network_security_config.xml` with `cleartextTrafficPermitted=false`
  in `base-config` and a `domain-config` exception for `127.0.0.1`/`localhost`
  only. That is exactly the shape API 37 requires.
- **Android 17 resizability/orientation opt-out removed on large screens
  (sw > 600dp): no exposure.** No `resizeableActivity` or `screenOrientation`
  opt-out appears in any manifest, so there is nothing to unwind.
- **Safer Dynamic Code Loading extended to native libraries at targetSdk 37: no
  exposure.** No `jniLibs`, `externalNativeBuild` or `ndkVersion` anywhere in
  `android`; `kzstd` is pure Kotlin across all 13 targets (zstd-jni is a
  test-only oracle, not a runtime dep). The 16 KB page-size requirement is
  likewise moot for the same reason.
- **Kotlin 2.4 raised Apple minimums: iOS/tvOS 15.0, macOS 12.0, watchOS 8.0.**
  No repo sets an explicit deployment target, so all three KMP libs inherit the
  new floor silently on their next Apple build. Confirm `apple` and any
  published podspec/SPM consumer expect ≥ iOS 15 before the next SDK release.
- **KGP 2.4.x fully-supports Gradle 7.6.3–9.5.0 and AGP 8.5.2–9.1.0.** Every
  Kotlin repo here runs *past* both ceilings (Gradle 9.6.1/9.7.0, AGP 9.3.1).
  Upstream's wording is "may encounter deprecation warnings or some new features
  might not work" — not a hard break, and detekt 2.0.0-alpha.6 is itself built
  against Kotlin 2.4.10 + Gradle 9.6.1 + AGP 9.3.1, so the combination is
  exercised in the wild. Treat as known-unsupported-but-working; Kotlin 2.4.20
  (Sept) should extend the range.

## 2. Version gaps not already covered by an open PR

Filtered against the open-PR lists from today's briefs — `meshtastic-sdk` #102
(Gradle 9.7.0), #101 (spotless 8.10.0), #99 (detekt-compose 0.6.4), #103/#100
(Actions) are queued, not gaps.

- **detekt is mid-migration and four repos are stranded on 1.23.8.**
  `MQTTastic-Client-KMP`, `kzstd`, `TAKPacket-SDK` and
  `gradle-flatpak-sources` still use `io.gitlab.arturbosch.detekt` 1.23.8 —
  released 2025-02-21 and **built against Kotlin 2.0.21** — while compiling
  Kotlin 2.4.10. `android` and `meshtastic-sdk` have already moved to the new
  `dev.detekt` plugin ID at 2.0.0-alpha.x. The old line will not parse Kotlin
  2.4 syntax (context parameters, collection literals) if it ever appears in
  those sources. detekt 2.0 breaking changes to plan for: ruleset renames
  (`documentation`→`comments`, `empty`→`emptyblocks`, `bugs`→`potentialbugs`),
  `UnnecessaryAnnotationUseSiteTarget` removed, `RuleSet.Id`→`RuleSetId`,
  `Detektion` now immutable. Note 2.0 is still alpha — this is a "decide
  deliberately" item, not an automatic bump.
- **Gradle wrapper skew: 9.6.1 vs 9.7.0 — and `android`'s is deliberate.**
  `android`, `meshtastic-sdk` and `TAKPacket-SDK` are on 9.6.1; the other three
  are on 9.7.0. `meshtastic-sdk` #102 covers the SDK. **Correction (traced
  2026-08-18):** `android` is not drifting — its `gradle-wrapper.properties`
  comments record a revert, because Gradle 9.7.0's `ExecOperations.exec` spec
  defaults `standardOutput` to null and CMP's `proguardReleaseJars` reads it
  back. Only `TAKPacket-SDK` is a real gap.
- **spotless skew: `meshtastic-sdk` 8.8.0, `TAKPacket-SDK` 8.9.0** vs 8.10.0
  elsewhere. SDK is covered by #101; TAK is not.
- **CMP skew across the ABI boundary.** `android` is on `1.12.0-rc01`;
  `meshtastic-sdk` and `MQTTastic-Client-KMP` are on `1.11.1` stable. Since
  `android` consumes the SDK, this is worth a deliberate decision rather than
  drift — either hold `android` at stable until 1.12.0 ships, or move the SDK
  up together with it. CMP 1.12.0 is still RC (rc01, 2026-08-11).
- **`kotlinx-datetime = "0.8.0-0.6.x-compat"` shim in `android` and
  `meshtastic-sdk`.** 0.8.0 stable shipped 2026-05-07; the compat artifact
  exists only to keep binary compatibility across the
  `Instant`/`Clock` → `kotlin.time` move. `TAKPacket-SDK` already runs on
  stdlib `kotlin.time` with no kotlinx-datetime dependency at all — in-repo
  precedent that dropping the shim is viable.
- **`meshtastic-sdk` catalog has a stale `gradle = "9.5.1"` entry** that no
  build script references (wrapper is 9.6.1). Dead entry; delete or wire it.
- **Stale catalog comments in `meshtastic-sdk`.** The `kable` line still
  explains a ceiling in terms of "our 2.3.21 pin (SKIE 0.10.12 ceiling)"; the
  repo is now on Kotlin 2.4.10 / SKIE 0.10.14. Misleading to the next reader.
- **`kzstd` and `TAKPacket-SDK` still use kotlinx-binary-compatibility-validator
  0.18.1.** `meshtastic-sdk` has already moved to KGP's built-in ABI validation
  (`abiValidation { }` on the Kotlin extension, `checkKotlinAbi` /
  `updateKotlinAbi`), which its own `PublishingConventionPlugin` documents as
  "the JetBrains-supported successor". Aligning the other two libs on the
  built-in removes a third-party plugin from two builds.

## 3. Adoptable in versions we already pin

- **SKIE 0.10.14 is the Kotlin ceiling, and it is where we are.** 0.10.14 adds
  Kotlin 2.4.10 support plus "Fix Gradle Configuration Cache and isolated
  projects" — relevant because `meshtastic-sdk` runs `configuration-cache` +
  `configuration-cache.parallel` but does *not* yet enable
  `org.gradle.isolated-projects`. The blocker SKIE cited is fixed. Note the
  ordering constraint for Sept: **Kotlin 2.4.20 cannot land in `meshtastic-sdk`
  until a SKIE release supports it.**
- **Swift export reached Alpha in Kotlin 2.4, with structured concurrency and
  Swift-package-import support.** Strategically it is the eventual replacement
  for the Obj-C bridge SKIE enhances, and the two are mutually exclusive — an
  all-or-nothing choice. Touchlab's own position is that SKIE remains the
  production answer for now. Worth an ADR in `meshtastic-sdk` recording the
  decision to stay on SKIE and what would trigger revisiting, not a migration.
- **Isolated Projects graduated experimental → incubating in Gradle 9.7.0.**
  `android` already runs `org.gradle.isolated-projects=true` plus
  `ksp.project.isolation.enabled=true`. `meshtastic-sdk`,
  `MQTTastic-Client-KMP`, `kzstd` and `gradle-flatpak-sources` do not — and
  `MQTTastic`/`kzstd`/`gradle-flatpak-sources` are already on 9.7.0, so the
  feature is available to them today. `kzstd` and `gradle-flatpak-sources`
  don't even set `configuration-cache`. Cheapest configuration-time win
  available in this sweep. (Also: the legacy
  `org.gradle.unsafe.isolated-projects` name is now deprecated — we don't use
  it anywhere, so nothing to rename.)
- **AGP 9.3 R8 tooling is unadopted in `android`.** New:
  `./gradlew :app:analyzeReleaseR8Config` (standalone R8 config analyzer, no
  full compile), an updated optimization DSL, and keep rules as source sets at
  `src/<variant>/keepRules/*.keep`. `android` still carries four hand-maintained
  `.pro` files (`androidApp`, `desktopApp`, `feature/car`,
  `config/proguard/shared-rules.pro`) and there is an `r8-analyzer` skill in the
  workspace built for exactly this problem. Highest-leverage feature adoption
  here.
- **Compose 1.12 / BOM 2026.08.00 APIs not yet used in `android`** (it is on
  CMP 1.12.0-rc01, so these are already on the classpath): wide colour gamut
  (P3) and HDR rendering end-to-end, mesh gradients, `LayerOutsets` on
  `GraphicsLayer`/`Modifier.graphicsLayer` to escape implicit `clipToBounds`,
  **named areas in `Grid`** (the new component is not used at all — every
  `*Grid(` hit in the app is a custom composable: `EmojiGrid`, `MetricsGrid`,
  `StatsGrid`, `createLatLongGrid`), `SoundEffectOnInteraction` plus click/focus
  interaction sounds, `KeyboardType.Date`/`Time`/`DateTime`/`SignedDecimal`, and
  Credential Manager integration. Also a free perf note: `SideEffect` is ~90%
  faster than `LaunchedEffect` and ~20% faster than `DisposableEffect`.
- **CMP 1.12.0 ships an MCP server for Compose Hot Reload**, letting an agent
  drive a running app. `android` already has `compose.hot.reload=true` and this
  workspace is agent-driven — plausibly the highest-value item in the whole
  sweep for how work actually gets done here. Not wired up.
- **Google publishes ~20 official Android Skills, and they cover exactly what
  we use.** `github.com/android/skills` targets "highly specific, fast-moving
  areas that standard models aren't fully grounded on yet — things like AGP 9,
  Navigation 3, advanced Camera APIs, and Perfetto SQL". `android` runs AGP
  9.3.1, navigation3 1.1.1 and camerax 1.6.1, so three of the four named areas
  apply directly. There is also an official AppFunctions agent skill that
  generates the Kotlin scaffolding, optimises KDoc for agent consumption and
  emits ADB test commands. The stated philosophy is "built for deprecation" —
  skills are temporary scaffolding retired as models absorb them — so adopt
  them as disposable, not as durable config. Google's own recommendation is to
  prefer the **Android Knowledge Base** (Android Studio, or the `android` CLI
  `docs` command) over installing many individual skills; note this workspace
  already has an `android-cli` skill and `android_docs_search` /
  `android_docs_fetch` MCP tools pointed at that surface. Caveat: the "built for
  deprecation" post is about agent skills, *not* about AppFunctions being
  superseded — our `appfunctions = "1.0.0-alpha10"` pin is the current release,
  and AppFunctions' Gemini integration is still private-preview.
- **Kotlin 2.4 stdlib/language, now stable and unused:** context parameters,
  explicit backing fields, the `@all` annotation meta-target, the stable UUID
  API, and `isSorted()`/`isSortedBy()`/`isSortedWith()` family. Experimental but
  interesting for the codec/parser libs: collection literals, improved
  compile-time constants, `@IntroducedAt` for version-based overload
  generation, and stricter unused-result checks via `returnsResultOf()`.
- **Kotlin 2.4 Native/Wasm wins that come for free on rebuild:** CMS GC on by
  default, 50% lower devirtualization memory, LLVM 21, Xcode 26.4 support; Wasm
  incremental compilation now stable (`kzstd` ships `wasmJs` + `wasmWasi`).

## 4. Verified correct — no action

- **`android`'s split `compose-multiplatform-material3 = "1.12.0-alpha03"` vs
  CMP `1.12.0-rc01` is required, not a leftover.** CMP's changelog confirms
  Material3 runs an independent cadence: CMP's `1.12.0-alpha03` corresponds to
  androidx `1.5.0-alpha22`. Leave the split alone.
- **No use of the Compose compiler feature flags Kotlin 2.4 promoted to
  ERROR-level deprecation** (`StrongSkipping`, `IntrinsicRemember`) in any repo.
- **`androidx-compose-bom-aligned = "1.12.0"`** matches androidx Compose 1.12 /
  BOM 2026.08.00, and Compose 1.12's own requirements (compileSdk 37, AGP
  ≥ 9.1.1) are met by compileSdk 37 / AGP 9.3.1.
- **K1 is gone in Kotlin 2.4** (`-language-version=1.9` removed); no repo pins a
  language version.

## 5. Upcoming — worth preparing for, nothing to do yet

From the KotlinConf'26 keynote and the release calendars:

- **Kotlin 2.4.20 (Sept 2026, tooling release), 2.5.0 (Dec 2026, language).**
  2.4.20 is the likely fix for the KGP-vs-Gradle/AGP ceiling above. Remember the
  SKIE ordering constraint for `meshtastic-sdk`.
- **androidx Compose 1.13.0-alpha01** shipped 2026-08-12 (Material3
  1.5.0-alpha26) — the next train has already left, so CMP 1.13 will follow.
- **Language previews:** multi-field value classes (compiler-generated equality,
  safer destructuring), "locality as a first-class language concept", and rich
  errors for recoverable failures.
- **Kotlin stdlib gains an 18-month security support policy starting 2.4**, with
  backported fixes across active release lines. Relevant to how long we can
  responsibly sit on a pin.
- **Kotlin Toolchain** — unified build/run/test entry point for JVM and
  multiplatform, with LSP integration, AI skills and native dependency
  provisioning planned. **Kotlin Language Server reached Alpha** with official
  VS Code support. Both are worth watching given this workspace's Nix-pinned
  toolchain approach.
- **Kotlin Documentation Model** — machine-readable `kdoc.jar` for IDE and agent
  consumption. Directly relevant to five published libraries here that already
  run Dokka 2.2.0.
- **ktfmt standardisation** via Kotlin Foundation + Meta. We currently format
  with spotless + ktlint 1.8.0; a standard may eventually redirect that choice.
- **CMP web reached Beta; Navigation 3 is stable multiplatform.** `android`
  already pins navigation3 1.1.1.
- **Kotlin/Native: builds ~25% faster on under half the RAM** versus a year ago
  — free on toolchain bumps.
- **AGP 9.4.0 is in preview.**

## Scope boundary

This sweep covered the **toolchain and platform** layer: Kotlin, KGP, Gradle,
AGP, Compose Multiplatform, androidx-Compose, SKIE, detekt, spotless, Dokka,
kotlinx-datetime, and Android/Play platform requirements. It did **not**
version-audit `android`'s individual androidx library pins — room3 3.0.1,
navigation3 1.1.1, lifecycle 2.11.0, work 2.11.2, glance 1.2.0-rc01, camerax
1.6.1, paging 3.5.1, datastore 1.2.1, appcompat 1.8.0, benchmark 1.5.0-rc01 —
nor the non-Android library pins (ktor 3.5.2, okio 3.18.1, kable 0.44.3,
atomicfu 0.33.0, coroutines 1.11.0, serialization 1.11.0). Renovate owns those
and the `dep-full-sweep` skill exists for a catalog-wide pass.

## Sources

- Kotlin releases — <https://kotlinlang.org/docs/releases.html>
- What's new in Kotlin 2.4.0 — <https://kotlinlang.org/docs/whatsnew24.html>
- KGP ↔ Gradle/AGP compatibility table —
  <https://kotlinlang.org/docs/gradle-configure-project.html>
- KotlinConf'26 keynote highlights —
  <https://blog.jetbrains.com/kotlin/2026/05/kotlinconf26-keynote-highlights/>
- JetBrains Kotlin blog — <https://blog.jetbrains.com/kotlin/>
- SKIE releases — <https://github.com/touchlab/SKIE/releases> · 0.10.14
  changelog — <https://skie.touchlab.co/changelog/0.10.14>
- Swift export — <https://kotlinlang.org/docs/native-swift-export.html> ·
  Touchlab, "The Future of KMP's iOS Interop" —
  <https://touchlab.co/the-future-of-kmps-ios-interop>
- Compose Multiplatform releases —
  <https://github.com/JetBrains/compose-multiplatform/releases> · CHANGELOG —
  <https://raw.githubusercontent.com/JetBrains/compose-multiplatform/master/CHANGELOG.md>
- androidx Compose releases —
  <https://developer.android.com/jetpack/androidx/releases/compose>
- What's new in the Jetpack Compose August '26 release —
  <https://android-developers.googleblog.com/2026/08/jetpack-compose-august-2026-release.html>
- Android Gradle Plugin release notes —
  <https://developer.android.com/build/releases/gradle-plugin>
- Android 17 behaviour changes, all apps —
  <https://developer.android.com/about/versions/17/behavior-changes-all> ·
  apps targeting Android 17 —
  <https://developer.android.com/about/versions/17/behavior-changes-17>
- Local network permission —
  <https://developer.android.com/privacy-and-security/local-network-permission>
- Play target-API requirement —
  <https://developer.android.com/google/play/requirements/target-sdk>
- Inside Android Skills — Built for deprecation —
  <https://android-developers.googleblog.com/2026/08/android-skills-philosophy.html>
  · catalog — <https://github.com/android/skills> · browse —
  <https://developer.android.com/tools/agents/android-skills/browse>
- AppFunctions overview — <https://developer.android.com/ai/appfunctions> ·
  releases — <https://developer.android.com/jetpack/androidx/releases/appfunctions>
- Gradle 9.7.0 release notes — <https://docs.gradle.org/9.7.0/release-notes.html>
  · all releases — <https://gradle.org/releases/>
- detekt releases — <https://github.com/detekt/detekt/releases>
- kotlinx-datetime releases —
  <https://github.com/Kotlin/kotlinx-datetime/releases>
