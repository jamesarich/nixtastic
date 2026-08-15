# Audit: meshtastic/meshtastic-sdk (REFERENCE repo)

Local path: `/Users/james/meshtastic/meshtastic-sdk`
GitHub: https://github.com/meshtastic/meshtastic-sdk
Audited: 2026-07-21. HEAD = `d0acda2` on `main`. Tags: `v0.1.0`, `v0.1.0-rc1`.
Method: read-only file inspection + `gh`/`gh api` + WebFetch against `central.sonatype.com` / `search.maven.org` (repo1.maven.org itself 403'd the fetch tool — see Publishing section). No Gradle builds executed.

---

## SCORECARD

| # | Criterion | Status | Evidence (path / value) |
|---|-----------|--------|-------------------------|
| **BUILD LOGIC** |
| 1 | Gradle wrapper version | ✅ Present | `9.6.1` — `gradle/wrapper/gradle-wrapper.properties:4` (`distributionUrl=...gradle-9.6.1-all.zip`) |
| 2 | Kotlin version | ✅ Present | `2.4.0` — `gradle/libs.versions.toml:5`, capped by comment: "SKIE 0.10.13 ceiling — it rejects 2.4.10 outright" |
| 3 | AGP version | ✅ Present | `9.3.0` — `gradle/libs.versions.toml:6`; Android target is used (all library modules apply `com.android.kotlin.multiplatform.library`) |
| 4 | Version catalog | ✅ Present | `gradle/libs.versions.toml` (127 lines; versions/libraries/plugins sections) |
| 5 | Convention plugins via `build-logic` composite | ✅ Present | `settings.gradle.kts:4` `includeBuild("build-logic")`; 6 plugins registered in `build-logic/convention/build.gradle.kts:31-58` |
| 6 | KMP targets declared | 🟡 Partial (narrow but deliberate) | `jvm()`, `iosArm64()`, `iosX64()`, `iosSimulatorArm64()` — `build-logic/convention/src/main/kotlin/KmpLibraryConventionPlugin.kt:78-81`; `androidTarget` via `com.android.kotlin.multiplatform.library` — `AndroidLibraryConventionPlugin.kt:20`. **No** macOS/linux/mingw/js/wasmJs/tvos/watchos. Explicitly a documented, deliberate scope (`docs/ci-cd.md:167-171`), not an oversight. |
| 7 | Hierarchical source sets / `applyDefaultHierarchyTemplate` | ✅ Present | `KmpLibraryConventionPlugin.kt:83`; `transport-serial/build.gradle.kts:24-31` adds a custom `jvmAndroid` group on top of the default template |
| 8 | `explicitApi()` strict mode | ✅ Present | `KmpLibraryConventionPlugin.kt:76` |
| 9 | JVM toolchain pinned | ✅ Present | `jvmToolchain(21)` — `KmpLibraryConventionPlugin.kt:74`, driven by `javaVersion = "21"` catalog entry |
| 10 | Gradle configuration cache / caching in gradle.properties | ✅ Present | `gradle.properties:2-6`: `org.gradle.caching=true`, `org.gradle.parallel=true`, `org.gradle.configuration-cache=true`, `.configuration-cache.parallel=true` |
| **PUBLISHING** |
| 11 | Publishing mechanism | ✅ Present | `com.vanniktech.maven.publish` v0.37.0 — `PublishingConventionPlugin.kt:19`, version in `gradle/libs.versions.toml:51` |
| 12 | Central Portal vs legacy OSSRH | ✅ Present | Central Portal — `publishToMavenCentral(automaticRelease = false)` (`PublishingConventionPlugin.kt:40`); explicitly confirmed "no OSSRH staging dance" in `docs/versioning.md:3` |
| 13 | GPG signing configured | ✅ Present | Conditional `signAllPublications()` when `signingInMemoryKey` gradle property present — `PublishingConventionPlugin.kt:41-42`; wired via `SIGNING_IN_MEMORY_KEY`/`_PASSWORD` secrets in `.github/workflows/release.yml:161-162` and `ci.yml:219-220` |
| 14 | BOM module published | ✅ Present | `bom/build.gradle.kts` (`java-platform`, constrains 6 `sdk-*` artifacts to `project.version`); **confirmed live on Maven Central** as `org.meshtastic:sdk-bom:0.1.0` (POM-only, constrains the same 6 modules) |
| 15 | POM metadata complete | ✅ Present | name/description/url/licenses/scm/developers all set — `PublishingConventionPlugin.kt:51-75`. Minor: license block has no `distribution` tag; `developers` is one generic org identity, not per-contributor (acceptable for an org project) |
| 16 | Sources jar + Dokka/javadoc jar attached | 🟡 Likely Present (not independently verified) | No explicit `configure(KotlinMultiplatform(...))` call in `PublishingConventionPlugin.kt` — relies on vanniktech's auto-detection of the applied `org.jetbrains.kotlin.multiplatform` plugin (documented plugin default behavior in recent versions). Could not confirm the actual jar/classifier listing: `repo1.maven.org` directory browsing 403'd the fetch tool, and `central.sonatype.com`'s artifact page didn't expose a file listing to the fetch tool either. |
| 17 | Group/artifact coordinates | ✅ Present | `groupId = "org.meshtastic"`, `artifactId = "sdk-${project.name}"` — `PublishingConventionPlugin.kt:46-49` (e.g. `org.meshtastic:sdk-core`) |
| 18 | Version single-source-of-truth | ✅ Present | `axion-release-plugin` reads git tags (`vMAJOR.MINOR.PATCH`) → `resolvedVersion` → `allprojects { version = resolvedVersion }` — `build.gradle.kts:25-44` |
| **API & COMPAT** |
| 19 | Binary Compatibility Validator | ✅ Present (modernized) | **Not** the classic `kotlinx-binary-compatibility-validator` plugin — uses Kotlin 2.4's **built-in** ABI validation (`abiValidation {}` DSL) — `PublishingConventionPlugin.kt:21-37`. Dumps committed for all 6 published modules: `<module>/api/jvm/<module>.api` (JVM) + `<module>/api/<module>.klib.api` (klib/native), e.g. `core/api/jvm/core.api` (2103 lines), `core/api/core.klib.api` (2081 lines). Last touched `bfa28ab` (2026-07-17), i.e. current. `**.internal.**` packages excluded from the surface (`PublishingConventionPlugin.kt:34-36`). |
| **TESTING & COVERAGE** |
| 20 | Test framework(s) | ✅ Present | `kotlin.test` (primary, all modules) + `kotest-assertions-core` (assertions only) + Turbine (Flow testing) + JUnit4/AndroidX Test (only for `androidDeviceTest` instrumented tests) — `KmpLibraryConventionPlugin.kt:91-96`, `transport-ble/build.gradle.kts:33-41` |
| 21 | `commonTest` + per-target test source sets | ✅ Present | `commonTest` in every library module; plus `jvmTest` (core, storage-sqldelight), `jvmAndroidTest` (transport-serial, custom group), `androidDeviceTest` (transport-ble, real-hardware) |
| 22 | Rough test count | ✅ Present | 80 files matching `*Test*` (79 true test files + 1 test-fixture `TestClock.kt`); **650** `@Test`-annotated functions (grep count). Heavily concentrated in `:core` (~65 files) |
| 23 | Coverage tool | ✅ Present (measurement only) | Kover (`org.jetbrains.kotlinx.kover` v0.9.9) applied to the 6 library modules and aggregated at root — `build.gradle.kts:16,106-135` |
| 24 | Coverage uploaded to Codecov/other in CI | ❌ Absent | No coverage step/upload-action in any of the 8 workflow files; no `codecov.yml` anywhere in the repo |
| 25 | Coverage threshold/verification enforced | ❌ Absent | No `koverReport { verify { rule { ... } } }` block found anywhere (repo-wide grep). Kover measures but nothing consumes the number — no CI-visible artifact, no gate |
| **CODE QUALITY TOOLING** |
| 26 | Formatter/linter + config | ✅ Present | Spotless (ktlint 1.8.0 engine) for `**/*.kt`, `**/*.gradle.kts`, misc — `build.gradle.kts:61-104`; detekt v2.0.0-alpha.5 applied to all subprojects — `build.gradle.kts:106-124`, config at `config/detekt/detekt.yml`; Compose-aware rules via `io.nlopez.compose.rules:detekt` |
| 27 | `.editorconfig` present | ✅ Present | `.editorconfig` (40 lines; ktlint-aware Kotlin section, yml/json/toml, Makefile, shell) |
| 28 | Pre-commit hooks / git hooks | 🟡 Partial | `.githooks/pre-commit` exists but is **opt-in** (`git config core.hooksPath .githooks`, not auto-installed by any Gradle task) and only runs `.github/tooling/check.sh` (shellcheck/markdownlint/actionlint/ajv/jq/yq against `.github/**`) — it does **not** run Spotless/detekt/tests on Kotlin source |
| **CI/CD (GitHub Actions)** |
| 29 | PR build+test workflow | ✅ Present | `.github/workflows/ci.yml` — 6 parallel jobs, `pull_request`+`push` to `main` |
| 30 | Multiplatform CI matrix incl. macOS runner | ✅ Present | `ci.yml` `test-ios` job and `release.yml` `publish` job both `runs-on: macos-latest` |
| 31 | Gradle caching in CI | ✅ Present (multi-layer) | Official `gradle/actions/setup-gradle@v6.2.0` via `.github/actions/gradle-setup/action.yml:30`, **plus** a custom remote HTTP build cache (`gradle/build-cache.settings.gradle`, push gated on secrets so fork PRs are pull-only), **plus** `actions/cache@v6.1.0` for the Konan/Kotlin-Native toolchain (`ci.yml:101-107`, `release.yml:77-83`) |
| 32 | Lint/format check step in CI | ✅ Present | `test-jvm` job: `./gradlew spotlessCheck detekt` (`ci.yml:52-53`); `arch-consistency` job also runs detekt (`ci.yml:157`) |
| 33 | API-compat check step in CI | ✅ Present | Dedicated `api-check` job: `./gradlew checkKotlinAbi` (`ci.yml:131-143`) |
| 34 | Coverage step in CI | ❌ Absent | (see #24) |
| 35 | Publish/release workflow | ✅ Present | `.github/workflows/release.yml` — tag-push (`v[0-9]+.[0-9]+.[0-9]+`, stable only) + `workflow_dispatch` (manual/RC/dry-run), publishes via `publishAndReleaseToMavenCentral` |
| 36 | Release automation | 🟡 Partial | Version derivation is automated (axion-release from git tags); GH release notes for `v0.1.0` are GitHub's auto-generated "What's Changed"/"New Contributors" format; **but** `CHANGELOG.md` is manually promoted per a documented manual checklist step (`RELEASING.md:38-40`) — no semantic-release/release-please style automation |
| 37 | Workflow hardening | 🟡 Partial | `concurrency:` + `permissions:` blocks present on 6 of 7 workflows, and **every** `uses:` action reference repo-wide is pinned to a full 40-hex SHA with a version comment (self-enforced by `.github/tooling/check.sh:60-70`). **Gap:** `.github/workflows/tooling-check.yml` has **no** `concurrency:` block and **no** `permissions:` block at all — the one exception in the repo |
| 38 | Dependency automation | ✅ Present | Renovate — `renovate.json` (grouped by ecosystem, Kotlin held ≤2.4.0 for the SKIE ceiling, vulnerability alerts on); dozens of merged Renovate PRs in `git log` |
| **DOCUMENTATION** |
| 39 | README badges | 🟡 Partial | License, Maven Central (dynamic shields.io), CI status, API Docs badges present (`README.md:7-10`); **no coverage badge** (consistent with #24) |
| 40 | README install snippet + quick-start | ✅ Present (but stale claim inside it) | `README.md:28-232` — install snippet, snapshot-repo instructions, full quick-start with connect/send/observe examples, transport picker, troubleshooting table. **Contains a stale warning** — see Gaps |
| 41 | README platform-support table | ✅ Present | `README.md:221-232` — per-module × per-target matrix with footnotes |
| 42 | API docs site (Dokka) published | ✅ Present | `.github/workflows/docs.yml` builds `:dokkaGenerate` and deploys to GitHub Pages on push to `main`; URL `https://meshtastic.github.io/meshtastic-sdk/` referenced consistently |
| 43 | KDoc coverage on public API | ✅ Present, high (~90%+ estimate) | 56 of 58 files in `core/src/commonMain` contain `/**` doc comments; **0** files found with public declarations and zero KDoc (repo-wide heuristic scan). Manual spot-check of `RadioClient.kt:37-79` and `AdminApi.kt:28-63` shows thorough per-member KDoc with usage examples, cross-refs (`[Type]` links), and `@since` tags |
| 44 | CHANGELOG present + maintained | ✅ Present | `CHANGELOG.md` (16KB), Keep a Changelog format, `[Unreleased]` + `[0.1.0] — 2026-07-16` sections; the 0.1.0 entry is extensive (Breaking/Added/Fixed with hardware-found annotations) |
| 45 | Samples / examples module | ✅ Present, strong | `samples/cli` (JVM TUI, all 3 transports), `samples/parity-app` (Compose Multiplatform: Android+iOS+JVM-desktop over TCP), `samples/parity-android-app` (standalone Android shell) — documented in `docs/samples.md` |
| 46 | Module-level docs (`Module.md`) | ✅ Present | `Module.md` in all 6 Kotlin modules (core, transport-ble, transport-tcp, transport-serial, storage-sqldelight, testing), wired into Dokka via `includes.from("Module.md")` (`KmpLibraryConventionPlugin.kt:32`). `:bom` correctly has none (no Kotlin sources) |
| **ORG ALIGNMENT** |
| 47 | LICENSE | 🟡 Partial (internal inconsistency) | GNU GPLv3 full text at `LICENSE`. **ADR-004** (`docs/decisions/004-licensing.md:25`) and **214** source files' SPDX headers all declare **GPL-3.0-or-later**; but `README.md:7` (badge) and `README.md:293` (License section) both say **GPL-3.0-only**. GitHub's own `licenseInfo` (`gh repo view`) reports the generic `gpl-3.0` key (doesn't disambiguate) |
| 48 | CONTRIBUTING + CODE_OF_CONDUCT | ✅ Present | `CONTRIBUTING.md` (13.7KB, DCO flow, env table, build requirements), `CODE_OF_CONDUCT.md` (83 lines, adopts the org-wide Meshtastic CoC) |
| 49 | Issue + PR templates | ✅ Present | `.github/ISSUE_TEMPLATE/{bug_report,feature_request,config}.yml` (blank issues disabled, contact links to security advisory + community), `.github/PULL_REQUEST_TEMPLATE.md` |
| 50 | CODEOWNERS | 🟡 Partial | Present and detailed (`CODEOWNERS`, 51 lines) but references **paths that no longer exist**: `/proto/` (protobufs are now consumed as the external `org.meshtastic:protobufs` Maven artifact per ADR-015 — no in-tree `:proto` module) and `/samples/ios-app/` (actual path is `/samples/parity-app/iosApp/`). Also uses placeholder team handles, explicitly flagged as TODO in the file's own header comment (`CODEOWNERS:6-7`) |
| 51 | SECURITY.md | ✅ Present | Detailed: private-disclosure channel, 5-business-day ack / 90-day fix SLA, explicit in/out-of-scope list |
| 52 | Default branch | ✅ Present | `main` (`gh repo view` `defaultBranchRef.name`; local `git branch --show-current`) |
| 53 | Repo description / topics / homepage | 🟡 Partial | Description: detailed, present. Topics: 16 relevant tags (android, bluetooth-low-energy, coroutines, ios, jvm, kmp, kotlin, kotlin-multiplatform, lora, mesh-networking, meshtastic, multiplatform, off-grid, protobuf, radio, sdk). **`homepageUrl` is empty** |
| 54 | Consistent group id + naming | ✅ Present | `org.meshtastic:sdk-core`, `sdk-transport-ble`, `sdk-transport-tcp`, `sdk-transport-serial`, `sdk-storage-sqldelight`, `sdk-testing`, `sdk-bom` — uniform `sdk-` prefix, all confirmed live on Maven Central at `0.1.0` |

---

## 1. Build logic

**Module list** (`settings.gradle.kts:37-53`): `:core`, `:testing`, `:transport-tcp`, `:storage-sqldelight`, `:samples:cli`, `:samples:parity-app`, `:samples:parity-android-app`, `:transport-ble`, `:transport-serial`, `:bom`. Commented-out roadmap modules (lines 55-63): `:transport-mqtt-proxy`, `:transport-rpc`, `:transport-http`, `:host-rpc-server`, `:rpc`, `:storage-okio-files`, `:samples:wasm-app`, `:samples:host-rpc-server` — explicitly deferred, not silently missing.

**Convention plugins** (`build-logic/convention/src/main/kotlin/`, registered in `build-logic/convention/build.gradle.kts:31-58`):
- `meshtastic.kmp.library` → `KmpLibraryConventionPlugin.kt` — applies Kotlin MPP + Dokka + power-assert, configures targets/toolchain/explicitApi/hierarchy/warnings-as-errors, and adds `-Xjvm-expose-boxed` for jvm/androidJvm targets only (so value classes like `NodeId`/`ChannelIndex`/`MessageId` get non-mangled boxed accessors for Java interop).
- `meshtastic.android.library` → `AndroidLibraryConventionPlugin.kt` — applies `com.android.kotlin.multiplatform.library` (the AGP-9 single-plugin KMP-Android integration, not the legacy `com.android.library`+`org.jetbrains.kotlin.android` combo), sets namespace/compileSdk/minSdk, enables `withHostTest {}`.
- `meshtastic.publishing` → `PublishingConventionPlugin.kt` — vanniktech + Kotlin's built-in ABI validation (see §3).
- `meshtastic.ios.framework` → `MeshtasticIosFrameworkPlugin.kt` — static `MeshtasticSDK.framework` per module + SKIE (Kotlin→Swift bridging for sealed classes/suspend/Flow). Extensive doc-comment explaining a deliberate naming choice to avoid a `RadioClient.RadioClient` Swift collision, and that the single-aggregator XCFramework (ADR-007) is a deferred follow-up.
- `meshtastic.sample.android` / `meshtastic.sample.jvm` → thin wrappers for the two non-KMP sample surfaces; both add `-Xskip-prerelease-check` because the SDK's own `-Xjvm-expose-boxed` flag marks library bytecode pre-release.

Every module's `build.gradle.kts` is a thin ~10-40 line file applying the shared convention IDs plus module-specific dependencies — there is essentially zero copy-pasted boilerplate across `core/`, `transport-ble/`, `transport-tcp/`, `transport-serial/`, `storage-sqldelight/`, `testing/build.gradle.kts`. No `buildSrc/` (fully migrated to the `build-logic` composite build).

**Architecture enforcement**: `core/build.gradle.kts:47-75` registers a custom `verifyModuleBoundary` task (ADR-008) that fails if `:core` declares any in-tree project dependency — walked in CI via the `arch-consistency` job. `:core` depends only on the external `org.meshtastic:protobufs` artifact (`core/build.gradle.kts:24`), not an in-tree `:proto` module (see ADR-015, §7 below).

**Hierarchy**: default template everywhere (`commonMain → nativeMain → appleMain → iosMain → {iosArm64,iosX64,iosSimulatorArm64}Main`, plus `jvmMain`/`androidMain`); `transport-serial/build.gradle.kts:24-31` layers on an extra `jvmAndroid` group since jSerialComm code is shared between JVM and Android but has no iOS equivalent.

**gradle.properties** (`/gradle.properties`): `org.gradle.jvmargs=-Xmx4g ...`, caching+parallel+config-cache all on, `org.gradle.configureondemand=false` (explicitly disabled — commented as incompatible with isolated projects/config-cache hygiene), `android.useAndroidX=true`, `android.nonTransitiveRClass=true`.

**Minor catalog oddity**: `gradle/libs.versions.toml:7` declares a `gradle = "9.5.1"` version entry, but no `build.gradle.kts`/`.kts` file in the repo references `libs.versions.gradle` (repo-wide grep found zero usages) — the actual wrapper is pinned independently to `9.6.1` (`gradle/wrapper/gradle-wrapper.properties:4`). Looks like a dead/unused catalog entry, and it doesn't match the real wrapper version if anyone did start consuming it. Low severity.

## 2. Publishing

Plugin: `com.vanniktech:gradle-maven-publish-plugin:0.37.0`, applied once in `PublishingConventionPlugin.kt:19` and used by every publishable module (`core`, `transport-ble`, `transport-tcp`, `transport-serial`, `storage-sqldelight`, `testing`, `bom` — all apply `id("meshtastic.publishing")`).

- **Target**: `publishToMavenCentral(automaticRelease = false)` — Sonatype Central Portal, not legacy OSSRH (`PublishingConventionPlugin.kt:40`).
- **Signing**: `signAllPublications()` gated on presence of the `signingInMemoryKey` Gradle property (`:41-42`); credentials/keys flow through env vars `ORG_GRADLE_PROJECT_mavenCentralUsername/Password` and `ORG_GRADLE_PROJECT_signingInMemoryKey(Password)` set from repo secrets in both `ci.yml:217-220` (snapshot job) and `release.yml:159-162` (release job).
- **Two distinct publish paths, correctly separated**:
  - `ci.yml` `publish-snapshot` job (push to `main` only, needs all test/check jobs green) runs `./gradlew -Prelease.forceSnapshot publishAllPublicationsToMavenCentralRepository --no-configuration-cache` — upload-only, skips silently (`::warning::`) if `MAVEN_CENTRAL_USERNAME` isn't set (`ci.yml:202-225`).
  - `release.yml` `publish` job (tag push or manual dispatch) runs `./gradlew publishAndReleaseToMavenCentral --no-configuration-cache` — the vanniktech convenience task that force-publishes+releases regardless of the `automaticRelease=false` extension default. This is a coherent, deliberate split (auto snapshot publishing never auto-releases; only the explicit, human/tag-triggered release path does), not a bug.
  - `release.yml:132-154` also probes `repo1.maven.org/.../sdk-core-$VERSION.pom` before publishing and skips if already published (idempotent re-run protection, since Sonatype rejects re-uploads of an existing component).
- **BOM**: `bom/build.gradle.kts` — `java-platform` + `meshtastic.publishing`, constrains all 6 `sdk-*` artifacts to `project.version`.
- **POM**: name/description/url/license(name+url)/scm(url+connection+developerConnection)/developers(id/name/url) all set (`PublishingConventionPlugin.kt:51-75`).
- **Snapshot handling**: documented in `README.md:45-66` — every push to `main` publishes `X.Y.Z-SNAPSHOT` to `https://central.sonatype.com/repository/maven-snapshots/`.

### Maven Central verification (live check performed)

`repo1.maven.org` directory listings and direct file fetches (`/maven2/org/meshtastic/`, `/maven2/org/meshtastic/sdk-core/maven-metadata.xml`) both returned **HTTP 403** to the WebFetch tool (looks like bot-blocking on that CDN, not evidence of absence). Fell back to `central.sonatype.com` (the Central Portal's own catalog, authoritative for what's actually been deployed) and `search.maven.org`'s Solr API:

- `central.sonatype.com/artifact/org.meshtastic/sdk-core` → **exists, version 0.1.0, published ~4 days ago** (consistent with the `v0.1.0` GitHub release timestamp of 2026-07-17T13:39:36Z, 4 days before this audit).
- `central.sonatype.com/artifact/org.meshtastic/sdk-bom` → exists, 0.1.0, POM-packaging, lists the same 6 constrained modules.
- `central.sonatype.com/artifact/org.meshtastic/sdk-transport-ble` → exists, 0.1.0.
- `search.maven.org/solrsearch/select?q=g:"org.meshtastic"` → **0 results** — the classic Maven Central search index hasn't picked up the group yet, even 4 days post-publish. This is a real (if cosmetic) discoverability gap: anyone using the traditional search.maven.org UI to look for `org.meshtastic` artifacts today finds nothing, even though they are genuinely live and resolvable via Central Portal / repo1.
- The GitHub `v0.1.0` release body itself (`gh api repos/.../releases`) states: *"Maven Central (deployment `e4d014bd`, may take a few minutes to appear in search/CDN)"* — so the team was aware publish-to-search latency could be an issue; in practice it's now been days, not minutes, for `search.maven.org` specifically.

**Repo-version vs. published-version**: repo `HEAD` is `d0acda2` (past `v0.1.0`, i.e. post-release commits already merged: Kover bump, actions/cache v6, apple-privacy-manifests fix). Latest **published** version is `0.1.0`. No `0.1.0-SNAPSHOT`or later tag has been independently confirmed published (not checked further — out of scope for a quick verification pass).

## 3. API / compat

Kotlin 2.4's **built-in klib/JVM ABI validation** is used (`abiValidation {}` DSL), explicitly chosen over the classic standalone `kotlinx-binary-compatibility-validator` plugin — commented in `PublishingConventionPlugin.kt:21-24` as "the JetBrains-supported successor." Confirmed current dumps for all 6 published modules:

| Module | JVM `.api` lines | klib `.api` lines |
|---|---|---|
| core | 2103 | 2081 |
| transport-ble | 24 | (present) |
| transport-tcp | 12 | (present) |
| transport-serial | 44 | (present) |
| storage-sqldelight | 7 | (present) |
| testing | 72 | (present) |

`**.internal.**` packages are excluded from the tracked surface (`PublishingConventionPlugin.kt:34-36`), matching ADR-005/API-P0-2 (hides e.g. SQLDelight-generated row/query classes). `core/api/jvm/core.api` was last touched in commit `bfa28ab` (2026-07-17) — current, not stale relative to `HEAD`. Enforced in CI via the dedicated `api-check` job (`./gradlew checkKotlinAbi`, `ci.yml:131-143`). `explicitApi()` is on (`KmpLibraryConventionPlugin.kt:76`), so anything not `public`/`internal`-marked fails to compile — a strong forcing function for a clean tracked surface. `docs/versioning.md` documents the full SemVer/ABI policy (pre-1.0: breaking changes bump MINOR + must regenerate dumps + `### Breaking` changelog section + release-notes callout).

## 4. Testing

- **Frameworks**: `kotlin.test` (`kotlinTest` catalog entry, applied to every module's `commonTest` — `KmpLibraryConventionPlugin.kt:91-96`), `kotest-assertions-core` (assertions library, not the full Kotest runner), Turbine (Flow testing), coroutines-test. JUnit4 + AndroidX Test Runner/Rules appear only in `transport-ble`'s `androidDeviceTest` source set (`transport-ble/build.gradle.kts:37-41`) for real-hardware instrumented conformance tests.
- **Layout**: `commonTest` in all 6 library modules; `jvmTest` in `core` (2 files) and `storage-sqldelight` (2 files); `jvmAndroidTest` in `transport-serial` (2 files, shares the custom hierarchy group); `androidDeviceTest` in `transport-ble` (1 file, `MeshtasticBleConformanceTest.kt` — real-hardware, "assume-skip when no radio in range" per `CHANGELOG.md:65`, so it never fails CI/local runs without hardware).
- **Volume**: 80 files matching `*Test*` (79 genuine test files + `testing/src/commonMain/kotlin/.../TestClock.kt`, a test-fixture source, not a test itself), **650** `@Test` functions. `:core` alone carries ~29 top-level test files (`AdminApiImplComprehensiveTest`, `EngineTest`, `HandshakeFsmTest`, `P0ReliabilityTest`/`P1EngineHardeningTest`/`P2*RpcTest` series, `StorageResilienceTest`, etc.) plus ~29 more under `ext/` and `ext/send/` packages and 2 `internal/` package tests — a genuinely deep suite for the core protocol engine, not a token smoke-test set.
- **What actually runs where in CI** (cross-checked `ci.yml` against its own description in `docs/ci-cd.md`):
  - `test-jvm` job: `./gradlew jvmTest` — this exercises `commonTest` (all 650 `@Test`s, transitively) via the JVM target, on a `[17, 21]` JDK matrix.
  - `test-ios` job: `./gradlew :core:iosSimulatorArm64Test` — re-exercises `:core`'s `commonTest` via the iOS Simulator target (native, real XCTest bridge).
  - `test-android` job: `./gradlew :core:compileAndroidMain :core:assembleAndroidMain` (`ci.yml:76-79`) — **compiles and assembles Android sources only; runs no test task whatsoever.** This directly contradicts `docs/ci-cd.md:59,80` which describes the job as running `:core:compileDebugKotlinAndroid :core:testDebugUnitTest` and labels the row "Android unit tests." The dedicated, named CI job for Android does not execute a single Android unit test. (`full-check`'s bare `./gradlew check` likely pulls in the Android host-test task transitively via AGP's `withHostTest {}` wiring, but there is no isolated CI signal for it — a failure there would be buried inside one large "check" job rather than surfaced as "Android tests failed.")
- **Coverage**: Kover (`org.jetbrains.kotlinx.kover:0.9.9`) applied to the 6 library modules and aggregated at root (`build.gradle.kts:126-135`, `libraryModules` set). No `koverReport { verify { ... } }` rule block anywhere (repo-wide grep for `KoverReportExtension`, `koverReport`, `minBound`, `verify {` returned nothing beyond the plugin application itself). No coverage step, XML/HTML report artifact, or Codecov/other upload action in any of the 8 workflow files. Net effect: coverage is measurable on demand locally (`./gradlew koverHtmlReport`) but is completely invisible in CI — no number is ever produced, gated, or surfaced on a PR.
- **SQLDelight migration check**: `storage-sqldelight/build.gradle.kts:40` sets `verifyMigrations.set(true)`, exercised transitively through `:storage-sqldelight:jvmTest` per `docs/ci-cd.md:63`.

## 5. CI enumeration (all 8 workflow files)

| File | Status | Trigger | Purpose |
|---|---|---|---|
| `ci.yml` | active | PR + push to `main` | 6 parallel jobs: `test-jvm` (JDK 17/21 matrix, `jvmTest` + `spotlessCheck detekt`), `test-android` (compile/assemble only, see §4), `test-ios` (macos-latest, iOS sim test + SwiftUI shell `xcodebuild` compile-check as an SKIE-export gate), `api-check` (`checkKotlinAbi`), `arch-consistency` (`verifyModuleBoundary` + detekt), `full-check` (`./gradlew check`), plus a `publish-snapshot` job gated on all of the above passing |
| `release.yml` | active | tag push `v[0-9]+.[0-9]+.[0-9]+` (stable only — RC tags deliberately excluded) or `workflow_dispatch` | Full release: checkout tag → Konan cache → memory-capped Gradle → verify tag==`currentVersion` → `assemble` (samples excluded, they OOM the macOS runner) → `check` (samples excluded) → probe Maven Central for idempotency → `publishAndReleaseToMavenCentral` |
| `docs.yml` | active | push/PR to `main` | Builds `:dokkaGenerate`, deploys to GitHub Pages on push only (PRs build-only) |
| `dependency-review.yml` | active | PR to `main` | `actions/dependency-review-action`, `fail-on-severity: high` |
| `tooling-check.yml` | active | path-filtered on `.github/**`/`.githooks/**` | Runs `.github/tooling/check.sh` — actionlint, SHA-pin enforcement, markdownlint, ajv schema validation, shellcheck |
| `codeql.yml.disabled` | **disabled** | (would be push/PR/weekly) | CodeQL for `actions` + `java-kotlin` |
| `scorecard.yml.disabled` | **disabled** | (would be push/weekly/branch-protection-rule) | OpenSSF Scorecard, SARIF upload |
| `.github/actions/gradle-setup/action.yml` | composite action (not a workflow) | — | Shared JDK setup + `gradle/actions/setup-gradle` wiring, used by every job above |

**Matrix/runners**: `ubuntu-latest` for JVM/Android/api/arch/tooling jobs; `macos-latest` for `test-ios` and the release `publish` job (needed for Xcode/iOS toolchain).

**Caching**: `gradle/actions/setup-gradle@v6.2.0` (official) + a bespoke self-hosted HTTP remote build cache (`gradle/build-cache.settings.gradle`, push disabled automatically when cache credentials are absent — i.e., safe for fork PRs) + `actions/cache@v6.1.0` keyed on `libs.versions.toml`+wrapper-properties hash for the Konan/Kotlin-Native toolchain.

**Hardening**: every `uses:` line repo-wide is pinned to a 40-hex commit SHA with a `# vX.Y.Z` comment, and this is self-enforced by a grep-based check in `.github/tooling/check.sh:60-70` that fails if it finds anything else. `concurrency:` + `permissions:` blocks present on `ci.yml`, `release.yml`, `docs.yml`, `dependency-review.yml`, and both `.disabled` workflows — **absent** on `tooling-check.yml` (no `concurrency:`, no `permissions:` key at all in the file). The two disabled workflows also pin to visibly older action SHAs than the active ones (`actions/checkout@11bd719...# v4.2.2` vs. `@9c091bb...# v7.0.0` used everywhere else) — a sign Renovate isn't (or wasn't) touching `.disabled`-suffixed workflow files, so they'll need a dependency refresh pass whenever they're re-enabled.

**Gap vs. stated intent**: `docs/ci-cd.md:3-10` (top-of-file banner) says *"release.yml... still ship with a `.yml.disabled` suffix and will be re-enabled before the public 1.0 push."* This is stale: `release.yml` has **no** `.disabled` suffix, is fully wired to Maven Central, and has already been used for a real publish (`v0.1.0`, confirmed live). The same document later (`docs/ci-cd.md:217-237,253`) correctly and separately describes `release.yml` as implemented, in detail — i.e., the doc is internally self-contradictory, not just stale relative to the repo. Only `codeql.yml`/`scorecard.yml` are still actually `.disabled`.

## 6. Documentation

**README.md** (16.4KB) — badges (License/Maven Central/CI/API-Docs), what-this-is, install snippet, snapshot-repo instructions, quick-start (connect/send/observe-nodes), a "picking a transport" walkthrough for BLE/TCP/serial, a troubleshooting table, platform-support matrix, building-from-source, contributing pointer, license, related-projects list. Very complete **except** it says at `README.md:39`: *"`0.1.0` is **not yet on Maven Central** — the first release tag has not been cut."* This is factually wrong as of this audit: the `v0.1.0` tag was cut and the GitHub release published on 2026-07-17, and `org.meshtastic:sdk-core:0.1.0` (plus the BOM and at least `sdk-transport-ble`) are confirmed live on Maven Central. This stale warning sits directly under a working `implementation("org.meshtastic:sdk-core:0.1.0")` snippet, which is actively confusing for a new consumer.

**docs/** — 60 files, ~14,650 lines / ~99,900 words: `SPEC.md`, `api-reference.md`, `protocol.md`, `error-taxonomy.md`, `glossary.md`, `versioning.md`, `security.md`, `manual-tests.md`, `ci-cd.md`, `samples.md`, `testing.md`, `threading-model.md`, `observability.md`, `performance*.md`, plus `architecture/` (9 files: handshake FSM, engine actor, storage, module graph, transport comparison/isolation, migration notes for Meshtastic-Android/Apple), `decisions/` (15 numbered ADRs + template), `consumer-guides/` (5 host-integration recipes: Hilt, MVVM, reactive lifecycle, R8/Proguard), `references/` (5 cross-repo protocol note files), `future/` (wasm/RPC roadmap). This is an unusually deep documentation set for a library at v0.1.0.

**Dokka**: v2.2.0 (`gradle/libs.versions.toml:55`), aggregated across `:core`, `:transport-ble`, `:transport-tcp`, `:transport-serial`, `:storage-sqldelight`, `:testing` (`build.gradle.kts:46-53`), each module's `Module.md` pulled in via `includes.from("Module.md")` and source-linked to GitHub (`KmpLibraryConventionPlugin.kt:29-41`). Published to GitHub Pages by `docs.yml` on every push to `main`.

**KDoc spot-check** (3 files): `RadioClient.kt:37-79` (class-level KDoc: philosophy, full worked example, multi-radio note, resource-management rationale, `@since` tag), `AdminApi.kt:28-63` (interface + per-method KDoc with worked example and `@param`/`@return`/`@since`), `core/Module.md` (module-level summary). Heuristic scan: 56/58 `core/src/commonMain` files contain `/**` blocks; 0 files found with `public` declarations and *zero* KDoc anywhere in the file. Estimate: high-90s percent KDoc coverage by file; the two spot-checked files suggest per-member (not just per-file) coverage is also strong.

**CHANGELOG.md** — Keep a Changelog format, SemVer-referenced, `[Unreleased]` scaffold present and empty (ready for next cycle), `[0.1.0] — 2026-07-16` is extensive (Breaking/Added/Fixed, several items annotated "*Found on hardware*" tying back to the `androidDeviceTest` conformance harness).

**Samples** (`docs/samples.md`): `samples/cli` (JVM TUI via Mosaic + Clikt, all 3 transports, scriptable NDJSON mode), `samples/parity-app` (Compose Multiplatform UI shared across Android/iOS/JVM-desktop, TCP-only), `samples/parity-android-app` (standalone Android shell wrapping `parity-app`). None are published (by design — `docs/samples.md:3`).

## 7. Org alignment

- **License**: GPL-3.0 full text at `/LICENSE`. ADR-004 (`docs/decisions/004-licensing.md:25`) explicitly decided **GPL-3.0-or-later**, and every one of 214 grep-matched source files carries `SPDX-License-Identifier: GPL-3.0-or-later`. `README.md:7` and `:293` instead say **GPL-3.0-only**. This is a real, citable inconsistency between the project's own recorded decision + the actual source headers vs. its most user-facing document. ADR-004 also references two things not found in the repo: a `dco-bot` workflow (`docs/decisions/004-licensing.md:40` — actual mechanism is the org-level GitHub DCO App, correctly described instead in `docs/ci-cd.md:208-213`) and a `LICENSES.md` file / `:checkLicenseHeaders` Gradle task (`004-licensing.md:56,70` — neither exists; license-header enforcement is in fact done, just via Spotless's `licenseHeader()` step in `build.gradle.kts:82`, not a dedicated task).
- **CODEOWNERS**: present and structured (general → specific ordering, security-sensitive paths called out), but references `/proto/` and `/samples/ios-app/` — neither exists post-ADR-015 (protobufs are now an external Maven artifact) / the actual sample path is `/samples/parity-app/iosApp/`. Also uses placeholder `@meshtastic/sdk-*` team handles, which the file's own header (`CODEOWNERS:6-7`) flags as a TODO pending real GitHub teams.
- **`.gitattributes`** also still references the removed `proto/src/protobufs/**` path as `linguist-vendored` (`.gitattributes:16`) — a third file (alongside CODEOWNERS and `core/Module.md`'s "`:core` ... depends only on `:proto`" line) that wasn't updated when ADR-015 removed the in-tree proto module in favor of the published artifact. Consistent pattern of post-refactor doc/config drift, not an isolated typo.
- **Community health files**: `CODE_OF_CONDUCT.md` (83 lines, adopts org-wide CoC), `GOVERNANCE.md` (60 lines), `SUPPORT.md` (45 lines), `CONTRIBUTING.md` (DCO-based, no CLA), `SECURITY.md` (private disclosure, scoped) — all present and substantive.
- **Issue/PR templates**: bug report + feature request YAML forms, blank issues disabled, contact links redirect security reports to the private advisory flow and general questions to the community channel; single PR template.
- **Repo metadata** (`gh repo view`): description is detailed and accurate; 16 topics set; **`homepageUrl` is empty** (could reasonably point at `meshtastic.org` or the Dokka Pages site); default branch `main`; license key `gpl-3.0` (generic, doesn't disambiguate -only/-or-later at the GitHub-metadata level).
- **Naming/coordinates**: fully consistent `org.meshtastic:sdk-<module>` scheme, confirmed both in build config and live on Maven Central.
- **RELEASING.md staleness**: `RELEASING.md:57-64` still describes a since-superseded state — *"All workflows are currently disabled (`.yml.disabled`) for the internal 0.1.0 team-share, so publish manually... Once `.github/workflows/release.yml` is re-enabled before the public push, pushing the tag will trigger `publishAllPublicationsToInternalRepository` automatically."* In reality `release.yml` is live, targets Maven Central (not an "InternalRepository"), and has already executed a real publish. This corroborates the `docs/ci-cd.md` banner staleness noted in §5 — three separate docs (`README.md`, `RELEASING.md`, `docs/ci-cd.md`'s banner) all still describe a pre-v0.1.0 "nothing is public yet" phase that the repo has already moved past.

---

## TOP 5 STRENGTHS

1. **Exceptionally deep, mostly-accurate documentation and KDoc.** ~60 files / ~100K words under `docs/`, 15 ADRs recording real decisions and their rationale, Module.md-per-module wired into a published Dokka site, and near-universal KDoc coverage on the public API (spot-checked `RadioClient`/`AdminApi` are genuinely example-driven, not boilerplate).
2. **Modern, well-reasoned build architecture.** Six focused convention plugins in a `build-logic` composite build eliminate per-module boilerplate; deliberate use of Kotlin 2.4's *built-in* ABI validation over the legacy BCV plugin; `explicitApi()` + `-Xjvm-expose-boxed` + a custom `verifyModuleBoundary` architecture-enforcement task show real engineering discipline, not just cargo-culted setup.
3. **Substantial, real test suite.** 650 `@Test` functions across 79 files, run cross-platform (JVM + iOS Simulator) on every PR, plus a genuine on-hardware BLE conformance harness (`androidDeviceTest`) that skips gracefully without a radio and has already caught real device-only bugs (per CHANGELOG "Found on hardware" entries).
4. **CI hardening that goes beyond typical OSS baseline.** 100% SHA-pinned actions self-enforced by a custom lint script, least-privilege `permissions:` almost everywhere, a multi-layer cache strategy (official Gradle action + custom remote HTTP cache + Konan cache), and an idempotency-safe release workflow that probes Maven Central before publishing.
5. **Publishing pipeline actually works end-to-end.** Not aspirational: `v0.1.0` is independently confirmed live on Maven Central (core, bom, transport-ble all verified via central.sonatype.com) with GPG signing, correct POM metadata, and a coherent snapshot-vs-release task split.

## TOP 8 GAPS

1. **Coverage is measured but completely dark.** Kover is applied but has zero verification rules and zero CI wiring — no report artifact, no Codecov upload, no threshold gate, no badge. (`build.gradle.kts:16,106-135`; absent from all 8 workflows)
2. **Multiple docs describe a "not yet public" state that's already been superseded by the real `v0.1.0` Maven Central release.** `README.md:39` ("not yet on Maven Central"), `RELEASING.md:57-64` ("workflows currently disabled... publish manually... InternalRepository"), and `docs/ci-cd.md:3-10`'s banner (contradicted by its own §217-237) all lag reality by at least 4 days at time of audit. This is the single biggest "read the docs, get the wrong answer" risk in the repo.
3. **License identifier inconsistency.** ADR-004 + 214 source-file SPDX headers say GPL-3.0-**or-later**; `README.md:7,293` says GPL-3.0-**only**. For a copyleft license this is a substantive (not cosmetic) discrepancy for downstream legal review.
4. **The `test-android` CI job doesn't test anything.** It only runs `:core:compileAndroidMain :core:assembleAndroidMain` (`ci.yml:76-79`) — no test task at all — contradicting `docs/ci-cd.md`'s own description of that job as running `testDebugUnitTest`. Any Android-host-test signal that exists is buried, unlabeled, inside the monolithic `full-check` job.
5. **Post-ADR-015 drift left stale references in three places.** `CODEOWNERS` (`/proto/`, `/samples/ios-app/`), `core/Module.md` ("depends only on `:proto`"), and `.gitattributes` (`proto/src/protobufs/**`) all still reference the in-tree proto module/submodule that ADR-015 removed in favor of the external `org.meshtastic:protobufs` artifact.
6. **`tooling-check.yml` is the one workflow without hardening.** No `concurrency:` group and no `permissions:` block, unlike every other active workflow in the repo.
7. **CODEOWNERS uses placeholder teams** (`@meshtastic/sdk-maintainers` et al.) that the file's own header admits don't exist yet as real GitHub teams — so review routing is currently a no-op / falls back to repo defaults.
8. **Supply-chain workflows are still off, and rotting while disabled.** `codeql.yml` and `scorecard.yml` both carry `.disabled` suffixes with no enablement date, and their pinned action SHAs are visibly older than the active workflows' (e.g. `checkout@...#v4.2.2` vs `#v7.0.0` elsewhere), suggesting Renovate isn't tracking them — they'll need a dependency catch-up pass in addition to just removing the suffix.

*(Minor/secondary notes captured in the full report but not in the top 8: unused `gradle="9.5.1"` catalog entry vs. real wrapper `9.6.1`; sources/javadoc jar attachment inferred but not independently confirmed; `homepageUrl` unset on the GitHub repo; search.maven.org not yet indexing the group 4 days post-publish; ADR-004 references a `LICENSES.md`/`:checkLicenseHeaders` task that don't exist under those names.)*
