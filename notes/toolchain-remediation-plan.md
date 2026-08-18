# Toolchain remediation plan (from the 2026-08-18 sweep)

Companion to [`toolchain-sweep-2026-08-18.md`](./toolchain-sweep-2026-08-18.md).
The sweep is the finding; this is the triage. One line splits it: **can I verify
this myself, or does James decide?**

PR state verified 2026-08-18 via `nix run .#brief` plus a `gh pr list` grep for
`gradle|wrapper|spotless|detekt` across all five org Gradle repos. Only
`meshtastic-sdk` has bot PRs queued (#102 wrapper, #101 spotless, #99
detekt-compose); `android`, `TAKPacket-SDK`, `MQTTastic-Client-KMP`, `kzstd` and
`gradle-flatpak-sources` have **none** — those bumps are real work, not
duplicates.

## Execution rules for every item below

- `nix run .#brief -- <repo>` before touching it; `nix run .#worktree -- <repo>
  <branch>` for the branch. Never the harness's own worktree isolation.
- **`./gradlew` from a non-interactive shell runs unpinned** — the direnv hook
  only fires interactively. Always `direnv exec <repo-or-worktree> ./gradlew …`.
- Never mix commits across repos. `TAKPacket-SDK` is imperative-with-body;
  every other repo here is Conventional.
- `meshtastic-sdk` lands before `android` on anything crossing the two.
- Wrapper bumps: check `distributionSha256Sum` first. If pinned, use
  `./gradlew wrapper --gradle-version <v>` twice rather than hand-editing.

## A. Do now — reversible and self-verifiable

1. **`android` — ACCESS_LOCAL_NETWORK on the connect paths. DONE (traced), fix
   in progress.** The gap is real: discovery is gated, connecting is not. Full
   trace in [`local-network-permission-gap.md`](./local-network-permission-gap.md).
   Two sub-items:
   - **1a.** Manual-IP entry and recent-address reconnect — one PR in
     `feature/connections/commonMain`, gating the entry point rather than the
     connect. **In progress.**
   - **1b.** The service's startup auto-reconnect. A service has no Activity, so
     it cannot `.request()`; this needs `checkSelfPermission` plus a fail-fast
     error routing the user to Connections instead of a socket timeout. Worst
     affected user — existing install, persisted TCP radio, no prompt, no error.
     **Not started; own PR.**
2. **`meshtastic-sdk` — catalog hygiene.** Delete the dead `gradle = "9.5.1"`
   entry (no build script references it; wrapper is 9.6.1). Correct the `kable`
   comment, which still justifies its ceiling by "our 2.3.21 pin (SKIE 0.10.12
   ceiling)" — the repo is on Kotlin 2.4.10 / SKIE 0.10.14. Pure text.
3. **Gradle wrapper 9.6.1 → 9.7.0** in `android` and `TAKPacket-SDK`. Both pin
   `distributionSha256Sum`, so use `./gradlew wrapper --gradle-version 9.7.0`
   (twice) rather than hand-editing the URL. Downstream note for `android`:
   `gradle-flatpak-sources` vendors the exact `-bin` distribution the wrapper
   verifies, so the vendored artifact and its checksum move with the wrapper —
   see [`gradle-flatpak-sources.md`](./gradle-flatpak-sources.md).
4. **spotless 8.9.0 → 8.10.0** in `TAKPacket-SDK`.
5. **Configuration cache and Isolated Projects** — the sweep grouped these, but
   module count splits them. `MQTTastic-Client-KMP` has six modules, so
   `org.gradle.isolated-projects` (incubating as of Gradle 9.7.0) is a genuine
   configuration-time win there. `kzstd` has **zero** subprojects and
   `gradle-flatpak-sources` exactly one (`:plugin`) — per-project isolation has
   nothing to isolate in either, so enabling it would be cargo cult. What those
   two actually lack is `org.gradle.configuration-cache`, which is the real win
   for them. Verified by an actual build, not just a properties edit.
6. **kotlinx-binary-compatibility-validator 0.18.1 → KGP built-in
   `abiValidation`** in `kzstd` and `TAKPacket-SDK`. `meshtastic-sdk` already
   made this move and its `PublishingConventionPlugin` documents the built-in as
   the JetBrains-supported successor — in-repo precedent, drops a third-party
   plugin from two builds.

## B. Decide deliberately — James's call, written up not executed

- **detekt 1.23.8 → 2.0.0-alpha.x** in `MQTTastic-Client-KMP`, `kzstd`,
  `TAKPacket-SDK`, `gradle-flatpak-sources`. Four repos stranded on a plugin
  built against Kotlin 2.0.21 while compiling 2.4.10 — but the target is
  *alpha*, and the migration carries ruleset renames and API breaks.
- **kotlinx-datetime compat shim removal.** The sweep files this as a version
  gap; it is not. The `0.8.0-0.6.x-compat` artifact exists precisely to hold
  binary compatibility across the `Instant`/`Clock` → `kotlin.time` move, so
  dropping it from `meshtastic-sdk` is an **ABI change** — and an SDK ABI change
  breaks `apple` and `android` without touching their repos.
- **CMP skew across the consumer boundary.** `android` on 1.12.0-rc01 vs
  `meshtastic-sdk`/`MQTTastic-Client-KMP` on 1.11.1 stable. Either hold
  `android` at stable until 1.12.0 ships, or move the SDK up with it.
- **Apple deployment floor.** Kotlin 2.4 raised the minimum to iOS 15 / macOS 12
  / watchOS 8, and no repo sets an explicit target, so all three KMP libs
  inherit it silently on their next Apple build. Confirm `apple` and any
  podspec/SPM consumer expect ≥ iOS 15 **before** the next SDK release.
- **Swift export vs SKIE.** Not a migration — an ADR in `meshtastic-sdk`
  recording that we stay on SKIE and what would trigger revisiting.

## C. Feature adoption — scope as its own work, later

- **AGP 9.3 R8 tooling in `android`**: `analyzeReleaseR8Config`, the updated
  optimization DSL, and keep rules as source sets. Four hand-maintained `.pro`
  files today, and the workspace already carries an `r8-analyzer` skill built
  for this. Highest-leverage adoption in the sweep.
- **Compose Hot Reload MCP server** (CMP 1.12.0) — `android` already sets
  `compose.hot.reload=true`, and this workspace is agent-driven.
- **Compose 1.12 APIs** already on `android`'s classpath: `Grid` named areas,
  `LayerOutsets`, mesh gradients, P3/HDR, the new `KeyboardType`s.
- **Kotlin 2.4 language features** now stable and unused: context parameters,
  explicit backing fields, `@all` meta-target, stable UUID, `isSorted*`.

## D. Watch — nothing to do

Kotlin 2.4.20 (Sept, likely fixes the KGP-vs-Gradle/AGP ceiling; blocked in
`meshtastic-sdk` on a SKIE release supporting it), 2.5.0 (Dec), androidx Compose
1.13, AGP 9.4, ktfmt standardisation, Kotlin Toolchain / LSP, the Kotlin
Documentation Model. See the sweep's section 5.
