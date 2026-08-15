# kzstd — Meshtastic KMP Library Audit

Repo: `/Users/james/meshtastic/kzstd` (GitHub: `meshtastic/kzstd`), audited read-only.
Default branch: `master`. HEAD at audit time: `ec388b7` ("Update com.vanniktech.maven.publish to v0.37.0 (#9)").
Repo size: 26 `.kt` files, 3037 lines of Kotlin (`src/`).

**Headline finding**: the repo's own files (VERSION, gradle.properties, CHANGELOG.md) all
declare **0.1.1** as the current version — PR #11 "chore(release): prepare v0.1.1" merged to
master on 2026-07-17 — but **no `v0.1.1` git tag, no GitHub Release, and no Maven Central
publish exist for it**. The Release workflow has run exactly once, ever, for `v0.1.0`
(2026-06-18). Maven Central's `latest`/`release` for all 14 published artifacts is still
`0.1.0`. Two more commits (vanniktech 0.37.0 bump, `actions/checkout@v7` bump) have landed on
master *after* the 0.1.1 release-prep commit, so cutting `v0.1.1` today would ship undocumented
changes under that changelog entry. README's install snippet (`README.md:27`) still shows
`0.1.0`, which is at least consistent with what's actually on Central — but the task's framing
of "at v0.1.0" is the *published* truth, while the *tree* is one un-triggered release workflow
away from 0.1.1.

---

