# Meshtastic KMP — Cross-Repo Gap Matrix

**Date:** 2026-07-21 · Measured against [MESHTASTIC-KMP-STANDARD.md](./MESHTASTIC-KMP-STANDARD.md). Full per-repo evidence in `repo-*.md`.

> **Status (updated 2026-07-21):** the table below is the original audit **baseline**. Execution progress — what merged, what's in open PRs, what remains — is tracked in [REMEDIATION-PLAN.md § Execution status](./REMEDIATION-PLAN.md#execution-status--updated-2026-07-21). In brief: the **foundation** (license/branches/merge-queues/shared cache/publishing) is **merged**; **API-stability (#5/#13/#14)**, **security-scanning (#27)**, and **docs (#10/#28)** are in **open PRs** across the 5 mergeable repos; **test-depth (#15–#17)** is not started; all **protobufs** work is review-blocked. Caveat: CodeQL currently scans `actions` only — its CLI (2.26.1) can't analyze Kotlin 2.4.10 yet.

Legend: ✅ meets · 🟡 partial · ❌ absent/fails · — N/A. Columns: **sdk**=meshtastic-sdk · **mqtt**=mqttastic-client-kmp · **kz**=kzstd · **tak**=takpacket-sdk · **flat**=gradle-flatpak-sources (Gradle plugin) · **pb**=protobufs (`packages/kmp`, generated).

| # | Criterion | sdk | mqtt | kz | tak | flat | pb |
|---|-----------|:--:|:--:|:--:|:--:|:--:|:--:|
| **BUILD LOGIC** |
| 1 | Gradle 9.6.1 wrapper | ✅ | ✅ | 🟡9.5.1 | ✅ | ✅ | ✅ |
| 2 | `distributionSha256Sum` pinned | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 3 | Version catalog | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 4 | `build-logic` convention plugins | ✅ | ✅ | — | ❌ | — | ❌ |
| 5 | `explicitApi()` strict | ✅ | ❌ | ✅ | ✅ | ❌ | ❌ |
| 6 | JVM toolchain pinned | ✅21 | ✅11 | ✅21 | ✅21 | ✅17 | ❌ |
| 7 | Config cache on | ✅ | ✅ | 🟡 | 🟡 | 🟡* | 🟡 |
| **PUBLISHING** |
| 8 | Central Portal + vanniktech/plugin-publish | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 9 | Signing + complete POM | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 10 | Real Dokka javadoc jar | ✅ | ✅ | ✅ | ✅ | ❌stub | ❌stub |
| 11 | BOM (multi-module) | ✅ | ✅ | — | — | — | — |
| 12 | Tag→publish trigger actually fires | ✅ | ✅ | ❌ | ✅ | 🟡 | ❌ |
| **API STABILITY** |
| 13 | ABI validation covers klib (not JVM-only) | ✅ | 🟡jvm | ✅ | 🟡jvm | — | ❌ |
| 14 | `apiCheck`/`checkAbi` runs in CI | ✅ | ✅ | ✅ | ❌ | ✅† | ❌ |
| **TESTING & COVERAGE** |
| 15 | All shipped modules have tests | ✅ | ❌ws | 🟡 | 🟡 | 🟡 | — |
| 16 | Native/Apple targets test-executed in CI | ✅ | ✅ | 🟡 | ❌ | — | ❌ |
| 17 | Kover + `koverVerify` gate + Codecov | 🟡meas | ✅ | ❌ | ❌ | ❌ | — |
| **CODE QUALITY** |
| 18 | Spotless/ktlint in CI | ✅ | ✅ | ❌ | ❌ | 🟡 | ❌ |
| 19 | detekt (custom config) | ✅ | ✅ | ❌ | ❌ | 🟡dflt | ❌ |
| 20 | `.editorconfig` | ✅ | ❌ | ✅ | ✅ | ❌ | ❌ |
| **CI/CD** |
| 21 | macOS runner + real test matrix | ✅ | ✅ | 🟡 | ❌ | — | 🟡 |
| 22 | `setup-gradle` caching all jobs | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| 23 | SHA-pinned actions | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 24 | Least-priv `permissions` every workflow | 🟡 | ✅ | 🟡 | 🟡 | 🟡 | ✅ |
| 25 | `concurrency` every workflow | 🟡 | ✅ | ✅ | ✅ | ❌ | ❌ |
| 26 | Renovate (`config:recommended`) | ✅ | ✅ | 🟡+db | ✅ | ✅ | ✅ |
| 27 | Supply-chain checks enabled (not `.disabled`) | 🟡 | ✅ | ❌ | ❌ | ❌ | ❌ |
| **DOCUMENTATION** |
| 28 | Dokka v2 → GitHub Pages | ✅ | ✅ | ❌ | ✅ | ❌ | ❌ |
| 29 | README badges incl. Maven Central | 🟡 | ✅ | 🟡 | ❌ | ✅ | 🟡broken |
| 30 | Platform-support table | ✅ | ✅ | 🟡 | 🟡 | — | 🟡 |
| 31 | Install snippet version current | 🟡 | ✅ | ❌ | ❌ | ❌ | 🟡 |
| 32 | CHANGELOG current | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 33 | Samples module in CI | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| **ORG ALIGNMENT** |
| 34 | Default branch `main` | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ |
| 35 | LICENSE correct GPL-3.0 | 🟡‡ | ✅ | ✅ | ✅ | ❌ | ✅ |
| 36 | CODE_OF_CONDUCT | ✅ | ✅ | ✅ | ❌ | 🟡 | ❌ |
| 37 | SECURITY.md | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| 38 | CONTRIBUTING | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 39 | CODEOWNERS | 🟡 | ❌ | 🟡 | ❌ | ❌ | ❌ |
| 40 | Issue + PR templates | ✅ | ✅ | ❌ | ❌ | 🟡 | 🟡 |
| 41 | Homepage URL / metadata | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | ✅ |

