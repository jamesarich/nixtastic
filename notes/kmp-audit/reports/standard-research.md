# The 2026 Gold Standard for a Kotlin Multiplatform (KMP) Library

**Purpose.** A concrete, citeable, checklist-style standard for building, testing, documenting, and publishing a Kotlin Multiplatform library, reflecting best practice as of **2026-07-21**. This is the reference against which we audit Meshtastic's KMP libraries.

**Method.** Version numbers are verified against upstream release pages, the GitHub Releases API, Maven Central, plugins.gradle.org, and the official Kotlin/Sonatype/Gradle/Android docs — not memory. Real conventions are corroborated by inspecting exemplar KMP repos: square/okio, cashapp/sqldelight, InsertKoinIO/koin, Kotlin/kotlinx-datetime, Kotlin/kotlinx.coroutines, touchlab/Kermit, russhwolf/multiplatform-settings. Each criterion states the best practice, why it matters, the concrete tool/version, and a citation.

> **Reality is ahead of the brief.** The task assumed Kotlin ~2.2.x and Gradle ~9.x. Verified today: **Kotlin 2.4.10**, **Gradle 9.6.1**, **AGP 9.3.0**. Kotlin 2.2.0 remains notable only as the release that introduced built-in ABI validation.
>
> Legend: **[REQUIRED]** = table-stakes for a credible 2026 KMP library; **[RECOMMENDED]** = strong best practice; **[EMERGING]** = where the ecosystem is heading — adopt deliberately.

---

## Executive reference versions (verified 2026-07-21)

| Tool | Version | Released | Source |
|---|---|---|---|
| Kotlin | **2.4.10** | 2026-07-14 | https://kotlinlang.org/docs/releases.html |
| Gradle (wrapper) | **9.6.1** | 2026-07-06 | https://docs.gradle.org/current/release-notes.html |
| Android Gradle Plugin | **9.3.0** (min Gradle 9.5.0) | Jul 2026 | https://developer.android.com/build/releases/agp-9-3-0-release-notes |
| Dokka (v2) | **2.2.0** (plugin id `org.jetbrains.dokka`) | 2026-03-26 | https://plugins.gradle.org/plugin/org.jetbrains.dokka |
| Kover | **0.9.9** | 2026-07-17 | https://github.com/Kotlin/kotlinx-kover/releases |
| binary-compatibility-validator (standalone) | **0.18.1** | 2025-07-09 | https://github.com/Kotlin/binary-compatibility-validator/releases/latest |
| Built-in ABI validation | KGP **2.2.0+**, Experimental | — | https://kotlinlang.org/docs/gradle-binary-compatibility-validation.html |
| vanniktech gradle-maven-publish-plugin | **0.37.0** | 2026-06-21 | https://github.com/vanniktech/gradle-maven-publish-plugin/releases/tag/0.37.0 |
| gradle/actions/setup-gradle | **v6.2.0** | 2026-06-12 | https://github.com/gradle/actions/releases |
| actions/checkout | **v7.0.1** | 2026-07-20 | https://github.com/actions/checkout/releases |
| actions/setup-java (Temurin) | **v5.6.0** | 2026-07-16 | https://github.com/actions/setup-java/releases |
| codecov/codecov-action | **v7.0.0** | 2026-06-07 | https://github.com/codecov/codecov-action/releases |
| Spotless (Gradle plugin) | **8.8.0** | 2026-06-29 | https://github.com/diffplug/spotless/releases |
| ktlint (engine/CLI) | **1.8.0** | 2025-11-14 | https://github.com/ktlint/ktlint/releases |
| ktlint-gradle (`org.jlleitschuh.gradle.ktlint`) | **14.2.0** | 2026-03-12 | https://github.com/JLLeitschuh/ktlint-gradle/releases |
| detekt (stable) | **1.23.8** (2.0.0 still alpha, id `dev.detekt`) | 2025-02-21 | https://github.com/detekt/detekt/releases |
| Kotest | **6.2.3** | 2026-07-20 | https://github.com/kotest/kotest/releases |
| kotlin.test | tracks Kotlin | — | bundled |

---

## 1. Build logic  **[REQUIRED baseline]**

