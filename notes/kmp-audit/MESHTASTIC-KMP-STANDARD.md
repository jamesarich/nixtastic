# The Meshtastic KMP Library Standard

**Status:** Draft v1 · **Date:** 2026-07-21 · **Applies to:** every Meshtastic repo that publishes a Kotlin/KMP artifact.

**In scope (6):** `meshtastic-sdk`, `mqttastic-client-kmp`, `kzstd`, `takpacket-sdk`, `gradle-flatpak-sources` (Gradle plugin — adapted subset), `protobufs` (`packages/kmp/`, Wire-generated — adapted subset).

**How this was derived.** The union of (a) verified 2026 ecosystem best practice (kotlinlang KMP guide + exemplars: okio, sqldelight, koin, kotlinx-datetime, kotlinx.coroutines, Kermit, multiplatform-settings), and (b) existing Meshtastic org conventions. Where our repos already exceed the ecosystem (e.g. SHA-pinned actions, built-in ABI validation, version catalogs — none of which the three kotlinx/okio exemplars all do), the org practice becomes the bar. The canonical internal reference implementation is **`meshtastic-sdk`**, with specific best-of-breed borrowings from `mqttastic-client-kmp` (coverage gate, CI matrix, SBOM/provenance) noted inline.

**Tiers:** **[R]** Required (table-stakes; non-compliance is a gap) · **[S]** Strongly recommended · **[E]** Emerging (adopt deliberately).