\* `gradle-flatpak-sources` config cache is legitimately off (plugin-under-test incompatibility). † plugin uses `validatePlugins` in place of ABI dump (appropriate). ‡ `meshtastic-sdk` GPL-3.0-only (README) vs GPL-3.0-or-later (SPDX headers/ADR) contradiction.

## Approximate standard-compliance by repo (of applicable criteria)

| Repo | ✅ full | 🟡 partial | ❌ gap | Headline |
|---|:--:|:--:|:--:|---|
| **meshtastic-sdk** | ~31 | ~7 | ~2 | **Reference impl.** Finish coverage chain, fix stale docs + license/CODEOWNERS drift. |
| **mqttastic-client-kmp** | ~30 | ~5 | ~5 | Most mature CI/coverage. Add `explicitApi`+klib ABI; test `transport-ws`; fix version drift; SHA-pin. |
| **takpacket-sdk** | ~20 | ~9 | ~11 | Great release eng + docs, but **CI barely tests/validates**: no macOS tests, toothless BCV, no coverage/lint. |
| **kzstd** | ~19 | ~8 | ~12 | Superb correctness tests; **v0.1.1 unreleased**; no coverage/lint/Dokka; on `master`; Gradle behind. |
| **gradle-flatpak-sources** | ~16 | ~10 | ~9 | Solid dual-publish; **broken v0.1.3 tag**, **license misreported**, empty javadoc, no unit tests. |
| **protobufs (kmp)** | ~14 | ~7 | ~15 | Modern publish of 14 targets, but **release never auto-fires**, no catalog/explicitApi/BCV/BOM, empty javadoc, thin governance. |

## Systemic gaps (present in most/all — best fixed once, applied everywhere)

1. **No `distributionSha256Sum`** on any wrapper (6/6).
2. **Actions not SHA-pinned** anywhere except `meshtastic-sdk` (5/6).
3. **Coverage chain incomplete** — only `mqttastic` has Kover-gate + Codecov end-to-end (5/6 gap, incl. sdk which measures but doesn't wire).
4. **`ci.yml`-class workflow missing `permissions:`/`concurrency:`** in most repos.
5. **Empty javadoc jar stubs** shipped to Maven Central (`protobufs`, `gradle-flatpak`).
6. **Release automation unproven/broken** — `protobufs` & `kzstd` never auto-published; `gradle-flatpak` has a burned tag.
7. **`master`→`main`** rename outstanding (`kzstd`, `takpacket`, `protobufs`).
8. **Stale install/version docs** across 4 repos.
9. **Governance files** (CoC/SECURITY/CODEOWNERS/templates/FUNDING→org) missing in the newer/smaller repos (`takpacket`, `protobufs`, partially `kzstd`, `gradle-flatpak`).
10. **`explicitApi` + klib-level ABI validation** inconsistent (JVM-only or absent in `mqtt`, `tak`, `pb`).

## Per-repo critical (P0) items

- **protobufs:** tag→publish trigger has never fired (all releases manual); empty javadoc stub; README CI badge → nonexistent `ci.yml`.
- **kzstd:** v0.1.1 fully staged (VERSION/CHANGELOG) but never tagged/released; no coverage/lint.
- **gradle-flatpak-sources:** permanently-broken v0.1.3 tag/release (no artifacts) still requestable; `COPYING` abbreviated → GitHub reports license "Other"; empty javadoc stub; CHANGELOG/README stuck at 0.1.2.
- **takpacket-sdk:** BCV claims a klib dump that doesn't exist + `apiCheck` never runs in CI (API-break risk for named consumers); 11/13 targets never test-executed.
- **mqttastic-client-kmp:** `transport-ws` shipped with zero tests; pervasive Kotlin-version doc drift (docs say 2.3.20, actual 2.4.10); stale `core/` module docs branding the pre-split artifact.
- **meshtastic-sdk:** docs still claim "not yet public / workflows disabled" though v0.1.0 is live on Central; GPL license inconsistency; CODEOWNERS + Module.md reference the removed in-tree `:proto` module.
