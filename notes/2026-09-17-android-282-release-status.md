# Android v2.8.2 release status — 2026-09-17

## Where it stands

- Latest shipped build: **`v2.8.2-open.2`**, versionCode **29322268**, tagged and
  published **2026-09-13**, Play **Open testing**.
- **There is no production 2.8.2.** Production is still **v2.8.1** (29321949,
  released 2026-08-19). The 2.8.2 cycle opened 2026-08-24 and has run 11 internal,
  3 closed and 2 open builds without promoting — much longer than 2.8.1, which went
  internal x4 → production in 8 days.
- `main` is **41 commits ahead** of the shipped tag. Next build would be
  versionCode **29322309**.
- All three newest tags (`internal.11`, `closed.3`, `open.2`) point at the same
  commit `f9002f205` — promotions retag one artifact, they do not rebuild.

## The blocker: open.2 carries a crash that main already fixes

`IllegalStateException: LookaheadDelegate has not been measured yet when
measureResult is requested` is the top live crash on the shipped build.

- Datadog RUM, 14 d, 2.8.2 only: **~707 events / ~248 users**, split across
  open.2 (556) and open.1 (151). Issues `7b4a1fb0-af7c` + `39858128-aeb9` (the
  split is the per-build R8 map id, same bug).
- PR #7185 measured it at **8.8 % of users on open.2** against 0.010 % on 2.8.1
  production — 261 of that build's 284 crashes. Strip it out and open.2 sits at
  0.20 crashes/100 sessions vs production's 0.32, i.e. this one issue is the whole
  regression.
- Cause: the `LazyLayoutCacheWindow` added in #7093 to the node list and the
  message list prefetches outside the normal pass; both screens render inside
  `ThreePaneScaffold`'s `LookaheadScope`, so placement reaches an item the
  lookahead pass never measured.