## Scorecard

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| **BUILD LOGIC** ||||
| 1 | Gradle wrapper version | 🟡 | `9.5.1` — `gradle/wrapper/gradle-wrapper.properties:3`. Siblings on 9.6.1. An **open, unmerged** Renovate branch `renovate/gradle-9.x` (commit `aac9c15`, "Update Gradle to v9.6.1", pushed 2026-07-21 — today) exists but has **no PR opened yet**. |
| 2 | Kotlin version | ✅ | `2.4.10` — `gradle/libs.versions.toml:2` |
| 3 | AGP version | N/A | No `android()` target declared anywhere in `build.gradle.kts` |
| 4 | Version catalog | ✅ | `gradle/libs.versions.toml` (23 lines: versions/libraries/plugins) |
| 5 | `build-logic` composite build | ❌ | Absent by deliberate design — `AGENTS.md:31-33`: "intentionally a single-module project... the multi-module `build-logic`/`bom` scaffolding used by larger meshtastic KMP SDKs would be over-engineering here." No `buildSrc` either. |
| 6 | KMP targets declared | ✅ (13) | `build.gradle.kts:34-68`: `jvm()`; `js{browser();nodejs()}`; `wasmJs{browser();nodejs()}`; `wasmWasi{nodejs()}`; `iosArm64()`, `iosSimulatorArm64()`, `iosX64()`, `macosArm64()`, `tvosArm64()`, `tvosSimulatorArm64()`, `linuxX64()`, `linuxArm64()`, `mingwX64()`. **No** `android`, `macosX64`, or `watchos*`. |
| 7 | Hierarchical source sets | ✅ | `applyDefaultHierarchyTemplate()` — `build.gradle.kts:70` |
| 8 | `explicitApi()` strict mode | ✅ | `build.gradle.kts:23` (no-arg = strict, not `explicitApiWarning()`) |
| 9 | JVM toolchain pinned | ✅ | `jvmToolchain(21)` — `build.gradle.kts:22` |
| 10 | Gradle caching / config cache | 🟡 | `org.gradle.caching=true`, `org.gradle.parallel=true` — `gradle.properties:2-3`. No `org.gradle.configuration-cache=true` set. |
| **PUBLISHING** ||||
| 11 | Publishing mechanism | ✅ | Vanniktech `com.vanniktech.maven.publish` v0.37.0 — `build.gradle.kts:7`, `gradle/libs.versions.toml:9,20` |
| 12 | Central Portal vs legacy OSSRH | ✅ Central Portal | `publishToMavenCentral(automaticRelease = true)` — `build.gradle.kts:108-112`; `RELEASING.md:13-14` names it "Sonatype Central Portal" explicitly (secret names retain historical `OSSRH_*` naming — `release.yml:107-108` — but the mechanism is the new Portal API). |
| 13 | GPG signing | ✅ | Conditional `signAllPublications()` gated on `signingInMemoryKey` property — `build.gradle.kts:113-115`; wired via `secrets.SIGNING_KEY` — `release.yml:73,109` |
| 14 | BOM module published | ❌ (by design) | Single-artifact project; siblings (`sdk-bom`, `mqtt-client-bom`) exist on Central but kzstd has no BOM — consistent with its single-module scope. |
| 15 | POM metadata complete | ✅ | name, description, inceptionYear, url, licenses, developers, scm all set — `build.gradle.kts:117-144` |
| 16 | Sources + Dokka/javadoc jar | ✅ | Verified live on Maven Central: `kzstd-jvm-0.1.0-sources.jar`, `kzstd-jvm-0.1.0-javadoc.jar`, and root `kzstd-0.1.0-sources.jar` / `kzstd-0.1.0-javadoc.jar` all present (checked via `repo1.maven.org` directory listing). |
| 17 | Group/artifact coordinates | ✅ | `org.meshtastic:kzstd` root + per-target (`kzstd-jvm`, `kzstd-iosarm64`, …) — `gradle.properties:10-11` |
| 18 | Version single-source-of-truth | 🟡 | `VERSION` (root file, "0.1.1") cross-checked against `gradle.properties` `VERSION_NAME` by `release.yml:29-37` ("Verify VERSION matches gradle.properties"). Two files to keep in sync by hand; `build.gradle.kts:15` also carries a hardcoded fallback default `"0.1.0"` that is now stale. |
| **API & COMPAT** ||||
| 19 | Binary Compatibility Validator | ✅ | Plugin `org.jetbrains.kotlinx.binary-compatibility-validator:0.18.1` applied (`build.gradle.kts:9`, `libs.versions.toml:8,22`); `api/kzstd.api` present and its public surface (`Zstd`, `ZstdDictionary`, `ZstdException`, `DEFAULT_LEVEL`) matches current `commonMain` sources — looks current, not stale. |
| **TESTING & COVERAGE** ||||
| 20 | Test framework(s) | ✅ | `kotlin.test` (commonTest, all targets) + JUnit 5 Jupiter (jvmTest only, `useJUnitPlatform()`) — `build.gradle.kts:78-89,100-102` |
| 21 | `commonTest` + per-target sets | 🟡 | `commonTest` (7 files), `jvmTest` (3 files), `nativeTest` (1 file, shared via hierarchy template across all 9 native targets), `wasmWasiTest` (1 file). **No dedicated `jsTest` or `wasmJsTest`** source set — those targets get only `commonTest` coverage. |
| 22 | Test count | ✅ (dense) | 12 test files, **22 `@Test` functions**, but several iterate whole corpora/every-byte/every-bit internally (e.g. `ZstdDecoderMalformedTest.bitFlipFuzzOnlyEverThrowsZstdException` flips every bit of every structured sample's compressed frame), so effective assertion count is far higher than 22. |
| 23 | Coverage tool (Kover/Jacoco) | ❌ | Not present in `libs.versions.toml` or `build.gradle.kts` |
| 24 | Coverage uploaded to CI | ❌ | No coverage tool to upload from |
| 25 | Coverage threshold enforced | ❌ | Absent |
| **CODE QUALITY TOOLING** ||||
| 26 | Formatter/linter + config | ❌ | Explicitly **not yet wired in** — `CONTRIBUTING.md:45-47`: "Static formatting/analysis (spotless + detekt, as used by larger meshtastic KMP SDKs) is not yet wired into the build... Wiring it in is a welcome contribution." No spotless/detekt/ktlint Gradle plugin anywhere. |
| 27 | `.editorconfig` present | ✅ | Root `.editorconfig`; documents intended ktlint-standard style as **IDE-honored guidance only** (not build-enforced) — `.editorconfig:16-21` |
| 28 | Pre-commit hooks / git hooks | ❌ (repo-level) | No `.pre-commit-config.yaml`, no husky/lefthook, no `core.hooksPath` override committed to the repo. (This local clone's `.git/hooks/prepare-commit-msg` is an untracked, machine-local hook — not project tooling.) |
| **CI/CD** ||||
| 29 | PR build+test workflow | ✅ | `.github/workflows/ci.yml` — push/PR to `[main, master]`; runs `./gradlew build --stacktrace` |
| 30 | Multiplatform CI matrix incl. macOS | 🟡 | `runs-on: macos-latest` on **both** workflows (`ci.yml:19`, `release.yml:20`) — real macOS runner used (needed for Apple klibs, per comment `ci.yml:16-18`), but it's a **single OS/JDK**, not a matrix. Linux/Windows native test binaries are cross-compiled but never executed (macOS host can't run them) — acknowledged in `ci.yml:33-35` and `AGENTS.md:66-69`. |
| 31 | Gradle caching in CI | ✅ | `gradle/actions/setup-gradle@v4` — `ci.yml:31`, `release.yml:46` |
| 32 | Lint/format check step in CI | ❌ | None (nothing to run — see #26) |
| 33 | API-compat check step in CI | ✅ (implicit) | `apiCheck` runs as part of `./gradlew build` (per `AGENTS.md:60`, `CONTRIBUTING.md:53`) — `ci.yml:37`, `release.yml:49` |
| 34 | Coverage step in CI | ❌ | Absent |
| 35 | Publish/release workflow | ✅ | `.github/workflows/release.yml` — triggers on `push: tags: ['v*']` + `workflow_dispatch`; builds, stages signed artifacts, attests provenance, publishes to Maven Central, creates a GitHub Release. **Not run since 2026-06-18** (v0.1.0) despite 0.1.1 being release-ready on master since 2026-07-17. |
| 36 | Release automation | 🟡 | Idempotent (`release.yml:89-102` probes `repo1.maven.org` and skips publish if the version is already there); auto-tags on `workflow_dispatch` (`release.yml:62-69`); auto-generates GH Release notes (`softprops/action-gh-release@v3`, `generate_release_notes: true`). But version bump + CHANGELOG edit are **manual** steps (`RELEASING.md` steps 1-3) — no release-please/changesets-style automation, and nothing auto-triggers the workflow when a release-prep PR merges. |
| 37 | Workflow hardening | 🟡 | `concurrency` block on both workflows (`ci.yml:9-11`, `release.yml:8-10`). `permissions:` block **only on `release.yml:12-15`** (`contents: write`, `id-token: write`, `attestations: write`) — **`ci.yml` has no explicit `permissions:` block at all** (defaults apply, undeclared). All actions pinned by **version tag** (`@v7`, `@v5`, `@v4`, `@v3`), **not by commit SHA** — no SHA-pinning anywhere in either workflow. |
| 38 | Dependency automation | ✅ | **Renovate** (`.github/renovate.json` — `config:recommended` + `group:recommended`, auto-merge minor/patch/pin/digest) is primary. **Dependabot** (`.github/dependabot.yml`) is deliberately scoped to just `npm`/`kotlin-js-store` and then fully disabled there (`open-pull-requests-limit: 0` + wildcard `ignore`) — a documented carve-out because Dependabot can't regenerate the Kotlin-plugin-owned yarn lock (`dependabot.yml:1-7`). |
| **DOCUMENTATION** ||||
| 39 | README badges | 🟡 | Maven Central, License (GPL-3.0), Kotlin Multiplatform — `README.md:3-5`. No CI/build-status badge, no coverage badge (none exists to badge). |
| 40 | README install + quick-start | 🟡 | Install snippet `README.md:25-28` (shows `0.1.0` — stale vs. tree's declared 0.1.1, though matches what Central actually has) + usage example with/without dictionary `README.md:32-45`. Content present but version is stale relative to VERSION/gradle.properties. |
| 41 | Platform-support table | 🟡 | `README.md:19-21` lists targets as a prose bullet line ("JVM · JS (browser + Node) · Wasm/JS · Wasm/WASI · and nine Kotlin/Native targets: …"), not a structured markdown table. |
| 42 | API docs site (Dokka) published | ❌ | Dokka only produces the javadoc jar bundled into the Central publication (confirmed present, see #16); no GitHub Pages workflow, no `gh-pages` branch, no hosted HTML docs site. |
| 43 | KDoc coverage on public API | ✅ (~100%, prose-style) | Spot-checked all 3 public files: `Zstd.kt:7-23` (object), `:26-32` (`DEFAULT_LEVEL`), `:35,42,47-50,57` (all 4 compress/decompress overloads) all documented; `ZstdDictionary.kt:7-23` (class), `:47` (`EMPTY`) documented; `ZstdException.kt:4-13` (class) documented. Style is prose with `[links]`, not formal `@param`/`@return` tags, but coverage is complete. |
| 44 | CHANGELOG present + maintained | ✅ | `CHANGELOG.md` — Keep a Changelog format + SemVer, per-version Added/Changed/Security/Notes sections, compare links (57 lines). Well-maintained in content, but see headline finding: describes an 0.1.1 that isn't actually tagged/published, and is already missing 2 subsequent master commits. |
| 45 | Samples / examples module | ❌ | None found |
| 46 | Module-level docs (`Module.md`) | ❌ | None found |
| **ORG ALIGNMENT** ||||
| 47 | LICENSE | ✅ | GPL-3.0 (full GPLv3 text) — `LICENSE`; `GPL-3.0-only` SPDX header on every source file (e.g. `Zstd.kt:1`) |
| 48 | CONTRIBUTING + CODE_OF_CONDUCT | ✅ | `CONTRIBUTING.md` (76 lines: DCO sign-off flow, build/test command table, public-API-change process); `CODE_OF_CONDUCT.md` (links Meshtastic org CoC + Contributor Covenant 2.1) |
| 49 | Issue + PR templates | ❌ | No `.github/ISSUE_TEMPLATE/`, no `PULL_REQUEST_TEMPLATE.md` |
| 50 | CODEOWNERS | 🟡 | Present (`CODEOWNERS`), routes catch-all + `/src/commonMain/`, `/api/`, build/CI paths, `/SECURITY.md` — **all to one individual**, `@jamesarich`, with an explicit self-noted bus-factor comment: "Pre-team phase: individual handles. Replace with `@meshtastic/*` teams once they exist." (`CODEOWNERS:2`) |
| 51 | SECURITY.md | ✅ | Reporting via private GHSA or email; 5-business-day ack / 90-day fix SLA; explicit in-scope (decoder memory-safety on untrusted input, `maxSize` bomb guard, build/release infra) and out-of-scope (RFC 8878 itself, consumer's post-decompress handling) |
| 52 | Default branch | ✅ | `master` (via `gh repo view --json defaultBranchRef`); CI targets `[main, master]` — belt-and-suspenders since only `master` exists |
| 53 | Repo description/topics/homepage | 🟡 | Description set; 13 topics set (`codec, compression, decompression, dictionary-compression, kmp, kotlin, kotlin-multiplatform, kotlin-native, meshtastic, multiplatform, pure-kotlin, zstandard, zstd`); **`homepageUrl` is empty** |
| 54 | Consistent group id + naming | ✅ | `org.meshtastic:kzstd` (+ per-target artifacts) matches sibling orgs' `org.meshtastic:sdk-*`, `mqtt-client-*`, `protobufs-*`, `takpacket-sdk-*` seen live on Maven Central |

---

## Detailed findings

### Build logic

Single-module project — everything lives in one root `build.gradle.kts` (160 lines) plus
`settings.gradle.kts` (9 lines, just `rootProject.name = "kzstd"` and plugin-management
repositories — no `dependencyResolutionManagement`, no `pluginManagement` version pins beyond
what the version catalog supplies). No `build-logic/`, no `buildSrc/`. This is a deliberate,
documented choice (`AGENTS.md:31-33`) appropriate to the codebase's size (26 files, ~3k LOC).

Targets (`build.gradle.kts:34-68`): `jvm()`; `js { browser(); nodejs() }`; `wasmJs { browser();
nodejs() }` (`@OptIn(ExperimentalWasmDsl::class)`); `wasmWasi { nodejs() }`; then nine native
targets — `iosArm64()`, `iosSimulatorArm64()`, `iosX64()`, `macosArm64()`, `tvosArm64()`,
`tvosSimulatorArm64()`, `linuxX64()`, `linuxArm64()`, `mingwX64()`. That's 13 targets, matching
both the README (`README.md:19-21`) and CHANGELOG (`CHANGELOG.md:41-43`) claims. Notably absent:
`android()`, `macosX64()` (Intel Mac), and all `watchos*` targets — reasonable exclusions for a
codec with no Android-specific need and shrinking Intel-Mac/watchOS relevance, but worth naming
explicitly since the rubric asks for the full possible list.
`applyDefaultHierarchyTemplate()` (`:70`) is called after all targets are declared, giving the
standard `nativeMain`/`nativeTest` intermediate source sets; the codec itself lives entirely in
`commonMain` with no `expect`/`actual` at all (confirmed by the comment at `build.gradle.kts:29`
and by there being a single `commonMain` source directory with no target-specific main sources).

Compiler options (`build.gradle.kts:25-32`): `allWarningsAsErrors.set(true)` and
`progressiveMode.set(true)` — stricter than the rubric asks for, worth calling out as a strength.
Reproducible-build settings are also applied to every archive task
(`isReproducibleFileOrder`/`isPreserveFileTimestamps` — `:95-98`), a supply-chain-hygiene detail
many larger projects skip.

`gradle.properties` (`:1-13`) sets `org.gradle.jvmargs`, `org.gradle.caching=true`,
`org.gradle.parallel=true`, and two Dokka V2 opt-in flags — but no
`org.gradle.configuration-cache=true`.

The Gradle wrapper is `9.5.1` (`gradle/wrapper/gradle-wrapper.properties:3`), one minor behind
sibling repos' `9.6.1`. This isn't neglect: a Renovate branch `renovate/gradle-9.x` already
exists with the bump commit (`aac9c15`, "Update Gradle to v9.6.1", authored today, 2026-07-21),
just not yet opened as a PR — an in-flight, not-yet-actioned update.

### Publishing

Vanniktech `maven-publish` 0.37.0 (`gradle/libs.versions.toml:9,20`) drives publishing via
`mavenPublishing { publishToMavenCentral(automaticRelease = true); ... }`
(`build.gradle.kts:108-145`). `automaticRelease = true` means a successful Central Portal upload
is released automatically rather than sitting for manual approval. Signing
(`signAllPublications()`) is conditional on the `signingInMemoryKey` Gradle property being
present (`:113-115`), which only exists in CI via `ORG_GRADLE_PROJECT_signingInMemoryKey:
${{ secrets.SIGNING_KEY }}` (`release.yml:73,109`) — so local/PR builds never attempt signing,
which is correct.

The POM block (`:117-144`) sets `name`, `description`, `inceptionYear`, `url`, one GPL-3.0
`license`, one `developer` (id `meshtastic`), and full `scm` (url/connection/developerConnection)
— complete by the rubric's checklist.

JitPack (`jitpack.yml`) is a documented fallback channel, JVM-only
(`com.github.meshtastic:kzstd:<tag>`), built via `publishToMavenLocal --no-daemon`
(`jitpack.yml:8-15`) — explicitly secondary to Maven Central per its own comment header.

**Verified against live Maven Central** (`repo1.maven.org/maven2/org/meshtastic/`, fetched via
`curl` after `WebFetch` 403'd on that host):
- 14 kzstd artifacts published: `kzstd` (root KMP metadata module),
  `kzstd-jvm`, `kzstd-js`, `kzstd-wasm-js`, `kzstd-wasm-wasi`, `kzstd-iosarm64`,
  `kzstd-iossimulatorarm64`, `kzstd-iosx64`, `kzstd-macosarm64`, `kzstd-tvosarm64`,
  `kzstd-tvossimulatorarm64`, `kzstd-linuxx64`, `kzstd-linuxarm64`, `kzstd-mingwx64` — i.e. every
  declared target plus the root module actually made it to Central. **All at `0.1.0` only**
  (`maven-metadata.xml` for `kzstd-jvm` and `kzstd-iosarm64` both show
  `<latest>0.1.0</latest><release>0.1.0</release>` with a single `<version>0.1.0</version>`).
- Full artifact set present per module (jar/klib, `-sources.jar`, `-javadoc.jar`, `.module`,
  `.pom`, each with `.asc` GPG signature + md5/sha1/sha256/sha512 checksums) — publishing
  mechanics look complete and correctly signed for what *has* shipped.
- No `0.1.1` anywhere on Central, confirming the headline finding: 0.1.1 is fully staged in the
  tree (VERSION, gradle.properties, CHANGELOG) but never released.

Sibling org modules also visible in the same `org/meshtastic/` listing for context:
`mqtt-client*` (with a `mqtt-client-bom`), `protobufs*`, `sdk-*` (with `sdk-bom`),
`takpacket-sdk*`, and an unrelated `flatpak/` entry — confirms `org.meshtastic:kzstd` coordinate
naming is consistent with the rest of the org, and confirms kzstd is the only one of these
without a BOM (appropriate given it's single-artifact).

### API & compatibility

`api/kzstd.api` (24 lines) declares exactly the public surface visible in `commonMain`: `Zstd`
(object, `DEFAULT_LEVEL`, two `compress` overloads + synthetic default-arg bridges, two
`decompress` overloads), `ZstdDictionary` (class + `Companion.EMPTY`), `ZstdException` (extends
`RuntimeException`). This matches `Zstd.kt`, `ZstdDictionary.kt`, `ZstdException.kt` read in
full — the dump looks current, not stale. `CONTRIBUTING.md:49-55` documents the
`apiDump`/`apiCheck` workflow correctly and warns against hand-editing the `.api` file.

### Testing

Layout: `commonTest` (7 files: `TestVectors.kt` fixture object + 6 test classes),
`jvmTest` (3 files), `nativeTest` (1 file, shared across all 9 native targets via the hierarchy
template), `wasmWasiTest` (1 file). No `jsTest`/`wasmJsTest` — those two targets run only what
`commonTest` gives them.

What's actually tested (this is a well-designed suite for the codec's risk profile):
- **Round-trip self-consistency**: `ZstdRoundTripTest` (commonTest, all targets) — compress→
  decompress over a corpus (structured JSON records + edge cases: empty, 1/2/3/4-byte inputs,
  a 5000-byte repetitive run, a Lorem-ipsum repeat, 2000 bytes of deterministic pseudo-random/
  near-incompressible data), with a trained dict, the empty dict, and dict-less overloads; also
  a dictionary-instance-reuse stress loop (50× over the corpus).
- **Real-libzstd interop oracle, both directions, JVM only**:
  `KzstdLibzstdInteropTest` (`src/jvmTest/.../KzstdLibzstdInteropTest.kt`) cross-checks kzstd
  frames decode under `zstd-jni` (real libzstd) and vice versa, with and without a dictionary,
  plus a guard (`libzstdActuallyEmitsTreelessDictFrames`) that asserts the interop fixture still
  exercises the dictionary-Huffman ("treeless literals") decode path rather than silently
  degrading to a no-op. `zstd-jni` (`libs.versions.toml:6`) is correctly scoped as
  `jvmTest`-only (`build.gradle.kts:88`), never a runtime dependency — verified structurally, not
  just by comment.
- **One pinned cross-target reference frame**: `DictEntropyDecodeTest` decodes a single
  real-libzstd-produced, dictionary-Huffman ("treeless") frame captured as a hex literal
  (`TestVectors.kt:156-163`) **on every target**, including native/JS/Wasm where the live
  `zstd-jni` oracle can't run. This is the only genuinely external/independently-produced
  reference vector exercised outside the JVM.
- **Byte-identical drift guard** (JVM): `ByteIdenticalRegressionTest` pins exact hex output for
  4 fixed inputs — explicitly a drift tripwire, not a correctness proof (its own doc comment
  says so, `:8-17`).
- **Adversarial/malformed-input hardening**: `ZstdDecoderMalformedTest` — bad magic, reserved
  block type, **truncation at every length** of every structured sample's compressed frame, and
  **bit-flip fuzzing of every bit of every byte** of every structured sample's frame — all
  asserted to surface only as `ZstdException`, never a raw exception/hang.
  `DictEntropyGuardTest` separately guards that the committed test dictionary is genuinely a
  *trained* dict (correct magic) so the entropy-decode paths don't silently go untested.
- **Concurrency**: `ConcurrencyTest` (JVM, 8-thread pool × 64 tasks × 50 iterations sharing one
  `ZstdDictionary`) and `NativeConcurrencyTest` (Kotlin/Native `Worker` API, 4 workers) both
  regression-protect the "no lock needed" immutability design invariant from `AGENTS.md:45-47`.
- **Block-size boundary**: `EncoderBlockLimitTest` — exactly-128-KiB accepted, 128 KiB + 1
  rejected with `ZstdException` (guards the documented single-block limitation).
- **Decompression-bomb guard**: `MaxSizeGuardTest` — a tiny frame that would expand to 4000
  bytes is rejected under a 1024-byte cap, accepted under 8192.

**Gap relative to the rubric's specific ask** ("tested against reference zstd vectors"): kzstd
does **not** use the official upstream zstd project's own test-vector/conformance corpus (e.g.
`facebook/zstd`'s test data). Its correctness strategy is a live oracle (`zstd-jni`) plus one
committed reference frame, and the live oracle only runs where a JVM is available. So
non-JVM targets' assurance against *real* libzstd-produced input rests on exactly one pinned
frame (`treelessDictFrame`) — everything else on those targets is self-consistency (kzstd
encoding, kzstd decoding its own output). This is a deliberate, well-reasoned, and clearly
documented trade-off (see the doc comments in `DictEntropyDecodeTest.kt:9-17` and
`KzstdLibzstdInteropTest.kt:11-22`), not an oversight — but it is a real cross-platform
correctness-verification gap worth naming.

No Kover/Jacoco anywhere — no line/branch coverage number can be reported; "unknown" by the
rubric's own standard (nothing to check further, tool absent).

### Code quality tooling

No spotless/detekt/ktlint plugin. This is explicitly acknowledged, not hidden:
`CONTRIBUTING.md:45-47` calls it out as a known gap and invites a contribution to close it.
`.editorconfig` (38 lines) encodes the *intended* ktlint-standard style (4-space indent, 120
max line length, trailing commas allowed, no-wildcard-imports) for IDEs to honor, but nothing
in the Gradle build enforces it — so style drift would not currently fail CI.

No pre-commit-hook framework versioned in the repo.

### CI/CD

Two workflows only, as flagged by the task:

1. **`ci.yml`** (37 lines) — `push`/`pull_request` to `[main, master]`; single job on
   `macos-latest`; `actions/checkout@v7` → `actions/setup-java@v5` (Temurin 21) →
   `gradle/actions/setup-gradle@v4` → `./gradlew build --stacktrace`. Comment
   (`:16-18`) correctly explains macOS is required to cross-compile the Apple klibs. No
   `permissions:` block. No lint/coverage steps (none exist to run).
2. **`release.yml`** (127 lines) — `push: tags: ['v*']` + `workflow_dispatch`; reads `VERSION`,
   cross-checks it against `gradle.properties` `VERSION_NAME` and fails loudly on mismatch
   (`:29-37`); builds+tests+`apiCheck` via `./gradlew build`; on `workflow_dispatch` (not on tag
   push) auto-tags and pushes `vX.Y.Z` if it doesn't already exist (`:62-69`); stages a signed
   local Maven publish, collects jar/klib/pom/module artifacts, and attests build provenance via
   `actions/attest-build-provenance@v4`; probes `repo1.maven.org` for the version and skips
   publish if already there (idempotent retry safety, `:89-102`); publishes to Maven Central;
   creates a GitHub Release with `generate_release_notes: true`
   (`softprops/action-gh-release@v3`). `permissions:` set narrowly
   (`contents: write, id-token: write, attestations: write`, `:12-15`).

Missing entirely from CI: no OS/JDK matrix (single `macos-latest` runner in both), no
`gradle/wrapper-validation-action` (or equivalent) step to verify the wrapper jar's checksum, no
dependency-review/CodeQL/OSV-scanner workflow, no SHA-pinning of any `uses:` action (all are
mutable version tags: `@v7`, `@v5`, `@v4`, `@v3`), no lint step, no coverage step. `ci.yml`
itself has no `permissions:` block at all (only `release.yml` does).

Dependency automation is real and active: Renovate (`config:recommended` + `group:recommended`,
auto-merge on minor/patch/pin/digest, dependency dashboard enabled) has been merging PRs steadily
(#5–#10 all Renovate/fix-branch merges within the last few days per `git log`/`gh pr list`), and
correctly hands off the one thing it can't manage (the Kotlin-plugin-owned
`kotlin-js-store/yarn.lock`) to a narrowly-scoped, self-disabling Dependabot config plus manual
`resolution()` pins in `build.gradle.kts:152-159` for known CVEs in the JS test-harness
toolchain (ws, serialize-javascript, webpack, diff) — a genuinely well-thought-out piece of
dependency hygiene for a KMP project's JS test tooling.

### Documentation

`README.md` (100 lines): title + 3 badges, one-paragraph pitch (notes it was extracted from
`TAKPacket-SDK`, replacing three separate native binding stacks), a "Targets" line (not a table),
"Install" (Maven Central snippet, version `0.1.0`), "Usage" (dictionary and non-dictionary
examples with brief inline explanation of `ZstdDictionary`/`maxSize`/exception model),
"Deviations and current limits" (no streaming, `level` is a no-op, 128 KiB single-block cap —
matches what the tests actually enforce), "Interoperability", "Building & testing", "Contributing"
(points to `CLAUDE.md`/`CHANGELOG.md`), "License". Solid and honest about limitations, but the
install version is stale and there's no platform-support table nor a build/CI badge.

`CHANGELOG.md` (57 lines) is genuinely well-maintained in *content* — Keep a Changelog format,
SemVer statement, dated version sections with Added/Changed/Security/Notes subsections and
compare-link footnotes — undermined only by the release-process gap already covered (the 0.1.1
section describes a release that was never cut, and is already missing two subsequent commits).

`AGENTS.md` (84 lines, canonical; `CLAUDE.md` and `GEMINI.md` are both 3-line pointers to it) is
an unusually good agent/contributor-facing document: it names concrete design invariants ("do not
violate") with rationale for each (one-shot only, one-block limit, no shared mutable state/lock,
required `maxSize` guard, single `ZstdException` type, `apiDump` discipline, libzstd
interoperability guarded by specific tests) and gives exact commands. This reads as unusually
mature process documentation for a repo this small.

No Dokka HTML site is published anywhere (no GH Pages workflow/branch) — Dokka's only visible
output is the javadoc jar bundled into the Central publication. No `Module.md`/package-level
docs, no samples/examples module.

### Org alignment

Community-health files are unusually complete for the repo's size: `LICENSE` (GPL-3.0 full text),
`CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODEOWNERS` are all present and
substantive (not stubs). The one structural gap is GitHub-native issue/PR templates (absent) and
CODEOWNERS routing everything to a single person (`@jamesarich`) — self-acknowledged as a
pre-team-phase placeholder in the file's own header comment.

Repo metadata (`gh repo view`): description is set and matches the POM description almost
verbatim; 13 topics are set (good discoverability); `homepageUrl` is empty (a candidate to point
at `https://meshtastic.org` or a future Dokka docs site); default branch is `master`; license
detected by GitHub as `gpl-3.0`. No branch protection configured on `master`
(`gh api .../branches/master/protection` → 404 "Branch not protected") — not in the rubric's
explicit checklist but worth noting alongside CODEOWNERS/bus-factor.

---

## Top 5 strengths

1. **Correctness-testing design is unusually sophisticated for the codebase's size**: a live
   bidirectional `zstd-jni` (real libzstd) oracle, a pinned cross-target reference frame for the
   dictionary-entropy decode path, byte-identical drift pinning, exhaustive truncation and
   bit-flip fuzzing over every byte/bit of every sample, and both JVM- and Native-specific
   concurrency stress tests for the "immutable, lock-free, thread-shareable dictionary" invariant.
2. **Genuinely zero runtime dependencies, verified structurally**: `zstd-jni` is correctly scoped
   to `jvmTest` only (`build.gradle.kts:88`); the pure-Kotlin codec compiles identically into all
   13 targets from a single `commonMain` with no `expect`/`actual`.
3. **Publishing mechanics are complete and were verified live**: Vanniktech + Central Portal +
   conditional GPG signing + complete POM + build-provenance attestation, and all 14 expected
   artifacts (root + 13 targets) with sources/javadoc/checksums/signatures are actually present
   on Maven Central for the version that has shipped.
4. **Dependency hygiene is mature and self-documenting**: Renovate handles everything except a
   narrow, correctly-carved-out Dependabot stub for the Kotlin-plugin-owned yarn lock, backed by
   explicit CVE-floor `resolution()` pins with inline rationale.
5. **Process documentation (`AGENTS.md`) states concrete, falsifiable design invariants** (one-shot
   API, one-block limit, no-lock immutability, mandatory `maxSize` guard, single exception type,
   `apiDump` discipline) rather than vague guidance — unusually actionable for a repo this size.

## Top 8 gaps

1. **Un-triggered release**: `VERSION`/`gradle.properties`/`CHANGELOG.md` all declare `0.1.1`
   (merged to master 2026-07-17), but there is no `v0.1.1` tag, no GitHub Release, and nothing
   published to Maven Central for it — the release workflow hasn't run since `v0.1.0`
   (2026-06-18), and 2 more commits have landed on master since the 0.1.1 release-prep PR.
2. **No coverage tooling at all** (Kover/Jacoco absent) — no line/branch number obtainable, no
   threshold enforceable, nothing to upload to CI.
3. **No formatter/linter wired into the build** (spotless/detekt/ktlint) — `.editorconfig` states
   intent only; explicitly flagged as not-yet-done in `CONTRIBUTING.md` itself.
4. **Cross-platform correctness assurance against *real* libzstd output is thin outside the JVM**:
   the live bidirectional oracle only runs where `zstd-jni` is available (JVM); native/JS/Wasm
   targets get exactly one pinned reference frame plus self-consistency round-trips — no broader
   independently-produced reference-vector corpus reaches those targets.
5. **CI is a single macOS runner with no matrix** — no Linux/Windows execution of the native test
   binaries that are cross-compiled there (acknowledged in-repo, but still a real gap), no JDK
   matrix, no wrapper-validation step, no SHA-pinned actions (all mutable version tags), and
   `ci.yml` has no `permissions:` block at all.
6. **Gradle wrapper one minor behind** (9.5.1 vs. siblings' 9.6.1) — already caught by an
   unopened Renovate branch (`renovate/gradle-9.x`, pushed today) but not yet actioned; no
   `distributionSha256Sum` pinned in `gradle-wrapper.properties` for wrapper-jar integrity.
7. **Documentation staleness/format gaps**: README install snippet shows `0.1.0` (stale vs. the
   tree's declared 0.1.1); no platform-support table (prose list instead); no CI/coverage README
   badges; no published Dokka HTML site (javadoc jar only); no samples module; no `Module.md`.
8. **Org/process bus-factor**: CODEOWNERS routes 100% of paths to one individual (self-flagged as
   a placeholder); no issue/PR templates; no branch protection on `master`; repo `homepageUrl`
   unset.
