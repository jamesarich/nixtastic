# Meshtastic KMP — Remediation: closeout

> Condensed 2026-08-15. The original plan (per-repo checklists, batches,
> effort tables) executed to completion within a day of being written and
> its tracking sections had all gone stale; git history of this file holds
> the full original. What follows is what still matters.

## Outcome

The 2026-07-21 audit ([GAP-MATRIX.md](./GAP-MATRIX.md), evidence in
[reports/](./reports/)) was remediated across all six repos in two waves,
everything merged by **2026-07-22**:

- **Foundation + depth**: kzstd #16/#17/#18, mqttastic #87/#89,
  takpacket #111/#112, meshtastic-sdk #78, gradle-flatpak-sources #13/#14.
- **protobufs** (briefly review-blocked): #1014 tag→publish, #1015 badge,
  #1016 cache.
- Test depth landed too: mqttastic `transport-ws` common+jvm suites, sdk
  `:core:testAndroidHostTest` real host tests, flatpak internal unit tests.
- kzstd released v0.1.1 and v0.1.2; CodeQL (`actions`) + OpenSSF Scorecard
  in all five mergeable repos; wrapper `distributionSha256Sum` on 5/6.

## Still open (verified 2026-08-15)

- **protobufs `packages/kmp`** is the laggard: still on `master`, no wrapper
  sha256, no version catalog / `explicitApi()` / BCV, no
  CONTRIBUTING/SECURITY/CoC. Develocity PR #1027 and Gradle 9.7.0 Renovate
  PR #1029 open.
- **CodeQL `java-kotlin` commented out everywhere** — see gotcha below.
- **meshtastic-sdk pinned to Kotlin 2.4.0**: SKIE 0.10.13 rejects 2.4.10.
  Un-pin when SKIE catches up.
- Codecov gating is still informational (never flipped to blocking).

## Hard-won gotchas (durable)

- **Shared HTTP build cache**: `GRADLE_CACHE_URL` **must include the
  `/cache/` path** — a bare-host URL returns 401 on reads and Gradle
  silently disables the remote cache ("remote build cache was disabled
  during the build due to errors"). *(The cache has since moved to
  Develocity — see the workspace CLAUDE.md — but the old secrets are the
  retained rollback path, where this still applies.)*
- **CodeQL can't scan recent Kotlin.** CodeQL CLI 2.26.1 rejects Kotlin
  2.4.10 ("too recent"), failing the `java-kotlin` autobuild. Every
  `codeql.yml` therefore scans `actions` only; `java-kotlin` is
  committed-but-commented with a re-enable note (upstream merged a 2.4.20
  ceiling). Re-enable when a newer CLI ships.

## Standing docs

[MESHTASTIC-KMP-STANDARD.md](./MESHTASTIC-KMP-STANDARD.md) is the living
standard — keep it current. [reports/RUBRIC.md](./reports/RUBRIC.md) is the
reusable audit prompt for running the next audit.
