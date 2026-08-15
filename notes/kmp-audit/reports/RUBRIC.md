# Meshtastic KMP Library Audit Rubric

You are auditing ONE Meshtastic Kotlin/KMP library repo for adherence to modern
(2026) Kotlin Multiplatform library best practices. Be **factual and evidence-based**:
open and read the actual files, cite `path:line` for every non-trivial claim, and
distinguish clearly between Present / Partial / Absent. Do **not** guess — if you
cannot determine something, say "unknown" and note what you checked. This is a
**READ-ONLY** audit: do not modify, format, build-write, or commit anything in the repo.
You may run read-only shell (git log, grep, find, cat, ./gradlew tasks --dry-run only if quick & safe).

## Output

1. Write your FULL detailed report to the scratchpad path you are given.
2. Return to me (as your final message) ONLY the compact SCORECARD table (section below),
   plus a short "TOP 5 STRENGTHS" and "TOP 8 GAPS" list. Keep the returned message tight;
   the full detail goes in the file.

## Scorecard — fill status as ✅ Present / 🟡 Partial / ❌ Absent / N/A, with a terse note

| # | Criterion | Status | Evidence (path / value) |
|---|-----------|--------|-------------------------|
| **BUILD LOGIC** |
| 1 | Gradle wrapper version | | value + path |
| 2 | Kotlin version | | value |
| 3 | AGP version (N/A if no Android target) | | value |
| 4 | Version catalog `gradle/libs.versions.toml` | | |
| 5 | Convention plugins via `build-logic` composite build | | |
| 6 | KMP targets declared (list ALL: jvm, android, iosArm64, iosSimulatorArm64, iosX64, macosArm64, macosX64, linuxX64, linuxArm64, mingwX64, js, wasmJs, wasmWasi, tvos*, watchos*) | | list them |
| 7 | Hierarchical source sets / `applyDefaultHierarchyTemplate` | | |
| 8 | `explicitApi()` strict mode enabled | | |
| 9 | JVM toolchain pinned (`jvmToolchain(N)`) | | value |
| 10 | Gradle configuration cache / caching enabled in gradle.properties | | |
| **PUBLISHING** |
| 11 | Publishing mechanism (vanniktech maven-publish plugin? / manual `maven-publish`? / other) | | which |
| 12 | Central Portal (`central-portal` / new Sonatype) vs legacy OSSRH | | which |
| 13 | GPG signing configured | | |
| 14 | BOM module published | | |
| 15 | POM metadata complete (name, description, url, licenses, scm, developers) | | which fields present |
| 16 | Sources jar + Dokka/javadoc jar attached | | |
| 17 | Group/artifact coordinates | | value (e.g. org.meshtastic:*) |
| 18 | Version single-source-of-truth (where version is defined) | | path |
| **API & COMPAT** |
| 19 | Binary Compatibility Validator (`.api` dumps present / plugin applied) | | |
| **TESTING & COVERAGE** |
| 20 | Test framework(s) (kotlin.test / kotest / junit) | | which |
| 21 | `commonTest` present + per-target test source sets | | |
| 22 | Rough test count (# test files / # @Test or test fns) | | numbers |
| 23 | Coverage tool (Kover / Jacoco) | | which |
| 24 | Coverage uploaded to Codecov/other in CI | | |
| 25 | Coverage threshold/verification enforced | | |
| **CODE QUALITY TOOLING** |
| 26 | Formatter/linter (spotless / ktlint / detekt) + config | | which |
| 27 | `.editorconfig` present | | |
| 28 | Pre-commit hooks / git hooks | | |
| **CI/CD (GitHub Actions)** |
| 29 | PR build+test workflow | | file |
| 30 | Multiplatform CI matrix incl. **macOS runner** for apple targets | | |
| 31 | Gradle caching in CI (`gradle/actions/setup-gradle` or actions/cache) | | which |
| 32 | Lint/format check step in CI | | |
| 33 | API-compat check step in CI | | |
| 34 | Coverage step in CI | | |
| 35 | Publish/release workflow (tag- or release-triggered → Maven Central) | | file |
| 36 | Release automation (auto version, changelog, GH release) | | |
| 37 | Workflow hardening: `concurrency` + least-privilege `permissions` + pinned action SHAs | | |
| 38 | Dependency automation (Renovate / Dependabot) | | which |
| **DOCUMENTATION** |
| 39 | README: badges (build, Maven Central, license, coverage) | | which |
| 40 | README: install snippet + quick-start usage | | |
| 41 | README: platform-support table | | |
| 42 | API docs site (Dokka) published (e.g. GH Pages) | | |
| 43 | KDoc coverage on public API (rough %) | | estimate |
| 44 | CHANGELOG present + maintained | | |
| 45 | Samples / examples module | | |
| 46 | Module-level docs (`Module.md` / package docs) | | |
| **ORG ALIGNMENT** |
| 47 | LICENSE (which one) | | value |
| 48 | CONTRIBUTING + CODE_OF_CONDUCT | | |
| 49 | Issue + PR templates | | |
| 50 | CODEOWNERS | | |
| 51 | SECURITY.md | | |
| 52 | Default branch (main/master) | | value |
| 53 | Repo description / topics / homepage set (check via `gh repo view`) | | |
| 54 | Consistent group id + naming (`org.meshtastic:<artifact>`) | | |

## Detailed sections to cover in the FULL report (with citations)

- **Build logic**: full module list; how each module's build script is structured;
  duplication vs shared convention plugins; how targets/toolchain/compiler opts are set;
  gradle.properties flags; any buildSrc; whether it matches KMP default hierarchy.
- **Publishing**: exact plugin + version; how signing/credentials are wired (env vars);
  POM block; BOM contents; whether publish is wired to CI; snapshot handling.
- **API/compat**: BCV setup, presence & currency of `*.api` files, explicitApi.
- **Testing**: test source layout, frameworks, what's actually tested vs stubbed, coverage config & numbers if available.
- **CI**: enumerate every workflow file with a one-line purpose; note matrix OSes, JDK, triggers, caching, hardening, and gaps.
- **Docs**: README section inventory; Dokka config; KDoc spot-check on 3–5 public APIs; changelog; samples.
- **Org alignment**: community-health files, license, branch naming, coordinates, repo metadata.
- **Notable strengths** and **Notable gaps/risks** (ranked).

Remember: cite `path:line`. Return only the compact scorecard + strengths + gaps.