**Verified reference versions (refreshed 2026-08-15).** Kotlin `2.4.10` (⚠️ meshtastic-sdk held at `2.4.0`: SKIE 0.10.13 rejects 2.4.10 — un-pin when SKIE catches up) · Gradle `9.7.0` (kzstd/mqtt/flatpak; tak+pb still 9.6.1, pb bump open as Renovate #1029) · AGP `9.3.1` · Dokka `2.2.0` (id stays `org.jetbrains.dokka`) · Kover `0.9.9` · BCV `0.18.1` (or Kotlin built-in ABI validation, KGP 2.2+) · vanniktech maven-publish `0.37.0` · Spotless `8.8.0` + ktlint `1.8.0` · detekt `1.23.8` · Kotest `6.2.3` · `gradle/actions/setup-gradle@v6.2.0` · `actions/checkout@v7.0.1` · `actions/setup-java@v5.6.0` · `codecov/codecov-action@v7.0.0`.

---

## 1. Build logic

- **1.1 [R] Gradle wrapper pinned to `9.6.1` with `distributionSha256Sum`.** Reproducible + supply-chain safe. (sqldelight pins the checksum; none of ours do yet.)
- **1.2 [R] Version catalog `gradle/libs.versions.toml`** as the single source of every dependency/plugin version. (Universal in the ecosystem; `protobufs` is the one repo missing it.)
- **1.3 [S] Convention plugins via a `build-logic` composite build** for any multi-module library (KMP setup, publishing, Dokka, quality gates as precompiled plugins). Required once a repo has ≥2 publishable modules. Single-artifact repos (`kzstd`) may keep a flat build.
- **1.4 [R] Declare only shipped targets; rely on the default hierarchy template.** Do not hand-wire `dependsOn` graphs. **House target policy:**
  - *App-coupled SDKs* (`meshtastic-sdk`): the deliberate `jvm + androidTarget + iosArm64/iosSimulatorArm64/iosX64` set is acceptable and documented.
  - *General-purpose libraries* (`kzstd`, `takpacket-sdk`, `protobufs`, `mqttastic-client-kmp`): ship the wide set already in use (jvm, js, wasmJs, wasmWasi, the Apple tier, linuxX64/Arm64, mingwX64). **[E]** keep `wasmJs`/`wasmWasi` current — now first-class in the official tutorial.
- **1.5 [R] `explicitApi()` (strict) in every library module.** Prerequisite for meaningful ABI validation. A Konsist allowlist (mqttastic) is a valid *supplement*, **not** a substitute.
- **1.6 [R] Pin the JVM toolchain explicitly and deliberately.** The hard requirement is *pin it and be deliberate about the value*. **Decided house values (2026-07):** `meshtastic-sdk`, `kzstd`, `takpacket-sdk` = `jvmToolchain(21)`; `mqttastic-client-kmp` = `11` (deliberately kept for widest JVM/Android consumer reach); `gradle-flatpak-sources` = `17`. (These per-repo decisions supersede the earlier blanket "17 for general-purpose libraries" guidance — reach vs. modern-bytecode was resolved case-by-case.)
- **1.7 [S] Gradle configuration cache on** (`org.gradle.configuration-cache=true`) + parallel + build cache in `gradle.properties`. Run publish tasks with `--no-configuration-cache` (vanniktech limitation). (`gradle-flatpak-sources` legitimately can't — the plugin under test is config-cache-incompatible.)

## 2. Publishing

- **2.1 [R] Sonatype Central Portal**, not legacy OSSRH (EOL 2025-06-30). All six already do. Rename lingering `OSSRH_*` secret names to `SONATYPE_CENTRAL_*` for clarity (cosmetic).
- **2.2 [R] vanniktech `com.vanniktech.maven.publish` 0.37.0** for KMP artifacts (auto-configures every target publication + root module + sources/javadoc). Gradle *plugins* use `com.gradle.plugin-publish` + `com.gradleup.nmcp` (`gradle-flatpak-sources` — correct).
- **2.3 [R] Complete POM** (name, description, url, licenses, scm, developers) + **2.4 [R] `signAllPublications()` with in-memory GPG** in CI. All six pass.
- **2.5 [R] Real sources **and** Dokka javadoc jars.** A 261-byte empty javadoc stub (current state of `protobufs` and `gradle-flatpak-sources`) is non-compliant — wire Dokka into the javadoc jar.
- **2.6 [S] BOM (`java-platform`) for any multi-module library.** Present in `meshtastic-sdk`, `mqttastic-client-kmp`; N/A for single-artifact repos.
- **2.7 [R] Tag-triggered release from CI on a macOS runner** with `--no-parallel --no-configuration-cache`, `concurrency` guard, idempotent re-run guard. **The trigger must actually be exercised:** `protobufs` and `kzstd` have release workflows whose `push: tags` path has *never fired* (every publish was manual) — that is a reliability gap, not a passing check.
- **2.8 [S] SNAPSHOTs on every `main` push** to the Central snapshot repo (meshtastic-sdk pattern).

## 3. API stability

- **3.1 [R] A checked-in ABI dump enforced by CI.** Either **BCV 0.18.1** (`apiCheck` wired into `check`) or **[E] Kotlin built-in ABI validation** (KGP 2.2+; `meshtastic-sdk` already uses `checkKotlinAbi` — the strategic choice). Built-in is the direction; BCV is fine today.
- **3.2 [R] Coverage must include the klib (native/common) surface, not JVM only.** `mqttastic` (JVM-only `.api`) and `takpacket` (JVM `.api`, klib dump *claimed in a comment but absent*, and `apiCheck` never runs in CI) fail this today.
- **3.3 [R] `explicitApi()`** — see 1.5.

## 4. Testing & coverage

- **4.1 [R] `kotlin.test` in `commonTest`** + per-target test sets; every *shipped* module has tests. A shipped-but-untested module (`mqtt-client-transport-ws`: zero tests) is non-compliant.
- **4.2 [R] Native/Apple targets actually test-executed in CI**, not merely cross-compiled. `takpacket` (only `jvmTest` runs; 11/13 targets never execute) and `protobufs`/`kzstd` (compile-only or single-runner) fail this.
- **4.3 [R] Kover `0.9.9` + a coverage-regression gate + Codecov upload.** The gate may be EITHER a local `koverVerify` threshold wired into `check` (reference: `mqttastic-client-kmp`, 80% `minBound`) **OR** a **Codecov project-status regression gate** (`codecov.yml` `project.default: target: auto, threshold: 1%, informational: false`). The org adopted the **Codecov regression gate** on `meshtastic-sdk`/`kzstd`/`takpacket-sdk` (2026-07) as the primary mechanism — self-calibrating (compares each PR to its base commit), so there is no per-repo threshold to pick or maintain; a local `koverVerify` floor is now an optional belt-and-suspenders supplement, not a requirement. Understood limit: Kover measures JVM/Android bytecode only — don't advertise "multiplatform coverage."
- **4.4 [S] Kotest / Turbine / coroutines-test** where they add value (assertions, property/data-driven, Flow testing) — already used well in `meshtastic-sdk` and `mqttastic`.
- Generated-code artifacts (`protobufs`) are legitimately exempt from unit-test coverage; assess the *generation/build/publish* pipeline instead.

## 5. CI/CD (GitHub Actions)

- **5.1 [R] Multiplatform matrix:** `ubuntu-latest` (jvm/js/linux/android) + **`macos-latest` (apple/native)**, tests actually run per-OS. Reference: `mqttastic` (macOS + Windows + Linux).
- **5.2 [R] `gradle/actions/setup-gradle@v6.2.0` caching in *every* build job** (incl. `~/.konan` for native). `takpacket`'s Kotlin CI job has no Gradle caching at all — fix.
- **5.3 [R] Harden every workflow:** SHA-pin third-party actions (version comment for Renovate) — **reference: `meshtastic-sdk`, 100% pinned; all others use mutable tags**; top-level least-privilege `permissions: { contents: read }` on *every* workflow (multiple repos miss it on `ci.yml`); `concurrency` cancel-in-progress everywhere (`protobufs` has none).
- **5.4 [R] Standard gate:** `spotlessCheck` → `detekt` → `apiCheck`/`checkKotlinAbi` → build+test matrix → `koverVerify` + Codecov → `dokkaGenerate` → tag-triggered publish. Run with `-Pci=true --continue`.
- **5.5 [S] Composite `gradle-setup` action + reusable `workflow_call` check** (android's pattern) once a repo's CI has real duplication.
- **5.6 [R] Renovate** at `.github/renovate.json`, `config:recommended` dialect (meshtastic-sdk's), `vulnerabilityAlerts.enabled`, ecosystem groups for lockstep deps (Kotlin/KSP/compiler plugins). Not Dependabot. Remove `kzstd`'s leftover Dependabot once Renovate covers it.
- **5.7 [S] Enable — not just scaffold — supply-chain checks** (CodeQL, Scorecard, dependency-review). `meshtastic-sdk` shipped these `.disabled`; now enabled and propagated to the mergeable repos (2026-07). **CodeQL caveat:** CLI 2.26.1 (current, via codeql-action v4.37.2) can't analyze Kotlin 2.4.10 — the `java-kotlin` autobuild fails — so scan the `actions` language only and keep `java-kotlin` committed-but-commented, re-enabling it when a newer CodeQL CLI ships (Kotlin ceiling 2.4.20 is merged upstream).

## 6. Documentation

- **6.1 [R] Dokka v2 (`2.2.0`, id `org.jetbrains.dokka`, v2 tasks) → GitHub Pages.** The hard requirement is *a live Pages site fed by a Dokka-v2 workflow*. Deploying on **every `main` push** (continuous docs) is blessed — `meshtastic-sdk`/`mqttastic-client-kmp`/`takpacket-sdk` do this and it keeps published docs current; tag-gated publish (`v*.*.*` only) is equally acceptable. Now live in `kzstd` too; still missing only in `gradle-flatpak-sources` (Pages not enabled) and `protobufs`.
- **6.2 [R] KDoc on all public declarations.** Already strong (~85–100%) where hand-written.
- **6.3 [R] README:** badge row (CI, License shields.io GPL, **Maven Central version**, coverage *only if measured*, API-docs/Dokka link) → one-liner → **platform-support table** → install snippet with the **current** coordinate → quickstart. Recurring defects to fix: stale install versions (`kzstd` 0.1.0, `takpacket` 0.7.0, `gradle-flatpak` 0.1.2), a CI badge pointing at a nonexistent workflow (`protobufs`), missing Maven Central badge (most).
- **6.4 [R] `CHANGELOG.md`** (keepachangelog), current to the latest tag. Fix stale/unreleased states (`gradle-flatpak` stuck at 0.1.2; `protobufs` has none as a file).
- **6.5 [S] Samples module built in CI** (meshtastic-sdk / mqttastic have them) to prove the published artifact is consumable.
- **6.6 [S] `Module.md` / package docs** wired into Dokka.

## 7. Code quality

- **7.1 [R] Spotless `8.8.0` (ktlint `1.8.0` step) OR ktlint-gradle, in CI** (`spotlessCheck`). Missing entirely in `kzstd` (acknowledged TODO), `takpacket`, `protobufs`; `gradle-flatpak` runs detekt only.
- **7.2 [S] detekt `1.23.8`** with a committed custom config (`gradle-flatpak` uses the default ruleset). For KMP use a `detektAll` aggregator over per-source-set tasks. Don't double-run ktlint via `detekt-formatting` if Spotless already formats.
- **7.3 [R] `.editorconfig` at repo root** (ktlint's config surface). Missing in `mqttastic`, `protobufs`.

## 8. Organizational alignment

- **8.1 [R] Default branch `main`.** `kzstd`, `takpacket-sdk`, `protobufs` are on `master` — rename.
- **8.2 [R] `LICENSE` = GPL-3.0**, standard FSF text. Fix `gradle-flatpak-sources`' abbreviated `COPYING` (GitHub reports license as "Other"). Fix `meshtastic-sdk`'s GPL-3.0-only (README) vs GPL-3.0-or-later (214 SPDX headers + ADR) contradiction — pick one.
- **8.3 [R] Coordinates & packages under `org.meshtastic`.** All six compliant.
- **8.4 [R] Community-health files:** `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (point at `meshtastic.org/docs/legal/conduct/`), `SECURITY.md` (android's shape), `CODEOWNERS` (directory-scoped precedent style), `.github/ISSUE_TEMPLATE/*.yml` (+ `config.yml`, `blank_issues_enabled: false`), `PULL_REQUEST_TEMPLATE.md`, `.github/FUNDING.yml` pointing at the **org** (`github: meshtastic`, `open_collective: meshtastic`) never an individual. Gaps concentrated in `protobufs` (most missing), `takpacket` (no CoC/SECURITY/CODEOWNERS/templates), `kzstd` (no templates).
- **8.5 [S] `SUPPORT.md` / `GOVERNANCE.md`** for libraries with external consumers (meshtastic-sdk has both).
- **8.6 [R] Repo metadata:** description, topics, and **homepage URL** set (homepage empty on almost all — point at the Dokka site or meshtastic.org). Use `discord.gg/meshtastic` consistently.
- **8.7 [R] `v`-prefixed semver tags**, documented pre-1.0 policy; a single version source-of-truth CI reads for both the build version and the tag.

---

## Appendix — the "gold" reference per dimension (who to copy)

| Dimension | Copy from | Why |
|---|---|---|
| Build-logic / convention plugins | `meshtastic-sdk` | 6 precompiled convention plugins, built-in ABI validation, explicitApi, architecture-boundary enforcement |
| Coverage (Kover gate + Codecov) | `mqttastic-client-kmp` | Only repo with the full chain: 80% `koverVerify` + Codecov upload |
| CI test matrix | `mqttastic-client-kmp` | Real macOS + Windows + Linux runners; SBOM + SLSA provenance |
| CI hardening (SHA-pins) | `meshtastic-sdk` | 100% SHA-pinned actions + least-privilege perms |
| Publishing + BOM + snapshots | `meshtastic-sdk` | Central Portal + BOM + `main`-push snapshots, verified live |
| Docs (Dokka→Pages, samples, ADRs) | `meshtastic-sdk` | ~100K words docs, Dokka site, samples, 15 ADRs |
| Release engineering (VERSION SSOT fan-out) | `takpacket-sdk` | Single VERSION → 5 files, CI-gated mismatch, post-publish self-verify |
| Correctness testing | `kzstd` | Live real-libzstd oracle, byte-drift pinning, fuzzing |
| Gradle-plugin publishing (dual registry) | `gradle-flatpak-sources` | plugin-publish + nmcp → Portal + Central, verified live |
| Renovate dialect | `meshtastic-sdk` | `config:recommended` + vuln alerts + ecosystem groups |

**Strategic implication:** no single repo is the whole standard, but `meshtastic-sdk` is closest. The highest-leverage move (see remediation plan) is to lift `meshtastic-sdk`'s `build-logic` + CI + community-health scaffold into a reusable template and apply it outward, folding in `mqttastic`'s coverage/matrix and closing `meshtastic-sdk`'s own loose ends first so the template is clean.
