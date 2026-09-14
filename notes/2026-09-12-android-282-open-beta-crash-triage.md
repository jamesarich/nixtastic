# 2.8.2 open beta crash triage — 2026-09-12

`v2.8.2-open.1` (versionCode **29322259**) shipped 2026-09-12 12:41 UTC. Triage
run ~9–11h later across Crashlytics, Datadog RUM and GitHub issues. Discord
`#android` **not checked** — the meshtastic MCP server dropped mid-session.

## Headline

Datadog RUM, same wall-clock window:

| | open beta 29322259 | prod 2.8.1 29321949 |
| --- | --- | --- |
| Sessions | 550 | 41,797 |
| Crashed sessions | 40 (**7.3%**) | 118 (0.28%) |
| **Crash-free sessions** | **92.7%** | **99.72%** |

Prod is healthy. The regression is contained to the open-beta ring.

## A. CONFIRMED regression — `ButtonGroup` (#7097)

`IllegalArgumentException: maxWidth must be >= than minWidth`
Crashlytics `edc0173a13051400fdf66c591b60e6a1` · RUM `1b16600c-aeb6-11f1-…`

Throw site, on 30/30 sampled events:
`androidx.compose.material3.ButtonGroupMeasurePolicy.measure` — **`ButtonGroup.kt:725`**,
inside `org.jetbrains.compose.material3:material3 1.12.0-alpha03`.

- 76 events / 21 users in 11h. **76 of 76 on 29322259; zero on prod.**
- Pre-beta baseline ≤15 events per 7.5 days (below the top-20 cutoff), i.e. ~97%
  of the week's events arrived in the 11h after launch.
