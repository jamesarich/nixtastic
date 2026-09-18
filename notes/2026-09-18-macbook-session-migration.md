# 2026-09-18 - MacBook sessions moved to james-pc

The Mac's Claude account hit its weekly limit at ~12:50 CDT with two sessions
mid-task. Everything below was pulled here from `Jamess-MacBook-Air.local`
(`~/nixtastic`) without touching the Mac's own worktrees or transcripts.

## Sessions - resumable here

All four live from `/home/james/meshtastic` with `claude --resume <id>`; the
transcripts were copied with `/Users/james/nixtastic` rewritten to
`/home/james/meshtastic`, all 14,831 lines still valid JSON.

| id | was | state when the limit hit |
| --- | --- | --- |
| `8d1a71d9-d0fc-4b5c-8a8d-64ade955f1f3` | node-kmp "pick it back up" - the gap plan, tiers 0-3 | died answering "Explain the on air format question", one grep into correcting `AGENTS.md:573` |
| `701ec65e-d65c-4b82-9dda-f9ed8c77952b` | Kotlin-repo renovate sweep, then the changelog-plugin adoption and an adversarial pass over it | died one `gh pr view` after "Get it sorted out" |
| `8db0d460-4843-4f44-8d52-01392c26f4e8` | memory scrub | finished; **blocked on a question**: fix `design`'s skill frontmatter (a PR in the `design` repo)? |
| `aff79dd4-08d0-40b6-99f2-b248dad5fce3` | Wire buildersOnly landing | finished, nothing pending |

The Mac's FleetView rows (`~/.claude/jobs/8d1a71d9`, `8db0d460`) were not
copied, so the job list here does not show them; the transcripts are the
resumable thing.

## Branches - here, worktrees not

Of the Mac's 75 worktrees, 12 held commits that existed nowhere else. Their
branches are now in the local repos (bundle + scp - `git fetch` over ssh to the
Mac mangles the refspec, see memory). No worktree was created for them; one
`just worktree <repo> <branch>` does when needed.

| repo | branch | why it was at risk |
| --- | --- | --- |
| android | `chore/kotlin-2.4.20-koin-adapter` | no upstream, 3 dirty files |
| android | `chore/mokkery-3.5.0` | no upstream |
| android | `feat/record-rejected-key` | no upstream |
| android | `diag/ble-subscribe-timeout` | 1 ahead |
| android | `feat/node-transport-demo` | 1 ahead |
| android | `fix/ble-subscribe-before-seed-read` | 1 ahead |
| android | `fix/koin-workerfactory-provided` | 1 ahead |
| android | `spike/kp1812-local-coverage` | 14 ahead / 14 behind |
| android | `mac/measure-koin-heap` | was a detached HEAD |
| meshtastic-node-kmp | `demo/node-kmp-hw-model` | 7 ahead |
| meshtastic-site-planner | `feat/golden-corpus` | 2 ahead, 1 untracked file |
| protobufs | `chore/wire-7` | untracked `kotlin-js-store/yarn.lock` |

Dirty and untracked files that were never committed are saved verbatim under
`notes/drafts/mac-rescue-2026-09-18/` (android koin adapter, site-planner
`scripts/check_corpus.py`, protobufs yarn.lock, OTAFIX `lib/tinyusb` submodule
bump, `kp1812/build.gradle.kts` - `kp1812` is not in this workspace).

Everything else on the Mac was already on `origin`; the Mac's workspace repo and
its memory store were both clean and pushed.

## What was picked up

**node-kmp session.** Tiers 0-3 of `notes/node-kmp-gap-plan-2026-09-17.md` were
already complete (PR #21 closed tier 1). The last prompt, "Explain the on air
format question", exposed a false premise in two decision notes - that service
data would buy iOS background receive of the mesh advertisement. It would not:
the advertisement is extended, iOS surfaces only legacy ones, so an iPad hears
none of them whatever the AD type (measured 2026-09-15). meshtastic-node-kmp#22
corrects `AGENTS.md` and `docs/positioning.md`; the open call is the identifier
replacing the SIG test value `0xFFFF`, which lives in the firmware's
`BLEMeshHandler.h` as much as in node-kmp.

**Kotlin-repos session.** Every PR it was tracking had already been merged from
this desktop (flatpak#58, MQTT#156, kzstd#87, TAK#142/#143, sdk#126/#137) and
all four releases were cut today. What was left after "Get it sorted out" was
its own finding, `patchEmpty`, plus two small leftovers:

- `patchEmpty = false` in all six changelog-plugin repos: kzstd#89, MQTT#159,
  gradle-flatpak-sources#61, meshtastic-sdk#141, TAKPacket-SDK#147,
  meshtastic-node-kmp#23. **The Mac session's premise was wrong** - the plugin's
  default does not cut an empty section, it *skips* the task green and leaves no
  heading (measured against 2.5.0 with a bumped version; the plugin source
  agrees). The change still earns its place: the failure moves from the release
  workflow's heading gate, one tag later, to the bump itself with the plugin's
  own message. #23 also adds the heading check to node-kmp's release ritual,
  because `getChangelog` prints the previous release when the declared version
  has no section.
- MQTT#155's one unresolved CodeRabbit thread was answered and resolved: #142
  landed protobufs 2.8.0 with `optional rx_rssi`, which is exactly what it asked.
- Checked and already done or moot: TAK and flatpak both carry
  `gradle-daemon-jvm.properties` on main; the sdk catalog comment it wanted
  corrected no longer exists. TAK's #132/#133 CHANGELOG backfill is policy and
  was left alone.
