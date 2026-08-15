# KMP Library Audit — meshtastic/TAKPacket-SDK

Audited path: `/Users/james/meshtastic/takpacket-sdk` (GitHub `meshtastic/TAKPacket-SDK`, default branch `master`, HEAD `36d58e0` "release: bump version to 0.8.0 (#107)").
Audit date: 2026-07-21. Method: static, read-only inspection of the working tree + `gh`/`gh api` + a handful of read-only `curl` GETs against `repo1.maven.org` (no builds executed).

## 0. Repo layout — where the Gradle root actually is

The Gradle wrapper is **not** at the repo root. This is a **polyglot monorepo**: one shared protobuf schema + shared test fixtures, consumed by **5 independent per-language SDK packages**, one of which (Kotlin) happens to be a full Kotlin Multiplatform module. There is no "KMP core *plus* 5 bindings" — **Kotlin/KMP is itself one of the five**, designated the *canonical* one (it generates the cross-language golden fixtures; the other four validate against them).

```
takpacket-sdk/
├── kotlin/          ← THE GRADLE ROOT (settings.gradle.kts here). Single-module KMP project,
│                       artifact org.meshtastic:takpacket-sdk (+ 13 per-target variants incl. takpacket-sdk-jvm)
├── swift/           Swift Package (SwiftPM), consumed via remote SPM URL / source zip release asset
├── python/          Python package (pyproject.toml), → PyPI-style wheel/sdist (not shown published to PyPI itself)
├── typescript/      npm package (package.json), → npm tarball as a release asset
├── csharp/          .NET 9 library (.csproj), → NuGet package as a release asset
├── protobufs/       git submodule (meshtastic/protobufs) — schema source of truth (atak.proto)
├── testdata/        47 shared CoT XML fixtures + golden .pb/.bin + sanitizer fixtures (cross-binding contract)
├── dictionaries/    2 canonical zstd dictionaries (512KB non-aircraft, 4KB aircraft), embedded per binding
├── docs/index.html  Landing page for the unified GH Pages doc site (Dokka+DocC+TypeDoc+pdoc+DocFX)
├── .github/         workflows (ci, release, docs, bump-version), renovate.json, copilot-instructions.md
├── VERSION          single cross-language version string (0.8.0), fanned out by scripts/bump-version.sh
├── CONTRIBUTING.md, CLAUDE.md, WIRE_FORMAT.md, TESTING_PUNCHLIST.md, jitpack.yml
└── build.sh         orchestrates "build/test all 5 bindings" from the repo root
```

Only the Kotlin module is a Gradle/KMP project; Swift/Python/TypeScript/C# each use their native ecosystem tooling. **This audit's KMP-specific rows (build logic, targets, BCV, Dokka, etc.) apply only to `kotlin/`.** CI/release/docs/org-alignment rows apply repo-wide since they're shared infrastructure.

---

## 1. Scorecard

