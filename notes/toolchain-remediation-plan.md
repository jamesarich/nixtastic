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

**Section A is fully landed as of 2026-08-18** — seven PRs, all merged through
their repos' merge queues after CodeRabbit + adversarial review: android #6766
+ #6767 (the two local-network fixes, both reworked to warn-and-proceed after
review), meshtastic-sdk #104, MQTTastic-Client-KMP #128 (+ version-resolution
hardening), gradle-flatpak-sources #38, TAKPacket-SDK #137, kzstd #62. What
remains in this file is section B (James's decisions) and section C (feature
adoption).

1. **`android` — ACCESS_LOCAL_NETWORK on the connect paths. DONE (traced), fix
   in progress.** The gap is real: discovery is gated, connecting is not. Full
   trace in [`local-network-permission-gap.md`](./local-network-permission-gap.md).
   Two sub-items:
   - **1a.** Manual-IP entry and recent-address reconnect — one PR in
     `feature/connections/commonMain`, gating the entry point rather than the
     connect. **In progress.**
   - **1b.** The service's startup auto-reconnect. **Done.** A service has no
     Activity, so it cannot `.request()` — the contract is decline-and-explain.
     A `LocalNetworkAccess` seam (`core/service`, Android + desktop impls) gates
     the cold-start connect in `MeshServiceOrchestrator`, which already has
     `ServiceStateWriter` injected; `errorMessage` is a `StateFlow` driving a
     modal alert, so the explanation is still waiting when the user next opens
     the app. **Discarded approach worth not re-deriving:** gating admission via
     `RadioTransportFactory.isAddressValid` looks natural (USB already checks a
     permission there) but does not work — `BaseRadioTransportFactory`
     short-circuits `InterfaceId.TCP.id` to `true` before `isPlatformAddressValid`
     runs, so the Android TCP branch is dead for admission. Reaching it means
     editing the common contract, adding a TCP branch to
     `DesktopRadioTransportFactory`, and rewriting `MockTransportAddressAdmissionTest`'s
     explicit "TCP must stay valid" assertion — and the failure would still be
     silent.
2. **`meshtastic-sdk` — catalog hygiene.** Delete the dead `gradle = "9.5.1"`
   entry (no build script references it; wrapper is 9.6.1). Correct the `kable`
   comment, which still justifies its ceiling by "our 2.3.21 pin (SKIE 0.10.12
   ceiling)" — the repo is on Kotlin 2.4.10 / SKIE 0.10.14. Pure text.
3. **Gradle wrapper 9.6.1 → 9.7.0 — `android` is OFF THE TABLE, `TAKPacket-SDK`
   only.** The sweep read `android`'s 9.6.1 as drift. It is not: the wrapper
   properties carry a comment saying so in as many words —

   > Pinned back to 9.6.1: Gradle 9.7.0's `ExecOperations.exec` spec defaults
   > `standardOutput` to null, which crashes CMP's `proguardReleaseJars`
   > (`ExternalToolRunner` reads it back).

   Somebody already tried 9.7.0 there and reverted it. Revisit only when
   Compose Multiplatform stops reading back a null `standardOutput`, or Gradle
   restores the old default. Two traps this exposed, both worth remembering:
   `./gradlew wrapper` **strips the comments** from `gradle-wrapper.properties`
   (that is how the pin's own rationale nearly got deleted), and it also resets
   `networkTimeout`/`retries` to defaults, silently undoing `android`'s
   30s/3-retry hardening. Diff the file, never trust the task's output blind.

   `TAKPacket-SDK` has no Compose anywhere, so the CMP failure mode does not
   apply; it also pins `distributionSha256Sum`, so use
   `./gradlew wrapper --gradle-version 9.7.0 --distribution-type bin
   --gradle-distribution-sha256-sum …` and check the diff. Downstream note:
   `gradle-flatpak-sources` vendors the exact `-bin` distribution `android`'s
   wrapper verifies, so if `android` ever does move, the vendored artifact and
   its checksum move with it — see
   [`gradle-flatpak-sources.md`](./gradle-flatpak-sources.md).
4. **spotless 8.9.0 → 8.10.0** in `TAKPacket-SDK`.
5. **Configuration cache and Isolated Projects — the sweep's "cheapest win" does
   not survive contact.** Module count splits the three repos, and then KGP
   blocks the one that was left. Verified by building each:
   - `kzstd` has **zero** subprojects and `gradle-flatpak-sources` exactly one
     (`:plugin`) — per-project isolation has nothing to isolate in either, so
     enabling it would be cargo cult. What those two genuinely lack is
     `org.gradle.configuration-cache`; that is the real win for them.
   - `MQTTastic-Client-KMP` has six modules, so IP *should* pay. Enabling it
     surfaced two failures. The first was ours: `allprojects { version = … }` in
     the root build script, which IP forbids. Moving the assignment to
     `gradle.lifecycle.beforeProject` in `settings.gradle.kts` fixes it (taking
     care to copy the value into a local first — a top-level `val` in a settings
     script is a field of the script object, and closing over it makes the
     configuration cache try to serialise the script). The second is **not**
     ours and is not fixable here: KGP's `WasmNpmResolverPlugin` reaches from
     `:sample` into the root project. So IP stays off in MQTTastic, the build's
     own side is left IP-ready, and the flip is a one-liner once JetBrains
     isolates the Wasm/npm plugins.
## B. Decide deliberately — James's call, written up not executed

- **kotlinx-binary-compatibility-validator 0.18.1 → KGP built-in
  `abiValidation`** in `kzstd` and `TAKPacket-SDK`. The sweep filed this as
  mechanical because `meshtastic-sdk` already made the move. Two reasons it is
  not:
  1. KGP's `abiValidation { }` is `@ExperimentalAbiValidation`. Trading a stable
     third-party plugin for an experimental API, in two *published* libraries
     whose ABI gate is the entire point, for tidiness — that is the same shape
     as the detekt-2.0-alpha decision below.
  2. **It cannot be verified on this machine.** `kzstd` runs
     `apiValidation { klib { enabled = true } }` across 12 non-JVM targets, and
     its own comment says targets a host cannot build are skipped and trusted
     from the committed dump. This box cannot build the tvOS simulator (proven
     while verifying the configuration-cache change). Regenerating the baseline
     here would commit a silently *narrowed* ABI dump — disarming the gate
     rather than moving it. Any attempt needs a host that can build every
     target, or a CI job that regenerates the dump.
  Also carries CI-workflow and doc churn: the task names change from
  `apiDump`/`apiCheck` to `updateKotlinAbi`/`checkKotlinAbi`, which both repos'
  agent docs and workflows reference by name.

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
- **Apple deployment floor — RESOLVED 2026-08-18.** Kotlin 2.4 raised the
  minimum to iOS 15 / macOS 12 / watchOS 8, inherited silently on the next
  Apple build. James: the SDK has **no consumers at all yet** (iOS or
  otherwise), so the floor inheritance breaks nobody and the next
  `meshtastic-sdk` release is unblocked.
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
