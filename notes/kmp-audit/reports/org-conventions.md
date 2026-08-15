# Meshtastic Org Conventions Audit (read-only)

Date: 2026-07-21
Scope: `meshtastic/meshtastic-android` (local: `/Users/james/meshtastic/android`), `meshtastic/meshtastic-apple` (local: `/Users/james/meshtastic/apple`), `meshtastic/.github`, org-wide repo inventory (155 repos via `gh repo list meshtastic --limit 200`), plus a light precedent check of four locally-checked-out Kotlin/KMP library repos (`meshtastic-sdk`, `mqttastic-client-kmp` / `MQTTastic-Client-KMP`, `takpacket-sdk` / `TAKPacket-SDK`, `kzstd`) since they are the closest existing analogue to "a KMP library" and materially changed the recommendation.

Raw inventory JSON saved at: `/private/tmp/claude-501/-Users-james-meshtastic/b9cd3c7a-8930-4c99-8f89-f1146419fc63/scratchpad/audit/repo_inventory.json`

---

## 1. Org-wide inventory (155 repos)

Source: `gh repo list meshtastic --limit 200 --json name,description,defaultBranchRef,licenseInfo,isArchived,primaryLanguage,repositoryTopics`

### Default branch name

| Branch | Count | % | Notes |
|---|---|---|---|
| `master` | 100 | 65% | 8 archived. Of the 92 active, most are **vendored third-party/embedded libraries** pulled in for firmware (`esp8266-oled-ssd1306`, `Adafruit_nRF52_Arduino`, `rpi-rgb-led-matrix`, `GxEPD2`, `TinyGPSPlus`, `ArduinoThread`, `Arduino_GFX`, `ESP8266Audio`, `ch341eeprom`, `ESP32-CH390`, `esp32_https_server`, `dotnet-MQTTnet`, …) whose branch name is inherited from upstream, not chosen by Meshtastic. But several **primary, actively-maintained** org repos are still on `master` too: `meshtastic/meshtastic` (main website/docs repo), `protobufs`, `device-ui`, `design`, `api`, `python`, `c-sharp`, `meshtastic-mcp`, `TAKPacket-SDK`, `kzstd`. |
| `main` | 46 | 30% | 1 archived. Includes **both flagship apps** (`Meshtastic-Android`, `Meshtastic-Apple`) and **7 of 8** Kotlin-primary repos (see §8). |
| `develop` | 6 | 4% | `firmware` + its 3 GHSA security-advisory temp forks, plus `platform-native`, `platform-nordicnrf52` (PlatformIO platform packages) — i.e. exclusively the embedded/firmware C++ ecosystem's git-flow branching. Not relevant to KMP/app repos. |
| `gh-pages`, `rpa-patch`, `org.meshtastic.MeshtasticDesktop` | 1 each | — | Static-site / bot / one-off repos. |

**Conclusion:** `master` is the numeric plurality only because of a long tail of vendored embedded C/C++ libraries. Among repos Meshtastic actually authors and actively develops — and overwhelmingly among Kotlin/KMP repos — **`main` is the real convention** (7/8 Kotlin repos; both flagship apps).

### License

| License | Count (all 155) | Count (146 non-archived) |
|---|---|---|
| GPL-3.0 | 74 | 70 |
| MIT | 26 | 23 |
| "other" (custom/non-SPDX, e.g. vendored code) | 19 | 19 |
| None declared | 21 | 20 |
| Apache-2.0 | 8 | 8 |
| LGPL-2.1 | 3 | 2 |
| GPL-2.0, CC0-1.0, BSD-3-Clause, zlib | 1 each | ~same |