- Introduced by **PR #7097** `feat(node): overflow the time frame selector
  instead of crushing it` (`84862ddbe`, 2026-09-09). Present in `v2.8.2-open.1`,
  absent from `v2.8.1` *and* `v2.8.2-closed.1` — and the closed beta shows none
  of this crash. `git grep ButtonGroup v2.8.1` returns nothing.
- `firstSeenVersion 2.7.8` is a red herring: that Crashlytics bucket groups 9
  unrelated variants by throw-helper frame. The dominant variant `d4dec1ce…`
  (57/76) is new.

Mechanism (read from the alpha03 source, `ButtonGroup.kt:725`): in the overflow
branch the measure policy does
`overflowMeasurables.fastMap { it.measure(constraints.copy(maxWidth = remainingSpace + overflowWidth)) }`
without lowering `minWidth`. `TimeFrameSelector` applied `fillMaxWidth()` (the
`FillNode` frame sits directly above `ButtonGroup` in every stack), which pins
incoming `minWidth == maxWidth`, so once at least one chip fits but not all,
`maxWidth < minWidth` and `Constraints.copy` throws. Deterministic for any user
whose chips overflow — every open of every metrics screen — which is why one
install crashed twice in 20 s (restored screen) and wide phones never see it.

Upstream: **not fixed.** That `copy` is unchanged in androidx-main today. The
earlier attribution to [b/516743181](https://issuetracker.google.com/issues/516743181)
(fixed in androidx M3 1.5.0-alpha22) was **wrong** — that change (I35074) is the
*compression-animation* path (`calculateEndPadding`, `growthLeft = min(…)`), a
different branch, and JetBrains' `1.12.0-alpha03` is based on alpha22 and already
contains it (verified in the sources jar). No upstream tracker for the overflow
bug found; #7141 is the tracking reference.

Blast radius: `ButtonGroup` appears in exactly one file. `TimeFrameSelector` has
**8** callers — DeviceMetrics, EnvironmentMetrics, AirQualityMetrics,
PowerMetrics, SignalMetrics, PaxMetrics, TracerouteLog, HostMetricsLog.

Reported as **#7141** (F-Droid), confirmed in-thread on the **Google** variant,
Android 15 and 16. Not flavour-specific. No device/OEM signal.

**Fix:** revert `feature/node/src/commonMain/kotlin/org/meshtastic/feature/node/metrics/TimeFrameSelector.kt:53-59`
to `SingleChoiceSegmentedButtonRow`. One file. Untested alternative that keeps
#7097's overflow UX: drop `.fillMaxWidth()` from the `ButtonGroup` modifier so the
incoming `minWidth` is 0 and the copy is legal — the group then wraps to content
width instead of stretching, a visual call. Upstream report belongs against
androidx (the bug is in androidx-main), not the JetBrains fork; needs James's
Google account. Three-line draft: *"ButtonGroup: in the overflow branch,
`overflowMeasurables.fastMap { it.measure(constraints.copy(maxWidth = remainingSpace + overflowWidth)) }`
keeps the incoming minWidth, so any caller using fillMaxWidth() throws
`maxWidth must be >= than minWidth` as soon as one item overflows."*

## B. UNATTRIBUTED — Compose lookahead race

Crashlytics `f4e0a3e3…` `LayoutNode should be attached to an owner` (17/11) and
RUM `39858128…` `LookaheadDelegate has not been measured yet` (15/10) are
**different messages** in the same Compose lookahead family. Do not merge them.

Evidence is genuinely thin, and the two backends disagree:

- Crashlytics: 18 events in 9.3h spread across **11 variants**, 8 of them
  singletons; prod 2.8.1 also carries it at ~1.1/day; an identical stack appears
  in a 2.8.1 sample from Aug 26, i.e. **pre-#7097**. App frames are truncated
  before any `org.meshtastic.*` call site, so the composable is not recoverable.
- RUM: reports its variant as absent from prod and from closed.1, on
  MainActivity / NodesRoute / ContactsRoute — none of which host
  `TimeFrameSelector`.

Leading unconfirmed suspect is the dependency bump that landed in open.1 only:
`navigation3 1.1.1 → 1.2.0-beta01`, `navigation3-runtime 1.2.0-rc01`,
`androidx-compose-bom-aligned 1.12.0 → 1.12.1`, plus **PR #7093**
(`5ca2423ad`, nav3/motion-scheme rewrite of `MeshtasticNavDisplay.kt`), also
open.1-only. Not actionable without a repro; **do not revert #7093 for crash A**,
which is proven to originate elsewhere.

## C. Watch, not cause — the removed Vico guard

**PR #7025** (`0595852ad`) deleted `ChartDrawGuard` / `.chartRestoreUnderflowGuard()`
from `GenericMetricChart` — the guard #6847 added for the Vico canvas underflow.
That crash (`7744c73d`) is flat: 219 events per 7.5 days pre-beta vs 11 in the
11h window, last seen on 2.8.1. Removal has not reopened it yet. Watch.

## D. 2.8.2 fixes a live prod crash

The #2 prod crash — KML `NoSuchMethodError: policyBuilder()` (`ac7ca3a7`, 348
events / 93 users / 7.5 days, last seen 2.8.1) — is fixed in 2.8.2 by moving KML
off maps-utils onto the app's own xmlutil converter (see the `android-maps-utils`
comment in `gradle/libs.versions.toml`). An argument for shipping 2.8.2 promptly
once A is fixed.

## Recommendation

Fix A and cut `open.2`. Don't pull the beta — 550 sessions, contained ring. Gate:
**do not promote 2.8.2 past open beta until A is fixed and both rates re-checked.**

### A: fixed

Draft PR **[#7142](https://github.com/meshtastic/Meshtastic-Android/pull/7142)**
on `fix/timeframe-selector-buttongroup-crash` (`3d9d131`) reverts #7097 -
`TimeFrameSelector.kt` restored to the exact 2.8.1 file, plus a comment at the
call site so it is not re-adopted. Baseline green including `kmpSmokeCompile`.
Trade-off accepted: ellipsised labels on narrow screens return. The first cut of
the comment and PR body cited b/516743181 as the fix to wait for; that was wrong
(see Mechanism/Upstream above) and was corrected on the branch.

## Tooling note

Crashlytics' `versionDisplayNames` filter is broken for this project — it matches
nothing even for prod 2.8.1. Use time windows plus `firstSeenVersion`/
`lastSeenVersion`. See memory `crashlytics-version-filter-broken`.
