# Meshtastic KMP — Remediation Plan

**Date:** 2026-07-21 · Pairs with [MESHTASTIC-KMP-STANDARD.md](./MESHTASTIC-KMP-STANDARD.md) + [GAP-MATRIX.md](./GAP-MATRIX.md).

## Execution status — updated 2026-07-21

The per-repo checklists below are the original baseline. This section tracks what has actually shipped.

### Foundation — MERGED
- **Licensing:** GPL-3.0-**or-later** standardized (kzstd relicensed via kzstd#14; sdk reconciled; gradle-flatpak `COPYING`→full GPL text via flatpak#11).
- **Branches:** `master`→`main` on kzstd + takpacket (protobufs left — not admin there).
- **Merge queues** live on all 4 admin repos + mqtt.
- **Shared HTTP build cache** on all 6 (server `gradle.hiddentemple.xyz`). ⚠️ The `GRADLE_CACHE_URL` **must include the `/cache/` path** — a bare-host URL returns 401 on reads and Gradle disables the remote cache ("remote build cache was disabled during the build due to errors").
- **Konan caching** added to kzstd/takpacket/protobufs.
- **kzstd v0.1.1 released** to Maven Central.
- All foundation alignment PRs merged: sdk #75/#76/#77, mqtt #85/#86, kzstd #13/#14/#15, gradle-flatpak #11/#12, takpacket #109.

### Depth phase — PRs OPEN (draft/ready; CI + CodeRabbit clearing on throttled runners)
| Workstream | PRs | Closes (matrix #) |
|---|---|---|
| **API stability (#6)** | takpacket #111, mqtt #87, kzstd #16 | klib ABI enforced (#13/#14); mqtt `explicitApi()` (#5) |
| **Security (#7)** | sdk #78, takpacket #112, kzstd #17, gradle-flatpak #13, mqtt #89 | CodeQL (`actions`) + OpenSSF Scorecard (#27); see CodeQL caveat |
| **Docs (#8)** | kzstd #18 (Pages site, #28), gradle-flatpak #14 (real Dokka javadoc jar, #10) | |

### Not started
- **Test depth (#9):** mqtt `transport-ws` tests (P0), sdk `test-android` real tests, gradle-flatpak internal-logic unit tests; then flip Codecov report-only → gating (matrix #15/#16/#17).

### Deferred — protobufs (review-blocked)
All protobufs work is blocked on its 1-required-review rule (author can't self-approve; org policy = don't admin-override). Open + blocked: badge #1015, cache #1016, James's release-trigger #1014. Its ABI (#5/#13), empty javadoc stub (#10), catalog, and governance gaps wait on that unblock.

### Key findings
- **CodeQL can't scan Kotlin 2.4.10 yet.** CodeQL CLI 2.26.1 (current; shipped by codeql-action v4.37.2) rejects Kotlin 2.4.10 ("too recent") — the `java-kotlin` autobuild fails. Every `codeql.yml` therefore scans **`actions` only**; `java-kotlin` is committed-but-commented with a re-enable note for when a newer CLI ships (Kotlin ceiling 2.4.20 merged upstream). mqtt had already documented+disabled this.
- **Build-cache URL needs `/cache/`** (see Foundation, above).

### Still systemic / unaddressed (lower priority)
- `distributionSha256Sum` on wrappers (6/6, #2).
- SHA-pinning *existing* workflow actions — new security/docs workflows are pinned; older `ci.yml`-class ones aren't (Renovate maintains versions) (#23).
- Governance-file pack (CoC/SECURITY/CODEOWNERS/templates) in takpacket/protobufs/kzstd/gradle-flatpak (#36–#40).
- kzstd Gradle 9.5.1→9.6.1 (Renovate branch) (#1); stale install/version docs (#31).

## Strategy

1. **Clean the reference first.** `meshtastic-sdk` is the closest to the standard and already holds the convention plugins, CI hardening, and community-health scaffold. Fix *its* loose ends first so it is a trustworthy template.
2. **Extract, then propagate.** Lift `meshtastic-sdk`'s `build-logic` + CI + `.github` scaffold into a reusable shape and apply outward, folding in `mqttastic`'s coverage/matrix. Do systemic one-liner fixes (SHA-pinning, `permissions:`, `distributionSha256Sum`) as consistent per-repo PRs.
3. **Priority order = risk to consumers first.** Broken/silent releases, mislabeled licenses, and untested-but-shipped code before polish.
4. **Everything via branches + PRs.** These are public repos — never commit to `main`/`master` directly. One P0 PR per repo, P1/P2 as focused follow-ups. Verify each repo's own CI green before merge.

## Priority definitions

- **P0 — Broken / misleading / risky to consumers.** Silent or broken release automation, wrong license metadata, shipped-but-untested code, ABI checks that don't run, docs that assert false states.
- **P1 — Standard non-compliance with real impact.** Missing coverage gate, no linter, JVM-only ABI, CI not testing native targets, unpinned actions, missing `permissions`.
- **P2 — Consistency & polish.** Branch rename, Dokka site, governance files, README/badges/samples, metadata.

---

## Per-repo checklists

### meshtastic-sdk  (reference — do first)
- **P0** Purge "not yet public / workflows disabled" claims from `README.md`, `RELEASING.md`, `docs/ci-cd.md` (v0.1.0 is live). **[S]**
- **P0** Resolve GPL-3.0-**only** (README) vs GPL-3.0-**or-later** (214 SPDX headers + ADR-004) — pick one, make consistent. **[S, human decision]**
- **P1** Wire the coverage chain: `koverXmlReport` + `koverVerify` gate in `check` + `codecov/codecov-action` upload + badge (borrow `mqttastic`'s config). **[M]**
- **P1** Make `test-android` actually run Android unit tests (currently compile/assemble only). **[M]**
- **P1** Harden `tooling-check.yml` (add `concurrency` + `permissions`); refresh rotting SHAs in `.disabled` supply-chain workflows and **enable** `codeql`/`scorecard`. **[S–M]**
- **P2** Fix post-ADR-015 drift: `CODEOWNERS`, `core/Module.md`, `.gitattributes` still reference the removed `:proto` module; swap placeholder `@meshtastic/*` teams for real ones (or document as intentional). **[S]**
- **P2** `distributionSha256Sum` on wrapper; set repo homepage → Dokka site. **[S]**

### mqttastic-client-kmp
- **P0** Add tests for `mqtt-client-transport-ws` (ships with zero). **[M]**
- **P0** Kill Kotlin-version doc drift (README, AGENTS.md, `core/README.md`, SKILL.md say 2.3.20 → actual 2.4.10) and the self-contradictory `libs.versions.toml` comment. **[S]**
- **P1** Enable `explicitApi()` on all modules (keep Konsist as supplement). **[M — may surface visibility fixes]**
- **P1** Extend BCV to klib/native surface (currently JVM-only) for the 8 non-JVM targets. **[M]**
- **P1** SHA-pin all workflow actions. **[S]**
- **P2** Refresh stale `core/README.md`/`core/Module.md` (pre-split branding); add `.editorconfig`, `CODEOWNERS`; set homepage; move integration-test broker config out of source. **[S–M]**

### takpacket-sdk
- **P0** Fix BCV: generate the missing klib dump and wire `apiCheck` into CI (comment claims a dump that doesn't exist). **[M]**
- **P1** CI: add a `macos-latest` job that runs native/Apple tests (only `jvmTest` runs today; 11/13 targets never execute); add `gradle/actions/setup-gradle` caching (absent). **[M]**
- **P1** Add Kover + gate + Codecov; add Spotless(ktlint) + detekt + `.editorconfig`-driven format gate. **[M]**
- **P1** Add `permissions:` to `ci.yml`; SHA-pin actions. **[S]**
- **P2** `master`→`main`; add `CODE_OF_CONDUCT`, `SECURITY.md`, `CODEOWNERS`, issue/PR templates, `FUNDING.yml`→org; README badges; fix stale `0.7.0` install snippet; set homepage. **[M]**

### kzstd
- **P0** Release the fully-staged **v0.1.1** (tag + let `release.yml` publish) — or explicitly de-stage it. **[S, human decision]**
- **P1** Add Kover + gate + Codecov. **[M]**
- **P1** Add Spotless(ktlint) + detekt (CONTRIBUTING already flags this TODO). **[M]**
- **P1** CI: add a real target matrix (jsTest/wasmJsTest missing); add `permissions:` to `ci.yml`; SHA-pin actions. **[M]**
- **P1** Bump Gradle 9.5.1→9.6.1 (Renovate branch already open) + `distributionSha256Sum`. **[S]**
- **P2** `master`→`main`; Dokka→Pages; samples; platform table; CI/coverage badges; fix stale `0.1.0` install snippet; remove leftover Dependabot (Renovate covers it). **[M]**

### gradle-flatpak-sources  (Gradle plugin — adapted subset)
- **P0** Handle the burned **v0.1.3** tag (document/yank; ensure nothing resolves it) and confirm v0.1.4 is the floor. **[S]**
- **P0** Fix `COPYING` → full GPL-3.0 text so GitHub stops reporting license "Other". **[S]**
- **P0** Replace empty javadoc stub with a real Dokka javadoc jar; update `CHANGELOG.md` (stuck at 0.1.2-Unreleased) and README install (0.1.2→0.1.4). **[S–M]**
- **P1** Add unit tests for the 3 internal logic classes (URL parse, mirror-gen, SHA-256/JSON) — currently only 7 black-box functional tests; add coverage. **[M]**
- **P1** Add `permissions:` + `concurrency:` to `ci.yml`; SHA-pin actions; commit a custom detekt config; add `.editorconfig`. **[S]**
- **P2** Add `SECURITY.md`, local `CODE_OF_CONDUCT`, `CODEOWNERS`, issue templates; declare min-Gradle compat metadata; set homepage. **[S]**

### protobufs (`packages/kmp/`)
- **P0** Fix the tag→publish path — `push: tags: v*` in `publish-kmp.yml` has never fired (every release manual). Verify end-to-end. **[M]**
- **P0** Replace the 261-byte empty javadoc stub with real Dokka output. **[S–M]**
- **P0** Fix root README CI badge (points at nonexistent `ci.yml`). **[S]**
- **P1** Add `gradle/libs.versions.toml`; add `explicitApi()`; add BCV/built-in ABI validation + `.api` dumps for the 14 targets; pin `jvmToolchain`. **[M — note generated code]**
- **P1** Add `permissions:` + `concurrency:` across the 7 workflows; SHA-pin actions. **[S]**
- **P2** `master`→`main`; Dokka→Pages; add `CONTRIBUTING`/`CODE_OF_CONDUCT`/`SECURITY.md`/`CODEOWNERS`/KMP-aware templates; add Maven Central badge + a Kotlin usage sample; consider a BOM; `distributionSha256Sum`. **[M]**

---

## Cross-cutting batches (alternative to per-repo; each = one small PR × N repos)

| Batch | Repos | Effort |
|---|---|---|
| SHA-pin all actions (+ Renovate comment) | mqtt, kz, tak, flat, pb | S each |
| Add `permissions:`/`concurrency:` to unhardened workflows | sdk, kz, tak, flat, pb | S each |
| `distributionSha256Sum` on wrapper | all 6 | S each |
| Coverage chain (Kover gate + Codecov) | sdk, kz, tak | M each |
| Spotless(ktlint)+detekt+`.editorconfig` gate | kz, tak, pb, flat | M each |
| Real Dokka javadoc jar | flat, pb | S each |
| Governance files pack (CoC/SECURITY/CODEOWNERS/templates/FUNDING→org) | tak, pb, kz, flat | M total |
| `master`→`main` | kz, tak, pb | S each (coordinate) |

## Effort & risk summary

| Repo | P0 | P1 | P2 | ~Total | Riskiest change |
|---|:--:|:--:|:--:|:--:|---|
| meshtastic-sdk | 2 | 3 | 2 | ~1–1.5d | license decision |
| mqttastic-client-kmp | 2 | 3 | 1 | ~1.5–2d | `explicitApi` may surface API fixes |
| takpacket-sdk | 1 | 3 | 1 | ~2–2.5d | enabling native test matrix (flaky risk) |
| kzstd | 1 | 4 | 1 | ~1.5–2d | releasing v0.1.1 |
| gradle-flatpak-sources | 3 | 2 | 1 | ~1–1.5d | broken-tag handling |
| protobufs | 3 | 2 | 1 | ~1.5–2d | release trigger; generated-code ABI |

## Items needing a human decision before I touch them

1. **License:** GPL-3.0-only vs -or-later for `meshtastic-sdk` (and confirm GPLv3 default org-wide).
2. **`jvmToolchain` value:** keep 21, or drop broadly-consumed libs (kzstd, protobufs, mqtt, takpacket) to 17 for consumer reach? (Affects the published bytecode's minimum runtime.)
3. **Branch renames** (`master`→`main` on kzstd/takpacket/protobufs): coordinate — breaks external links, open PRs, CI refs.
4. **Releasing kzstd v0.1.1** and **yanking gradle-flatpak v0.1.3**: publish/withdraw actions.
5. **Execution unit:** per-repo PR series (recommended) vs cross-cutting theme PRs.

## Suggested execution order

**meshtastic-sdk (reference cleanup) → protobufs + gradle-flatpak (most broken P0s) → kzstd + takpacket → mqttastic (already closest).** Then the cross-cutting P1 hardening batch, then P2 polish.