- **Fixed on main** by `941c1d2d0` (#7185, merged 2026-09-16) — drops the cache
  window from `NodeListScreen.kt` and `Message.kt`. Not in any shipped build.

Conclusion: **open.2 must not be promoted to production.** Cut a new build from
`main`.

## Cross-checked against Crashlytics

Crashlytics agrees independently. Issue `f4e0a3e3`
(`InlineClassHelperKt.throwIllegalStateExceptionForNullCheck`, the same
LookaheadDelegate fault) is **632 of open.2's 677 fatal events in 7 days — 93 %**,
208 more on open.1, and **zero on production**. Strip it and open.2 drops to ~45
fatals/week. Introduced by `5ca2423ad` (#7093).

Fatal events, 7 d: 2.8.1 production 2,299 · open.1 (29322259) 755 · open.2
(29322268) 677. Crashlytics exposes no sessions denominator, so there is no
crash-free-rate figure from that side; the Datadog per-100-sessions numbers above
are the ones to quote.

### Already fixed and shipped — no action

- `edc0173a` `ButtonGroupMeasurePolicy.measure` Constraints IAE
  (`TimeFrameSelector.kt`): 530 events on open.1, **0 on open.2**. Fixed by
  `bd8341e0f` (#7142). Same issue Datadog logs as `1b16600c-aeb6`.
- `f07b6801` SQLITE_BUSY "database is locked" (`BusyTimeoutSQLiteDriver.kt:65`):
  1,118 of 1,119 events are the 2.8.1 production tail; **n=1 on open.2**. Fixed by
  `459eb6194` (#6809), in all 16 2.8.2 tags. The sticky `lastSeenVersion` makes it
  read as live — worth a note on the issue saying so.
- FTS "database disk image is malformed": all three issues stop at 2.8.1,
  confirming #6808 (`b6213f94e`, in `v2.8.2-closed.1`) healed it.

### Live but not blocking this build

- `3df011ca` `DatabaseManager.abandonWedgedDbBlock` — the 30 s Room pool wedge,
  NON_FATAL, 1,086 events / 221 users, present at the same rate on 2.8.2 as on
  2.8.1. **Root cause still open; nothing on main touches it.** #6809 fixed the
  downstream fatal, not the wedge. Concrete lead: `BusyTimeoutSQLiteDriver` waits
  10 s (`:65`) while `DatabaseManager` abandons at 30 s (`:1241`) — confirm the
  mechanism from a `withDb waited`/`abandon` log pair before changing constants.
- `0bfea846` `startForegroundSafely` FGS-not-allowed — NON_FATAL but the **highest
  user count of any issue, 2,018**. Not a crash: after a cold START_STICKY restart
  the mesh link silently fails to come back until the user reopens the app. All 20
  sampled events bypass `ForegroundStartPolicy` entirely. The real fix is the CDM
  `REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND` exemption already
  in the CDM adoption plan (#6477 / #6479), not a patch here.
- `d79ee407` `DiscoveryDao_Impl$insertPresetResult` FK 787 — **latent in 2.8.2, live
  in production.** Exhaustive `topVersions` by `issueId` (09-03..09-17): 65 events /
  64 users on 2.8.1 production, 1 on 29322131, **0 on open.1 and open.2**. No FK or
  session-race fix has landed on main (`git log v2.8.2-closed.1..main -- '*Discovery*'`
  returns only #7159, the wakelock change, which does not touch persistence), so the
  path is identical in 2.8.2 — the testing cohort is simply too small to have hit the
  race. Mechanism: the FK is `discovery_preset_result.session_id → discovery_session.id`
  ON DELETE CASCADE (`DiscoveryPresetResultEntity.kt:29-35`); `DiscoveryScanEngine`
  holds `sessionId` as a long-lived in-memory var while `SwitchingDiscoveryDao`
  re-resolves the active DB through `withDb` on every call rather than pinning the DB
  the session row was written to, so a transport or DB switch mid-scan (BLE drop,
  forced transport restart, node re-select) lets a later insert land against a DB with
  no parent row. `DiscoveryScanEngine.kt:515` is a bare `persistCurrentDwellResults()`
  with no try/catch and no existence guard, unlike `DiscoveryTerminalCoordinator.kt:283`
  which null-checks `getSession(sessionId)` for this exact race; it runs on a
  `SupervisorJob` scope with no `CoroutineExceptionHandler`, which is why the race is
  fatal rather than a logged scan abort. **Caveat:** Crashlytics truncates the app
  frames above Room internals here, so `:515` is inferred from code structure plus
  breadcrumbs, not observed in a raw stack — treat it as the leading candidate.
- ANR buckets (`21efb6ea-8679` / `81f27de6-877f` in RUM; 28 events/7 d in
  Crashlytics) — long-standing, cross-version, heterogeneous (GMS Maps dynamite,
  ART GC MarkCompact, Compose recompose). Not a 2.8.2 regression. Worth a separate
  perf investigation of the Map/Nodes screens, not a quick patch.

### Reading noise — not defects

- The top-20-by-count Crashlytics list is dominated by Kermit/Timber log lines
  routed to Crashlytics as NON_FATAL. The 38 k-event "Handshake still stalled"
  bucket is **intentional telemetry** (#6848), as are "Destroying mesh service",
  "Requesting foreground service=true" and "Successfully cleaned old MeshLog
  entries". Do not read those counts as health.
- Compose stacks interleave
  `com.google.gson.stream.JsonToken$EnumUnboxingLocalUtility.m` frames. That is an
  R8 merged/inlined-class artifact, not a real Gson caller.

## What the next build would ship (41 commits)

Seven user-facing fixes plus one feature; the other 33 are deps, docs and CI chores.

| PR | What |
| --- | --- |
| #7185 | the LookaheadDelegate crash above |
| #7197 | `API_BASE_URL` → `api.meshtastic.org`; `apiv2` is the Worker's **staging** route, frozen since 2026-09-08, serving a 115-entry device table against production's 116 (missing `TLORA_C6`, `MINI_EPAPER_S3`, wrong `T5_S3_EPAPER_PRO` targets) — a stale `platformioTarget` is a firmware lookup that resolves to nothing |
| #7155 | Enter key in the message composer — `ImeAction.Send` on a multi-line field leaves Samsung Keyboard and SwiftKey users with **no way to type a newline** |
| #7162 | conversations keyed to channel identity, not slot index |
| #7159 | process stays alive and awake through firmware updates and scans |
| #7158 | store-and-forward router replay deduped by `original_id` |
| #7171 | lockdown enable dialog states its irreversibility |
| #7191 | licence notice on the About screen (feature) |

### Dependency bumps that reach the shipped app

Only 5 of the 16 `chore(deps)` commits are runtime; the rest are CI tooling.

- `com.juul.kable:kable-core` 0.44.3 → **0.45.0** (BLE transport)
- `maplibre.compose` 0.16.0 → **0.17.0** (maps)
- `ktor` 3.5.2 → **3.6.0**
- `org.jetbrains:markdown` → 0.7.14
- `org.meshtastic:protobufs` 2.8.0.35 → **2.8.0.63-g8fc402a-SNAPSHOT**

Both Kable and MapLibre landed as plain Renovate bumps with no accompanying code
change, so nothing exercised BLE or the map on device. They are the argument for
walking a new build through internal → closed/open rather than shortcutting to
production the way 2.8.1 did.

`protobufs` on a SNAPSHOT is **precedent, not new**: 2.8.1 shipped to production on
`2.7.26.151-gef0ae57-SNAPSHOT`. There is no `resolutionStrategy` force in the build,
so Gradle resolves `takpacket-sdk` 0.9.1's transitive protobufs up to the app's pin —
the documented Wire all-args-constructor trap. Same shape already shipped in open.2
with no reports, and the legacy ATAK plugin is gone since the AIDL removal, so this
is a standing risk to verify rather than a new regression.

## Housekeeping before tagging

- **Main CI at HEAD (`549aaddf0`) was cancelled, never green** — superseded by
  concurrency. The release workflow has *no* lint/test gate (RELEASE_PROCESS.md), so
  it tags whatever is at HEAD. Re-run as `35241925866` on 2026-09-17: **all eight
  verify-and-build jobs green** (android-check, three test shards, four desktop
  builds). HEAD is verified.
- PR **#7188** (`docs: update CHANGELOG.md`) is open, all checks pass. Automation;
  not a release blocker.
- `VERSION_NAME_BASE` is already `2.8.2` and the `<release version="2.8.2">` entry
  exists in `org.meshtastic.MeshtasticDesktop.metainfo.xml`, so no version-bump PR
  is needed for another 2.8.2 build.
- The `no_review_in_flight` Play Console gate applies to **promotions only**.
  Cutting `internal.12` needs no Play check; the first promotion off it does.
- No new bug reports from the open cohort — newest open `[Bug]` issue is #6685 from
  2026-08-13.

## Recommendation

Cut **`v2.8.2-internal.12`** from `main` (Actions → *Create or Promote Release*,
`base_version: 2.8.2`, `channel: internal`) once Main CI is green at HEAD. Nothing
else blocks it: no unfixed crash on the 2.8.2 line needs code first, and the two
live issues that do need work (`3df011ca` Room wedge, `0bfea846` FGS restore) are
both non-fatal, both equally present on 2.8.1 production, and neither is a
regression this build would introduce.

The channel path from there — straight to production, or back through closed/open —
is a judgement call. The untested Kable 0.45.0 and MapLibre 0.17.0 bumps argue for
at least one open build rather than the internal×4 → production shortcut 2.8.1 took.

**Do not promote `open.2` itself.** Promotion retags an existing artifact, so it
would ship the LookaheadDelegate crash to the whole fleet.

## Follow-ups, not blockers

1. `3df011ca` — the Room pool wedge. Confirm the 10 s driver wait vs 30 s abandon
   gap from a real log pair before touching constants.
2. `0bfea846` — FGS restore after a sticky restart; 2,018 users. Folds into the CDM
   adoption plan (#6477 / #6479).
3. `d79ee407` — the Discovery FK race. Unfixed and live in production; the fix also
   closes a latent hole in 2.8.2. Pin the DB for a scan session, or guard the insert
   the way `DiscoveryTerminalCoordinator` already does.
4. Add a "verified n=1 on 29322268 as of 2026-09-17" note to `f07b6801` so its
   sticky `lastSeenVersion` stops reading as a live regression.
5. The ANR buckets deserve a Map/Nodes-screen perf investigation on their own.