### 1.1 Pin Gradle via the wrapper, with checksum verification
**Practice.** Commit `gradle/wrapper/gradle-wrapper.properties` pinning **Gradle 9.6.1**, and include `distributionSha256Sum` so the wrapper distribution is integrity-checked. **Why.** Reproducible builds and supply-chain safety; a tampered wrapper is a known attack vector. **Exemplar.** cashapp/sqldelight pins `gradle-9.5.1-bin.zip` *with* `distributionSha256Sum=...` — https://github.com/sqldelight/sqldelight/blob/master/gradle/wrapper/gradle-wrapper.properties. **Source.** https://docs.gradle.org/current/release-notes.html

### 1.2 Version catalog: `gradle/libs.versions.toml`  **[REQUIRED]**
**Practice.** Centralize every dependency and plugin version in `gradle/libs.versions.toml`. **Why.** Single source of truth, type-safe accessors, and it is the unit Renovate/Dependabot update. **Universal** across every exemplar inspected (okio, sqldelight, koin, Kermit, multiplatform-settings). **Source.** https://docs.gradle.org/current/userguide/version_catalogs.html

### 1.3 Convention plugins via a `build-logic` composite build  **[RECOMMENDED]**
**Practice.** Factor shared build configuration (KMP setup, publishing, Dokka, quality gates) into precompiled convention plugins in an included build (`pluginManagement { includeBuild("build-logic") }` or `"convention-plugins"`). **Why.** DRY across modules, testable build logic, and it avoids cross-project `subprojects {}`/`allprojects {}` coupling (which also breaks the configuration cache). **Exemplars.** touchlab/Kermit — `settings.gradle.kts` has `pluginManagement { includeBuild("convention-plugins") }` (https://github.com/touchlab/Kermit/blob/main/settings.gradle.kts); russhwolf/multiplatform-settings keeps a separate `conventionKotlin` version for its convention plugins.

### 1.4 Declare targets and let the default hierarchy template wire intermediate source sets  **[REQUIRED]**
**Practice.** Declare only the targets you ship; the Kotlin Gradle plugin **auto-applies `applyDefaultHierarchyTemplate()`**, creating intermediate source sets (e.g. `iosMain` over `iosArm64Main`/`iosSimulatorArm64Main`/`iosX64Main`, `appleMain`, `nativeMain`). Call `applyDefaultHierarchyTemplate()` explicitly only when adding custom intermediate sets; disable via `kotlin.mpp.applyDefaultHierarchyTemplate=false`. **Why.** Hand-wiring `dependsOn` graphs is error-prone; the template is the supported convention for sharing code across target families. **Recommended target set** (tiered): baseline `jvm`, `androidTarget`, `iosArm64`, `iosSimulatorArm64`, `iosX64`; wide adds `macosArm64/macosX64`, `tvos*`, `watchos*`, `linuxX64/linuxArm64`, `mingwX64`, `js(IR){browser();nodejs()}`; **[EMERGING]** `wasmJs` (now a first-class, documented target featured in the official library tutorial) and `wasmWasi`. Note: multiple JVM targets, JVM+Android, or multiple JS targets cannot share one source set. **Sources.** https://kotlinlang.org/docs/multiplatform/multiplatform-hierarchy.html , https://kotlinlang.org/docs/multiplatform/create-kotlin-multiplatform-library.html , https://kotlinlang.org/docs/wasm-overview.html

### 1.5 `explicitApi()` for every library module  **[REQUIRED]**
**Practice.** Enable explicit API mode in `kotlin { explicitApi() }` (fail) or `explicitApiWarning()`, or `kotlin.explicitApi=strict`. **Why.** Forces visibility modifiers and explicit return/property types on public declarations so type inference cannot silently alter the public API — a prerequisite for stable API management. **Source.** https://kotlinlang.org/docs/api-guidelines-simplicity.html

### 1.6 `jvmToolchain(N)` to pin the JVM  **[REQUIRED]**
**Practice.** `kotlin { jvmToolchain(17) }` (17 is the safe library floor — vanniktech 0.37.0's minimum JDK; use 21 to match the official CI sample). **Why.** Consistently sets `jvmTarget` across Kotlin/Java compile, test, and javadoc tasks and provisions a matching JDK, eliminating JVM-target-compatibility errors. **Source.** https://kotlinlang.org/docs/gradle-configure-project.html

### 1.7 Gradle configuration cache on by default  **[RECOMMENDED]**
**Practice.** Enable `org.gradle.configuration-cache=true` (and `--parallel`, caching) in `gradle.properties`. KGP is configuration-cache compatible (lazy task registration since 1.8.20). **Caveat.** The vanniktech publish plugin is **not** configuration-cache compatible during publishing — run publish tasks with `--no-configuration-cache` (see §2). **Why.** Large speedups on incremental and CI builds. **Source.** https://kotlinlang.org/docs/gradle-configure-project.html

---

## 2. Publishing to Maven Central

### 2.1 Use the Central Portal, not legacy OSSRH  **[REQUIRED]**
**Practice.** Publish through the **Sonatype Central Portal** (`central.sonatype.com`). **Why.** OSSRH (`oss.sonatype.org`, Nexus Repository Manager v2) reached **end-of-life 30 June 2025**; namespaces were migrated to the Portal (same login). A temporary "OSSRH Staging API" compatibility shim exists, but new work targets the Portal. **Sources.** https://central.sonatype.org/news/20250326_ossrh_sunset/ , https://central.sonatype.org/pages/ossrh-eol/

### 2.2 Use the vanniktech gradle-maven-publish-plugin  **[RECOMMENDED — official + de-facto]**
**Practice.** Use **`com.vanniktech.maven.publish` 0.37.0**. It is the plugin the **official Kotlin "Publish your library to Maven Central" tutorial recommends**, and it auto-detects the KMP/Android/Java plugins and configures every target's publication, the root `-kotlinMultiplatform` module, `metadata`, Gradle Module Metadata, and the sources + javadoc/Dokka jars automatically. **Why.** Hand-rolled `maven-publish` for KMP must wire one publication per target plus shared metadata — error-prone (missing platform artifacts, broken sources/javadoc jars). **Verified.** 0.37.0 (2026-06-21); min JDK 17 / Gradle 9.0.0 / AGP 8.13.0 / Kotlin 2.2.0; tested up to JDK 26 / Gradle 9.6.0 / AGP 9.2.1 / Kotlin 2.4.0. *(The official docs page still shows `0.36.0` in its snippet — docs lag; 0.37.0 is the current release, confirmed via GitHub Releases API.)* **Sources.** https://kotlinlang.org/docs/multiplatform/multiplatform-publish-libraries-to-maven.html , https://github.com/vanniktech/gradle-maven-publish-plugin/releases/tag/0.37.0 , https://vanniktech.github.io/gradle-maven-publish-plugin/central/

### 2.3 Minimal correct configuration  **[REQUIRED]**
```kotlin
plugins { id("com.vanniktech.maven.publish") version "0.37.0" }
mavenPublishing {
  publishToMavenCentral()          // targets the Central Portal
  signAllPublications()            // GPG signature on every artifact (Central requires it)
  coordinates("com.example", "my-kmp-lib", "1.2.3")
  pom {
    name = "My KMP Library"; description = "..."; url = "https://github.com/example/my-kmp-lib"
    licenses { license { name = "..."; url = "..." } }
    developers { developer { id = "..."; name = "..."; email = "..." } }
    scm { url = "..."; connection = "..."; developerConnection = "..." }
  }
}
```
Use `publishAndReleaseToMavenCentral` to also auto-release the deployment (skip the manual portal "publish" click). **Source.** https://vanniktech.github.io/gradle-maven-publish-plugin/central/

### 2.4 Satisfy Central's requirements  **[REQUIRED]**
Every release must carry: complete POM (`groupId`/`artifactId`/non-SNAPSHOT `version`; `name`, `description`, `url`; ≥1 `license` name+url; `developers`; `scm` connection/developerConnection/url); matching `-sources.jar` and `-javadoc.jar`; `.md5`+`.sha1` checksums; and a `.asc` PGP signature per file. **Source.** https://central.sonatype.org/publish/requirements/

### 2.5 GPG signing with in-memory keys in CI  **[REQUIRED]**
`signAllPublications()` plus an ASCII-armored key passed as env/Gradle properties — never a committed keyring:
`ORG_GRADLE_PROJECT_signingInMemoryKey`, `...signingInMemoryKeyId` (optional), `...signingInMemoryKeyPassword` (export via `gpg --export-secret-keys --armor <id>`). **Source.** https://vanniktech.github.io/gradle-maven-publish-plugin/central/

### 2.6 SNAPSHOTs  **[RECOMMENDED]**
Publish pre-release SNAPSHOTs to **`https://central.sonatype.com/repository/maven-snapshots/`**. They receive no validation, are mutable, and are pruned after ~90 days — for integration testing only. **Source.** https://central.sonatype.org/publish/publish-portal-snapshots/

### 2.7 Publish a BOM for multi-module libraries  **[RECOMMENDED]**
Ship a `java-platform` BOM so consumers align all of a library's modules with one import (e.g. `kotlinx-coroutines-bom`, `okio-bom`). **Why.** Eliminates version skew across a library's own module family.

### 2.8 Release from CI on a git tag, on a macOS runner  **[REQUIRED for KMP]**
Trigger on a tag; run publish on **`macos-latest`** (only macOS can build the Apple/native artifacts that must be in the release); serialize the upload; guard with `concurrency`. **Exemplar (cashapp/sqldelight `Release.yml`):** `on: push: tags: ['*']`; `concurrency: {group: "release-${{ github.ref }}", cancel-in-progress: false}`; job `runs-on: macos-latest`, `permissions: {contents: read}`; `./gradlew publishToMavenCentral --no-parallel` with `ORG_GRADLE_PROJECT_mavenCentralUsername/Password` (`SONATYPE_CENTRAL_*`) and `signingInMemoryKey/Password` (GPG) secrets; a final tag-guarded job cuts the GitHub Release from changelog notes. Add `--no-configuration-cache` (vanniktech is not config-cache compatible during publish). **Sources.** https://github.com/sqldelight/sqldelight/blob/master/.github/workflows/Release.yml , https://kotlinlang.org/docs/multiplatform/multiplatform-publish-libraries-to-maven.html

---

## 3. API stability  **[REQUIRED for a public library]**

### 3.1 Track the ABI with a checked-in dump
**Practice.** Enforce binary compatibility by committing an API dump and failing CI on unreviewed changes. Two options today:
- **Standalone JetBrains binary-compatibility-validator (BCV) 0.18.1** — id `org.jetbrains.kotlinx.binary-compatibility-validator`; `./gradlew apiDump` writes `api/*.api`, `apiCheck` (wired into `check`) fails on drift. **Stable, and universal across exemplars** (okio, sqldelight, koin, Kermit all pin **0.18.1**; multiplatform-settings 0.16.3).
- **[EMERGING] Kotlin built-in ABI validation** — ships in **KGP 2.2.0+**, still **Experimental** (opt-in `@OptIn(...ExperimentalAbiValidation::class)`). Enable in `kotlin { abiValidation { … } }`; tasks `checkLegacyAbi` / `updateLegacyAbi`. Stabilization tracked in YouTrack **KT-71172**.

**Direction.** Standalone BCV is now in **maintenance mode** (critical fixes + new-Kotlin support only); feature work has moved into the KGP built-in validator. **Recommendation:** use **BCV 0.18.1** for production stability today; pilot the built-in `abiValidation {}` DSL where you accept the experimental opt-in, and plan to migrate as it stabilizes. **Sources.** https://github.com/Kotlin/binary-compatibility-validator , https://kotlinlang.org/docs/gradle-binary-compatibility-validation.html

### 3.2 `explicitApi()` is the foundation
BCV/ABI validation is only meaningful when the public surface is explicit — see §1.5. Pair them. **Source.** https://kotlinlang.org/docs/api-guidelines-backward-compatibility.html

---

## 4. Testing & coverage

### 4.1 `kotlin.test` in `commonTest` by default  **[REQUIRED]**
**Practice.** Write shared tests in `commonTest` using **`kotlin.test`** (bundled with Kotlin, fully multiplatform, zero external test-dependency added to your graph; delegates to JUnit on JVM, native runners on Apple, etc.). Put platform-specific tests in `jvmTest`, `androidUnitTest`, `iosSimulatorArm64Test`, `jsTest`, `linuxX64Test`, … ; `./gradlew allTests` aggregates. **Sources.** https://www.jetbrains.com/help/kotlin-multiplatform-dev/multiplatform-run-tests.html

### 4.2 Kotest where its power helps  **[RECOMMENDED, optional]**
**Practice.** Add **Kotest 6.2.3** for rich spec styles, nested/data-driven/property tests, or coroutine-test ergonomics; Kotest 6.x is genuinely multiplatform (JVM/Android, Native, JS, Wasm) with the `io.kotest.multiplatform` plugin. Popular middle ground: keep `kotlin.test` as runner + add only `kotest-assertions-core`. Trade-off: Kotest tracks new Kotlin versions more slowly than bundled `kotlin.test`. **Sources.** https://kotest.io/docs/release6/ , https://klibs.io/project/kotest/kotest

### 4.3 Coverage with Kover — know the JVM-only limit  **[RECOMMENDED]**
**Practice.** Use **Kover 0.9.9** (`org.jetbrains.kotlinx.kover`). Generate Codecov XML with `./gradlew koverXmlReport` (JaCoCo-compatible). **Critical caveat:** Kover instruments **only JVM/Android bytecode** — you measure common code as exercised by JVM tests; Native/JS/Wasm execution is not counted. Do not claim "multiplatform coverage." **Gate:** configure `kover { reports { verify { rule { minBound(NN) } } } }` and wire **`koverVerify`** into `check` to fail CI below threshold. **Source.** https://kotlin.github.io/kotlinx-kover/gradle-plugin/

### 4.4 Upload coverage to Codecov  **[RECOMMENDED]**
**Practice.** After `koverXmlReport`, upload `build/reports/kover/report.xml` with **`codecov/codecov-action@v7.0.0`** (SHA-pinned, `CODECOV_TOKEN` secret). **Source.** https://github.com/codecov/codecov-action/releases

---

## 5. CI/CD (GitHub Actions)

### 5.1 Multiplatform matrix: Linux for JVM/JS/Linux/Android, macOS for Apple  **[REQUIRED]**
**Practice.** Fan out per-OS: `ubuntu-latest` for `jvmTest`/`jsTest`/`linuxX64Test`/Android; **`macos-latest` for `ios*`/`macos*`/`tvos*`/`watchos*`** (and any cinterop/CocoaPods). **Why.** Apple targets link with the Xcode toolchain, which exists only on macOS; Kotlin/Native's target-support matrix requires a macOS host for Apple targets. Keep macOS jobs scoped (they cost more). **Exemplars.** sqldelight `PR.yml` matrix `os: [macOS-14, windows-latest, ubuntu-latest]` splitting `iosX64Test`/`linuxX64Test`/`mingwX64Test` by OS; Kermit `build_mac.yml` on `macos-latest`. **Sources.** https://kotlinlang.org/docs/multiplatform/github-actions-for-kmp.html , https://kotlinlang.org/docs/native-target-support.html , https://github.com/sqldelight/sqldelight/blob/master/.github/workflows/PR.yml

### 5.2 Cache with `gradle/actions/setup-gradle@v6.2.0`  **[REQUIRED]**
**Practice.** Use `gradle/actions/setup-gradle` (v6.2.0) — caches the Gradle User Home (wrapper dists, `modules-2` dependencies, compiled scripts, transformed jars, `build-cache-1`). Cache is **written only from default-branch jobs**; feature branches read-only (prevents cache poisoning). Also caches `~/.konan` for Kotlin/Native (Kermit does this explicitly). **Source.** https://github.com/gradle/actions/blob/main/docs/setup-gradle.md

### 5.3 Harden every workflow  **[REQUIRED]**
- **SHA-pin third-party actions** to a full 40-char commit SHA with a version comment: `actions/checkout@<sha> # v7.0.1`. A tag is mutable and can be re-pointed by a compromised maintainer; a SHA is immutable. (Real-world nuance: even top KMP repos often still use major-tag pins like `@v7` — SHA-pinning is the hardening bar to hold *our* repos to.) Let Renovate bump pins while preserving the comment.
- **Least privilege:** top-level `permissions: { contents: read }`, elevate per-job only where needed (e.g. `contents: write` on the release job). sqldelight sets `contents: read` on every job.
- **Cancel superseded runs:** `concurrency: { group: ${{ github.workflow }}-${{ github.ref }}, cancel-in-progress: true }` (use `cancel-in-progress: false` on release jobs).
**Sources.** OpenSSF Scorecard Pinned-Dependencies — https://github.com/ossf/scorecard/blob/main/docs/checks.md ; GitHub secure-use — https://docs.github.com/en/actions/reference/security/secure-use

### 5.4 Standard action versions
`actions/checkout@v7.0.1`, `actions/setup-java@v5.6.0` (`distribution: temurin`), `gradle/actions/setup-gradle@v6.2.0`, `codecov/codecov-action@v7.0.0`. **Sources.** respective release pages above.

### 5.5 CI job set for a KMP library  **[REQUIRED]**
Lint/format (`spotlessCheck` / `ktlintCheck`) → detekt → **API check** (`apiCheck` or `checkLegacyAbi`) → build+test matrix → coverage (`koverXmlReport` + `koverVerify`, upload to Codecov) → docs build (`dokkaGenerate`) → tag-triggered publish (§2.8). sqldelight additionally runs `test -z "$(git status --porcelain)"` to assert generated/API/committed files are current.

### 5.6 Dependency automation: Renovate preferred  **[RECOMMENDED]**
**Practice.** Prefer **Renovate** over Dependabot for KMP: first-class Gradle **version-catalog** support (`gradle/*.versions.toml`), grouping, scheduling, automerge-on-green, and it updates SHA-pinned actions while keeping the version comment. Dependabot is a fine GitHub-native fallback for security-only updates. **Sources.** https://docs.renovatebot.com/java/ , https://appsecsanta.com/sca-tools/dependabot-vs-renovate

---

## 6. Documentation

### 6.1 Dokka v2 for API docs  **[REQUIRED]**
**Practice.** Generate API docs with **Dokka 2.2.0**. **Important correction to a common assumption: the Gradle plugin id did *not* change — it is still `org.jetbrains.dokka`.** What changed in "Dokka v2" (Dokka Gradle Plugin, rebuilt on Dokkatoo with a top-level DSL and K2 analysis) is the *implementation, DSL, and task names* — e.g. `dokkaHtml` → `dokkaGenerate` / `dokkaGeneratePublicationHtml` (sqldelight's CI already invokes `dokkaGeneratePublicationHtml`). v2 became the **default in Dokka 2.1.0**; v1 is deprecated and being removed. During migration you may temporarily set `org.jetbrains.dokka.experimental.gradlePlugin.v2=true` (unnecessary on 2.1.0+). **Sources.** https://plugins.gradle.org/plugin/org.jetbrains.dokka , https://kotlinlang.org/docs/dokka-migration.html

### 6.2 Publish API docs to GitHub Pages  **[RECOMMENDED]**
**Practice.** A CI job builds Dokka HTML and deploys to GH Pages (with versioned docs, e.g. mike/mkdocs as sqldelight does via `Publish-Website.yml`; Kermit uses a Docusaurus template). **Exemplars.** https://github.com/sqldelight/sqldelight/blob/master/.github/workflows/Publish-Website.yml

### 6.3 KDoc on all public declarations  **[REQUIRED]**
**Practice.** Every public/`explicitApi` declaration carries KDoc (summary, `@param`, `@return`, `@throws`, `@sample`). Explicit API mode makes the public surface obvious to document. **Source.** https://kotlinlang.org/docs/api-guidelines-simplicity.html

### 6.4 README structure  **[REQUIRED]**
Badges (Maven Central version, build, license, Kotlin version) → one-line description → **platform-support table** (target × supported) → install (catalog + Gradle snippet with current coordinate) → quickstart → links to API docs/changelog. Confirm target coverage via **klibs.io** project pages.

### 6.5 CHANGELOG (Keep a Changelog)  **[REQUIRED]**
Maintain `CHANGELOG.md` in **keepachangelog.com** format; automate with `org.jetbrains.changelog` (sqldelight pins **2.5.0**) and feed release notes into the GitHub Release (sqldelight extracts them in `Release.yml`). **Source.** https://keepachangelog.com/

### 6.6 Samples module  **[RECOMMENDED]**
Ship a `sample`/`samples` module that consumes the library as a real dependency and is built in CI (sqldelight builds `sample` and `sample-web` on macOS; Kermit does `publishToMavenLocal` then runs `ci-test-samples.sh`). **Why.** Guarantees the published artifact is actually consumable and keeps docs honest.

---

## 7. Code quality

### 7.1 Formatting: Spotless + ktlint, driven by `.editorconfig`  **[REQUIRED]**
**Practice.** **Spotless 8.8.0** (`com.diffplug.spotless`) as the aggregating gatekeeper with its Kotlin step wired to **ktlint 1.8.0**; `spotlessCheck` in CI, `spotlessApply` locally. Or use the standalone **ktlint-gradle 14.2.0** wrapper — pick one to avoid double-formatting. Both read **`.editorconfig`** as ktlint's primary config surface: `ktlint_code_style = ktlint_official`, per-rule `ktlint_standard_<rule> = disabled`, and `indent_size`/`indent_style`/`max_line_length` — one file drives IDE, Spotless, and CLI identically. *(Note: Spotless now versions modules independently — the Gradle plugin is 8.8.0; don't confuse it with the core lib 4.8.0. And ktlint moved orgs: `pinterest/ktlint` → `ktlint/ktlint`.)* **Sources.** https://github.com/diffplug/spotless/releases , https://github.com/ktlint/ktlint , https://github.com/JLLeitschuh/ktlint-gradle/releases

### 7.2 Static analysis: detekt  **[RECOMMENDED]**
**Practice.** Add **detekt 1.23.8** (`io.gitlab.arturbosch.detekt`) for complexity/code-smell/bug/design analysis — complementary to formatters, not a replacement. For KMP, the plain `detekt` task under-analyzes; use a **`detektAll`** aggregator that `dependsOn` the per-source-set tasks (or `source.setFrom(...)` across all sets). **2.0.0 is still alpha** (new id `dev.detekt`, immutable `Property` API, per-compilation tasks that fix the KMP gap) — do not adopt for production yet. Avoid enabling `detekt-formatting` if ktlint already runs via Spotless (overlap). **Sources.** https://detekt.dev/docs/introduction/migration/ , https://github.com/detekt/detekt/releases

### 7.3 `.editorconfig` committed at repo root  **[REQUIRED]**
Single formatting contract for humans, IDEs, and tooling (see §7.1).

---

## Appendix A — Exemplar raw findings

### Batch 2 (researched directly)

**cashapp/sqldelight** — Kotlin **2.3.10**, Gradle **9.5.1** (wrapper pins `distributionSha256Sum`), AGP **9.2.1** via `com.android.kotlin.multiplatform.library`; Dokka **2.2.0**; publishing vanniktech **0.36.0**; API stability **BCV 0.18.1**; quality Spotless **8.7.0** + ktlint **1.7.1**; changelog `org.jetbrains.changelog` **2.5.0**; no Kover. CI `PR.yml`: `os:[macOS-14,windows-latest,ubuntu-latest]`, native tests split by OS, `spotless` job, `gradle/actions/setup-gradle@v6`, `permissions: contents: read` per job, sample builds on `macos-15`, `git status --porcelain` clean-tree check; actions major-tag-pinned (not SHA). `Release.yml`: tag-triggered, `concurrency`, `publishToMavenCentral --no-parallel` on `macos-latest` with `SONATYPE_CENTRAL_*` + GPG in-memory secrets. Files: https://github.com/sqldelight/sqldelight/blob/master/gradle/libs.versions.toml , https://github.com/sqldelight/sqldelight/blob/master/.github/workflows/PR.yml , https://github.com/sqldelight/sqldelight/blob/master/.github/workflows/Release.yml

**InsertKoinIO/koin** — Kotlin **2.3.20**, AGP **8.13.2**, Dokka **2.1.0**; **BCV 0.18.1**; publishing via `io.github.gradle-nexus.publish-plugin` **2.0.0** **plus** `com.gradleup.nmcp.aggregation` **1.3.0** (NMCP = "New Maven Central Publishing", a Portal-native aggregation plugin — the notable alternative to vanniktech). Nested build under `projects/`. File: https://github.com/InsertKoinIO/koin/blob/main/projects/gradle/libs.versions.toml

**touchlab/Kermit** — Kotlin **2.2.0**, Gradle **8.14.4**, AGP **8.12.3**, Dokka **2.0.0**; **build-logic present** (`pluginManagement { includeBuild("convention-plugins") }`); publishing vanniktech **0.34.0**; **BCV 0.18.1**; ktlint via `org.jlleitschuh.gradle.ktlint` **12.3.0**; docs via Docusaurus template; wasm signals present; multi-module. CI `build_mac.yml` on `macos-latest`, caches `~/.konan`, `publishToMavenLocal` to test samples (uses older checkout@v2/setup-java@v2 — weaker hardening example). Files: https://github.com/touchlab/Kermit/blob/main/settings.gradle.kts , https://github.com/touchlab/Kermit/blob/main/gradle/libs.versions.toml

**russhwolf/multiplatform-settings** — Kotlin **2.1.20** (lagging), Gradle **8.11.1**, AGP **8.7.2**; convention-plugins pattern (separate `conventionKotlin`); **BCV 0.16.3**; publishing `io.github.gradle-nexus.publish-plugin` **2.0.0** (hand-configured, pre-Portal-migration style). File: https://github.com/russhwolf/multiplatform-settings/blob/main/gradle/libs.versions.toml

**Cross-cutting (batch 2):** version catalogs universal; Dokka v2 universal; **BCV 0.18.1 universal**; convention-plugins/`includeBuild` common; publishing split between vanniktech (turnkey) and gradle-nexus+NMCP (Portal-native); macOS runner for native/release universal.

### Batch 1 (okio, kotlinx-datetime, kotlinx.coroutines)
*Pending — research stream still running; will be appended on completion.*

---

## Appendix B — Consolidated audit checklist

**Build logic:** [ ] Gradle 9.6.1 wrapper + `distributionSha256Sum` · [ ] `gradle/libs.versions.toml` · [ ] `build-logic`/convention plugins · [ ] targets + default hierarchy template · [ ] `explicitApi()` · [ ] `jvmToolchain` · [ ] configuration cache on.
**Publishing:** [ ] Central Portal (not OSSRH) · [ ] vanniktech 0.37.0 · [ ] complete POM · [ ] `signAllPublications()` + in-memory GPG · [ ] sources + Dokka javadoc jars · [ ] BOM (multi-module) · [ ] SNAPSHOTs to Portal snapshot repo · [ ] tag-triggered publish on macOS with `--no-parallel --no-configuration-cache`.
**API stability:** [ ] BCV 0.18.1 (`apiCheck` in `check`) or built-in `abiValidation` · [ ] API dump committed · [ ] `explicitApi()`.
**Testing/coverage:** [ ] `kotlin.test` in `commonTest` · [ ] per-target test sets · [ ] Kover 0.9.9 (JVM-only understood) · [ ] `koverVerify` gate in `check` · [ ] Codecov upload.
**CI/CD:** [ ] Linux+macOS matrix · [ ] `setup-gradle@v6.2.0` caching · [ ] SHA-pinned actions · [ ] `permissions: contents: read` · [ ] `concurrency` cancel · [ ] lint+detekt+apiCheck+coverage jobs · [ ] Renovate.
**Docs:** [ ] Dokka 2.2.0 (`org.jetbrains.dokka`, v2 tasks) · [ ] API docs to GH Pages · [ ] KDoc on public API · [ ] README (badges/platform table/install/quickstart) · [ ] Keep-a-Changelog · [ ] samples module built in CI.
**Quality:** [ ] Spotless 8.8.0 + ktlint 1.8.0 · [ ] detekt 1.23.8 (`detektAll` for KMP) · [ ] `.editorconfig` at root.
