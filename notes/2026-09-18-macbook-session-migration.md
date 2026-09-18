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

See the PR list at the end of the job report; this note is updated when they
land.
