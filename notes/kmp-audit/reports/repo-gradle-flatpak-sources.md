# Audit: meshtastic/gradle-flatpak-sources

Repo: `/Users/james/meshtastic/gradle-flatpak-sources` (GitHub: `meshtastic/gradle-flatpak-sources`)
Type: **Gradle plugin written in Kotlin** (NOT a KMP library) — single JVM target, `kotlin-dsl`-based.
Audited version: `0.1.4` (gradle.properties:4), current HEAD `05a7098` (2026-07-17), default branch `main`.
Audit date: 2026-07-21. Read-only; no builds executed (only `gh`, `git`, `curl`/WebFetch to public endpoints).

Rubric adaptation: rows 6, 7, 30 (KMP targets, hierarchical source sets, macOS CI matrix) are **N/A** — this
is a single-target JVM Gradle plugin, not KMP. Row 5 (build-logic composite build) is also marked **N/A**:
the project has exactly one subproject (`:plugin`), so there is nothing for convention plugins to share.
Row 21 (commonTest) is N/A/adapted. In place of the KMP-specific checks, nine Gradle-plugin-specific items
(A–I) are evaluated: `java-gradle-plugin`, `com.gradle.plugin-publish`, plugin marker artifacts, id/marker
coordinates, `gradlePlugin{}` metadata, TestKit functional tests, `validatePlugins`, plugin compatibility
declarations, and dual-publication correctness.

---