GPL-3.0 is the clear plurality (~48% of licensed, non-archived repos) and is used by **every first-party app/SDK repo checked**: android, apple, firmware, and all 8 Kotlin-primary repos including all 4 KMP-library precedents. MIT/Apache-2.0/etc. cluster in vendored/forked dependencies. `android/LICENSE` and `apple/LICENSE` are byte-for-byte the same GPLv3 text (Copyright note: android's `settings.gradle.kts` header says "Copyright (c) 2026 Meshtastic LLC").

**Verify-per-repo caveat honored:** GPL-3.0 is confirmed, not assumed, for android, apple, firmware, meshtastic-sdk, mqttastic-client-kmp, takpacket-sdk, kzstd — all identical FSF GPLv3 boilerplate.

### Archived / language

- 9 of 155 repos archived (~6%).
- Kotlin-primary repos (8 total): `Meshtastic-Android`, `kzstd`, `meshtastic-sdk`, `MQTTastic-Client-KMP`, `gradle-flatpak-sources`, `pluginmeshtastic`, `geeksville-androidlib` (archived), `meshtastic-backend`. Swift-primary: 2 (`Meshtastic-Apple` and one other). This is a small but growing cohort — exactly the population a KMP-library baseline needs to target.

---

## 2. Community-health files: org-level defaults vs per-repo reality

### `meshtastic/.github` (community-health default repo)

Default branch: `master`. Root contents (`gh api repos/meshtastic/.github/contents`): **only** `LICENSE`, `README.md`, `profile/README.md`. That's it.

```
gh api repos/meshtastic/.github/contents
→ LICENSE, README.md, profile/ (dir, containing only profile/README.md)
```

Critically, **none of the files GitHub actually treats as org-wide fallback defaults are present**: no `CONTRIBUTING.md`, no `CODE_OF_CONDUCT.md`, no `SECURITY.md`, no `ISSUE_TEMPLATE/`, no `PULL_REQUEST_TEMPLATE.md`, no `FUNDING.yml`, no `SUPPORT.md`. (GitHub only inherits these specific filenames from `.github`/`.github` — a root `LICENSE`/`README.md` in the community-health repo does **not** propagate to other repos.)

- `profile/README.md` (604 bytes) renders on the org's public profile page (`github.com/meshtastic`). Content: one paragraph describing Meshtastic (LoRa mesh radios, off-grid comms), no badges.
- Root `README.md` (1128 bytes) — near-duplicate intro plus 3 badges: CLA-assistant, OpenCollective "Fiscal Contributors", and a "Powered by Vercel" badge.
- `LICENSE` = GPL-3.0 (same text as android/apple).

**Practical effect:** every repo must supply its own `CONTRIBUTING.md`/`CODE_OF_CONDUCT.md`/`SECURITY.md`/issue & PR templates — there is no safety net. This is visible in the GitHub Community Profile health check:

| Repo | `health_percentage` | Has CoC | Has CONTRIBUTING | Has SECURITY (not surfaced by API but confirmed by file read) | Has issue templates | Has PR template |
|---|---|---|---|---|---|---|
| Meshtastic-Android | **100%** | ✅ (`CODE_OF_CONDUCT.md`) | ✅ | ✅ (`SECURITY.md`) | (API reports `null` even though 4 `.yml` forms exist under `ISSUE_TEMPLATE/` — a known API quirk with YAML-form templates) | ✅ `.github/PULL_REQUEST_TEMPLATE.md` |
| Meshtastic-Apple | **62%** | ❌ missing entirely | ✅ | ❌ missing entirely | (same YAML-template quirk; 3 `.yml` forms exist) | ✅ `.github/pull_request_template.md` |

(`gh api repos/meshtastic/Meshtastic-Android/community/profile` and the `-Apple` equivalent.)

**Org-wide counts** (GitHub code search, so counts real occurrences of the literal filename, dedup by repo):

- `SECURITY.md` present in only **10 of 155** repos.
- `CODE_OF_CONDUCT.md` present in only **9 of 155** repos.
- `CODEOWNERS` present in only **6 of 155** repos: `meshtastic-sdk`, `kzstd`, `meshtastic` (main repo), `web-flasher`, `rust`, `meshtastic-mcp`. Notably **not** android, **not** apple, **not** `mqttastic-client-kmp`/`takpacket-sdk`. CODEOWNERS is concentrated in the newer, more greenfield library/SDK repos — a deliberate pattern worth adopting for new KMP libraries, not a legacy one to copy from the flagship apps.

### Per-repo ISSUE_TEMPLATE structure (both flagship apps use the modern YAML form, `config.yml` + `blank_issues_enabled: false`)

- android: `.github/ISSUE_TEMPLATE/{bug_report.yml, feature_request.yml, zbug_report_internal.yml, config.yml}`. `config.yml` disables blank issues and links out to GitHub Discussions (`orgs/meshtastic/discussions/categories/android`) and meshtastic.org.
- apple: `.github/ISSUE_TEMPLATE/{bug.yml, feature.yml, config.yml}`. `config.yml` only sets `blank_issues_enabled: false` (no contact links).

### FUNDING.yml — inconsistent between the two flagship repos

- android: `github: meshtastic`, `open_collective: meshtastic` (org-level accounts).
- apple: `github: [garthvh]` (a **named individual maintainer**), no `open_collective` set.
- Of the 4 KMP precedents, only `meshtastic-sdk` and `mqttastic-client-kmp` have a `FUNDING.yml` at all (`takpacket-sdk`, `kzstd` do not).

This is a concrete drift the baseline should fix: **`FUNDING.yml` should point at the org (`github: meshtastic`, `open_collective: meshtastic`), never an individual**.

---

## 3. CI conventions — android (`meshtastic/meshtastic-android`, the flagship/most mature practice)

All workflow files: `/Users/james/meshtastic/android/.github/workflows/` (18 files) + one composite action `/Users/james/meshtastic/android/.github/actions/gradle-setup/action.yml`.

| Workflow | Trigger | Purpose |
|---|---|---|
| `pull-request.yml` | `pull_request` → `main`, `release/**` | Path-filters changes (`dorny/paths-filter`), verifies the filter itself hasn't drifted from `settings.gradle.kts` module roots (a Python self-check step), validates store-listing metadata length + AppStream `<release>` entry, then calls `reusable-check.yml`, then a final `check-workflow-status` gate job. |
| `merge-queue.yml` | `merge_group` | Cancels superseded queue runs (custom `gh api`/`gh run cancel` logic), diffs merge-group base→head to skip docs-only changes, calls `reusable-check.yml`. |
| `reusable-check.yml` | `workflow_call` | The actual build/test/lint matrix (jobs: `setup` → `lint-check`, `screenshot-check`, `rb-check` (merge-queue only, reproducible-build verification), `test-shards` (3-way sharded KMP/Android/Robolectric matrix with Kover coverage → Codecov), `android-check` (APK assembly + size report to `$GITHUB_STEP_SUMMARY`), `build-desktop` (4-OS matrix), `build-flatpak-src`. |
| `main-check.yml` | `push` → `main` | Re-uses `reusable-check.yml` with lint/tests **off** (already verified by the merge queue) to build desktop distributables + publish a rolling "snapshot" prerelease APK (deleted & recreated on every push, versionCode-suffixed filenames for Obtainium). |
| `docs-deploy.yml` / `docs-release.yml` | push to `main` (build-only) / tag `v*.*.*` (publish) | Dokka (KDoc API docs) + Jekyll (user/dev guide) — build-validated on every `main` push, only **published** to GitHub Pages on a version tag. |
| `create-or-promote-release.yml`, `release.yml`, `promote.yml`, `post-release-cleanup.yml` | `workflow_dispatch` / `workflow_call` | Multi-channel release pipeline (internal → closed → open → production), auto-changelog from PR labels, Play Store + GitHub Release + Desktop installers (DMG/MSI/EXE/DEB/RPM/AppImage) + build attestations/provenance. |
| `msstore-publish.yml`, `winget-publish.yml` | `release: released` / dispatch | Store-specific publishing (Microsoft Store, winget). |
| `update-changelog.yml` | `push` → `main` | Keeps `CHANGELOG.md` in sync. |
| `scheduled-updates.yml` (hourly cron) / `scheduled-baseline.yml` (daily cron) | `schedule` + dispatch | Firmware/hardware/translation (Crowdin) sync PRs (cheap, hourly) vs. Macrobenchmark Baseline Profile + dependency graph regen (needs a booted emulator, ~14 min, so decoupled to a daily cron). |
| `stale.yml` | daily cron | `actions/stale@v10.4.0`, 30-day staleness, broad exempt-label list. |
| `verify-flatpak.yml` | `pull_request` (path-scoped) | Verifies the Flatpak offline build manifest. |
| `pull-request-target.yml` | `pull_request_target` | Auto-labeler: derives changelog-aligned labels from branch-prefix / conventional-commit PR title / changed-file paths (custom `actions/github-script` JS, not the third-party `labeler` action), then **enforces** the PR carries at least one recognized label before merge. |

### Standard/repeated building blocks (android)

- **Composite action** `.github/actions/gradle-setup`: copies CI-specific `.github/ci-gradle.properties` → `~/.gradle/gradle.properties`, `gradle/actions/wrapper-validation@v6`, `actions/setup-java@v5` (JDK 25, Temurin, with an optional JetBrains-JDK path for Compose Desktop + Foojay auto-provision fallback), `gradle/actions/setup-gradle@v6` with `cache-cleanup: on-success`, `add-job-summary: always`, and extra `gradle-home-cache-includes` for Robolectric's `~/.m2`.
- **Action versions in active use** (`grep -h "uses:" *.yml`, deduped): `actions/checkout@v7.0.1` (27×, dominant), `actions/upload-artifact@v7` / `download-artifact@v8`, `actions/setup-java@v5`, `gradle/actions/setup-gradle@v6`, `gradle/actions/wrapper-validation@v6`, `dorny/paths-filter@v4`, `actions/github-script@v9`, `codecov/codecov-action@v7`, `actions/attest-build-provenance@v4`/`attest@v4`, `actions/upload-pages-artifact@v5`/`deploy-pages@v5`, `ruby/setup-ruby@v1` (Jekyll), `crowdin/github-action@v2`, `actions/stale@v10.4.0`, `peter-evans/create-pull-request@v8`, `softprops/action-gh-release@v3`, `microsoft/store-submission@v1`, `vedantmgoyal9/winget-releaser@v2`, `azure/artifact-signing-action@v2.0.0`, `reactivecircus/android-emulator-runner@v2`. **Version pinning style: tagged semver (not pinned SHAs)** — contrast with meshtastic-sdk below.
- **Lint/static-analysis command**: `./gradlew spotlessCheck detekt androidApp:lintFdroidDebug androidApp:lintGoogleDebug core:barcode:lintFdroidDebug core:barcode:lintGoogleDebug kmpSmokeCompile -Pci=true --continue`. Spotless + Detekt is the standard; no ktlint used directly (Spotless wraps formatting).
- **Runner sizing convention** (from `.github/instructions/ci-workflows.instructions.md`): lightweight jobs (labelers, triage, stale) → `ubuntu-24.04-arm`; Gradle-heavy jobs → `ubuntu-24.04`.
- **Concurrency**: every workflow sets a `concurrency.group` keyed on workflow+ref/PR number with `cancel-in-progress: true`.
- **Coverage**: Kover (Kotlin) → XML → `codecov/codecov-action@v7`, split by shard `flags`. `codecov.yml` sets `precision: 2`, coverage range 70–100, 1% drop tolerance, per-component tracking (`core`, `features`, `app`, `desktop`), ignores generated/proto/test/mocks.
- **AI-assisted review**: `.coderabbit.yaml` — `profile: chill` (fewer nitpicks; CI already gates lint/tests), skips drafts and bot/Renovate PRs, per-path instructions (e.g., flag `java.*`/`android.*` imports under `commonMain/`, flag un-sorted `strings.xml`, PII/location/crypto-key logging).
- **PR gating** requires a recognized label (enforced in `pull-request-target.yml`) — every merged PR is guaranteed a changelog category.
- Release notes are label-driven via `.github/release.yml` `changelog.categories` (🏗️ Features = `enhancement`, 🖥️ Desktop = `desktop`, 🛠️ Fixes = `bug`/`bugfix`, 📝 Other = `*`), excluding `dependencies/automation/release/repo/skip-changelog/chore/ci/build/testing/documentation/l10n` labels and bot authors.

## 4. CI conventions — apple (`meshtastic/meshtastic-apple`)

Workflows: `/Users/james/meshtastic/apple/.github/workflows/` (7 files): `docs-deploy.yml`, `docs-release.yml`, `docs-release-bundle.yml`, `sync_device_svgs.yml`, `sync_design_standards.yml`, `docs-staleness.yml`, `swiftlint.yml`, plus `bug-report-analyzer.yml`.

- `swiftlint.yml`: PR-triggered, path-scoped to `*.swift`/lint config; runs `norio-nomura/action-swiftlint@3.2.1` on changed files only, via `actions/checkout@v1` (very old, unpinned-minor action version — notably behind android's hygiene).
- `docs-deploy.yml`/`docs-release.yml`: same "validate on every `main` push, publish only on `v*.*.*` tag" pattern as android — this is a **shared org idiom**, not android-specific. Uses `xcodebuild test` to regenerate SwiftUI snapshot doc screenshots, `cmark-gfm` + Jekyll (`ruby/setup-ruby@v1`, same as android) to build the docs bundle, `actions/upload-pages-artifact`/`deploy-pages`.
- `docs-release-bundle.yml`: creates the GitHub Release + attaches a `meshtastic-apple-docs-<version>.tar.gz` that the main `meshtastic/meshtastic` website repo's `sync-apple-docs` job later consumes (weekly schedule + on-demand) — cross-repo docs syndication, no submodule/live clone.
- `sync_device_svgs.yml`, `sync_design_standards.yml`: pull hardware SVGs / the shared design-standards doc from other org repos (`meshtastic/design` is stated as upstream source of truth per `AGENTS.md`/`copilot-instructions.md` in both android and apple).
- `bug-report-analyzer.yml`, `docs-staleness.yml`: AI-assisted issue triage / doc-staleness advisory checks (surfaced via `skip-preview-check`/`skip-docs-check` labels referenced directly in the PR template checklist).
- **Action versions are noticeably older/less consistent than android**: `actions/checkout@v1`/`v4` (mixed), `actions/github-script@v7`, `peter-evans/create-pull-request@v5`**and**`@v7` (two different versions in the same repo), `actions/setup-node@v4`, `actions/upload-artifact@v4`/`download-artifact@v4`, `actions/configure-pages@v5`. No Gradle equivalent obviously (Swift/Xcode project), no reusable-workflow decomposition, no merge queue, no sharded test matrix, no coverage tool wired into CI, no dependency-automation config at all (see §5).
- No `CODEOWNERS`, no `renovate.json`/`dependabot.yml`, no `codecov.yml`-equivalent, no composite actions.

**Conclusion vs. the task's framing:** android is confirmed as the org's CI/build maturity ceiling (reusable workflows, composite actions, sharded+covered tests, reproducible-build verification, supply-chain attestations, pinned tool versions, enforced PR labeling). Apple is functional but materially behind — this matters for the baseline because a new KMP library should target android's rigor, not apple's.

---

## 5. Renovate / Dependabot

- **android**: `.github/renovate.json`. Extends granular presets (`:dependencyDashboard`, `:semanticCommitTypeAll(chore)`, `:ignoreModulesAndTests`, `group:recommended`, `replacements:all`, `workarounds:all`) rather than the monolithic `config:recommended`. `osvVulnerabilityAlerts: true`. Custom `packageRules`: automerge non-major on stable (`!/^0/`) versions, automerge patch-only on 0.x, automerge pins/digests always, disable automerge for major bumps, hand-groups Compose Multiplatform + a hand-curated "kotlin-toolchain" group (Kotlin/KSP/Mokkery/Koin-compiler-plugin locked together, human-reviewed), a bespoke `allowedVersions` regex to defeat a real Maven-snapshot-comparator bug against `org.meshtastic:protobufs` (documented inline with a link to the PR that surfaced it).
- **apple**: **no Renovate, no Dependabot, no dependency-automation config of any kind** found (checked repo root, `.github/`, code search). This is the single biggest gap between the two flagship repos.
- **Org-wide** (`gh api search/code -f 'filename:renovate.json org:meshtastic'` / `filename:dependabot.yml`): Renovate is far more common among Meshtastic-authored repos — `firmware`, `ATAK-Plugin`, `meshtastic-sdk`, `Meshtastic-arduino`, `openwrt`, `protobufs`, `gradle-flatpak-sources`, `MQTTastic-Client-KMP`, `platform-wasm`, `meshtastic-mcp`, `Meshtastic-Android`, `TAKPacket-SDK`, `kzstd`, `firmware-ota`. Dependabot appears in a smaller, more mixed set: `meshtastic/meshtastic`, `device-ui`, `c-sharp`, `home-assistant`, `kzstd` (has **both** — likely mid-migration), `gh-action-firmware`, `web`, `gh-runners`, `meshtasticd-wasm-node`, `homebrew-tap`, `api`. **Renovate is the dominant/preferred tool, especially for every Kotlin/KMP repo** — Dependabot shows up mostly on non-Kotlin repos.
- **File location varies**: root `renovate.json` (`meshtastic-sdk`, `mqttastic-client-kmp`) vs `.github/renovate.json` (`Meshtastic-Android`, `takpacket-sdk`, `kzstd`, `meshtastic-mcp`). No settled org convention on location, but `.github/renovate.json` is slightly more common among the checked set.
- **`meshtastic-sdk`'s renovate.json is a materially newer "dialect"** than android's: extends the monolithic `config:recommended` + `:dependencyDashboard` + `:semanticCommits` + `:timezone(UTC)`, `schedule: ["before 6am on monday"]`, `prHourlyLimit`/`prConcurrentLimit` caps, `rangeStrategy: "bump"`, `configMigration: true`, `lockFileMaintenance`, explicit `vulnerabilityAlerts.enabled` + `security` label, and per-ecosystem groups (kotlin, ktor, sqldelight, kable, wire, kotlinx) plus a documented Kotlin version ceiling tied to a specific third-party plugin (SKIE) incompatibility. This is a good candidate "house style" for new KMP libraries — arguably cleaner than android's older preset style.

---

## 6. README / branding conventions

Both flagship READMEs and the KMP-library READMEs converge on a shared shape:

1. Centered `<h1>`/logo block (android has an actual logo image `.github/meshtastic_logo.png`; apple/meshtastic-sdk use plain centered text + a tagline).
2. A badge row immediately under the title. Recurring badges across the org:
   - CI status badge (workflow badge SVG) — universal.
   - License badge (android: none explicit besides footer text; apple: `img.shields.io/badge/license-GPL...`; meshtastic-sdk: same shields.io GPL badge).
   - Package-registry badge where applicable: `meshtastic-sdk` has a live **Maven Central** badge (`img.shields.io/maven-central/v/org.meshtastic/sdk-core`) — the pattern a new KMP library publishing to Maven Central should copy verbatim.
   - Coverage badge: android only (`codecov` badge) — apple/meshtastic-sdk have no coverage tooling wired up, so no badge.
   - Localization badge: android only (Crowdin badge, since only android/apple ship translated UI; a backend KMP library likely doesn't need this).
   - Org-wide badges (present in the `.github` org profile/README and echoed in android's README): CLA-assistant, OpenCollective "Fiscal Contributors", "Powered by Vercel".
   - `meshtastic-sdk` additionally has an "API Docs" badge linking to its published Dokka site.
3. A short links row (User Guide • Developer Guide • Getting Started • License) — apple's style; meshtastic-sdk instead puts a "📚 API Reference (Dokka)" callout line right under the badges.
4. Overview → Features/Highlights → Install/Getting-Started → Architecture/module table → Contributing/Release-process pointer → License/footer.
5. Both flagship apps end with `Copyright <year>, Meshtastic LLC. GPL-3.0 license` (android, literal) / a `## License` section pointing at the `LICENSE` file (apple).
6. Universal external links: `meshtastic.org`, Discord invite (`discord.gg/meshtastic` — android; apple's CONTRIBUTING.md instead links an older `discord.com/invite/ktMAKGBnBs` invite — **inconsistent, should be unified to `discord.gg/meshtastic`**), GitHub org Discussions (`github.com/orgs/meshtastic/discussions`).
7. android's README also embeds a Repobeats analytics badge (`repobeats.axiom.co`) — not seen elsewhere, treat as optional/android-specific rather than baseline.

---

## 7. CODEOWNERS, labels, release/tagging, versioning

### CODEOWNERS (see §2 for org-wide count: 6/155)

`meshtastic-sdk/CODEOWNERS` and `kzstd/CODEOWNERS` are both explicit, well-commented, ordered general→specific, and route by directory (build/infra, protocol surface, public API, per-transport ownership, security-sensitive files get an extra `@meshtastic/security` reviewer). `meshtastic-sdk` uses placeholder GitHub team handles (`@meshtastic/sdk-maintainers`, `@meshtastic/build-infra`, etc.) with an explicit `TODO(scaffold)` comment to swap in real teams later; `kzstd` (single-maintainer repo) just uses `@jamesarich` throughout. **Neither android nor apple has a CODEOWNERS file at all** — for a KMP library the newer pattern (meshtastic-sdk/kzstd), not the flagship-app pattern, is the one to copy.

### Labels

- android: 40 labels — GitHub defaults (`bug`, `documentation`, `duplicate`, `enhancement`, `good first issue`, `help wanted`, `invalid`, `question`, `wontfix`) plus a large custom set: changelog-relevant (`bugfix`, `enhancement`(reused), `desktop`, `chore`, `ci`, `build`, `testing`, `documentation`(reused), `repo`, `automation`, `release`, `refactor`, `dependencies`), domain (`ui`, `a11y`, `maps`, `crash`, `l10n`, `firmware`, `hardware`, `modularization`), process (`critical`, `backlog`, `needs-review`, `needs-logs`, `skip-changelog`, `skip-preview-check`, `skip-docs-check`, `do-not-merge`, `ai-generated`, `spam`, `Needs CLA`, `Stale`, `Upstream`), and release-channel (`ch_Gplay`, `ch_Obtanium`, `ch_Testing`).
- apple: 15 labels — the same GitHub defaults plus a much smaller custom set: `backlog`, `security issue`, `needs sponsor`, `has sponsor`, `accessibility`, `skip-docs-check`.
- **Common baseline across both** (i.e. safe to assume as the org minimum): `bug`, `documentation`, `duplicate`, `enhancement`, `good first issue`, `help wanted`, `invalid`, `question`, `wontfix`, `backlog`, `skip-docs-check`.
- android's `.github/release.yml` header literally says: *"Labels here must match actual repo labels. Run `gh label list` to verify."* — labels are hand-maintained per repo, no shared org-level label-sync workflow was found.
- Auto-labeling is custom JS in `pull-request-target.yml` (branch-prefix / conventional-commit-title / changed-path derived), not the common `actions/labeler` + `labeler.yml` pattern — worth knowing if replicating, since there's no separate `labeler.yml` config file to copy.

### Release / tagging / versioning

- Both flagship repos use **`v`-prefixed semver tags** (`vX.Y.Z`), enforced/consumed by their respective `docs-release*.yml` (triggers are literally `tags: ['v*.*.*', '!v*-*']` on android).
- android: version resolution is `config.properties` (`VERSION_NAME_BASE`, `VERSION_CODE_OFFSET`) + `git rev-list --count HEAD` for the monotonic `versionCode`; multi-channel prerelease tags follow `vX.Y.Z-{internal,closed,open}.N`, promoted in sequence to a clean `vX.Y.Z` for production (`RELEASE_PROCESS.md`). A rolling `snapshot` prerelease tag also exists (force-moved to `HEAD` on every `main` push).
- apple: version lives in the Xcode project's `MARKETING_VERSION`; release branches are named `X.YY.ZZ-release`; the final tag is `vX.YY.ZZ` (`RELEASING.md`). Hotfixes land on the release branch and get cherry-picked back to `main`.
- meshtastic-sdk (KMP precedent): plain semver, explicitly **pre-1.0** or `0.1.0` with a documented `docs/versioning.md`, a dedicated `bom/` (Bill-of-Materials) module so consumers can align all published-module versions together, and CI publishes a moving `0.1.0-SNAPSHOT` to the **Sonatype Central snapshot repository** on every push to `main`. `kzstd`/`takpacket-sdk` instead keep a plain-text `VERSION` file at repo root (simpler, no BOM module, single-artifact library) plus a `jitpack.yml` (JitPack as an alternative distribution channel to Maven Central).
- **Both flagship apps target `X.Y.Z` (2-part-plus-patch) semver; the KMP-library precedents also use plain semver** (no CalVer anywhere in the org). Recommend semver for any new KMP library.

---

## 8. Coordinates / package naming — `org.meshtastic.*`

Confirmed directly in build files (not inferred):

- android module namespaces (`namespace = "..."` in each module's `build.gradle.kts`): `org.meshtastic.app`, `org.meshtastic.core.barcode`, `org.meshtastic.feature.car`, `org.meshtastic.feature.widget`, `org.meshtastic.feature.discovery`, `org.meshtastic.feature.wifiprovision`, `org.meshtastic.feature.docs`, `org.meshtastic.baselineprofile`, `org.meshtastic.screenshot.tests`, `org.meshtastic.screenshot.docs`, etc. — i.e. **every internal Kotlin package/namespace uses `org.meshtastic.<layer>.<module>`.**
- The shipped Android app's `applicationId`, however, stays **grandfathered at `com.geeksville.mesh`** (`androidApp/build.gradle.kts:73`, debug variants get `com.geeksville.mesh.$flavor.debug`) — historical Play Store identity predates the `org.meshtastic` rebrand and cannot change without losing the store listing. **Do not treat `com.geeksville.mesh` as a convention to copy** — it's legacy-locked, `org.meshtastic.*` is the actual convention for anything new.
- Maven coordinates already published/consumed under the `org.meshtastic` group: `org.meshtastic:protobufs` (consumed by android, pinned in `gradle/libs.versions.toml`), `org.meshtastic:sdk-core` / `org.meshtastic:sdk-transport-tcp` / `org.meshtastic:sdk-storage-sqldelight` / `org.meshtastic:sdk-bom` (meshtastic-sdk's own published artifacts, confirmed via its README install snippet and Maven Central badge).
- `meshtastic-sdk/build.gradle.kts:42`: `group = "org.meshtastic"` (root project group, inherited by publishing convention plugin `meshtastic.publishing` applied per-module).
- `mqttastic-client-kmp/gradle.properties:20`: `GROUP=org.meshtastic` (same group, different mechanism — a Gradle property instead of a hardcoded root `group =`), applied via its own `mqtt.publishing` convention plugin.
- `kzstd/build.gradle.kts:14`: `group = providers.gradleProperty("GROUP").getOrElse("org.meshtastic")` — same group, overridable-with-fallback pattern.
- `takpacket-sdk/kotlin/build.gradle.kts:15`: `group = "org.meshtastic"`, publishing via the Vanniktech `maven-publish` plugin to Maven Central.

**Verdict: `org.meshtastic` is the unambiguous, unanimous Maven/Gradle group-id and Kotlin package-root convention for every KMP-flavored artifact in the org** (4 for 4 precedents, plus android's own internal modules). A new KMP library should publish as `org.meshtastic:<artifact-name>` and root its Kotlin packages at `org.meshtastic.<library>.<module>`.

---

## 9. Existing KMP-library precedent (the closest analogue to the target)

Four repos are the org's actual prior art for "a KMP library," and they're notably **more security/publishing-hardened than either flagship app**, though CI-simpler:

| | meshtastic-sdk | mqttastic-client-kmp | takpacket-sdk | kzstd |
|---|---|---|---|---|
| Default branch | main | main | (not checked, likely main) | **master** |
| Community files | CODEOWNERS, CODE_OF_CONDUCT, CONTRIBUTING, **GOVERNANCE.md**, LICENSE, README, **RELEASING.md**, **SECURITY.md**, **SUPPORT.md** | CODE_OF_CONDUCT, CONTRIBUTING, LICENSE, README, SECURITY | CONTRIBUTING, LICENSE, README (no CoC/SECURITY/CODEOWNERS) | CODEOWNERS, CODE_OF_CONDUCT, CONTRIBUTING, LICENSE, README, RELEASING.md, SECURITY.md |
| CI workflows | `ci.yml`, `codeql.yml.disabled`, `dependency-review.yml`, `docs.yml`, `release.yml`, `scorecard.yml.disabled`, `tooling-check.yml` | `ci.yml`, `codeql.yml` (**enabled**), `docs.yml`, `release.yml` | `bump-version.yml`, `ci.yml`, `docs.yml`, `release.yml` | `ci.yml`, `release.yml` |
| Action pinning | **Pinned to commit SHA with version comment**, e.g. `actions/checkout@9c091bb...# v7.0.0` | (not fully checked) | (not fully checked) | (not fully checked) |
| Dependency automation | `renovate.json` (root) — modern `config:recommended` dialect, weekly schedule, rate limits, per-ecosystem grouping, vulnerability alerts | `renovate.json` (root) | `.github/renovate.json` | `.github/renovate.json` + `.github/dependabot.yml` (both — likely mid-migration) |
| Publishing | Maven Central (Sonatype Central) + snapshot repo, `bom/` module, Dokka → GitHub Pages | Maven Central pattern (own `mqtt.publishing` convention plugin), `bom/` module | Maven Central via Vanniktech plugin + JitPack (`jitpack.yml`) | JitPack (`jitpack.yml`) |
| Group ID | `org.meshtastic` | `org.meshtastic` | `org.meshtastic` | `org.meshtastic` (overridable property, defaults to it) |
| Versioning | semver, pre-1.0 (`0.1.0`), documented `docs/versioning.md` | (not checked in depth) | plain-text `VERSION` file | plain-text `VERSION` file |
| Supply-chain | `actions/dependency-review-action`, `codeql`/`scorecard` present but **disabled** (`.disabled` suffix — aspirational, not yet turned on) | `codeql.yml` active | — | — |
| README badges | License, **Maven Central**, CI, **API Docs (Dokka)** | (not checked in depth) | — | — |

**Key takeaway:** the org already has an informal "KMP library scaffold" distinct from (and in security/publishing hygiene, ahead of) the flagship apps: CODEOWNERS, SECURITY.md, GOVERNANCE.md/SUPPORT.md, Renovate with vulnerability alerts, CodeQL/Scorecard/dependency-review, `org.meshtastic` Maven group, a `bom/` module for multi-artifact libraries, and Dokka-published API docs on GitHub Pages. It is inconsistent between the four (e.g. `kzstd` still on `master`, `takpacket-sdk` missing CODEOWNERS/SECURITY, mixed Renovate file location, mixed dependabot/renovate). **This inconsistency is itself the strongest argument for writing down one explicit baseline** rather than each new KMP repo scaffolding its own variant from memory.

---

## 10. Proposed "Meshtastic org baseline" — what every repo (especially a KMP library) should meet

Below, "flagship" = copy android's pattern; "precedent" = copy the meshtastic-sdk/kzstd pattern; "new" = a gap nothing in the org currently fills well.

### Required community-health files (repo root unless noted)
- [ ] `README.md` with: centered title/logo, badge row (CI, License, package-registry if published, coverage if measured), one-line links row, Overview → Install → Architecture → Contributing/Release pointers → License footer. *(flagship shape, precedent's Maven Central badge)*
- [ ] `LICENSE` — **GPL-3.0** (org-dominant for first-party code; verify per-repo intent but default to GPLv3 unless there's a specific reason for a permissive license, e.g. a thin client SDK meant for broad embedding).
- [ ] `CONTRIBUTING.md` — present in 100% of checked repos; keep it.
- [ ] `CODE_OF_CONDUCT.md` — copy android's one-liner pointing at `https://meshtastic.org/docs/legal/conduct/` (the parent-project CoC), don't reinvent. *(org-wide only 9/155 have this — be one of them.)*
- [ ] `SECURITY.md` — copy android's shape (supported-version table + "use the Security tab to file a private report"). *(org-wide only 10/155 have this.)*
- [ ] `CODEOWNERS` — **use the precedent, not the flagships**: ordered general→specific, directory-scoped, extra reviewer on security-sensitive paths, placeholder `@meshtastic/<team>` handles with a scaffold TODO if teams don't exist yet.
- [ ] `SUPPORT.md` / `GOVERNANCE.md` — *(new/optional but recommended for a library with external consumers — copy meshtastic-sdk, since a library has different "how do I get help" needs than a consumer app.)*
- [ ] `.github/FUNDING.yml` — point at the **org**, not an individual: `github: meshtastic`, `open_collective: meshtastic`.
- [ ] `.github/ISSUE_TEMPLATE/{bug_report.yml,feature_request.yml,config.yml}` with `blank_issues_enabled: false`.
- [ ] `.github/PULL_REQUEST_TEMPLATE.md` (or `pull_request_template.md`) — prefer apple's structured What/Why/How-tested/Screenshots/Checklist form over android's free-text tips form; it's more actionable for reviewers and scales better to a library where "how is this tested" matters more.

### Default branch & license
- [ ] Default branch: **`main`** (matches both flagship apps and 7/8 Kotlin-primary repos; `master` in the org is legacy/vendored-dependency debt, and `develop` is firmware-specific git-flow, neither applies to a KMP library).
- [ ] License: **GPL-3.0**, same FSF boilerplate text as android/apple/all 4 KMP precedents.

### Package/coordinate naming
- [ ] Gradle group id **and** Kotlin package root: **`org.meshtastic`** (e.g. `org.meshtastic:my-library-core`, packages under `org.meshtastic.mylibrary.*`). Use a Gradle property (`GROUP=org.meshtastic` in `gradle.properties`, mqttastic-client-kmp's style) or a root `group = "org.meshtastic"` (meshtastic-sdk/kzstd/takpacket-sdk style) — either is attested; property-based is slightly more overridable for forks/samples.
- [ ] A shared `*.publishing` Gradle convention plugin (build-logic) wired to the Vanniktech `maven-publish` plugin, publishing to Maven Central (+ Sonatype Central snapshots on every `main` push) — this is what all 4 precedents already do independently; formalizing it once avoids 4 slightly-different reinventions.
- [ ] If the library ships more than one publishable module, add a `bom/` module (meshtastic-sdk/mqttastic-client-kmp pattern) so consumers can pin one BOM version instead of N module versions.

### CI hygiene (target android's rigor, adapted to library scope)
- [ ] A composite `gradle-setup` action (copy android's shape): CI-only `gradle.properties`, `gradle/actions/wrapper-validation`, `actions/setup-java` (pin the same JDK major the org's other Kotlin repos use), `gradle/actions/setup-gradle` with cache-cleanup and job-summary on.
- [ ] Reusable `workflow_call` check workflow (android's `reusable-check.yml` pattern) invoked from both a `pull_request` workflow and a `push`-to-`main` workflow, rather than duplicating steps per trigger.
- [ ] Standard gate: `spotlessCheck` + `detekt` + `allTests`/`test` + (if KMP) a `kmpSmokeCompile`-equivalent target-compile check, run with `-Pci=true --continue` so all failures surface in one run.
- [ ] Pin third-party Action **major versions at minimum** (android's `@v7`/`@v6` style); consider pinning to commit SHA with a version comment (meshtastic-sdk's stricter style) for anything touching publishing/secrets.
- [ ] `codecov.yml` + Kover (or equivalent) if the library carries meaningful logic — component-scoped coverage like android's `core`/`features`/`app`/`desktop` split, adapted to the library's own module boundaries.
- [ ] Enable, don't just scaffold, supply-chain checks: `dependency-review-action` (mqttastic/meshtastic-sdk already run or ship this) and turn **on** the `codeql.yml`/`scorecard.yml` files meshtastic-sdk currently ships `.disabled` — a fresh library is a good place to actually enable them rather than let them sit disabled again.
- [ ] Docs: Dokka → GitHub Pages, built on every `main` push but only **published** on a `v*.*.*` tag (shared idiom in both android and apple's `docs-deploy.yml`/`docs-release.yml` split) — avoids the released docs site drifting ahead of the last released artifact version.
- [ ] `pull_request_target` auto-labeler enforcing at least one changelog-relevant label before merge (android's custom-JS pattern), feeding a `.github/release.yml` label-driven changelog.

### Dependency automation
- [ ] **Renovate**, not Dependabot (the org's de facto standard for every Kotlin/KMP repo checked). Prefer the newer `config:recommended`-based dialect (meshtastic-sdk's) over android's older granular-preset style for new repos: `extends: ["config:recommended", ":dependencyDashboard", ":semanticCommits", ":timezone(UTC)"]`, weekly schedule, `prHourlyLimit`/`prConcurrentLimit` caps, `rangeStrategy: "bump"`, `lockFileMaintenance`, `vulnerabilityAlerts.enabled: true`.
- [ ] Group ecosystem-coupled dependencies explicitly (Kotlin/KSP/compiler-plugins that must move in lockstep — android and meshtastic-sdk both hand-roll this group for good reason; expect the same class of problem in any new KMP repo depending on Kotlin/Compose/Ktor/etc.).
- [ ] File location: put it at **`.github/renovate.json`** (marginally more common of the two observed locations, and keeps repo root uncluttered) unless there's a reason to prefer root.
- [ ] `labels: ["dependencies"]` matching whatever label taxonomy the repo settles on (§7's common baseline should include a `dependencies` label).

### Branding/README
- [ ] Badge row order/content: CI status, License (shields.io GPL badge, apple/meshtastic-sdk style), Maven Central version (if published), Coverage (only if measured — don't cargo-cult a codecov badge with no coverage tooling behind it), API-docs (Dokka) link.
- [ ] Use `discord.gg/meshtastic` everywhere (not the stale `discord.com/invite/ktMAKGBnBs` link apple's CONTRIBUTING.md still has — flag that as a fix for apple independent of this baseline).
- [ ] Footer: `Copyright <year>, Meshtastic LLC. GPL-3.0 license`.

### Versioning/release
- [ ] Plain semver (`X.Y.Z`), pre-1.0 while the API is unstable, documented in a `docs/versioning.md` (meshtastic-sdk's pattern) — this matters more for a library (semver is a public API contract) than it does for the two consumer apps.
- [ ] `v`-prefixed git tags (`vX.Y.Z`), consistent with every other repo checked.
- [ ] A `VERSION` plain-text file **or** a `config.properties`-style base-version file — either is attested (kzstd/takpacket-sdk vs. android); pick one and let CI read it for both the Gradle version and the release-tag name so they can't drift.

---

## Appendix: file paths cited

- `/Users/james/meshtastic/android/.github/workflows/*.yml`, `/Users/james/meshtastic/android/.github/actions/gradle-setup/action.yml`, `/Users/james/meshtastic/android/.github/renovate.json`, `/Users/james/meshtastic/android/.github/release.yml`, `/Users/james/meshtastic/android/.github/FUNDING.yml`, `/Users/james/meshtastic/android/.github/ISSUE_TEMPLATE/config.yml`, `/Users/james/meshtastic/android/.github/PULL_REQUEST_TEMPLATE.md`, `/Users/james/meshtastic/android/.github/instructions/{kmp-common,ci-workflows}.instructions.md`, `/Users/james/meshtastic/android/{README.md,CONTRIBUTING.md,SECURITY.md,CODE_OF_CONDUCT.md,RELEASE_PROCESS.md,codecov.yml,crowdin.yml,LICENSE,.coderabbit.yaml}`, `/Users/james/meshtastic/android/androidApp/build.gradle.kts`, `/Users/james/meshtastic/android/screenshot-tests/build.gradle.kts` (and sibling modules' `build.gradle.kts` for `namespace =`).
- `/Users/james/meshtastic/apple/.github/workflows/*.yml`, `/Users/james/meshtastic/apple/.github/{FUNDING.yml,pull_request_template.md,copilot-instructions.md,ISSUE_TEMPLATE/config.yml}`, `/Users/james/meshtastic/apple/{README.md,CONTRIBUTING.md,RELEASING.md,LICENSE}`.
- `/Users/james/meshtastic/meshtastic-sdk/{README.md,CODEOWNERS,SECURITY.md,SUPPORT.md,GOVERNANCE.md,renovate.json,build.gradle.kts,.github/workflows/*.yml}`.
- `/Users/james/meshtastic/mqttastic-client-kmp/{gradle.properties,renovate.json,.github/}`.
- `/Users/james/meshtastic/takpacket-sdk/kotlin/build.gradle.kts`, `/Users/james/meshtastic/takpacket-sdk/.github/renovate.json`.
- `/Users/james/meshtastic/kzstd/{CODEOWNERS,build.gradle.kts,.github/renovate.json,.github/dependabot.yml}`.
- Org data via `gh`: `gh repo list meshtastic --limit 200 --json name,description,defaultBranchRef,licenseInfo,isArchived,primaryLanguage,repositoryTopics` (saved to `repo_inventory.json` alongside this report), `gh repo view meshtastic/.github`, `gh api repos/meshtastic/.github/contents[/profile]`, `gh api repos/{meshtastic/Meshtastic-Android,meshtastic/Meshtastic-Apple}/community/profile`, `gh label list --repo meshtastic/{Meshtastic-Android,Meshtastic-Apple}`, `gh api search/code -f 'filename:{renovate.json,dependabot.yml,CODEOWNERS,SECURITY.md,CODE_OF_CONDUCT.md} org:meshtastic'`.
