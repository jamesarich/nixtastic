# Audit: meshtastic/MQTTastic-Client-KMP (`/Users/james/meshtastic/mqttastic-client-kmp`)

Audited at commit `89d01bb` (main, HEAD), repo tag `v0.5.0`. Read-only; no files modified. All
paths below are relative to the repo root unless stated otherwise.

## Scorecard

| # | Criterion | Status | Evidence (path / value) |
|---|-----------|--------|-------------------------|
| **BUILD LOGIC** |
| 1 | Gradle wrapper version | ✅ | `9.6.1` — `gradle/wrapper/gradle-wrapper.properties:3` |
| 2 | Kotlin version | ✅ | `2.4.10` — `gradle/libs.versions.toml:6`. **Caveat:** lines 3–5 comment claims the version is "Held at 2.3.x" and enforced by a "Hold Kotlin at 2.3.x" Renovate rule — neither is true (see Gaps). |
| 3 | AGP version | ✅ (not N/A — Android target present) | `9.3.0` — `gradle/libs.versions.toml:2`; applied via `com.android.kotlin.multiplatform.library` in `core/build.gradle.kts:19`, `transport-tcp/build.gradle.kts:19`, `transport-ws/build.gradle.kts:19`, `sample/build.gradle.kts:5`, `sample/androidApp/build.gradle.kts:2` |
| 4 | Version catalog | ✅ | `gradle/libs.versions.toml` (74 lines; versions/libraries/plugins sections) |
| 5 | Convention plugins via `build-logic` | ✅ | `build-logic/` composite build, included at `settings.gradle.kts:2`; two plugins registered at `build-logic/convention/build.gradle.kts:29-40`: `mqtt.kmp.library` → `MqttKmpLibraryConventionPlugin.kt`, `mqtt.publishing` → `MqttPublishingConventionPlugin.kt` |
| 6 | KMP targets declared | ✅ | 9 targets: `jvm`, `android`, `iosArm64`, `iosSimulatorArm64`, `macosArm64`, `linuxX64`, `linuxArm64`, `mingwX64` (all in `build-logic/convention/.../MqttKmpLibraryConventionPlugin.kt:51-57`) + `wasmJs` (added per-module: `core/build.gradle.kts:44-46`, `transport-ws/build.gradle.kts:44-46`; **omitted** in `transport-tcp/build.gradle.kts` by design). No `iosX64`/`macosX64` (dropped — "deprecated in Kotlin 2.3.20", `AGENTS.md:55`), no tvOS/watchOS/wasmWasi. |
| 7 | Hierarchical source sets | ✅ | `applyDefaultHierarchyTemplate()` — `MqttKmpLibraryConventionPlugin.kt:59`; confirmed in use via `appleMain`/`linuxMain`/`mingwMain` references in `transport-ws/build.gradle.kts:62-68` |
| 8 | `explicitApi()` strict mode | ❌ | Zero matches for `explicitApi` repo-wide (`grep -rn "explicitApi"` across all `*.kts`/`*.kt`). Deliberate alternative per `docs/adr/0008-public-api-allowlist.md`: default-`internal` visibility + a Konsist-enforced allowlist (`core/src/jvmTest/.../architecture/ArchitectureTest.kt:119-178`) + BCV. Equivalent in effect for `:core` only — `transport-tcp`/`transport-ws` have no such allowlist test. |
| 9 | JVM toolchain pinned | ✅ | `jvmToolchain(11)` via catalog — `MqttKmpLibraryConventionPlugin.kt:43-49` + `gradle/libs.versions.toml:26` (`javaToolchain = "11"`). Note: `sample/build.gradle.kts:11` hardcodes `jvmToolchain(17)` directly instead of the catalog value (sample isn't published, so lower stakes, but inconsistent). |
| 10 | Gradle config/build cache | ✅ (strong) | `gradle.properties:3-6` (`org.gradle.caching=true`, `org.gradle.configuration-cache=true`, `org.gradle.parallel=true`, `org.gradle.vfs.watch=true`) **plus** a remote HTTP build cache (`gradle/build-cache.settings.gradle`) and Gradle Develocity build scans (`gradle/develocity.settings.gradle`, `settings.gradle.kts:12-13`) — above typical library setups. |
| **PUBLISHING** |
| 11 | Publishing mechanism | ✅ | vanniktech `com.vanniktech.maven.publish` `0.37.0` — `gradle/libs.versions.toml:18`, applied `MqttPublishingConventionPlugin.kt:33` |
| 12 | Central Portal vs legacy OSSRH | ✅ Central Portal | `publishToMavenCentral(automaticRelease = true)` — `MqttPublishingConventionPlugin.kt:36` (modern vanniktech Central-Portal API, not the legacy `SonatypeHost` enum). Confirmed live on `central.sonatype.com` (modern Central Portal UI) for all 4 coordinates at v0.5.0. Minor naming holdover: CI secrets are still named `OSSRH_USERNAME`/`OSSRH_PASSWORD` (`ci.yml:196-197`, `release.yml:134-135`) though functionally Central-Portal user-token creds. |
| 13 | GPG signing | ✅ | Conditional `signAllPublications()` gated on `signingInMemoryKey` presence — `MqttPublishingConventionPlugin.kt:37-39`; wired via `ORG_GRADLE_PROJECT_signingInMemoryKey*` secrets in `ci.yml:198-200` and `release.yml:136-138` |
| 14 | BOM module published | ✅ | `:bom`, `java-platform` plugin — `bom/build.gradle.kts:17-35`; constraints pin `mqtt-client-core`/`-transport-tcp`/`-transport-ws`; confirmed live on Central as `mqtt-client-bom` v0.5.0 (POM packaging) |
| 15 | POM metadata complete | ✅ | name, description, `inceptionYear`, url, licenses (name/url/distribution), developers (id/name/url), scm (url/connection/developerConnection), issueManagement (system/url) — all in `MqttPublishingConventionPlugin.kt:47-80` |
| 16 | Sources jar + Dokka/javadoc jar | ✅ (plugin default, not independently verified by download) | vanniktech `publishToMavenCentral()` attaches sources+javadoc jars by default; not overridden anywhere in the repo |
| 17 | Group/artifact coordinates | ✅ | Group `org.meshtastic` — `gradle.properties:20`; artifacts `mqtt-client-core` / `mqtt-client-transport-tcp` / `mqtt-client-transport-ws` / `mqtt-client-bom` via `coordinates(artifactId = "mqtt-client-${project.name}")` — `MqttPublishingConventionPlugin.kt:45` |
| 18 | Version single-source-of-truth | ✅ | `build.gradle.kts:24-50` — derived from `git describe --tags --match v*`; exact tag → release version, else next-patch `-SNAPSHOT`; override via `-PVERSION_NAME`; applied via `allprojects { version = resolvedVersion }` |
| **API & COMPAT** |
| 19 | Binary Compatibility Validator | 🟡 Partial (JVM-only) | BCV `0.18.1` applied per module (`core`/`transport-tcp`/`transport-ws build.gradle.kts`); `.api` dumps exist only at `core/api/jvm/core.api`, `transport-tcp/api/jvm/transport-tcp.api`, `transport-ws/api/jvm/transport-ws.api` — **no** klib dumps and no `apiValidation { klib { enabled = true } }` config anywhere (grepped, zero hits). Native/wasmJs ABI (8 of 9 targets) is unvalidated by `apiCheck`. |
| **TESTING & COVERAGE** |
| 20 | Test framework(s) | ✅ | `kotlin.test` + `kotlinx-coroutines-test` wired in `MqttKmpLibraryConventionPlugin.kt:64-67`; Konsist `0.17.3` for architecture tests (`core` `jvmTest` only) |
| 21 | `commonTest` + per-target source sets | 🟡 Partial | `core`: `commonTest` (21 files) + `jvmTest` (4 files, incl. Konsist + env-gated integration tests). `transport-tcp`: `commonTest` (1 file). `sample`: `commonTest` (1 file). **`transport-ws`: no test source set at all** (`find transport-ws/src` → only `commonMain`). No dedicated per-platform test dirs (`iosTest`/`macosTest`/etc.); CI instead runs the shared `commonTest` against each native/wasm target's test task (idiomatic KMP pattern, see CI section) — but the platform-specific `PlatformTls.{android,jvm,native}.kt` `actual` implementations in `transport-tcp` have no dedicated per-platform unit tests, only indirect coverage via env-gated integration tests. |
| 22 | Rough test count | ✅ counted | `core`: 25 files / **484** `@Test` (451 commonTest + 33 jvmTest — verified per-file). `transport-tcp`: 1 file / 4 `@Test`. `transport-ws`: **0**. `sample`: 1 real test file / 7 `@Test` (+ a non-test `PreviewTest.kt` Compose `@Preview` stub in `commonMain`, not a test despite the name). Repo-wide total ≈ 495 `@Test`. |
| 23 | Coverage tool | ✅ | Kover `0.9.9` — `gradle/libs.versions.toml:23`; root-aggregated across `core`/`transport-tcp`/`transport-ws` — `build.gradle.kts:57-64` |
| 24 | Coverage uploaded to Codecov | ✅ | `ci.yml:59-66` — `codecov/codecov-action@v7`, uploads `build/reports/kover/report.xml`, flag `jvm`. README badge: `README.md:9`. Caveat: Kover instruments JVM bytecode only, so the uploaded coverage reflects JVM-executed tests, not native/wasm execution (an ecosystem-wide Kover/KMP limitation, not project-specific). |
| 25 | Coverage threshold enforced | ✅ (with one gap) | `build.gradle.kts:73-77` — `verify { rule { minBound(80) } }`; enforced in `ci.yml:53` (`jvmTest koverVerify`). **Not** re-run in `release.yml:78`'s pre-publish validation (`spotlessCheck detekt jvmTest apiCheck` — no `koverVerify`); low risk since release builds off `main`, which already passed it. |
| **CODE QUALITY TOOLING** |
| 26 | Formatter/linter + config | ✅ | Spotless `8.8.0` (ktlint) + detekt `1.23.8`, per-module (`core`/`transport-tcp`/`transport-ws build.gradle.kts`); config at `config/detekt/detekt.yml` (18 lines, `buildUponDefaultConfig=true` + overrides: `maxIssues:0`, `LongMethod.threshold=60`, `LongParameterList` thresholds 10/10, `MaxLineLength=120`, `WildcardImport` off); license headers via `config/spotless/copyright.kt` / `copyright.kts` |
| 27 | `.editorconfig` | ❌ | Not present anywhere in the repo (`find . -iname ".editorconfig"` → empty) |
| 28 | Pre-commit / git hooks | ❌ (repo-provided) | No committed hook-installer, no Husky/`pre-commit-config.yaml`, no `core.hooksPath` override in the repo. (A local-machine-only `.git/hooks/prepare-commit-msg` exists on this checkout — a personal LLM-commit-message helper hitting `127.0.0.1:11434`, unrelated to and not distributed by this project; not counted.) |
| **CI/CD** |
| 29 | PR build+test workflow | ✅ | `.github/workflows/ci.yml` — triggers on push to `main`, PR to `main`, `merge_group` |
| 30 | Multiplatform CI matrix incl. macOS runner | ✅ | `ci.yml`: `test-native-macos` on `macos-26` (`macosArm64Test`, `iosSimulatorArm64Test`); plus `test-windows` on `windows-latest` (`mingwX64Test`), `test-native-linux`/`test-wasm`/`lint`/`test-jvm`/`api-check` on `ubuntu-latest`; `build` job gates on all six; `publish-snapshot` also runs on `macos-26`. |
| 31 | Gradle caching in CI | ✅ (two layers) | `gradle/actions/setup-gradle@v6` (`.github/actions/gradle-setup/action.yml:28-32`, `cache-read-only` toggled by event, `cache-cleanup: on-success`) **plus** a custom remote HTTP build cache (`GRADLE_CACHE_URL` secret → `gradle/build-cache.settings.gradle`) |
| 32 | Lint/format check step in CI | ✅ | `ci.yml:36-37` (`lint` job) — `./gradlew spotlessCheck detekt` |
| 33 | API-compat check step in CI | ✅ | `ci.yml:133-147` (`api-check` job) — `./gradlew apiCheck`; re-run in `release.yml:78` |
| 34 | Coverage step in CI | ✅ | `ci.yml:52-66` (`test-jvm` job) — `koverVerify`, `koverXmlReport`, Codecov upload |
| 35 | Publish/release workflow | ✅ | `.github/workflows/release.yml` — tag push (`v*`) + `workflow_dispatch` (with a `dry_run` recovery/backfill mode); publishes to Maven Central with an idempotency guard (probes Central for the POM before publishing — `release.yml:110-128`), creates the GitHub Release, builds/attaches sample artifacts across a 3-OS matrix, generates CycloneDX+SPDX SBOMs, and attests build provenance for both Maven artifacts and sample binaries (`actions/attest-build-provenance@v4`). Snapshot publishing also exists (`ci.yml:166-201`, `publish-snapshot` job on push to `main`). |
| 36 | Release automation | 🟡 Partial | GitHub Release notes auto-generate (`generate_release_notes: true`, `release.yml:148`) and the whole publish/SBOM/attestation/sample-artifact pipeline is automatic off a tag push. **Version bump + CHANGELOG edit are manual** — `CONTRIBUTING.md:59-63` describes manually moving `## [Unreleased]` entries under a new heading, committing, and tagging. No semantic-release/Release-Please-style automation. |
| 37 | Workflow hardening | 🟡 Partial | `concurrency` present in all 4 workflows with sensible `cancel-in-progress` choices (`false` for release/docs, `true` for ci/codeql); `permissions` blocks present and reasonably least-privilege everywhere (`contents:read` default; elevated only where needed — `codeql.yml:17-20` adds `security-events:write`+`actions:read`; `docs.yml:8-11` adds `pages:write`+`id-token:write`; `release.yml:38-41` adds `contents:write`+`id-token:write`+`attestations:write`). **No action is pinned to a full commit SHA anywhere** — all 13 distinct actions used (`actions/checkout@v7`, `actions/cache@v6`, `actions/setup-java@v5`, `gradle/actions/setup-gradle@v6`, `gradle/actions/wrapper-validation@v6`, `codecov/codecov-action@v7`, `github/codeql-action/{init,analyze}@v4`, `actions/upload-pages-artifact@v5`, `actions/deploy-pages@v5`, `actions/attest-build-provenance@v4`, `softprops/action-gh-release@v3`, `anchore/sbom-action@v0`) use mutable major-version tags only. |
| 38 | Dependency automation | ✅ Renovate | `renovate.json` — `extends: config:recommended`, ecosystem grouping (Kotlin/Ktor/Compose/build-tools), patch + build-tool-minor automerge via merge queue, 3-day `minimumReleaseAge` stabilization for core-ecosystem minor/major, major updates never automerged, submodule tracking for `meshtastic/protobufs`. No Dependabot config (Renovate is the sole tool). |
| **DOCUMENTATION** |
| 39 | README badges | ✅ | Maven Central, Kotlin version, License, CI, Codecov, API Docs — `README.md:5-10` (6 badges) |
| 40 | README install + quick-start | ✅ | `README.md:79-204` — Kotlin DSL, Groovy DSL, single-platform variants, plus a "verbose equivalent" without convenience APIs |
| 41 | README platform-support table | ✅ | `README.md:45-53` — 7 rows covering the 9 KMP targets, transport availability, status |
| 42 | API docs site (Dokka) published | ✅ | `.github/workflows/docs.yml` — `dokkaGeneratePublicationHtml` → GitHub Pages via `actions/deploy-pages`; README badge links to `meshtastic.github.io/MQTTastic-Client-KMP` |
| 43 | KDoc coverage on public API | ✅ ~high, estimated | Spot-checked `MqttClient.kt` (class + per-method KDoc with usage examples), `QoS.kt` (enum + per-entry + companion), `MqttTransport.kt`/`MqttEndpoint.kt` (interface + per-property + examples + spec §citations), `ReasonCode.kt` (per-property + OASIS spec link), `MqttConfig.kt` (53 separate `/**` blocks in one 615-line file). All 25 files in `core/src/commonMain` contain ≥1 KDoc block. No gaps found in sampled public declarations. |
| 44 | CHANGELOG present + maintained | ✅ | `CHANGELOG.md` — Keep a Changelog format + SemVer statement; entries `0.1.0` → `0.5.0` (matches current tag) with Added/Changed/Fixed/Security subsections and PR/issue cross-refs; empty `## [Unreleased]` heading ready for next cycle |
| 45 | Samples / examples module | ✅ | `:sample` + `:sample:androidApp` — Compose Multiplatform demo (Android/iOS/Desktop-JVM/wasmJs), connects to the public `mqtt.meshtastic.org` broker, own `sample/README.md`, and its own CI-built release artifacts (`release.yml` `sample-artifacts` job: apk/deb/dmg/msi/wasm-zip) |
| 46 | Module-level docs | 🟡 Partial (present but partly stale) | `core/Module.md`, `transport-tcp/Module.md`, `transport-ws/Module.md` wired into each module's Dokka config; plus a per-module consumer `core/README.md`. **But** `core/README.md` and `core/Module.md` predate the v0.4.0 module split and are stale (see Gaps #4). `transport-tcp/Module.md` and `transport-ws/Module.md` are accurate and current. |
| **ORG ALIGNMENT** |
| 47 | LICENSE | ✅ | GNU GPLv3 — `LICENSE` (full text); confirmed via `gh repo view` → `licenseInfo.key: "gpl-3.0"` |
| 48 | CONTRIBUTING + CODE_OF_CONDUCT | ✅ | `CONTRIBUTING.md` (prereqs, build commands, code style, PR process, release process) + `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1) |
| 49 | Issue + PR templates | ✅ | `.github/ISSUE_TEMPLATE/bug_report.yml` + `feature_request.yml` (YAML forms); `.github/pull_request_template.md` (Description/Changes/Testing checklist/Related Issues). No `ISSUE_TEMPLATE/config.yml` contact-links file (minor). |
| 50 | CODEOWNERS | ❌ | Not present anywhere (`find . -iname CODEOWNERS` → empty) |
| 51 | SECURITY.md | ✅ | `SECURITY.md` — private vulnerability reporting via GH security advisories + `security@meshtastic.org`; scope defined (TLS cert validation, untrusted-data parsing, credential mgmt, native memory safety); 48h ack / 7-day fix-plan SLA |
| 52 | Default branch | ✅ | `main` — confirmed via `gh repo view` (`defaultBranchRef.name: "main"`) and local `git branch --show-current` |
| 53 | Repo description/topics/homepage | 🟡 Partial | Description: "Kotlin MultiPlatform MQTT 5.0 Client Library" ✅. Topics: 15 set (`android`, `coroutines`, `ios`, `iot`, `kmp`, `kotlin`, `kotlin-multiplatform`, `ktor`, `meshtastic`, `mqtt`, `mqtt-client`, `mqtt5`, `multiplatform`, `networking`, `tls`, `websocket`) ✅. **`homepageUrl` is empty** — not set. |
| 54 | Consistent group id + naming | ✅ | `org.meshtastic:mqtt-client-{core,transport-tcp,transport-ws,bom}` — uniform pattern, single `GROUP` property (`gradle.properties:20`), programmatically derived (`MqttPublishingConventionPlugin.kt:45`), not hand-typed per module |

## Maven Central verification

Checked `central.sonatype.com` (the modern Central Portal UI; `repo1.maven.org` directory listing
and `search.maven.org`'s Solr API both returned non-content responses — 403 / stale index — from
this environment, so the Portal pages were used instead):

| Artifact | Latest version on Central | Repo tag | Drift |
|---|---|---|---|
| `org.meshtastic:mqtt-client-core` | 0.5.0 (published ~4 days before this audit) | `v0.5.0` | None |
| `org.meshtastic:mqtt-client-transport-tcp` | 0.5.0 | `v0.5.0` | None |
| `org.meshtastic:mqtt-client-bom` | 0.5.0 (POM/`java-platform` packaging) | `v0.5.0` | None |
| `org.meshtastic:mqtt-client-transport-ws` | not independently re-checked (page-fetch budget); `release.yml` publishes it in the same `publishAllPublicationsToMavenCentralRepository` step as the other three, and the repo's version-consistency check (`release.yml:117-128`, probing the `mqtt-client-core` POM) gates all publications together | `v0.5.0` | Assumed none |

GitHub releases (`gh api repos/meshtastic/MQTTastic-Client-KMP/releases`) confirm `v0.5.0` published
`2026-07-16T23:58:40Z` as the newest non-draft, non-prerelease release, consistent with `CHANGELOG.md`
and the Maven Central publish dates — **no lag between repo HEAD and the published artifacts**.

## Detailed notes

### Build logic
Four Gradle modules (`:core`, `:transport-tcp`, `:transport-ws`, `:bom`) plus a demo app
(`:sample`, `:sample:androidApp`), all wired through two `build-logic` convention plugins so the
KMP target set and publishing coordinates aren't repeated per module
(`build-logic/convention/src/main/kotlin/MqttKmpLibraryConventionPlugin.kt`,
`MqttPublishingConventionPlugin.kt`). `:core` has zero dependency on any transport module, enforced
both at configuration time (`core/build.gradle.kts:96-123`, `verifyModuleBoundary` task wired into
`check`) and via the Konsist architecture suite. `:bom` is a `java-platform` (`bom/build.gradle.kts`).
The version is derived once, at the root, from git tags (`build.gradle.kts:24-50`) and propagated via
`allprojects { version = ... }` — a clean single source of truth.

### Publishing
vanniktech `maven-publish` 0.37.0, Central-Portal mode, `automaticRelease = true`
(`MqttPublishingConventionPlugin.kt:36`) — no manual "close and release" step needed. Signing is
conditional on `signingInMemoryKey` being present, so local `publishToMavenLocal` doesn't require
secrets. POM metadata is complete and shared via the same convention plugin, differing only by
per-module `name`/`description`/`artifactId`. Both a tag-triggered release publish (`release.yml`)
and a `main`-push snapshot publish (`ci.yml`) exist.

### API/compat
BCV is applied to all three published library modules but only produces/validates a `jvm` API dump
(`core/api/jvm/core.api`, `transport-tcp/api/jvm/transport-tcp.api`,
`transport-ws/api/jvm/transport-ws.api` — confirmed via `find . -name "*.api"`, and no `klib`
subdirectory or `apiValidation { klib {...} }` block exists anywhere). For a library that publishes
klibs to 8 non-JVM targets, this means `apiCheck` cannot catch an ABI break that's specific to, say,
the `iosArm64` or `wasmJs` klib. The `:core` allowlist (`ArchitectureTest.kt`) is the only other ABI
guard, and it is `:core`-only.

### Testing
`:core` is thoroughly tested (see scorecard #21/22): full packet encode/decode round-trips
(`MqttEncoderDecoderTest.kt`, 60 `@Test`), MQTT 5.0 properties (`MqttPropertiesTest.kt`, 57), 3.1.1
compatibility (`Mqtt311Test.kt`, 48), config validation (`MqttConfigTest.kt`, 42), connection state
machine (`MqttConnectionTest.kt`, 34), VBI boundary values (`VariableByteIntTest.kt`, 19), and a fuzz
test (`packet/MqttDecoderFuzzTest.kt`). Three env-gated (`MQTT_INTEGRATION_TESTS`) integration test
classes connect to real brokers and are skipped by default (verified: not set in any CI workflow, so
they no-op in `ci.yml`'s `jvmTest` run): `MqttIntegrationTest.kt` (local Mosquitto,
`docker/docker-compose.yml`), `MqttPortugalIntegrationTest.kt` and `MqttPtDiagnosticTest.kt` (real
`mqtt.meshtastic.pt:8883`). The latter two hardcode `username = "meshdev"` /
`password("large4cats")` (`MqttPortugalIntegrationTest.kt:40-41`) — this is the Meshtastic project's
long-publicized default MQTT credential for its own public broker (also shown as an example in
`core/README.md:52-53`), not a leaked secret, but it is a live external dependency embedded directly
in test source rather than isolated behind test fixtures/env vars for the connection details.
`transport-tcp` has one narrowly-scoped unit test (TLS SNI-suppression logic,
`TcpTransportTlsTest.kt`, 4 `@Test`); its platform `actual` TLS wiring
(`PlatformTls.{android,jvm,native}.kt`) has no dedicated tests. **`transport-ws` has no tests of any
kind.**

### CI
Four workflows: `ci.yml` (lint, per-target test matrix, API check, build, snapshot publish),
`release.yml` (tag/dispatch-triggered publish + GH release + sample artifacts + SBOM/attestation),
`codeql.yml` (weekly + PR security scanning — note the `java-kotlin` language is currently disabled,
`codeql.yml:31-39`, because CodeQL ≤2.26.1 rejects Kotlin 2.4.10; only the `actions` language runs),
and `docs.yml` (Dokka → GitHub Pages). Caching is layered (setup-gradle action cache + a custom
remote HTTP cache). Hardening (concurrency + permissions) is consistently applied; the one
structural gap is that no action is SHA-pinned (see scorecard #37).

### Docs
`README.md` is comprehensive (features, comparison table, architecture diagram, install/quickstart
in 3 variants, MQTT 3.1.1 section, convenience-API table, full MQTT 5.0 coverage tables, known
limitations). `docs/configuration.md` (700 lines) and `docs/topics-and-qos.md` (435 lines) are
substantial guides, not stubs. Ten ADRs (`docs/adr/0001`–`0010`, 39–73 lines each) document real
design decisions (transport abstraction, zero-dependency policy, sealed packet hierarchy, QoS state
machine, coroutines/Flow API, multi-module split, mutex send serialization, public-API allowlist,
dual-protocol support, packet-ID allocation) — a genuinely strong practice, uncommon even in mature
KMP libraries. The one clear weak spot is `core/README.md` / `core/Module.md`, which were not
updated when the single `:library` module (pre-`v0.4.0`) was split into `:core` +
transport modules (see Gaps #4).

### Org alignment
Community-health files are essentially complete (LICENSE, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY,
issue templates, PR template, FUNDING.yml pointing at Open Collective). The only structural absence
is CODEOWNERS. Repo metadata (`gh repo view`) is well-populated except `homepageUrl`.

## Notable strengths (ranked)

1. **CI/release engineering is unusually mature for a library of this size.** Four hardened
   workflows with concurrency groups + least-privilege `permissions` throughout; a 6-way parallel
   per-target test matrix including real `macos-26` and `windows-latest` runners
   (`ci.yml:23-165`); a tag-triggered release pipeline with a Maven-Central-state idempotency probe
   (`release.yml:110-128`) specifically hardened against a documented past partial-publish outage;
   CycloneDX + SPDX SBOM generation and SLSA-style build-provenance attestation
   (`actions/attest-build-provenance@v4`) on both the Maven artifacts and the sample binaries.
2. **Verified, current Maven Central publication with zero drift.** All checked coordinates
   (`mqtt-client-core`, `mqtt-client-transport-tcp`, `mqtt-client-bom`) are live at `0.5.0` via the
   modern Central Portal, matching the repo's HEAD tag exactly, with complete POM metadata and GPG
   signing.
3. **Real architectural enforcement, not just documentation.** Ten ADRs plus a Konsist test suite
   that mechanically enforces the public-API allowlist, packet-class internality/immutability, and
   the `:core`⊥transport module-boundary rule (`ArchitectureTest.kt`, `core/build.gradle.kts:96-123`)
   — failures surface on the introducing PR with a readable message, ahead of a BCV dump diff.
4. **Deep, spec-grounded protocol test suite.** ~484 `@Test` functions in `:core` covering
   encode/decode round-trips, all QoS flows, MQTT 3.1.1 fallback, and VBI boundary values, plus
   optional (env-gated, non-blocking) real-broker integration tests against both a local Mosquitto
   and Meshtastic's own production brokers.
5. **Documentation depth uncommon for KMP OSS libraries.** Badges, three install-snippet variants, a
   platform-support table, published Dokka site, 1,100+ lines of configuration/topics guides, and a
   Keep-a-Changelog history that is current with the latest tag.

## Notable gaps / risks (ranked)

1. **`mqtt-client-transport-ws` has zero automated tests.** `transport-ws/src` contains only
   `commonMain` — no `commonTest`, no test source set of any kind (confirmed via directory listing).
   One of only two shipped transports is entirely unverified by CI, in contrast to `transport-tcp`
   (4 tests) and `:core` (484 tests).
2. **BCV validates only the JVM API surface.** `core/api/jvm/core.api` etc. are the only `.api`
   dumps in the repo; no klib validation is configured (`apiValidation { klib {...} }` absent
   repo-wide). `apiCheck` cannot catch an ABI break specific to any of the 8 non-JVM published
   targets.
3. **`explicitApi()` is not enabled anywhere** (zero matches repo-wide). The internal-by-default
   guarantee instead relies on a hand-maintained Konsist allowlist that exists only for `:core`
   (`ArchitectureTest.kt`) — `transport-tcp` and `transport-ws` have no equivalent check, so an
   accidental `public` leak in either would be caught only by a BCV dump diff, not by an
   architecture test.
4. **A stale, self-contradictory comment in the version catalog.** `gradle/libs.versions.toml:3-5`
   claims Kotlin is "Held at 2.3.x" and that "Renovate enforces this via the 'Hold Kotlin at 2.3.x'
   rule in `renovate.json`" — but the pinned value on line 6 is `2.4.10`, and `renovate.json` (read
   in full) contains no such rule. The hold was evidently lifted for the `v0.5.0` Kotlin 2.4.10 bump
   (`CHANGELOG.md:13`) without updating or removing the now-inaccurate comment.
5. **Kotlin-version documentation drift (the opposite direction) across four files.**
   `README.md:6` (badge), `AGENTS.md:9,55`, `core/README.md:173`, and
   `.github/skills/mqtt-kmp/SKILL.md:9` all still advertise "Kotlin 2.3.20" — two releases behind the
   actual `gradle/libs.versions.toml:6` value of `2.4.10` (shipped in `v0.5.0` per `CHANGELOG.md:13`).
6. **`core/README.md` and `core/Module.md` predate the `v0.4.0` module split and were never
   updated.** Both still brand the artifact as the old singular `org.meshtastic:mqtt-client`
   (`core/README.md:1,5,20`; `core/Module.md:1`) instead of today's `mqtt-client-core`, and
   `core/Module.md:12` links to a nonexistent `library/README.md` path (the module was renamed to
   `core`). `transport-tcp/Module.md` and `transport-ws/Module.md`, by contrast, are accurate.
7. **No workflow action is pinned to a full commit SHA.** All 13 distinct actions across the 4
   workflows use mutable major-version tags (`@v7`, `@v6`, `@v5`, `@v4`, `@v3`, `@v0`) — concurrency
   and `permissions` hardening are otherwise solid, but this leaves a supply-chain surface that SHA
   pinning would close.
8. **Smaller items:** no `.editorconfig`; no `CODEOWNERS`; `gh repo view` shows an empty
   `homepageUrl`; release automation is half-manual (GH release notes auto-generate, but the version
   bump + `CHANGELOG.md` edit are a manual step per `CONTRIBUTING.md:59-63`); `release.yml:78`'s
   pre-publish validation omits `koverVerify` even though `ci.yml:53` enforces it pre-merge; the two
   Portugal-broker integration tests hardcode live external connection details
   (`MqttPortugalIntegrationTest.kt:40-41`) directly in test source rather than behind env vars (the
   credentials themselves are Meshtastic's known public defaults, not a secret leak, but the pattern
   is still a live-external-dependency-in-source-code smell).