| # | Criterion | Status | Evidence (path / value) |
|---|-----------|--------|-------------------------|
| **BUILD LOGIC** |
| 1 | Gradle wrapper version | ✅ Present | `9.6.1` — `kotlin/gradle/wrapper/gradle-wrapper.properties:3` (`gradle-9.6.1-bin.zip`) |
| 2 | Kotlin version | ✅ Present | `2.4.10` — `kotlin/gradle/libs.versions.toml:2` |
| 3 | AGP version | N/A | No Android Gradle Plugin anywhere in `kotlin/`; no `com.android.*` plugin applied. Android consumers pull the plain `-jvm` artifact rather than an in-repo Android library target. |
| 4 | Version catalog `gradle/libs.versions.toml` | ✅ Present | `kotlin/gradle/libs.versions.toml` (9 versions, 4 libraries, 4 plugins) |
| 5 | Convention plugins via `build-logic` composite build | ❌ Absent | No `build-logic/`, no `buildSrc/`. Single-module project (one `build.gradle.kts`), so there's nothing to share convention plugins across — but also no scaffolding for if/when it grows. |
| 6 | KMP targets declared | ✅ Present | **13 targets**: `jvm()`, `js{browser();nodejs()}`, `wasmJs{browser();nodejs()}`, `wasmWasi{nodejs()}`, `iosArm64()`, `iosSimulatorArm64()`, `iosX64()`, `macosArm64()`, `tvosArm64()`, `tvosSimulatorArm64()`, `linuxX64()`, `linuxArm64()`, `mingwX64()` — `kotlin/build.gradle.kts:43-78`. Notably **no `macosX64`** (Intel Mac) and **no watchOS**. All 13 confirmed actually published on Maven Central (see §5). |
| 7 | Hierarchical source sets / `applyDefaultHierarchyTemplate` | 🟡 Partial | `applyDefaultHierarchyTemplate()` called — `kotlin/build.gradle.kts:80` — but **moot**: `grep` for `expect`/`actual` across `src/commonMain` returns zero hits, and the only per-target `Main` dir is `src/jvmMain/resources` (dictionary binary resources only, no Kotlin code). 100% of implementation code lives in `commonMain`; the intermediate hierarchy source sets (`nativeMain`, `appleMain`, etc.) exist structurally but are currently empty. This is a deliberate consequence of extracting the platform-divergent zstd codec into the separate `kzstd` library (see CLAUDE.md "Kotlin is canonical" section). |
| 8 | `explicitApi()` strict mode enabled | ✅ Present | `kotlin/build.gradle.kts:27` |
| 9 | JVM toolchain pinned (`jvmToolchain(N)`) | ✅ Present | `jvmToolchain(21)` — `kotlin/build.gradle.kts:26` |
| 10 | Gradle configuration cache / caching in gradle.properties | 🟡 Partial | `org.gradle.caching=true`, `org.gradle.parallel=true` — `kotlin/gradle.properties:2-3`. **No** `org.gradle.configuration-cache=true` anywhere. |
| **PUBLISHING** |
| 11 | Publishing mechanism | ✅ Present | Vanniktech `com.vanniktech.maven.publish` **0.37.0** — `kotlin/gradle/libs.versions.toml:8`, applied `kotlin/build.gradle.kts:10`, configured `:395-438` |
| 12 | Central Portal vs legacy OSSRH | ✅ Central Portal | `publishToMavenCentral(automaticRelease = true)` — `kotlin/build.gradle.kts:408` — this is vanniktech 0.37's Central-Portal-only API (no `SonatypeHost` argument exists any more; OSSRH's legacy Nexus UI was sunsetted). Note: the GitHub Actions **secret names** are still `OSSRH_USERNAME`/`OSSRH_PASSWORD` (legacy branding — `.github/workflows/release.yml:207-208`) even though they're wired to `mavenCentralUsername`/`mavenCentralPassword`, i.e. Central Portal user-token credentials, not old OSSRH Nexus creds. |
| 13 | GPG signing configured | ✅ Present | Conditional `signAllPublications()` when `signingInMemoryKey` gradle property present — `kotlin/build.gradle.kts:409-411`; wired from `secrets.SIGNING_KEY` in both `ci.yml:126` (snapshots) and `release.yml:167,209`. **Verified live**: every artifact on Maven Central for v0.8.0 has a matching `.asc` signature file (confirmed via `repo1.maven.org` listing, §5). |
| 14 | BOM module published | ❌ Absent | No `takpacket-sdk-bom` on Maven Central (checked the full `org/meshtastic/` index — a `sdk-bom` exists but belongs to a *different* Meshtastic library, not this one). Gradle Module Metadata on the root `takpacket-sdk` coordinate does let Gradle consumers auto-resolve the right per-target variant, which covers part of what a BOM is for, but non-Gradle/Android consumers must hand-pick `-jvm` explicitly (documented in `kotlin/README.md:25-27`). |
| 15 | POM metadata complete | ✅ Present | `name`, `description`, `inceptionYear`, `url`, `licenses` (GPL-3.0), `developers` (org-level `id=meshtastic`, not per-person), `scm` (url/connection/developerConnection) — all set, `kotlin/build.gradle.kts:413-437` |
| 16 | Sources jar + Dokka/javadoc jar attached | ✅ Present | `configure(KotlinMultiplatform(javadocJar = JavadocJar.Dokka("dokkaGeneratePublicationHtml")))` — `kotlin/build.gradle.kts:400` (sourcesJar is a vanniktech default, confirmed live). **Verified live** on Maven Central 0.8.0: `takpacket-sdk-jvm-0.8.0-sources.jar` and `-javadoc.jar` both present (§5). |
| 17 | Group/artifact coordinates | ✅ Present | `org.meshtastic` / root artifact `takpacket-sdk` (`GROUP`/`POM_ARTIFACT_ID` in `kotlin/gradle.properties:10-11`), Android/JVM consumers use `org.meshtastic:takpacket-sdk-jvm` |
| 18 | Version single-source-of-truth | ✅ Present (cross-language) | Root `VERSION` file is the ultimate SSOT; `kotlin/gradle.properties:12` (`VERSION_NAME=0.8.0`) is the Kotlin-specific mirror, read by `build.gradle.kts:16`. Propagation + drift-detection is automated: `scripts/bump-version.sh` stamps all 5 language-specific version fields from one CLI arg, and `release.yml:32-73` ("Verify version sources agree") hard-fails the release if any of the 5 disagree. This is a notably more rigorous SSOT story than a typical single-language repo needs. |
| **API & COMPAT** |
| 19 | Binary Compatibility Validator | 🟡 Partial | Plugin applied: `org.jetbrains.kotlinx.binary-compatibility-validator` 0.18.1 (`kotlin/build.gradle.kts:12`, `libs.versions.toml:7`); `ignoredPackages.add("org.meshtastic.proto")` configured (`:144-146`). One dump file checked in: `kotlin/api/takpacket-sdk.api` (891 lines, JVM-descriptor format — `public final class org/meshtastic/tak/...`). **However**: this file is the classic **JVM-only** BCV dump format; there is no separate klib ABI dump (`.klib.api` / `// Klib ABI Dump` header) anywhere in the repo despite a code comment claiming "the klib `.api` baseline lives in api/ alongside the JVM one" (`build.gradle.kts:148-153`) — `find . -iname "*klib*"` returns nothing. So the 12 non-JVM targets' public API surface has **no committed compatibility baseline**, only the JVM one. **More importantly: `apiCheck` is never invoked in any CI workflow** (`grep -rn "apiCheck" .github` → no hits) — so even the JVM `.api` dump isn't verified as current on every PR; it can silently drift until someone runs `./gradlew apiDump` locally. |
| **TESTING & COVERAGE** |
| 20 | Test framework(s) | ✅ Present | `kotlin.test` in `commonTest` (`build.gradle.kts:100`); JUnit Jupiter 6.1.2 + junit-platform-launcher in `jvmTest` (`:103-105`, `useJUnitPlatform()` at `:163`) |
| 21 | `commonTest` present + per-target test source sets | 🟡 Partial | `commonTest` ✅ (4 files: `GoldenDecodeCommonTest`, `LoggerCommonTest`, `ResilienceCommonTest`, `RoundTripCommonTest`, runs on all 13 targets via hierarchy). `jvmTest` ✅ (8 files, the heavy suite). `wasmWasiTest` ✅ (1 file, `WasmWasiCodecTest`, 3 tests). **No dedicated test source set for the other 11 targets** (js, wasmJs, and all 9 native) — they get `commonTest` only, by inheritance, and (see CI row 30) CI never actually *executes* tests for them, only `jvmTest`. |
| 22 | Rough test count | ✅ Present | **95 `@Test`-annotated functions** total across 14 test files: `jvmTest` 80 (`RoundTripTest` 39, `MalformedInputTest` 16, `CotTypeMapperTest` 9, `CompressionTest` 8, `ResilienceTest` 4, `CotMeshSanitizerTest` 2, `CompatibilityTest` 1, `DictionaryTrainingTest` 1), `commonTest` 12 (`ResilienceCommonTest` 5, `LoggerCommonTest` 3, `GoldenDecodeCommonTest` 3, `RoundTripCommonTest` 1), `wasmWasiTest` 3. The 80-JVM-only figure exactly matches the root README's claimed "Kotlin | ✅ 80" (`README.md:855`), corroborating both. Per README, parametrization expands these to **315 executed test cases** on the JVM suite. |
| 23 | Coverage tool (Kover / Jacoco) | ❌ Absent | No `kover` or `jacoco` string anywhere in `kotlin/` (`.kts`/`.toml`) or `.github/`. |
| 24 | Coverage uploaded to Codecov/other in CI | ❌ Absent | No coverage step in `ci.yml` or `release.yml`; no Codecov config file in the repo. |
| 25 | Coverage threshold/verification enforced | ❌ Absent | Follows directly from 23/24 — nothing to enforce. |
| **CODE QUALITY TOOLING** |
| 26 | Formatter/linter (spotless / ktlint / detekt) + config | ❌ Absent | Zero hits for `ktlint`/`detekt`/`spotless` anywhere in the repo (`.kts`, `.toml`, `.json`, `.yml`). `.github/copilot-instructions.md:105-111` documents a **manual** style policy ("Kotlin: standard Kotlin conventions, 4-space indent") but nothing enforces it — no plugin, no CI step, no pre-commit hook. |
| 27 | `.editorconfig` present | ✅ Present | `kotlin/.editorconfig` — sets charset/EOL/indent per-filetype; explicitly turns `max_line_length = off` for `*.kt`/`*.kts` |
| 28 | Pre-commit hooks / git hooks | ❌ Absent | No `.pre-commit-config.yaml`, `.husky/`, `lefthook.yml`, or `.githooks/` anywhere in the tree. |
| **CI/CD (GitHub Actions)** |
| 29 | PR build+test workflow | ✅ Present | `.github/workflows/ci.yml` — triggers on `pull_request`/`push` to `main`/`master` (`:3-7`); `kotlin` job runs `gradle jvmTest --quiet` (`:31`) |
| 30 | Multiplatform CI matrix incl. macOS runner for apple targets | ❌ Absent (for the Kotlin job specifically) | The `kotlin` CI job runs on `ubuntu-latest` (`ci.yml:16`) and only runs `jvmTest` — **the 9 Apple/native/JS/Wasm targets are never compiled or tested on any per-PR CI run.** The two `macos-latest` runners in this repo are the `swift` job (tests the separate Swift binding, not Kotlin) and `publish-snapshot` (`ci.yml:101`, master-push only), which *compiles* all 13 KMP variants as a side effect of `publishAllPublicationsToMavenCentralRepository` but does not run their test tasks. Net effect: 11 of 13 Kotlin targets are compiled but never test-executed by automation; only `jvm` (every PR) and, weakly, `wasmWasi` (only when someone runs it locally) have any test execution evidence. |
| 31 | Gradle caching in CI | ❌ Absent | No `gradle/actions/setup-gradle` and no `actions/cache` step in any workflow that touches `kotlin/`. The `kotlin` CI job invokes a bare `gradle` (not even `./gradlew`) with no caching action — `ci.yml:31`. (Release/snapshot jobs do use `./gradlew`.) |
| 32 | Lint/format check step in CI | ❌ Absent | Confirmed absent, consistent with row 26. |
| 33 | API-compat check step in CI | ❌ Absent | Confirmed absent, consistent with row 19 (`apiCheck` never invoked). |
| 34 | Coverage step in CI | ❌ Absent | Consistent with rows 23/24. |
| 35 | Publish/release workflow (tag- or release-triggered → Maven Central) | ✅ Present | `.github/workflows/release.yml` — triggers on `push: tags: ['v*']` + `workflow_dispatch` (`:3-6`); publishes via `publishAllPublicationsToMavenCentralRepository` (`:210`) |
| 36 | Release automation (auto version, changelog, GH release) | ✅ Present | Separate `.github/workflows/bump-version.yml` (workflow_dispatch, stamps version + opens a PR via `scripts/bump-version.sh`) intentionally decoupled from `release.yml` (which tests, publishes, and cuts the GH release via `softprops/action-gh-release@v3`, `:266`, with `generate_release_notes: true`). `kotlin/CHANGELOG.md` is hand-maintained (Keep a Changelog format), not auto-generated from commits. |
| 37 | Workflow hardening: `concurrency` + least-privilege `permissions` + pinned action SHAs | 🟡 Partial | **Concurrency**: present in all 4 workflows (`ci.yml:9-11`, `release.yml:8-11`, `docs.yml:42-44`, and implicitly single-job in `bump-version.yml`). **Permissions**: explicit least-privilege blocks in `release.yml:12-15` (`contents:write, id-token:write, attestations:write`), `docs.yml:38-39,162-164` (`contents:read` default, `pages:write`+`id-token:write` scoped to the deploy job only), `bump-version.yml:18-20` (`contents:write, pull-requests:write`) — but **`ci.yml` has no top-level `permissions:` block at all**, so it runs with the repo/org default (unknown from the repo alone, but a gap relative to its sibling workflows' discipline). **SHA-pinning**: **none** — every action reference across all 4 workflows uses a mutable version tag (`actions/checkout@v7`, `actions/setup-java@v5`, `softprops/action-gh-release@v3`, etc.), not a pinned commit SHA. |
| 38 | Dependency automation (Renovate / Dependabot) | ✅ Present | Renovate — `.github/renovate.json`, extends `config:recommended` + `:dependencyDashboard` + `group:recommended`; git-submodule updates enabled (tracks the `protobufs` submodule specifically, weekly schedule); auto-merge enabled for minor/patch/pin/digest, disabled for major. GitHub's native Dependabot **security alerts** (not version-update PRs) also appear to be enabled at the repo level — referenced by commit `1597450` "fix(security): pin JS test-harness deps past open Dependabot CVEs". No `dependabot.yml` config file (Renovate fully supersedes it for version PRs). |
| **DOCUMENTATION** |
| 39 | README: badges | ❌ Absent | Zero badges (no shields.io / `![...]` images) in either `README.md` (root) or `kotlin/README.md`. No build-status, Maven Central version, license, or coverage badge anywhere. |
| 40 | README: install snippet + quick-start usage | ✅ Present | Root `README.md:865-945` (Quick Start per language incl. Kotlin) and `kotlin/README.md:14-54` (Install + Quick start with imports, sanitizer pipeline, compress/decompress). |
| 41 | README: platform-support table | 🟡 Partial | `README.md:851-859` "Supported Platforms" maps each of the 5 **language bindings** to a platform + test count — but it is not a KMP **target** matrix (doesn't enumerate js/wasmJs/wasmWasi/linux/mingw/tvos individually). The full 13-target list only appears in prose (`kotlin/README.md:8-10`, `CLAUDE.md`, `jitpack.yml` comments), not as a table. |
| 42 | API docs site (Dokka) published (e.g. GH Pages) | ✅ Present | `.github/workflows/docs.yml` — builds Dokka HTML (`dokkaGeneratePublicationHtml`, job `kotlin` `:47-64`) alongside DocC/TypeDoc/pdoc/DocFX for the other 4 bindings, assembles into one site, deploys to GitHub Pages (`deploy` job, `:158-207`) at `meshtastic.github.io/TAKPacket-SDK/kotlin/`. Dokka config: `kotlin/build.gradle.kts:119-140` — public-only visibility, `module.md` include, GitHub source linking, suppresses generated `org.meshtastic.proto.*` from docs. |
| 43 | KDoc coverage on public API (rough %) | ✅ Present, estimated high | Spot-checked 5 of 13 `commonMain` files (`CotXmlParser`, `TakCompressor`, `AtakPalette`, `CotMeshSanitizer`, `TakPacketV2Data`): every public class and public function carries a substantive KDoc block (often with rationale/provenance, e.g. `AtakPalette.kt:3-20` cites the exact upstream ATAK source file its constants were transcribed from). `TakPacketV2Data.kt` has 140 KDoc blocks for its ~162 top-level declarations. Bulk enum/constant lists (e.g. `CotTypeMapper`'s ~140 `COTTYPE_*` constants) are not individually annotated but are self-describing by name. Net estimate: **~85-90%+ of the public API surface** (by class/function, not by raw declaration count) carries real documentation, not just autogenerated stubs. |
| 44 | CHANGELOG present + maintained | ✅ Present | `kotlin/CHANGELOG.md` — Keep a Changelog format, entries for every release including the current `[0.8.0]` with a substantive multi-bullet writeup (`:7-34`). Repo-root-level changes (cross-language) are not separately changelogged — only the Kotlin module has one. |
| 45 | Samples / examples module | ❌ Absent | No `samples/`, `examples/`, or similar directory anywhere in the repo. Partially mitigated by extensive inline runnable-looking code snippets in `README.md` (per payload type) and `kotlin/README.md`, but nothing is a compiled/tested sample module. |
| 46 | Module-level docs (`Module.md` / package docs) | ✅ Present | `kotlin/module.md` — wired into Dokka via `includes.from("module.md")` (`build.gradle.kts:126`); contains both a `# Module TAKPacket-SDK` section and a `# Package org.meshtastic.tak` section per Dokka convention. |
| **ORG ALIGNMENT** |
| 47 | LICENSE | ✅ Present | GPL-3.0 — `LICENSE` (full GPLv3 text), confirmed via `gh repo view` (`licenseInfo.key: "gpl-3.0"`) and matches the POM `licenses` block (`build.gradle.kts:419-423`) |
| 48 | CONTRIBUTING + CODE_OF_CONDUCT | 🟡 Partial | `CONTRIBUTING.md` ✅ present at root — thorough (prerequisites table, build/test/regen-goldens/PII workflow, release process, commit conventions). `CODE_OF_CONDUCT.md` ❌ absent anywhere in the repo. |
| 49 | Issue + PR templates | ❌ Absent | No `.github/ISSUE_TEMPLATE/` directory, no `ISSUE_TEMPLATE.md`, no `PULL_REQUEST_TEMPLATE.md` anywhere. |
| 50 | CODEOWNERS | ❌ Absent | No `CODEOWNERS` file at root or under `.github/`. |
| 51 | SECURITY.md | ❌ Absent | Not present. (PII-handling and dictionary-poisoning-adjacent guidance exists, but as `.github/copilot-instructions.md` prose, not a `SECURITY.md` vulnerability-disclosure policy.) |
| 52 | Default branch | ✅ Present | `master` — confirmed via `gh repo view` (`defaultBranchRef.name`) and local `git branch -a` (`remotes/origin/HEAD -> origin/master`) |
| 53 | Repo description / topics / homepage set | 🟡 Partial | Description ✅ "Cross-platform SDK for converting real world CoTs into wire-optimized TAK Packets"; Topics ✅ 15 set (`atak`, `compression`, `cot`, `cross-platform`, `cursor-on-target`, `lora`, `mesh-networking`, `meshtastic`, `off-grid`, `protobuf`, `sdk`, `situational-awareness`, `tak`, `team-awareness-kit`, `zstd`); Homepage URL ❌ empty string. |
| 54 | Consistent group id + naming (`org.meshtastic:<artifact>`) | ✅ Present | `org.meshtastic:takpacket-sdk` (+ 13 target-suffixed variants, `-jvm` for JVM/Android) follows the exact same convention as sibling Meshtastic KMP libraries also live under `org.meshtastic` on Maven Central — `org.meshtastic:protobufs`(+ variants) and `org.meshtastic:kzstd` (+ variants), both direct dependencies of this SDK, confirmed via the live `repo1.maven.org/maven2/org/meshtastic/` index (§5). |

---

## 2. Publishing model — is it "JVM-only" or full KMP? (explicit clarification requested by task)

**It is genuinely full KMP publishing, not JVM-only.** The `-jvm` suffix on the commonly-referenced coordinate (`org.meshtastic:takpacket-sdk-jvm`) is just the ordinary Gradle Module Metadata per-target classifier — the same pattern every KMP library uses (e.g. this project's own dependencies `protobufs-jvm`, `kzstd-jvm` alongside their `-iosarm64`, `-linuxx64`, `-wasm-js`, etc. siblings).

Live confirmation from `repo1.maven.org/maven2/org/meshtastic/` (fetched via `curl`, since `WebFetch` itself hit an HTTP 403 on that host — likely bot-detection on the default WebFetch UA):

```
takpacket-sdk/                    (root — Gradle Module Metadata / KMP umbrella coordinate)
takpacket-sdk-iosarm64/
takpacket-sdk-iossimulatorarm64/
takpacket-sdk-iosx64/
takpacket-sdk-js/
takpacket-sdk-jvm/                (the one Android/plain-JVM consumers depend on directly)
takpacket-sdk-linuxarm64/
takpacket-sdk-linuxx64/
takpacket-sdk-macosarm64/
takpacket-sdk-mingwx64/
takpacket-sdk-tvosarm64/
takpacket-sdk-tvossimulatorarm64/
takpacket-sdk-wasm-js/
takpacket-sdk-wasm-wasi/
```

That's exactly 1 umbrella + 13 target variants = matches all 13 `kotlin { ... }` target blocks declared in `kotlin/build.gradle.kts:43-78` one-for-one. **Every declared KMP target is actually published**, with real jars/klibs, GPG `.asc` signatures on every file, and `-sources.jar`/`-javadoc.jar` present for the JVM variant (verified for v0.8.0). The reason the docs/README/CLAUDE.md all emphasize the `-jvm` artifact specifically is a **consumption** guidance (Android/plain-JVM consumers must pick that one target explicitly rather than the umbrella coordinate, since Android/Maven tooling doesn't do automatic KMP variant resolution the way Gradle-to-Gradle does) — it is not evidence of reduced publishing scope.

`maven-metadata.xml` for both `takpacket-sdk` and `takpacket-sdk-jvm` show `<latest>0.8.0</latest>` / `<release>0.8.0</release>`, matching the repo's `VERSION` file and the most recent GitHub Release (`v0.8.0`, published 2026-07-17T00:15:19Z) exactly. **Maven Central is fully caught up with the repo — no publish lag.**

Full version history on Maven Central (`takpacket-sdk-jvm`): 0.2.4, 0.2.5, 0.2.6, 0.3.0, 0.3.1, 0.3.2, 0.3.3, 0.4.0, 0.5.0, 0.5.1, 0.5.3, 0.7.0, 0.8.0 (13 releases; note 0.2.0-0.2.3 and 0.6.x and 0.5.2 are absent from Maven Central — either never published, yanked, or version numbers that only ever existed as gradle.properties defaults/in-between states — not independently confirmed, flagged as "unknown" rather than guessed).

GitHub Releases (`gh api repos/meshtastic/TAKPacket-SDK/releases`) show 11 releases from v0.2.6 through v0.8.0, each with exactly 6 assets (Kotlin jar, Python wheel+sdist, npm tarball, NuGet nupkg, Swift zip) — consistent with `release.yml`'s "Collect release artifacts" step (`:239-261`).

---

## 3. Build logic detail

- **Single Gradle module.** `kotlin/settings.gradle.kts` is 8 lines: plugin-management repos + `rootProject.name = "takpacket-sdk"`. No `include(...)` calls — there is exactly one Gradle project, so there's no multi-module duplication problem to solve with convention plugins, and correspondingly no `build-logic`/`buildSrc`.
- **Targets and compiler options** are all declared inline in the one `kotlin/build.gradle.kts` (453 lines total, but only lines 25-113 are the `kotlin { }` DSL block itself; the remainder is Dokka config, BCV config, two custom codegen tasks — see below — and the `mavenPublishing` block).
- **`allWarningsAsErrors.set(true)` + `progressiveMode.set(true)`** (`build.gradle.kts:39-40`) — a stricter-than-default compiler posture; comment claims the whole tree (commonMain + every actual + commonTest + every test leaf) compiles warning-clean under this.
- **`-Xexpect-actual-classes`** opt-in (`:34`) is present but, per §1 row 7, currently unused (no expect/actual classes remain in the source tree) — likely a holdover from before the kzstd extraction, or defensive for future re-introduction.
- **Two custom Gradle tasks** worth noting as build-logic sophistication despite the lack of a `build-logic` folder:
  - `GenerateEmbeddedDictionaries` (`:176-256`) — reads the two `.zstd` dictionary binaries from `jvmMain/resources` and emits a generated `EmbeddedDictionaries.kt` (chunked Base64 constants) into `commonMain`, so every target (including Native/Wasm with no classpath-resource loading) gets the dictionaries compiled in.
  - `GenerateInlinedFixtures` (`:273-372`) — reads all 47 `testdata/cot_xml/*.xml` + `testdata/golden/*.bin` + `testdata/protobuf/*.pb` and emits a generated `InlinedFixtures.kt` into `commonTest`, so the cross-target test suites don't need filesystem access to `../testdata` (which Native/JS/Wasm can't do the way JVM file I/O can).
  - Both are wired via `kotlin.sourceSets.named(...) { kotlin.srcDir(taskProvider) }` rather than by task-name matching, specifically to avoid missing the `sourcesJar` task (a documented past bug, per the inline comment at `:249-253`).
- **Reproducible archives**: `tasks.withType<AbstractArchiveTask>().configureEach { isReproducibleFileOrder = true; isPreserveFileTimestamps = false }` (`:157-160`) — byte-deterministic published jars/klibs.
- **JS security floors**: `plugins.withType<YarnPlugin> { ... resolution(...) }` (`:445-452`) pins 4 transitive Karma/Webpack/Mocha test-harness dependencies (`ws`, `serialize-javascript`, `webpack`, `diff`) past known CVEs — dev-time only, doesn't ship in published artifacts. Corroborated by `kotlin/kotlin-js-store/yarn.lock` presence and CHANGELOG 0.8.0 entry.

## 4. API/compat detail

- BCV plugin `org.jetbrains.kotlinx.binary-compatibility-validator:0.18.1` applied (`build.gradle.kts:12`), `ignoredPackages.add("org.meshtastic.proto")` (`:144-146`, correctly excluding the third-party-generated proto types from the SDK's own compatibility contract).
- Single checked-in dump: `kotlin/api/takpacket-sdk.api`, 891 lines, JVM-descriptor syntax (`Lorg/meshtastic/tak/...;`). Spot-checked head and tail: covers `AtakPalette`, `CotMeshSanitizer`, `CotTypeMapper` (through `TakPacketV2Data$SensorFovData$SensorType` and `TakPacketV2Serializer`/`ZstdException` at the tail) — looks like a complete, single-target (JVM) surface dump.
- **Gap**: no klib ABI dump is checked in despite a build-file comment implying one should exist "alongside the JVM one." `find -iname "*klib*"` across the whole repo returns nothing. Combined with `apiCheck` never running in CI (confirmed absent from all 4 workflow files), this BCV setup is currently **advisory-only** — a contributor can run `./gradlew apiDump` locally and forget to, or skip `apiCheck` entirely, with no automated backstop either locally-enforced-by-CI or covering the 12 non-JVM targets.

## 5. Testing detail

See scorecard rows 20-22 for the numeric breakdown. Qualitative notes:
- `RoundTripTest.kt` (39 tests) and `MalformedInputTest.kt` (16 tests) are the two largest JVM suites — round-trip fixture validation and hardening against malformed/adversarial CoT XML input, respectively.
- `ResilienceTest`/`ResilienceCommonTest` specifically guard the "every packet independently decodable, zero cross-packet zstd state" invariant documented in CLAUDE.md as a hard constraint.
- `GoldenDecodeCommonTest` is the retained cross-target oracle post-kzstd-extraction: decodes the shipped golden `.bin` wire frames using each target's own `ZstdCodec`/`kzstd` binding, so even native/JS/Wasm targets get *some* golden-fixture assurance when their test task is actually invoked — but per row 30, that invocation doesn't currently happen in CI for 11 of 13 targets.
- `DictionaryTrainingTest` (1 test) and `CompressionTest` (8 tests, including the `"generate compression report"` test that is the canonical fixture generator for the *entire cross-language SDK*, not just Kotlin) are notable single-purpose-but-high-leverage tests.
- No JVM-side mutation testing, fuzzing harness (beyond the static `testdata/malformed/` corpus + `testdata/generate_malformed.py`), or property-based testing framework (e.g. Kotest property testing) detected.

## 6. CI detail — every workflow, one line each

| File | Trigger | Purpose |
|---|---|---|
| `ci.yml` | PR/push to `main`/`master` | Parallel per-language test jobs (`kotlin`→`gradle jvmTest`, `swift`→`swift test`, `python`→`pytest`, `typescript`→`vitest`, `csharp`→`dotnet test`), then (`publish-snapshot`, master-push only) publishes a `<next-patch>-SNAPSHOT` to Maven Central's snapshot repo. |
| `release.yml` | `push: tags: v*` or manual dispatch | The real release pipeline: verifies all 5 version sources agree, tests all 5 bindings, pushes the git tag (if dispatched rather than tag-triggered), stages+signs+attests Maven artifacts (`actions/attest-build-provenance`), publishes to Maven Central (idempotent — probes `repo1.maven.org` first), builds all 5 release artifacts (jar/wheel/tarball/nupkg/zip), cuts a GitHub Release, then self-verifies (tag-on-origin + Maven-Central-reachable, polling up to 25 minutes). |
| `docs.yml` | manual, on GitHub Release published, or push to `master` touching doc-relevant paths | Builds Dokka(Kotlin)/DocC(Swift)/TypeDoc(TS)/pdoc(Python)/DocFX(C#) in parallel, assembles into one static site + a hand-written landing page (`docs/index.html`), deploys to GitHub Pages. |
| `bump-version.yml` | manual dispatch with a version input | Runs `scripts/bump-version.sh`, opens (or force-updates) a `release/bump-<version>` PR. Deliberately decoupled from `release.yml` so the version bump is human-reviewable before release. |
| `jitpack.yml` (not a GH Action — JitPack's own config) | JitPack build trigger (tag push) | Fallback distribution channel: `publishToMavenLocal` on JitPack's own infra, serves `com.github.meshtastic:TAKPacket-SDK:<tag>` for consumers who haven't migrated to Maven Central. |

Gaps (repeating scorecard rows 30/31/37 with the "why it matters" framing):
- **No non-JVM Kotlin test execution in CI.** A regression that only manifests on, say, `linuxX64` or `wasmJs` (e.g. a subtle `kotlin.time` or byte-order difference) would not be caught by `ci.yml` at all — only surfaced (if at all) by a contributor manually running that target's test task, or by a downstream consumer.
- **No Gradle build-cache action in CI** (`gradle/actions/setup-gradle` or `actions/cache`) — `org.gradle.caching=true` in `gradle.properties` only helps if there's a persistent cache directory across runs, which bare `actions/checkout` + `gradle`/`./gradlew` doesn't provide. Every CI run likely does a fully cold compile.
- **`ci.yml` has no `permissions:` block** — its sibling workflows (`release.yml`, `docs.yml`, `bump-version.yml`) all set explicit least-privilege `permissions`, so this is an inconsistency in an otherwise security-conscious repo, not a from-scratch gap.
- **No SHA-pinned actions anywhere** — supply-chain best practice (and a common Renovate/Dependabot-assisted pattern) would pin `actions/checkout@<sha> # v7` etc.; this repo uses mutable tags throughout all 4 workflows.

## 7. Documentation detail

- Root `README.md` (997 lines) is unusually thorough for a multi-language SDK: architecture Mermaid diagrams, a full wire-format byte-level spec, a payload-type reference table (13 `oneof` variants), 6 fully worked real-CoT-to-wire-bytes examples with size-reduction tables, per-language quick-start snippets, dictionary-management explanation, and a testing section. It has **zero badges** and its "Supported Platforms" table is binding-oriented, not KMP-target-oriented (rows 39/41).
- `kotlin/README.md` (87 lines) is the binding-specific companion: install snippet (pins the example to `0.7.0` — one version stale relative to the repo's actual `0.8.0`, `kotlin/README.md:21` — a small, low-risk staleness, but a citable inconsistency for a doc that's supposed to be the install source of truth), quick start, core-class table, error-handling note, build/test instructions.
- `kotlin/module.md` feeds Dokka's Module/Package overview pages directly (row 46).
- `kotlin/CHANGELOG.md` follows Keep a Changelog and is genuinely maintained with substantive per-release prose (not just "bump version") — e.g. the `[0.8.0]` entry explains *why* it's a minor bump rather than a patch (Kotlin 2.4.10 toolchain requirement for Native/iOS klib consumers).
- `CLAUDE.md` (root, injected into this session's context) and `.github/copilot-instructions.md` (14 KB) are two overlapping-but-distinct AI-agent-facing instruction files — thorough, specific, and clearly battle-tested (they document past incidents: a real PII leak requiring `git filter-repo`, a Maven-Central-stuck-pending incident on v0.3.0, a TypeScript zstd-napi footgun, several "phantom optimizations" explicitly rejected with rationale). This is unusually mature institutional-memory documentation for a library of this size, though it lives outside the rubric's normal "docs" categories.
- `WIRE_FORMAT.md` (284 lines) and `TESTING_PUNCHLIST.md` (176 lines, a fully-unchecked manual ATAK↔iTAK interop QA checklist) both exist but are outside the strict rubric row list; flagged here as context. The manual punchlist being 100% unchecked is not itself damning (it may simply not have been re-rendered for this snapshot) but is worth the maintainers' attention if it's meant to gate releases.

## 8. Org alignment detail

- Community health files present: `LICENSE` (GPL-3.0), `CONTRIBUTING.md`. Absent: `CODE_OF_CONDUCT.md`, `SECURITY.md`, any issue/PR template, `CODEOWNERS`. For a `meshtastic` org repo this is worth checking against the org's other repos for a possible `.github`-org-level-default-community-health-files fallback (GitHub supports org-wide defaults via a `.github` repo) — not verifiable from this local clone/audit scope; flagged as **unknown**, not assumed absent at the GitHub-experience level, even though nothing is committed locally in this repo.
- `gh repo view` confirms: default branch `master`, description set, 15 topics set (well-curated, relevant), license correctly detected as `gpl-3.0`, but `homepageUrl` is an empty string (a homepage — e.g. pointing at the GitHub Pages docs site — is not configured at the repo-metadata level even though the docs site itself exists and is deployed).
- Group ID consistency: `org.meshtastic` is shared with at least two other published sibling libraries this SDK directly depends on (`org.meshtastic:protobufs`, `org.meshtastic:kzstd`), both following the identical per-KMP-target artifact-suffix convention. This indicates real cross-repo coordination/convention within the Meshtastic org, not just a one-off choice.

---

## 9. Notable strengths (ranked)

1. **Genuinely complete, verified full-KMP publishing.** All 13 declared targets are live on Maven Central with matching version (`0.8.0`), full GPG signatures, and sources+javadoc jars — confirmed by direct inspection of `repo1.maven.org`, not just by reading the build script.
2. **Unusually rigorous cross-language release engineering.** A single `VERSION` file fans out to 5 language-specific version fields via `scripts/bump-version.sh`, with a hard CI gate (`release.yml:32-73`) that fails loudly on any mismatch, plus post-publish self-verification that polls Maven Central for up to 25 minutes and distinguishes "still propagating" from "actually broken." This is materially more careful than most single-language library releases.
3. **KMP architecture is unusually clean**: zero `expect`/`actual` remaining after extracting the platform-divergent zstd codec into a standalone `kzstd` library — 100% of the SDK's logic is `commonMain`, which is about as good as KMP code-sharing gets.
4. **Deep, well-maintained documentation with real institutional memory**: KDoc coverage is consistently substantive (not stub comments), `CHANGELOG.md` explains the *why* behind version bumps, and `CLAUDE.md`/`copilot-instructions.md` encode hard-won incident lessons (a real PII leak + recovery playbook, a stuck-Maven-Central-release incident, several explicitly-rejected "phantom optimizations" with rationale) that most repos never write down.
5. **Security-conscious in places most KMP libraries overlook**: XXE/entity-expansion guards in the XML parser (`CotXmlParser.kt:31-34`), a decompression-bomb guard (`MAX_DECOMPRESSED_SIZE = 4096`), proactive Dependabot-CVE pin-floors for the JS test harness even though it's dev-only, and a documented PII-scrubbing workflow (`scripts/pii-scan.sh`, `.github/copilot-instructions.md:128+`) for a codebase that handles real-world location data.

## 10. Notable gaps/risks (ranked)

1. **No automated test execution for 11 of the 13 declared KMP targets.** CI only runs `jvmTest`; the 9 native targets + `js` + `wasmJs` are compiled (as a side effect of publishing) but never test-executed by any workflow. A target-specific regression would ship silently.
2. **Binary Compatibility Validator is present but toothless.** `apiCheck` is never run in CI, so the one checked-in `.api` dump (JVM-only — no klib dump exists despite a comment claiming otherwise) can drift indefinitely without detection. Combined with gap #1, the 12 non-JVM targets have essentially no automated API-surface or behavioral safety net.
3. **Zero code-coverage tooling** (no Kover/Jacoco, no Codecov upload, no threshold) — test *count* is decent (95 declared, 315 executed on JVM) but there's no visibility into what fraction of `CotXmlParser`'s 1403 lines or `CotXmlBuilder`'s 837 lines is actually exercised.
4. **No linter/formatter enforcement.** `ktlint`/`detekt`/`spotless` are entirely absent; the only style guidance is a one-line prose note in `copilot-instructions.md`, unenforced by any tool, pre-commit hook, or CI step.
5. **CI workflow-hardening is inconsistent.** `release.yml`/`docs.yml`/`bump-version.yml` all set explicit least-privilege `permissions:`; `ci.yml` — the workflow that runs on every external PR — does not. No workflow anywhere pins actions by commit SHA (all use mutable version tags).
6. **No community-health scaffolding for external contributors**: no `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue templates, PR template, or `CODEOWNERS` anywhere in the repo (org-level defaults not verifiable from this audit's scope).
7. **No BOM and no samples/examples module.** Non-Gradle consumers must know to pick `-jvm` specifically (documented, but a footgun for anyone skimming just the root coordinate); there's no compiled/tested sample app for any of the 5 bindings, only README-embedded snippets.
8. **Several small, low-risk staleness/consistency nits**: `kotlin/README.md:21`'s install snippet pins the example to `0.7.0` though the repo is at `0.8.0`; no README badges at all (build status, Maven Central version, license); repo homepage URL unset even though a GitHub Pages docs site is live; Gradle Configuration Cache is not enabled (only build cache + parallel); the manual `TESTING_PUNCHLIST.md` interop QA checklist is 100% unchecked.