## Scorecard

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| **BUILD LOGIC** |||
| 1 | Gradle wrapper version | ✅ Present | `9.6.1` — `gradle/wrapper/gradle-wrapper.properties:3` (`distributionUrl=...gradle-9.6.1-all.zip`) |
| 2 | Kotlin version | 🟡 Partial/Info | Not independently declared. Project applies `kotlin-dsl` (`plugin/build.gradle.kts:21`), not `org.jetbrains.kotlin.jvm`, so the Kotlin compiler used is whatever Gradle 9.6.1 embeds. Web search reports Gradle 9.6.0 embeds Kotlin **2.3.21**, but I could not confirm this from a primary Gradle doc during this audit (release-notes page fetched did not state it) — treat as unverified secondary source. |
| 3 | AGP version | N/A | No Android target — pure JVM Gradle plugin. |
| 4 | Version catalog `libs.versions.toml` | ✅ Present | `gradle/libs.versions.toml` — declares `detekt` (1.23.8), `nmcp` (1.6.1), plugin aliases for `gradle-plugin-publish` (2.1.1), `detekt`, `nmcp`. No Kotlin/AGP entries needed (see #2). |
| 5 | Convention plugins via `build-logic` composite build | N/A | Single-module build — only `:plugin` (`settings.gradle.kts:19`). No `buildSrc/` or `build-logic/` present or needed. |
| 6 | KMP targets | N/A | Not a KMP project — single JVM target (compiles against Gradle API). |
| 7 | Hierarchical source sets | N/A | No KMP source sets. Plugin has only `main` and a custom `functionalTest` JVM source set (`plugin/build.gradle.kts:139-142`). |
| 8 | `explicitApi()` strict mode | ❌ Absent | `grep -rn "explicitApi"` → no hits anywhere. Internal classes are instead scoped manually via Kotlin `internal` modifier (`internal object CacheFileLocator`, `internal object MirrorGenerator`, `internal class SourcesWriter` — all under `plugin/src/main/kotlin/.../internal/`), so there is informal API discipline, just not compiler-enforced. |
| 9 | JVM toolchain pinned | ✅ Present | `JavaLanguageVersion.of(17)` — `plugin/build.gradle.kts:31-34`. `foojay-resolver-convention` applied for toolchain auto-provisioning (`settings.gradle.kts:15`). |
| 10 | Gradle config/build caching in gradle.properties | 🟡 Partial | `org.gradle.caching=true`, `org.gradle.parallel=true` (`gradle.properties:2-3`) — build cache + parallel ON. Configuration cache is **not** enabled at the root, which is consistent: the plugin itself declares configuration-cache incompatibility (see #H) and README.md:110 tells users to run with `--no-configuration-cache`. |
| **PUBLISHING** |||
| 11 | Publishing mechanism | ✅ Present | `com.gradleup.nmcp` v1.6.1 for Maven Central (`plugin/build.gradle.kts:24,131-136`) + `com.gradle.plugin-publish` v2.1.1 for the Gradle Plugin Portal (`plugin/build.gradle.kts:22`). Not vanniktech `maven-publish` plugin; not manual `maven-publish` (though `maven-publish` is present transitively via `java-gradle-plugin`, itself transitively applied by `kotlin-dsl` — see #A). |
| 12 | Central Portal vs legacy OSSRH | ✅ Present (new Central Portal) | `nmcp` tasks `publishAllPublicationsToCentralPortal` (`.github/workflows/publish.yml:40`) and `publishAllPublicationsToCentralSnapshots` (`.github/workflows/snapshot.yml:32`) are the new Sonatype Central Portal APIs. No `s01.oss.sonatype.org` / legacy OSSRH references anywhere. |
| 13 | GPG signing configured | ✅ Present, verified live | `signing` plugin + `useInMemoryPgpKeys(signingKey, signingPassword)`, `sign(publishing.publications)`, `isRequired = !version.endsWith("SNAPSHOT")` (`plugin/build.gradle.kts:123-129`). Keys injected via `ORG_GRADLE_PROJECT_signingKey`/`signingPassword` secrets in CI (`publish.yml:30-31,38-39`; `snapshot.yml:30-31`). **Verified**: every file published at `org/meshtastic/flatpak/plugin/0.1.4/` on Maven Central (jar, sources jar, javadoc jar, `.module`, `.pom`) has a matching `.asc` signature. |
| 14 | BOM module published | N/A / ❌ Absent | Single-artifact plugin; no BOM present or needed. |
| 15 | POM metadata complete | ✅ Present | `name`, `description`, `url`, `licenses` (GPL-3.0-or-later + URL), `developers` (id/name/url = meshtastic), `scm` (connection/developerConnection/url) — all set, `plugin/build.gradle.kts:93-121`. |
| 16 | Sources jar + Dokka/javadoc jar attached | 🟡 Partial | `withSourcesJar()` + `withJavadocJar()` (`plugin/build.gradle.kts:35-36`). Sources jar is substantive (14,049 bytes on Central). **Javadoc jar is a stub** — only 261 bytes on Maven Central (`plugin-0.1.4-javadoc.jar`), because no Dokka plugin is applied; the plain `javadoc` task has no `.java` sources to process, so the jar exists (satisfies Central's requirement) but carries no real API docs. |
| 17 | Group/artifact coordinates | ✅ Present, verified live | `group = "org.meshtastic.flatpak"` (`plugin/build.gradle.kts:28`), artifact id `plugin` (module name via `settings.gradle.kts:19`) → `org.meshtastic.flatpak:plugin:0.1.4`. Confirmed live on Maven Central at `org/meshtastic/flatpak/plugin/0.1.4/`, plus both plugin-marker artifacts (see #C). |
| 18 | Version single-source-of-truth | ✅ Present | `gradle.properties:4` → `version=0.1.4`; conditionally suffixed with `-SNAPSHOT` for snapshot builds (`plugin/build.gradle.kts:29`: `if (project.hasProperty("snapshotBuild")) version = "$version-SNAPSHOT"`). |
| **API & COMPAT** |||
| 19 | Binary Compatibility Validator | ❌ Absent | No `.api` dump files in repo; no BCV plugin in `libs.versions.toml`. (Less critical than for a KMP library, but the plugin's own extension DSL — `FlatpakSourcesExtension` — is an unguarded compatibility surface.) |
| **TESTING & COVERAGE** |||
| 20 | Test framework(s) | ✅ Present | JUnit 5 Jupiter via `kotlin("test-junit5")` + `gradleTestKit()` (`plugin/build.gradle.kts:47-49`), `junit-platform-launcher:6.1.2` runtime (`:49`). Assertions use `kotlin.test` (`assertEquals`/`assertTrue`). |
| 21 | `commonTest` + per-target test source sets | N/A (adapted) | Not KMP. Only source set is a custom `functionalTest` (`plugin/build.gradle.kts:139-155`). **There is no `src/test/kotlin` unit-test source set at all** — see gap list. |
| 22 | Rough test count | 7 `@Test` functions | All in one file: `plugin/src/functionalTest/kotlin/org/meshtastic/flatpak/sources/FlatpakSourcesPluginFunctionalTest.kt` (211 lines). Zero unit tests of the three internal helper classes (`CacheFileLocator`, `MirrorGenerator`, `SourcesWriter`) in isolation — all testing is black-box, via `GradleRunner.withPluginClasspath()`. |
| 23 | Coverage tool (Kover/Jacoco) | ❌ Absent | No coverage plugin in `libs.versions.toml` or build script. |
| 24 | Coverage uploaded to Codecov/other | ❌ Absent | No such step in any workflow. |
| 25 | Coverage threshold enforced | ❌ Absent | N/A given #23/#24. |
| **CODE QUALITY TOOLING** |||
| 26 | Formatter/linter + config | 🟡 Partial | detekt 1.23.8 applied (`plugin/build.gradle.kts:23,39-43`) with `detekt-formatting` (style/formatting rules, `:46`). `buildUponDefaultConfig = true`, `allRules = false` (`:40-41`) — **no custom `config/detekt/detekt.yml`** override found anywhere in the repo; runs the bundled default ruleset only. No ktlint/spotless present (`grep ktlint` → no hits). |
| 27 | `.editorconfig` present | ❌ Absent | Not found anywhere in the repo tree. |
| 28 | Pre-commit hooks / git hooks | ❌ Absent | No `.pre-commit-config.yaml`, lefthook, husky config; `git config core.hooksPath` unset. |
| **CI/CD** |||
| 29 | PR build+test workflow | ✅ Present | `.github/workflows/ci.yml` — triggers on `push`(main) + `pull_request`(main); runs `./gradlew :plugin:build :plugin:functionalTest --stacktrace` (ci.yml:29); uploads `plugin/build/reports/` on failure. |
| 30 | Multiplatform CI matrix incl. macOS runner | N/A | Single JVM target, `ubuntu-latest` only (ci.yml:12). No Apple/native targets, so no macOS runner is needed. Note: ci.yml does declare a Gradle-version matrix (`gradle: ['9.5.1']`, ci.yml:15) though it currently has just one entry — a placeholder for future multi-Gradle-version testing, not currently exercised. |
| 31 | Gradle caching in CI | ✅ Present | `gradle/actions/setup-gradle@v6` in all three workflows (ci.yml:24, publish.yml:21, snapshot.yml:21) — auto-manages Gradle User Home caching. |
| 32 | Lint/format check step in CI | 🟡 Partial/Implicit | No explicit `./gradlew detekt` step in any workflow YAML. Relies on detekt's documented default behavior of attaching its `detekt` task as a dependency of `check` (itself pulled in transitively by the `build` task run in CI) — not an explicit, independently-visible CI step, so failures would surface as part of the generic `build` step rather than being called out. |
| 33 | API-compat check step in CI | 🟡 Partial | No BCV step (see #19), but `validatePlugins` is configured strict (`enableStricterValidation = true`, `failOnWarning = true`, `plugin/build.gradle.kts:53-56`) and — per `java-gradle-plugin`'s default wiring — runs as part of `:plugin:build` in CI. This is the plugin-appropriate analogue of an API-compat gate. |
| 34 | Coverage step in CI | ❌ Absent | None of the 3 workflows run/upload coverage. |
| 35 | Publish/release workflow | ✅ Present, verified live | `.github/workflows/publish.yml`, triggered on tag push `v*` (publish.yml:5). Dual-publishes: `./gradlew :plugin:publishPlugins` → Gradle Plugin Portal (publish.yml:32), then `./gradlew :plugin:publishAllPublicationsToCentralPortal` → Maven Central (publish.yml:40). **Verified live**: both plugin ids show v0.1.4 on plugins.gradle.org; main artifact + both markers show v0.1.4 on repo1.maven.org, fully signed. Bonus: `.github/workflows/snapshot.yml` continuously publishes `-SNAPSHOT` builds to Central on every push to `main`. |
| 36 | Release automation (auto version, changelog, GH release) | 🟡 Partial/mostly manual | Version bump is a manual commit (`git log`: "release: bump version to 0.1.4", "release: bump version to 0.1.3"). **CHANGELOG.md is not updated per release** — still shows `## [0.1.2] - Unreleased` at CHANGELOG.md:8 while 0.1.4 is the live published version (2 releases' worth of changes undocumented). GH Releases are hand-authored prose (no `gh release create` / `action-gh-release` step in any workflow) — the tag push triggers `publish.yml`, but creating the GitHub Release itself is a separate manual maintainer action. |
| 37 | Workflow hardening (`concurrency` + least-privilege `permissions` + pinned SHAs) | 🟡 Partial | `permissions: contents: read` is set in `publish.yml:12` and `snapshot.yml:12` (good, least-privilege) but **`ci.yml` has no `permissions:` block at all** (falls back to repo/org default, potentially broader than needed for a PR-triggered workflow that can run on fork PRs). **No `concurrency:` block in any of the 3 workflows.** Actions are pinned to version tags (`@v7`, `@v5`, `@v6`), **not** full commit SHAs. |
| 38 | Dependency automation | ✅ Present, actively used | Renovate (`renovate.json`: extends `config:recommended`, automerge minor/patch/pin/digest, no automerge for major). Evidenced by 6 merged Renovate PRs in `git log` (#3 nmcp 1.5.0, #4 foojay-resolver v1, #6 actions/checkout v7, #7 Gradle 9.6.1, #8 nmcp 1.6.1, #9 junit-platform-launcher 6.1.2). No Dependabot config present (Renovate is the sole mechanism). |
| **DOCUMENTATION** |||
| 39 | README badges | ✅ Present | CI badge, Gradle Plugin Portal version badge, License badge, CLA-assistant badge — README.md:3-6. No coverage badge (consistent with #23/#24 absence). |
| 40 | README install snippet + quick-start | 🟡 Present but **stale** | Full "Quick Start" + "How It Works" + "Configuration" sections present (README.md:10-104). **However** the install snippet pins `version "0.1.2"` in TWO places (README.md:17 and README.md:46) even though the live published version is 0.1.4 — copy-pasting the README today installs a version two releases behind. |
| 41 | README platform-support table | N/A | Single JVM/Gradle-plugin target — no multiplatform table needed. README instead has a "Requirements" list: Gradle 9.0+, JDK 17+, `--no-configuration-cache` (README.md:106-110). |
| 42 | API docs site (Dokka) published | ❌ Absent | No Dokka plugin anywhere; no GitHub Pages / docs-publish workflow found. |
| 43 | KDoc coverage on public API | ✅ Present, high (~90-100% of true public surface) | Spot-checked: `FlatpakSourcesExtension` — every property documented (FlatpakSourcesExtension.kt:26-38 class-level + :41,44,47,50,53,57,62-67,70-75 per-property). `FlatpakSourcesPlugin` — thorough class KDoc incl. usage snippet (FlatpakSourcesPlugin.kt:35-44). `FlatpakSourcesSettingsPlugin` — thorough class KDoc incl. usage snippet (:35-52). Even `internal` helpers (`CacheFileLocator`, `MirrorGenerator`, `SourcesWriter`) are fully documented, beyond what's strictly required. |
| 44 | CHANGELOG present + maintained | 🟡 Partial | `CHANGELOG.md` exists, Keep-a-Changelog format + SemVer statement (CHANGELOG.md:1-6). But stale — see #36; `git log --oneline -- CHANGELOG.md` shows only 2 commits total in the file's history, and the newest entry is still labeled "Unreleased" under 0.1.2. |
| 45 | Samples/examples module | ❌ Absent | No `samples/`/`example/` directory; only inline README snippets. |
| 46 | Module-level docs (`Module.md`/package docs) | ❌ Absent | No `Module.md`, no `package-info.java`/package-level KDoc file found. |
| **ORG ALIGNMENT** |||
| 47 | LICENSE | 🟡 Present but non-canonical text | GPL-3.0-or-later stated in COPYING, README.md:5, README.md:124, and the POM (#15). **But** `COPYING` (23 lines) contains only the license preamble + a pointer to the full text at gnu.org — not the complete canonical ~674-line GPL-3.0 text. Corroborating evidence: `gh repo view` reports `licenseInfo: {"key":"other","name":"Other"}` — GitHub's own license detector does **not** recognize this as GPL-3.0, almost certainly because the abbreviated COPYING file doesn't match the canonical text fingerprint Licensee matches against. Net effect: no GPL-3.0 badge/pill shows on the GitHub repo page despite the project clearly intending GPL-3.0-or-later. |
| 48 | CONTRIBUTING + CODE_OF_CONDUCT | 🟡 Partial | `CONTRIBUTING.md` present and thorough (setup, code style/detekt, branch-naming convention, CLA-assistant requirement, Discord/Discussions links, issue-reporting guidance). **No local `CODE_OF_CONDUCT.md`** — CONTRIBUTING.md:55 links out to `meshtastic.org/docs/legal/conduct/` instead of including an in-repo file. |
| 49 | Issue + PR templates | 🟡 Partial | `.github/PULL_REQUEST_TEMPLATE.md` present (Description/Related Issue/Testing checklist/Checklist). **No issue templates** — `.github/ISSUE_TEMPLATE/` directory does not exist. |
| 50 | CODEOWNERS | ❌ Absent | Not found. |
| 51 | SECURITY.md | ❌ Absent | Not found. |
| 52 | Default branch | ✅ Present | `main` — confirmed both via `gh repo view` (`defaultBranchRef.name`) and local `git branch --show-current`. |
| 53 | Repo description/topics/homepage | 🟡 Partial | Description Present: "Gradle plugin for generating Flathub-compliant offline dependency manifests (flatpak-sources.json)". 10 topics Present: `dependency-management`, `flathub`, `flatpak`, `gradle`, `gradle-plugin`, `kotlin`, `linux`, `maven`, `offline`, `packaging`. **`homepageUrl` is empty** (not set). |
| 54 | Consistent group id + naming | ✅ Present (namespaced, not flat) | Coordinates `org.meshtastic.flatpak:plugin` + plugin ids `org.meshtastic.flatpak.sources`/`org.meshtastic.flatpak.sources.settings` are all consistently under the `org.meshtastic.*` namespace and match each other internally, though the groupId is the sub-namespace `org.meshtastic.flatpak` rather than a flat bare `org.meshtastic:<artifact>`. This is a reasonable, deliberate per-product namespacing choice, not an inconsistency. |
| **GRADLE-PLUGIN-SPECIFIC (replacing KMP rows 6/7/30 per task adaptation)** |||
| A | `java-gradle-plugin` applied | ✅ Present (transitive) | Not applied by explicit plugin id; comes transitively via `kotlin-dsl` (`plugin/build.gradle.kts:21`). Confirmed two ways: (1) Gradle's own docs/plugin listing for `kotlin-dsl` state it applies `java-gradle-plugin`; (2) empirically, the build successfully uses the `gradlePlugin {}` extension (only contributed by `java-gradle-plugin`) and produces the marker-artifact publications on Maven Central that only `java-gradle-plugin`'s publish wiring generates (see #C). |
| B | `com.gradle.plugin-publish` applied | ✅ Present | v2.1.1, `plugin/build.gradle.kts:22`; `gradle/libs.versions.toml:6`. |
| C | Plugin marker artifact(s) | ✅ Present, verified live | Both markers published at 0.1.4: `org.meshtastic.flatpak.sources:org.meshtastic.flatpak.sources.gradle.plugin` (repo1.maven.org: `org/meshtastic/flatpak/sources/org.meshtastic.flatpak.sources.gradle.plugin/0.1.4/`) and `org.meshtastic.flatpak.sources.settings:org.meshtastic.flatpak.sources.settings.gradle.plugin` (`org/meshtastic/flatpak/sources/settings/org.meshtastic.flatpak.sources.settings.gradle.plugin/0.1.4/`). Both marker POMs are signed (`.asc` present). |
| D | Plugin id/marker coordinates | ✅ Present | ids `org.meshtastic.flatpak.sources` and `org.meshtastic.flatpak.sources.settings` (`plugin/build.gradle.kts:65,78`). |
| E | `gradlePlugin { plugins { ... } }` metadata (id/displayName/description/tags) | ✅ Present, complete for both plugins | `plugin/build.gradle.kts:59-91`: `website`/`vcsUrl` (:60-61); per-plugin `id`, `displayName`, `description`, `implementationClass`, `tags` (:65-70, :78-83) — all fields filled, descriptions are substantive (not placeholders). |
| F | TestKit-based `functionalTest` | ✅ Present | See #20-22. `plugin/build.gradle.kts:139-155` wires a dedicated source set + `Test` task, and `tasks.check { dependsOn(functionalTestTask) }` (:155) ensures it runs as part of `check`/`build`. |
| G | `validatePlugins` task | ✅ Present, strict | `enableStricterValidation = true`, `failOnWarning = true` (`plugin/build.gradle.kts:53-56`). |
| H | Plugin compatibility declarations (min Gradle version / feature flags) | 🟡 Partial | `compatibility { features { configurationCache = false } }` declared for **both** plugins (`plugin/build.gradle.kts:71-75, 84-88`) — this uses the newer `org.gradle.plugin.compatibility.compatibility` API (import at :18). **Verified live**: the Plugin Portal page for `org.meshtastic.flatpak.sources` shows "Configuration Cache: Not supported ×". No explicit *minimum-Gradle-version* compatibility metadata is declared via the same DSL — only asserted informally in prose (README.md:108: "Gradle 9.0+"). |
| I | Dual-publication correctness (Plugin Portal + Maven Central) | ✅ Present, verified live | Confirmed independently on both registries at v0.1.4 (see #35, #13, #17, #C). All Maven Central files are GPG-signed; both Plugin Portal listings show current metadata (tags, description, compatibility). |

---

## Detailed findings

### Build logic

- Single-module build: root (`settings.gradle.kts`) includes only `:plugin` (`settings.gradle.kts:19`). Root `build.gradle.kts` is an empty stub with a comment ("Root project — no plugins applied here", `build.gradle.kts:1-3`) — no shared convention-plugin logic exists or is needed at this scale.
- `plugin/build.gradle.kts` plugin block (`:20-26`): `kotlin-dsl`, `alias(libs.plugins.gradle.plugin.publish)`, `alias(libs.plugins.detekt)`, `alias(libs.plugins.nmcp)`, `signing`. No `java-gradle-plugin` or `maven-publish` explicit ids — both arrive transitively via `kotlin-dsl` (see scorecard row A).
- Toolchain: Java 17 pinned (`:31-34`); `withSourcesJar()` + `withJavadocJar()` (`:35-36`).
- `detekt {}` block: `buildUponDefaultConfig = true`, `allRules = false`, `source.setFrom(files("src/main/kotlin"))` (`:39-43`) — scoped to main sources only (functionalTest sources are not linted).
- `gradlePlugin {}` DSL (`:59-91`) declares both plugins with full metadata plus per-plugin `compatibility { features { configurationCache = false } }`.
- `publishing {}` block (`:93-121`) configures POM for `withType<MavenPublication>` — applies uniformly to the main publication and (per `java-gradle-plugin` convention) the marker publications too.
- `signing {}` block (`:123-129`) — in-memory PGP keys from project properties/env, required unless version ends in `-SNAPSHOT`.
- `nmcp {}` block (`:131-136`) — Central Portal credentials from project property or env var fallback.
- Functional test source set wiring (`:139-155`) — extends `testImplementation`/`testRuntimeOnly` configs, registers a `functionalTest` `Test` task, wires it into `check`.
- Version: `gradle.properties:4` (`version=0.1.4`), read implicitly by Gradle's root `version` property; `-SNAPSHOT` suffix appended conditionally in `plugin/build.gradle.kts:29`.
- `gradle.properties` full contents: `org.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8`, `org.gradle.parallel=true`, `org.gradle.caching=true`, `version=0.1.4` (4 lines total).

### Publishing

- Mechanism: `com.gradle.plugin-publish` (Plugin Portal) + `com.gradleup.nmcp` (Maven Central, new Central Portal API) + Gradle's own `signing` plugin. No vanniktech `maven-publish`.
- Credentials wiring: Plugin Portal via `GRADLE_PUBLISH_KEY`/`GRADLE_PUBLISH_SECRET` env vars (standard for `com.gradle.plugin-publish`, publish.yml:28-29); Central Portal via `CENTRAL_PORTAL_USERNAME`/`PASSWORD` read from project property or env var with empty-string fallback (`plugin/build.gradle.kts:133-134`); signing key/password via `ORG_GRADLE_PROJECT_signingKey`/`signingPassword` (auto-mapped Gradle project-property convention).
- Snapshot handling: `snapshot.yml` runs `./gradlew :plugin:publishAllPublicationsToCentralSnapshots -PsnapshotBuild` on every push to `main` (snapshot.yml:32), which sets the `snapshotBuild` project property, triggering the `-SNAPSHOT` suffix in `build.gradle.kts:29`. This gives continuous snapshot delivery beyond what the rubric strictly asks for.
- Live verification (2026-07-21, via WebFetch + curl to plugins.gradle.org and repo1.maven.org):
  - `plugins.gradle.org/plugin/org.meshtastic.flatpak.sources` → latest 0.1.4, tags match repo, "Configuration Cache: Not supported".
  - `plugins.gradle.org/plugin/org.meshtastic.flatpak.sources.settings` → latest 0.1.4, tags match repo.
  - `repo1.maven.org/maven2/org/meshtastic/flatpak/plugin/0.1.4/` → jar/sources-jar/javadoc-jar/module/pom + `.asc`/`.md5`/`.sha1`/`.sha512` for each (full signing + checksums).
  - Both marker artifacts present at 0.1.4 with signed POMs.
  - **0.1.3 is absent from Maven Central** (only 0.1.0, 0.1.1, 0.1.2, 0.1.4 directories exist) — corroborated by: (a) the v0.1.4 GitHub release body stating "v0.1.3 was a burned tag — no artifacts were published under it"; (b) `gh run list` showing the `Publish` workflow run for tag `v0.1.3` has conclusion **failure** (run 29551189227, 2026-07-17T02:57:20Z, 47m29s). The `CI`/`Snapshot` workflows for the same commit succeeded — only the publish step failed. This is a real (if transparently disclosed) operational hiccup: a failed release leaves a permanent, non-functional git tag + GitHub Release with no corresponding artifacts anywhere.

### API & compatibility

- No Binary Compatibility Validator. For a Gradle plugin the more relevant compatibility surface is `FlatpakSourcesExtension`'s public properties (all `Property<T>`/`SetProperty<T>`/`ListProperty<T>`, which is itself a binary-compatible-by-design Gradle idiom) plus the two `Plugin<T>` entry points — none of which are guarded by BCV `.api` dumps.
- `validatePlugins { enableStricterValidation = true; failOnWarning = true }` (`plugin/build.gradle.kts:53-56`) is the plugin-ecosystem analogue of an API/compat gate — it fails the build on missing `@Input`/`@OutputFile` annotations, incorrect task property types, etc.

### Testing

- Test layout: `plugin/src/functionalTest/kotlin/org/meshtastic/flatpak/sources/FlatpakSourcesPluginFunctionalTest.kt` — the **only** test file in the repo. 7 `@Test` functions using `GradleRunner.create().withPluginClasspath()`:
  1. `plugin applies successfully and task exists`
  2. `custom output file path is respected`
  3. `output JSON is valid array`
  4. `multi-module project works`
  5. `settings plugin applies project plugin and task exists`
  6. `settings plugin captures URLs without init script warning`
  7. `settings plugin works with included build reuse pattern`
- These are genuine black-box functional/integration tests (they spin up real temp Gradle projects and run the plugin end-to-end) — good coverage of "does applying the plugin work as documented" across several scenarios (multi-module, settings-plugin auto-apply, custom config).
- **Gap**: no unit tests at all for the three `internal` logic classes: `CacheFileLocator.locate()`/`relativePath()` (URL→cache-path resolution, including the "longest suffix match" group-derivation algorithm at `CacheFileLocator.kt:42-56`), `MirrorGenerator.mirrorsFor()` (host substitution logic, `MirrorGenerator.kt:33-43`), `SourcesWriter` (JSON entry construction, SHA-256 hashing, suffix filtering, `SourcesWriter.kt` throughout). These are exactly the kind of small, pure, edge-case-heavy functions (malformed URLs, unusual group/artifact names, non-Maven-Central mirror hosts) that unit tests are best suited for, and they currently have zero direct coverage — only whatever incidental paths the 7 functional tests happen to exercise.

### CI/CD

Three workflows, all Ubuntu-only, JDK 17 (Temurin):
1. **`ci.yml`** — PR/push-to-main gate. `push`(main)+`pull_request`(main) → `./gradlew :plugin:build :plugin:functionalTest --stacktrace`; uploads `plugin/build/reports/` as an artifact on failure. Gradle-version matrix declared (`['9.5.1']`) but only one entry currently (dead-code matrix, or a placeholder for future expansion — note the wrapper itself is pinned to 9.6.1, so this matrix entry (9.5.1) tests against an *older* Gradle than the wrapper uses).
2. **`publish.yml`** — tag `v*` push → build+test, then `publishPlugins` (Plugin Portal), then `publishAllPublicationsToCentralPortal` (Maven Central). `permissions: contents: read` set.
3. **`snapshot.yml`** — push-to-main → build+test, then `publishAllPublicationsToCentralSnapshots -PsnapshotBuild`. `permissions: contents: read` set.

Hardening gaps: `ci.yml` has no `permissions:` block (low actual risk here since it never touches secrets or writes, but still a missed best practice, especially since it runs on `pull_request`); no workflow declares a `concurrency:` group (recent Renovate-driven pushes 2026-07-17T00:13:09–00:14:17 show several `CI`/`Snapshot` runs with conclusion "cancelled" in `gh run list`, but since no `concurrency:` key exists in the YAML, this was either a manual cancellation or a repo/org-level "auto-cancel redundant workflow runs" Actions setting — not something guaranteed or reviewable from the workflow files themselves); actions pinned by tag (`@v7` etc.), not commit SHA.

Renovate is genuinely active (see #38) — 6 merged dependency PRs visible in `git log`, including the Gradle-wrapper bump itself (PR #7, "chore(deps): update gradle to v9.6.1").

### Documentation

- README.md (129 lines) structure: badges → Quick Start → How It Works (3 numbered steps with links to Gradle internals + a peer project `flatpak/flatpak-gradle-generator`) → Included Builds → Use in Your Flatpak Manifest → Configuration (full DSL example) → Cross-Platform Artifact Resolution → Requirements → Internal APIs (explicitly lists the 3 internal Gradle APIs it depends on and since when they've been stable) → License → Contributing.
- This is an unusually thorough README for a small plugin — it explains *why* two plugin variants exist, documents internal-API risk transparently, and gives a full config reference. The one real defect is the stale `version "0.1.2"` in the two install snippets (README.md:17, :46) vs. the actual 0.1.4 currently live.
- KDoc spot-check (5 public/near-public declarations):
  1. `FlatpakSourcesExtension` class + all 7 properties — fully documented (`FlatpakSourcesExtension.kt:26-38, 41, 44, 47, 50, 53, 57, 62-67, 70-75`).
  2. `FlatpakSourcesPlugin` class — documented with a usage snippet (`FlatpakSourcesPlugin.kt:35-44`).
  3. `FlatpakSourcesSettingsPlugin` class — documented with a usage snippet (`FlatpakSourcesSettingsPlugin.kt:35-52`).
  4. `CacheFileLocator` (internal) — documented, including the non-obvious "longest suffix match" rationale (`CacheFileLocator.kt:22-30, 35-41, 58-63`).
  5. `MirrorGenerator` (internal) — documented, explains why only Maven Central gets mirrors (`MirrorGenerator.kt:22-27, 32`).
  Estimate: ~90-100% KDoc coverage of the genuinely public API, and unusually high coverage of internal code too.
- No Dokka, no published API docs site, no samples module, no `Module.md`.
- CHANGELOG.md (24 lines) — Keep-a-Changelog format, but only ever had 2 commits touch it (`f65c9da`, `75e3168`) and is stuck at "[0.1.2] - Unreleased" while 0.1.4 is live.

### Org alignment

- License: GPL-3.0-or-later intended (README, POM, badge) but `COPYING` is an abbreviated 23-line file (preamble + pointer to full text), not the canonical full GPL-3.0 text — and GitHub's license detector consequently reports `"Other"` rather than `"GPL-3.0"` (`gh repo view` → `licenseInfo.key: "other"`).
- `CONTRIBUTING.md` (63 lines) is thorough: JDK requirement, build/test command, detekt usage, branch-naming convention (`bugfix/`, `enhancement/`, `docs/`), PR checklist, **CLA requirement via CLA-assistant** (also badged in the README), Discord + GitHub Discussions links, external Code of Conduct link, issue-reporting guidance.
- Community-health files present: `CONTRIBUTING.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/FUNDING.yml` (github: meshtastic, open_collective: meshtastic). Absent: `CODE_OF_CONDUCT.md` (local file), `.github/ISSUE_TEMPLATE/`, `CODEOWNERS`, `SECURITY.md`.
- Repo metadata (`gh repo view meshtastic/gradle-flatpak-sources --json description,repositoryTopics,homepageUrl,licenseInfo,defaultBranchRef`): description and 10 topics set; `homepageUrl` empty; default branch `main`; created 2026-05-26, last pushed 2026-07-17.
- Naming: `org.meshtastic.flatpak:plugin` + plugin ids under `org.meshtastic.flatpak.*` — internally consistent, namespaced under the org.

---

## TOP 5 STRENGTHS

1. **Dual-publication is real and verified, not just configured.** Both plugin ids (`org.meshtastic.flatpak.sources`, `.settings`) are live at 0.1.4 on the Gradle Plugin Portal, and the main artifact plus both plugin-marker artifacts are live and fully GPG-signed (jar/sources/javadoc/module/pom, each with `.asc`) at 0.1.4 on Maven Central — confirmed by direct fetch, not just by reading the workflow YAML.
2. **Sophisticated, correct use of Gradle-plugin-specific conventions**: complete `gradlePlugin{}` metadata for both plugins (id/displayName/description/tags/website/vcsUrl), strict `validatePlugins` (`failOnWarning = true`), and modern per-plugin `compatibility { features { configurationCache = false } }` declarations that are visibly reflected on the Plugin Portal listing — this is above-average sophistication for a small plugin.
3. **Unusually thorough KDoc and README for the project's size** — every extension property documented, both plugin classes documented with usage snippets, even internal helper classes documented with design rationale (e.g., why the cache-locator uses longest-suffix matching, why only Maven Central gets mirror URLs). README explicitly discloses the internal-Gradle-API risk and how long those APIs have been stable.
4. **Active, working dependency automation** — Renovate is not just configured but demonstrably merging PRs (6 in git log), including keeping the Gradle wrapper itself current (9.5→9.6.1).
5. **Transparent handling of its own release failure** — when the v0.1.3 tag's publish step failed, the next release's notes candidly documented it ("v0.1.3 was a burned tag — no artifacts were published under it") rather than leaving it unexplained.

## TOP 8 GAPS

1. **README install snippet is stale**: pins `version "0.1.2"` (README.md:17, :46) while 0.1.4 is the actual live version — anyone copy-pasting the Quick Start today gets an outdated plugin version.
2. **CHANGELOG.md is stale**: still headed "[0.1.2] - Unreleased" (CHANGELOG.md:8) with no entries for 0.1.3 or 0.1.4; only 2 commits have ever touched the file.
3. **Zero unit tests**: only test file is the 7-case `functionalTest` suite; the three `internal` logic classes (`CacheFileLocator`, `MirrorGenerator`, `SourcesWriter` — URL parsing, mirror-host substitution, SHA-256/JSON writing) have no direct/unit-level test coverage at all.
4. **No coverage tooling** (Kover/Jacoco) and no coverage step in any CI workflow — test-effectiveness on the untested internal classes is entirely unmeasured.
5. **Javadoc jar is an empty stub** (261 bytes on Maven Central) because no Dokka plugin is applied — satisfies Central's requirement mechanically but ships no real API docs; no Dokka site is published anywhere either.
6. **CI/CD hardening gaps**: `ci.yml` has no `permissions:` block (unlike `publish.yml`/`snapshot.yml`, which correctly scope to `contents: read`); no workflow declares a `concurrency:` group (evidenced by several "cancelled" runs around back-to-back Renovate merges that aren't explained by any YAML config); actions pinned to version tags, not commit SHAs.
7. **Release process allowed a permanently broken tag/release**: `v0.1.3`'s publish workflow failed, but the git tag and GitHub Release for v0.1.3 still exist with no corresponding artifacts on either registry — nothing prevents a consumer from trying `version "0.1.3"` and hitting a 404. Release automation is otherwise manual (hand-bumped version commits, hand-written GH release notes, no automated changelog generation).
8. **License-file/community-health gaps**: `COPYING` contains only the GPL-3.0 preamble (not the full canonical text), causing GitHub to classify the license as "Other" instead of "GPL-3.0" in repo metadata; no `SECURITY.md`, no `CODEOWNERS`, no `.github/ISSUE_TEMPLATE/`, no local `CODE_OF_CONDUCT.md` (external link only); no `.editorconfig`; no detekt custom config (default ruleset only); `explicitApi()` not enabled (internal-vs-public boundary relies only on the `internal` keyword, not compiler-enforced strict mode); no BCV.
