# Audit: meshtastic/protobufs — packages/kmp/ (org.meshtastic:protobufs)

Read-only audit. Repo at `/Users/james/meshtastic/protobufs` (local clone, branch `master`,
remote `https://github.com/meshtastic/protobufs.git`). Audited at HEAD on 2026-07-21.
This is a **TypeScript-primary monorepo** (`packages/ts` is the flagship consumer path; the
root README, `.coderabbit.yaml` path-filter excluding `packages/**`, and CI structure all
reflect that). `packages/kmp/` is one of three generated-client packages (`packages/ts`,
`packages/rust`, `packages/kmp`), and it is **100% Wire-generated code** — there is no
hand-written `src/` tree anywhere in the module (verified: `find packages/kmp -iname src`
returns nothing). Consequently, rubric rows about test coverage / KDoc coverage on
hand-written code are reframed as "N/A — no source to test/document; assess the
generation/build/publish pipeline instead," per the task instructions.

## Scorecard

| # | Criterion | Status | Evidence (path / value) |
|---|-----------|--------|-------------------------|
| **BUILD LOGIC** |
| 1 | Gradle wrapper version | ✅ Present | `9.6.1` — `packages/kmp/gradle/wrapper/gradle-wrapper.properties:3` (`distributionUrl=...gradle-9.6.1-bin.zip`). Note: repo root has **no** top-level wrapper/settings/build files at all (`find -maxdepth 1 -iname "*.gradle*"` → empty); `packages/kmp/` is a fully standalone Gradle build with its own `gradlew`. |
| 2 | Kotlin version | ✅ Present | `2.4.10` — `packages/kmp/build.gradle.kts:2` (`kotlin("multiplatform") version "2.4.10"`) |
| 3 | AGP version | ✅ Present | `9.3.0`, via `id("com.android.kotlin.multiplatform.library") version "9.3.0"` — `packages/kmp/build.gradle.kts:3`. This is the new AGP-9 KMP-native Android plugin (not legacy `com.android.library`), consistent with current (2026) best practice. |
| 4 | Version catalog `gradle/libs.versions.toml` | ❌ Absent | Not found anywhere in the repo (`find … -iname "libs.versions.toml"` → empty). All plugin/dependency versions are hardcoded literals in `packages/kmp/build.gradle.kts:2-5,67`. |
| 5 | Convention plugins via `build-logic` composite build | ❌ Absent | No `build-logic/` or `buildSrc/` directory anywhere in the repo; `packages/kmp/settings.gradle.kts` declares no `includeBuild`. Single flat `build.gradle.kts` (155 lines). Moot at current scale (one Gradle module) but would matter if more KMP modules are added. |
| 6 | KMP targets declared | ✅ Present | **14 targets**, `packages/kmp/build.gradle.kts:38-62`: `android` (namespace `org.meshtastic.proto`, compileSdk 37, minSdk 24), `jvm()`, `js{browser();nodejs()}`, `wasmJs{browser()}`, `wasmWasi{nodejs()}`, `macosArm64`, `linuxX64`, `linuxArm64`, `mingwX64`, `iosX64`, `iosArm64`, `iosSimulatorArm64`, `tvosArm64`, `tvosSimulatorArm64`. All 14 are confirmed **actually published** on Maven Central for 2.7.26 (verified via `curl` directory listing of `repo1.maven.org/maven2/org/meshtastic/` — see Publishing section). No `watchos*`, no `linuxArm32`, no `androidNativeX*`. |
| 7 | Hierarchical source sets / `applyDefaultHierarchyTemplate` | ✅ Present (implicit) | No explicit call — but Kotlin Gradle Plugin has applied the default hierarchy template automatically since 1.9.20, and this project is on 2.4.10, well past that. No manual `sourceSets{}` hierarchy wiring beyond the `commonMain` dependency block (`build.gradle.kts:64-70`), so the implicit default is what's in effect. |
| 8 | `explicitApi()` strict mode | ❌ Absent | No `explicitApi()` call found (`grep -n "explicitApi" build.gradle.kts` → no match). Low-impact since the only "API" is Wire-generated, but nothing would catch accidental hand-written additions leaking implicit visibility either. |
| 9 | JVM toolchain pinned (`jvmToolchain(N)`) | ❌ Absent | No `jvmToolchain` call anywhere in `build.gradle.kts` (`grep -n "jvmToolchain"` → no match). JVM target compiles with whatever JDK Gradle resolves (CI pins Temurin 21 via `actions/setup-java@v5`, e.g. `.github/workflows/kmp-pull-request.yml:20-24`, but that's a CI-runner concurrence with the build script, not a toolchain contract enforced by the build itself). |
| 10 | Gradle configuration cache / caching in `gradle.properties` | 🟡 Partial | `packages/kmp/gradle.properties:2-3`: `org.gradle.caching=true`, `org.gradle.parallel=true`. No `org.gradle.configuration-cache=true` (`grep` → no match). Build cache + parallel are on; configuration cache is not explicitly enabled. |
| **PUBLISHING** |
| 11 | Publishing mechanism | ✅ Present | `com.vanniktech.maven.publish` **v0.37.0** — `packages/kmp/build.gradle.kts:5`. Configured via the `mavenPublishing {}` DSL at `build.gradle.kts:123-154`. Not manual `maven-publish`. |
| 12 | Central Portal vs legacy OSSRH | ✅ Present — Central Portal | `build.gradle.kts:124`: `publishToMavenCentral(automaticRelease = true)`. Snapshot repo is explicitly `https://central.sonatype.com/repository/maven-snapshots/` (`packages/kmp/README.md:81`), the new Central Portal snapshot host — not legacy `s01.oss.sonatype.org`. |
| 13 | GPG signing configured | ✅ Present | `build.gradle.kts:125-127`: `signAllPublications()` gated on presence of `signingInMemoryKey` gradle property. **Confirmed live**: every artifact on Maven Central for 2.7.26 has a matching `.asc` signature file (verified via `curl` of `repo1.maven.org/maven2/org/meshtastic/protobufs/2.7.26/` — `.jar.asc`, `-sources.jar.asc`, `-javadoc.jar.asc`, `.module.asc`, `.pom.asc` all present, 801 bytes each). CI wires the key via `ORG_GRADLE_PROJECT_signingInMemoryKey: ${{ secrets.MAVEN_SIGNING_KEY }}` (`.github/workflows/publish-kmp.yml:94`, `snapshot-kmp.yml:69`). |
| 14 | BOM module published | ❌ Absent (for this artifact) | No `protobufs-bom` on Maven Central. Note: the `org.meshtastic` group **does** publish BOMs for sibling libraries (`org/meshtastic/sdk-bom/`, `org/meshtastic/mqtt-client-bom/` — seen in the group directory listing), so the org knows the pattern; it just isn't applied here. Lower priority for a single logical artifact with 14 platform suffixes resolved automatically via Gradle Module Metadata, but would help pin cross-platform version alignment explicitly. |
| 15 | POM metadata complete | ✅ Present | `build.gradle.kts:129-153`: `name` ("Meshtastic Protobufs"), `description`, `inceptionYear` (2025), `url`, `licenses` (GPLv3 + URL + distribution), `developers` (id/name/url), `scm` (url/connection/developerConnection). All fields the rubric asks for are populated. Confirmed rendered into the live POM (`protobufs-2.7.26.pom`, 2022 bytes, fetched via curl). |
| 16 | Sources jar + Dokka/javadoc jar attached | 🟡 Partial | Sources jar: **present and substantial** — `protobufs-2.7.26-sources.jar`, 456,092 bytes (confirmed on Maven Central). Javadoc jar: **present but an empty stub** — `protobufs-2.7.26-javadoc.jar` is only **261 bytes** (confirmed on Maven Central, both for the root `protobufs` artifact and the `protobufs-jvm` platform artifact). No Dokka plugin is applied anywhere in the repo (`grep -ril dokka` → no hits), so vanniktech's publish plugin falls back to its empty-javadoc-jar default to satisfy Central's "must have a javadoc artifact" rule — it ships no real API documentation. |
| 17 | Group/artifact coordinates | ✅ Present | `org.meshtastic:protobufs` (+ 14 platform-suffixed artifacts, e.g. `protobufs-jvm`, `protobufs-android`, `protobufs-iosarm64`, `protobufs-wasm-js`, …) — `packages/kmp/gradle.properties:8-9` (`GROUP=org.meshtastic`, `POM_ARTIFACT_ID=protobufs`), confirmed live on Maven Central. |
| 18 | Version single-source-of-truth | ✅ Present | Git tags. `build.gradle.kts:8-29`: `version` resolves from the `-PVERSION_NAME` Gradle property (always supplied by CI, derived from the pushed tag — see `publish-kmp.yml:34-48`); local/no-flag builds fall back to `git describe --tags --abbrev=0` + patch-bump, degrading to `0.0.1-SNAPSHOT` if git/tags are unavailable. Thoroughly documented in `packages/kmp/README.md:14-38`. `gradle.properties` deliberately holds only `GROUP`/`POM_ARTIFACT_ID`, not a version literal. |
| **API & COMPAT** |
| 19 | Binary Compatibility Validator | ❌ Absent | No BCV plugin applied, no `*.api` files anywhere in the repo (`find … -iname "*.api"` → empty; `grep -ril "binary-compatibility\|apiValidation"` → empty). For a library with 14 live platform artifacts and real downstream consumers (Meshtastic-Android, TAKPacket-SDK per `build.gradle.kts:106-107` comment), there is no automated guard against an accidental breaking change in generated models between releases. |
| **TESTING & COVERAGE** |
| 20 | Test framework(s) | N/A | No test source sets exist at all — see below. |
| 21 | `commonTest` present + per-target test source sets | ❌ Absent / N/A | Confirmed: `packages/kmp/` has **zero** `src/` directories checked into git (`find packages/kmp -iname src` → empty; the only checked-in files are `README.md`, `build.gradle.kts`, `gradle.properties`, `gradle/wrapper/*`, `gradlew(.bat)`, `settings.gradle.kts` — 8 files total). All Kotlin is Wire-generated at build time into `build/generated/source/wire`. This is expected/moot for a pure-codegen module per the audit brief — there is no hand-written logic to unit-test in this repo; correctness of the generated models is effectively validated by downstream consumer test suites (Android app, SDKs), not here. |
| 22 | Rough test count | 0 | No test files exist. |
| 23 | Coverage tool (Kover/Jacoco) | ❌ Absent / N/A | None configured; none applicable given #21. |
| 24 | Coverage uploaded to Codecov/other | ❌ Absent | Not present in any workflow. |
| 25 | Coverage threshold/verification enforced | ❌ Absent | Not present. |
| **CODE QUALITY TOOLING** |
| 26 | Formatter/linter (spotless/ktlint/detekt) | ❌ Absent (Kotlin) | No ktlint/detekt/spotless plugin or config anywhere in the repo. The repo **does** lint the `.proto` schema itself via Buf (`format`/`lint`/`breaking` in `.github/workflows/pull_request.yml:16-24`), but that is proto-level and runs as a separate, repo-wide workflow — it does not touch generated Kotlin or `packages/kmp/build.gradle.kts`. |
| 27 | `.editorconfig` present | ❌ Absent | Not found anywhere in the repo. |
| 28 | Pre-commit hooks / git hooks | ❌ Absent | No `.pre-commit-config.yaml`, no Husky config, no custom hook scripts found. |
| **CI/CD** |
| 29 | PR build+test workflow | ✅ Present | `.github/workflows/kmp-pull-request.yml` — triggers on PRs touching `meshtastic/**/*.proto`, `nanopb.proto`, or `packages/kmp/**` (lines 4-8); runs `gradlew … build -PVERSION_NAME=0.0.0-pr` (line 33). "Build" here is compile + Wire codegen only — there is no test step because there are no tests to run. |
| 30 | Multiplatform CI matrix incl. macOS runner | 🟡 Partial | All 3 KMP-related jobs run on `runs-on: macos-latest` (`kmp-pull-request.yml:15`, `publish-kmp.yml:24,69`, `snapshot-kmp.yml:20`) — necessary for the Apple/tvOS native targets. However it's a **single OS, single job**, not a matrix — every target (JVM/JS/Wasm/Linux/Windows/macOS/iOS/tvOS) is cross-compiled from the one macOS runner rather than validated on native runners per host OS (e.g. no Linux runner for `linuxX64`/`linuxArm64`, no Windows runner for `mingwX64`). This is a normal simplification for Kotlin/Native cross-compilation but means Linux/Windows native outputs are never actually executed/tested anywhere, only compiled. |
| 31 | Gradle caching in CI | ✅ Present | `gradle/actions/setup-gradle@v6` in all 3 KMP workflows (`kmp-pull-request.yml:30`, `publish-kmp.yml:60,87`, `snapshot-kmp.yml:37`) — this action provides automatic build-cache/dependency caching. |
| 32 | Lint/format check step in CI | ❌ Absent (Kotlin) | No ktlint/detekt/spotless step in any KMP workflow. (Proto-level Buf lint exists but lives in the separate, repo-wide `pull_request.yml`.) |
| 33 | API-compat check step in CI | ❌ Absent | No BCV step anywhere, consistent with #19. |
| 34 | Coverage step in CI | ❌ Absent | Consistent with #23-25. |
| 35 | Publish/release workflow | ✅ Present | `.github/workflows/publish-kmp.yml` (tag `v*` push **or** `workflow_dispatch`) and `.github/workflows/snapshot-kmp.yml` (push to `master`, path-filtered to proto/kmp changes, **or** `workflow_dispatch`). Both publish to Maven Central via `publishAllPublicationsToMavenCentralRepository`. |
| 36 | Release automation (auto version, changelog, GH release) | 🟡 Partial | `.github/workflows/create_tag.yml` fully automates repo-wide version-bump tagging + a GitHub Release with auto-generated notes (`ncipollo/release-action@v1`, `generateReleaseNotes: true`, lines 52-58) — this part works well and is confirmed live (e.g. the `v2.7.26` GitHub Release body is an auto-generated PR list). **But** the tag-triggered *Maven Central* publish is not reliably automatic in practice — see Gap #1 below; every recorded KMP publish so far has been a manual `workflow_dispatch`, not the `push: tags: v*` trigger firing. |
| 37 | Workflow hardening (`concurrency` + least-privilege `permissions` + pinned SHAs) | 🟡 Partial | **Permissions**: every one of the 7 workflows declares an explicit, mostly minimal top-level `permissions:` block (e.g. `kmp-pull-request.yml:10-11` → `contents: read` only; `publish.yml:19-21` → `contents: write, id-token: write` for JSR OIDC publish). Good practice, consistently applied. **Concurrency**: `grep -l "concurrency:" .github/workflows/*.yml` → **no matches in any of the 7 files**. Overlapping runs (e.g. two snapshot publishes racing on rapid pushes to `master`) are not guarded against. **Pinned SHAs**: `grep -rEo "uses: [^@]+@[0-9a-f]{40}"` → **zero matches**; every single `uses:` in every workflow references a floating version tag (`actions/checkout@v7`, `gradle/actions/setup-gradle@v6`, `bufbuild/buf-action@v1.4.0`, etc.), not an immutable commit SHA. |
| 38 | Dependency automation | ✅ Present — Renovate | `renovate.json` at repo root, extending `config:recommended` plus a custom regex manager that tracks tool versions embedded as comments inside workflow YAML (e.g. `version: 1.72.0 # renovate: datasource=github-releases depName=bufbuild/buf` in `pull_request.yml:19`). Confirmed active via git history — e.g. `164b6e2 Update plugin com.vanniktech.maven.publish to v0.37.0 (#1003)`, `3703b06 Update plugin com.android.kotlin.multiplatform.library to v9.3.0 (#1002)`, `63f15a7 Update dependency com.squareup.wire:wire-runtime to v6.4.5 (#992)`, `84fcb58 Update Gradle to v9.6.1 (#1001)` — all recent, all Renovate-authored, all against `packages/kmp`. |
| **DOCUMENTATION** |
| 39 | README badges | 🟡 Partial / stale | Root `README.md:3-6` has 4 badges: CI, CLA-assistant, Fiscal-Contributors, Vercel. The **CI badge is broken/stale**: it points at `.../workflows/ci.yml` (`README.md:3`), but **no `ci.yml` file exists** among the repo's 7 workflows (confirmed: `find .github/workflows -iname ci.yml` → empty; the 7 are `create_tag.yml`, `kmp-pull-request.yml`, `publish-kmp.yml`, `publish.yml`, `pull_request.yml`, `schema-registry.yml`, `snapshot-kmp.yml`). No Maven Central version badge, no coverage badge anywhere. `packages/kmp/README.md` itself has **zero badges**. |
| 40 | README install snippet + quick-start usage | 🟡 Partial | `packages/kmp/README.md:42-61` gives full Maven coordinates for the root artifact and all 14 platform-specific artifacts; `:93-117` gives local-build/publish commands. **Missing**: any actual Kotlin usage sample (e.g., constructing/parsing a `MeshPacket`) — the README documents how to *depend on* the artifact, not how to *use* it. |
| 41 | README platform-support table | 🟡 Partial | `packages/kmp/README.md:8` lists platform families in prose ("Kotlin/Android, Kotlin/JVM, Kotlin/JS, Kotlin/Wasm (`wasmJs` and `wasmWasi`), and Kotlin/Native"), and `:46-60` enumerates all 14 artifact coordinates. It's a bulleted/prose list, not a formal support matrix table, but coverage of the information is complete. |
| 42 | API docs site (Dokka) published | ❌ Absent | No Dokka plugin, no GH Pages deploy step in any workflow. Root `README.md:12` links to Buf's schema registry (`https://buf.build/meshtastic/protobufs`) for *proto* docs, not Kotlin API docs. |
| 43 | KDoc coverage on public API | N/A (generated) — strong proxy signal | No hand-written KDoc exists (100% generated). As a proxy: the source `.proto` files are densely doc-commented — `meshtastic/mesh.proto` has **522** `/* … */` block-comment openings against **229** field declarations and **54** message/enum declarations (i.e. most fields/messages carry a doc comment); spot-checks of `admin.proto` (153 comments / 18 messages+enums) and `config.proto` (236 comments / 28 messages+enums) show the same density. The repo's own PR template enforces this discipline: `.github/pull_request_template.md:9-10` — checklist items "All top level messages commented" / "All enum members have unique descriptions." Square Wire's Kotlin generator is documented to carry proto leading-comments through as KDoc on generated types/properties, so realized KDoc coverage on the generated Kotlin is likely high — but this was not build-verified (no codegen was run, per the read-only/no-build constraint). |
| 44 | CHANGELOG present + maintained | ❌ Absent (as a file) | No `CHANGELOG.md` anywhere. GitHub Releases (auto-generated by `create_tag.yml`) function as a de facto repo-wide changelog, but it is not KMP-specific and not a file in the repo. |
| 45 | Samples/examples module | ❌ Absent | No `samples/`, `example/`, or similar directory under `packages/kmp/` or elsewhere. |
| 46 | Module-level docs (`Module.md`) | ❌ Absent | No Dokka `Module.md`. `packages/kmp/README.md` is the only module-level document. |
| **ORG ALIGNMENT** |
| 47 | LICENSE | ✅ Present — GPL-3.0 | Root `LICENSE` (GNU GPLv3 full text) + `gh repo view` → `licenseInfo.key: gpl-3.0`. Re-declared in the POM (`build.gradle.kts:135-139`) and physically copied into every published jar via `tasks.withType<Jar>().configureEach { from(rootProject.layout.projectDirectory.file("../../LICENSE")) }` (`build.gradle.kts:78-80`). Consistent everywhere. |
| 48 | CONTRIBUTING + CODE_OF_CONDUCT | ❌ Absent | Neither file found anywhere in the repo. |
| 49 | Issue + PR templates | 🟡 Partial | `.github/pull_request_template.md` exists but its content is proto/hardware-model-centric (comment-coverage checklist + a "New Hardware Model Acceptance Policy" section) — not KMP-aware. No `ISSUE_TEMPLATE/` directory or files at all. |
| 50 | CODEOWNERS | ❌ Absent | Not found anywhere in the repo. |
| 51 | SECURITY.md | ❌ Absent | Not found anywhere in the repo. |
| 52 | Default branch | `master` | Confirmed via `gh repo view --json defaultBranchRef` → `{"name":"master"}`. |
| 53 | Repo description / topics / homepage | ✅ Present | `gh repo view`: description `"Protobuf definitions for the Meshtastic project"`; `homepageUrl: "https://meshtastic.org"`; 11 topics: `meshtastic, protobuf, firmware, iot, lora, mesh, mesh-networking, nanopb, off-grid, protocol-buffers, radio`. |
| 54 | Consistent group id + naming | ✅ Present | `org.meshtastic:protobufs` (+14 suffixes) matches the naming convention of sibling artifacts also published under `org.meshtastic` on Maven Central (`sdk-core*`, `sdk-bom`, `mqtt-client*`, `mqtt-client-bom`, `kzstd*`, `takpacket-sdk*` — all observed in the live `org/meshtastic/` directory listing), confirming this repo is one contributor to a coherently-namespaced multi-repo org. |

## Detailed findings

### Build logic

`packages/kmp/` is a **complete standalone Gradle build** disconnected from the repo root —
the repo root itself has no `build.gradle.kts`/`settings.gradle.kts`/wrapper at all. Its
`settings.gradle.kts` (16 lines) only sets `rootProject.name = "protobufs"` and repositories
(`google()`, `gradlePluginPortal()`, `mavenCentral()` for plugin management;
`google()`, `mavenCentral()` for dependency resolution) — no `include()` calls, so it is a
single-module build (the KMP module IS the root project).

`build.gradle.kts` (155 lines) is a single flat file with 4 plugins (`kotlin("multiplatform")
2.4.10`, `com.android.kotlin.multiplatform.library 9.3.0`, `com.squareup.wire 6.4.5`,
`com.vanniktech.maven.publish 0.37.0`, lines 1-6), no version catalog, no convention plugins.

Wire configuration (`build.gradle.kts:94-114`) is worth calling out as thoughtful, non-default
tuning with inline rationale comments:
- `boxOneOfsMinSize = 5000` (line 108) — flattens `oneof` fields into nullable properties
  instead of sealed classes, explicitly because downstream consumers (Meshtastic-Android,
  TAKPacket-SDK, named in the comment at lines 106-107) are written against that shape.
- `makeImmutableCopies = false` (line 112) — skips defensive copies of repeated/map fields on
  decode "to reduce allocations on high-frequency decode paths (mesh packets)" — a
  domain-aware performance decision, not a default.
- Two custom `Sync` tasks (`syncProtos`, `syncNanopb`, lines 84-92) stage `../../meshtastic/`
  and `../../nanopb.proto` from the repo root into `build/protos/` before Wire codegen runs,
  wired via `afterEvaluate { tasks.matching { name startsWith "generate" && endsWith "Protos" }
  .configureEach { dependsOn(syncProtos, syncNanopb) } }` (lines 117-121).
- **Minor doc/implementation drift**: `packages/kmp/README.md:10` states "Wire reads schema
  sources from `packages/kmp/proto/`, which symlinks back to the repo-root proto files" — but
  no such `proto/` directory or symlink exists in the working tree (`find packages/kmp -iname
  proto` → empty), and the actual mechanism is the `Sync`-task copy described above, not a
  symlink. The README prose has drifted from the implementation.

No `jvmToolchain()`, no `explicitApi()`, no version catalog, no `build-logic`/`buildSrc` —
all confirmed absent by direct grep across the whole repo, not just the module.

### Publishing

`mavenPublishing {}` block (`build.gradle.kts:123-154`) is compact and modern:
`publishToMavenCentral(automaticRelease = true)` targets the Central Portal; signing is
conditional (`if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()`,
lines 125-127) so unsigned local builds don't fail; the POM block is fully populated.

Credentials/signing are wired purely through environment variables mapped to Gradle properties
in CI — `ORG_GRADLE_PROJECT_mavenCentralUsername`, `ORG_GRADLE_PROJECT_mavenCentralPassword`,
`ORG_GRADLE_PROJECT_signingInMemoryKey` (`publish-kmp.yml:92-94`, `snapshot-kmp.yml:67-69`) —
standard vanniktech convention, no secrets in the repo.

**Live Maven Central verification** (via `curl`, since the `WebFetch` tool returned HTTP 403
for `repo1.maven.org` — direct `curl` from the sandbox succeeded fine):
- `maven-metadata.xml` for `org/meshtastic/protobufs/`: `<latest>2.7.26</latest>
  <release>2.7.26</release>`, only two `<version>` entries ever recorded: `2.7.25`, `2.7.26`.
  **The KMP artifact's Maven Central publishing history is very short** — only 2 stable
  releases exist on Central at all, despite the repo having 26+ historical `v2.7.x` tags going
  back to `v2.7.7` (2025-08-29). This is consistent with the git log showing KMP
  multi-target publishing (`feat(kmp): add JS, Wasm, and additional native publish targets`)
  and the Renovate-tracked plugin bumps as recent additions to this module.
- Directory listing shows `2.7.25/` dated `2026-06-10 10:49` and `2.7.26/` dated
  **`2026-07-21 14:01`** — i.e., published *today*, the same day as this audit.
- `org/meshtastic/protobufs/2.7.26/` contains, for the root KMP-metadata artifact:
  `protobufs-2.7.26.jar` (212,761 B), `-sources.jar` (456,092 B), `-javadoc.jar` (**261 B —
  empty stub**), `.module` (Gradle Module Metadata, 25,675 B), `.pom` (2,022 B), plus a
  `-kotlin-tooling-metadata.json`, and matching `.asc`/`.md5`/`.sha1`/`.sha256`/`.sha512` for
  each. `org/meshtastic/protobufs-jvm/2.7.26/` shows the same shape (real jar 1,857,924 B,
  sources 456,092 B, javadoc still 261 B).
- The broader `org/meshtastic/` group listing confirms all 14 declared targets are published
  (`protobufs-android`, `-iosarm64`, `-iossimulatorarm64`, `-iosx64`, `-js`, `-jvm`,
  `-linuxarm64`, `-linuxx64`, `-macosarm64`, `-mingwx64`, `-tvosarm64`,
  `-tvossimulatorarm64`, `-wasm-js`, `-wasm-wasi`), and reveals sibling `org.meshtastic`
  artifacts from other Meshtastic repos (`sdk-core*`, `sdk-bom`, `mqtt-client*`, `kzstd*`,
  `takpacket-sdk*`) sharing the same group namespace.

**Release-automation reality check** (via `gh api repos/meshtastic/protobufs/actions/workflows/
publish-kmp.yml/runs`): **total_count = 3, all three `event: workflow_dispatch`, zero
`event: push`.**
1. `2026-06-10T10:43:51Z`, dispatched against ref `v2.7.25` → published `2.7.25`.
2. `2026-07-21T12:48:40Z`, dispatched against `master`.
3. `2026-07-21T13:14:47Z`, dispatched against `master` → this is the run that produced the
   `2.7.26` artifacts timestamped `14:01` above.

So although `publish-kmp.yml:4-6` declares `on: push: tags: "v*"`, and tag `v2.7.26` was cut
and released on GitHub on **2026-06-20** (`gh api .../releases/latest` →
`"published_at":"2026-06-20T00:30:34Z"`), the Maven Central publish for that tag did not
happen until **2026-07-21 — roughly a month later — and via two manual dispatches**, not the
tag-push trigger. In the entire recorded history of this workflow, the automatic
tag-triggered path has never fired. By contrast, `snapshot-kmp.yml` (master-push triggered)
has **41** successful automatic runs, most recently 2026-07-19, so the snapshot half of the
pipeline is demonstrably healthy — it's specifically the *stable release* publish path whose
automation is unproven.

### API/compat

No Binary Compatibility Validator plugin, no `*.api` dump files anywhere in the repo, no
`explicitApi()`. Given 14 live published targets and named external consumers
(Meshtastic-Android, TAKPacket-SDK per the Wire-config comment), there is currently no
automated signal if a schema/codegen change silently breaks binary or source compatibility
for those consumers before a release goes out.

### Testing

Zero test infrastructure, and — unusually for an audit — this is because there is **zero
source infrastructure**: `packages/kmp/` contains exactly 8 checked-in files (README, build
script, gradle.properties, wrapper jar+properties, gradlew, gradlew.bat, settings.gradle.kts).
No `src/` directory of any kind exists in git. All Kotlin is generated fresh at build time
under `build/generated/source/wire/` from the synced `.proto` files. This matches the audit
brief's framing exactly: testing/coverage rubric rows are not "failing," they're inapplicable
to a repo that ships no hand-written logic — correctness is a downstream-consumer concern.

### Code quality tooling

No ktlint/detekt/spotless/`.editorconfig`/pre-commit hooks anywhere. The repo does enforce
schema quality via Buf (`format`, `lint`, `breaking`-change detection in
`.github/workflows/pull_request.yml:16-24`, using `bufbuild/buf-action@v1.4.0` pinned to Buf
CLI `1.72.0` with a Renovate marker comment at line 19), but that workflow is repo-wide
(triggers on any PR) and proto-focused — it has no awareness of `packages/kmp/` or generated
Kotlin quality.

### CI (all 7 workflows enumerated)

| File | Purpose | Trigger | Touches KMP? |
|---|---|---|---|
| `create_tag.yml` | Repo-wide version-bump: computes next `vX.Y.Z` tag, creates a GH Release w/ auto-generated notes, pushes tag to Buf schema registry | `workflow_dispatch` (choice: patch/minor/major) | Indirectly (its tag is what `publish-kmp.yml`/`publish.yml` key off of) |
| `kmp-pull-request.yml` | Build-only gate for KMP: `gradlew build -PVERSION_NAME=0.0.0-pr` | `pull_request` paths: `meshtastic/**/*.proto`, `nanopb.proto`, `packages/kmp/**` | **Yes — KMP's only PR gate** |
| `publish-kmp.yml` | Build + publish KMP to Maven Central (release) | `push: tags: v*` **or** `workflow_dispatch` (with `dry_run` option limiting to `publishToMavenLocal`) | **Yes — KMP release publish** |
| `publish.yml` | Generate TS code via `buf generate`, build with `tsdown`, zip release assets, push to Buf registry, publish to NPM + JSR | `push: tags: v*` **or** `workflow_dispatch` | No — TypeScript only |
| `pull_request.yml` | Buf format/lint/breaking-change check on the `.proto` schema itself | `pull_request` (all) | No — proto-schema only (indirectly upstream of KMP's inputs) |
| `schema-registry.yml` | Push schema to Buf registry on every `master` commit | `push: branches: master` | No |
| `snapshot-kmp.yml` | Build + publish a uniquely-versioned KMP snapshot to Central Portal snapshots repo | `push: branches: master` paths: proto/`packages/kmp/**` **or** `workflow_dispatch` | **Yes — KMP snapshot publish** |

**So: 3 of 7 workflows touch KMP** (`kmp-pull-request.yml`, `publish-kmp.yml`,
`snapshot-kmp.yml`); the other 4 are TS/NPM/JSR/Buf-registry concerns. KMP does have its own
dedicated PR-gate and publish/snapshot workflows — it is *not* CI-less — but none of the 3 run
any lint/format/BCV/coverage step; they only build (and, for the two publish workflows,
publish).

All three KMP workflows run on `macos-latest` (needed for Apple/tvOS native compilation) and
use `gradle/actions/setup-gradle@v6` for caching. None declare a `concurrency:` group. All
declare explicit least-privilege `permissions:` blocks. No workflow in the repo (KMP or
otherwise) pins a `uses:` action to a commit SHA — every reference is a floating major-version
tag (`actions/checkout@v7`, `actions/setup-java@v5`, `android-actions/setup-android@v4`,
`gradle/actions/setup-gradle@v6`, `bufbuild/buf-action@v1.4.0`, etc.).

Renovate (`renovate.json`, extends `config:recommended` + a custom regex manager for
version-in-comment patterns inside workflow YAML) is active and demonstrably keeps the KMP
toolchain current — 4 of the last ~15 commits touching `packages/kmp` are Renovate-authored
version bumps (Gradle 9.6.1, Wire 6.4.5, AGP-KMP-plugin 9.3.0, vanniktech-publish 0.37.0).

### Docs

Root `README.md` (23 lines) is monorepo-level: badges (CI — broken link, see scorecard #39;
CLA-assistant; Fiscal-Contributors; Vercel), a one-line overview, a link to Buf's hosted schema
docs, and a "Generated client packages" list naming `packages/ts`, `packages/rust`,
`packages/kmp` (lines 14-18).

`packages/kmp/README.md` (117 lines) is the actual KMP-specific documentation and is
genuinely strong on *versioning mechanics* — it has a full table of version-by-context
(release/snapshot/local/override, lines 18-23) and several paragraphs explaining the
dot-vs-hyphen Maven version-ordering trick used for snapshots (lines 25-38, 65-91), which is
unusually rigorous for a generated-code module. It is weaker on *usage*: it tells a consumer
exactly which coordinate to depend on for every platform (lines 42-61) but never shows a line
of Kotlin actually using a generated model.

No Dokka, no published API docs site, no samples module, no `CHANGELOG.md`, no `Module.md`.

### Org alignment

License is consistently GPLv3 everywhere it's declared (root `LICENSE`, POM, packaged into
every jar). Repo metadata (`gh repo view`) is complete and sensible (description, homepage,
11 topics, default branch `master`). Community-health files are thin: only a
`pull_request_template.md` exists (proto/hardware-focused, not KMP-aware), and there is no
`CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CODEOWNERS`, or `ISSUE_TEMPLATE/`
anywhere in the repo. Group/artifact naming (`org.meshtastic:protobufs*`) is consistent with
sibling `org.meshtastic` artifacts from other Meshtastic repos observed live on Maven Central.

## Notable strengths (ranked)

1. **Verified, broad platform coverage.** 14 KMP targets declared in `build.gradle.kts:38-62`
   are *all* confirmed actually published and version-matched (`2.7.26`) on Maven Central —
   not just aspirational build config.
2. **Modern, correctly-wired publish stack.** vanniktech maven-publish 0.37.0 → Central Portal
   (not legacy OSSRH), `automaticRelease=true`, conditional GPG signing confirmed live via
   `.asc` files on every artifact, complete POM, Gradle Module Metadata.
3. **Unusually rigorous version-scheme design and documentation.** The dot-vs-hyphen
   Maven-ordering trick for snapshot coordinates is both correctly implemented
   (`build.gradle.kts:8-29`, `snapshot-kmp.yml:39-60`) and thoroughly explained inline and in
   the README — rare care for a generated-code module.
4. **Healthy, active snapshot pipeline.** `snapshot-kmp.yml` has 41 successful automatic runs
   off `master` pushes, giving downstream KMP consumers a continuously fresh dependency.
5. **Dense, enforced proto documentation** (high `/* */` comment density in `.proto` sources,
   PR-template checklist mandating message/enum comments) sets Wire up to generate
   well-documented Kotlin even with zero hand-written KDoc.

## Notable gaps / risks (ranked, framed for a generated-code KMP artifact in a TS-primary monorepo)

1. **The tag-triggered Maven Central release path has never fired automatically.** All 3
   recorded `publish-kmp.yml` runs are `workflow_dispatch`; `v2.7.26` sat unpublished to
   Central for ~1 month after its tag/GitHub-release before two manual dispatches produced it
   today. The `on: push: tags: v*` trigger is unverified in practice.
2. **No API/binary-compatibility safety net** (no BCV, no `.api` dumps, no `explicitApi()`)
   despite 14 published targets and named real consumers — nothing catches an accidental
   breaking change in generated models before it reaches Maven Central.
3. **No Kotlin-level code-quality gate in CI** — no ktlint/detekt/spotless, no `.editorconfig`.
   Proto-level Buf linting exists but lives in a separate, repo-wide workflow uninvolved with
   `packages/kmp`.
4. **Workflow hardening is half-done.** Least-privilege `permissions:` blocks are consistently
   present (good), but *zero* actions across all 7 workflows are SHA-pinned (all float on
   `@vN` tags) and *no* workflow declares a `concurrency:` group.
5. **Shipped javadoc jar is an empty 261-byte stub** (verified on Maven Central for both the
   root and per-platform artifacts) — no Dokka plugin means Central/IDE consumers get no
   rendered API reference, despite the source protos being densely doc-commented.
6. **No BOM for this artifact**, unlike sibling `org.meshtastic` libraries (`sdk-bom`,
   `mqtt-client-bom`) — would help consumers pin the 14 platform-suffixed artifacts coherently.
7. **Thin community/governance files for a Maven Central publisher**: no `SECURITY.md`, no
   `CODEOWNERS`, no `CONTRIBUTING.md`/`CODE_OF_CONDUCT.md`, no `ISSUE_TEMPLATE/`; the one PR
   template is hardware/proto-centric, not KMP-aware.
8. **Root README's CI badge links to a nonexistent `ci.yml`** (no such workflow file exists
   among the repo's 7), and neither README carries a Maven Central version badge or an actual
   Kotlin usage/quick-start snippet — only dependency-coordinate listings.
