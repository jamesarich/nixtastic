# Agent ergonomics audit — what would help cross-repo work here

Measured 2026-09-05 on both machines over every interactive workspace
transcript: james-pc since 2026-08-12 (84 sessions, 10 355 Bash calls) and
the MacBook Air (97 sessions, 14 711 Bash calls, measured over ssh). Findings
ranked by measured weight, not by opinion. Nothing here is built yet.

## What the numbers say

| signal | count | share |
| --- | --- | --- |
| `gh` calls | 1 482 | 14 % of all Bash |
| of which `gh pr view` / `gh pr checks` / `gh run view` | 159 / 87 / 85 | |
| of which `gh api repos/…/pulls/N/comments` filtered by reviewer login | ~30 | CodeRabbit thread reading |
| feedback memories that are GitHub-status traps | 6 | SHA, merge queue, conflicts, resolved threads, cache replay, dequeue |
| poll attempts blocked (`sleep N; gh …`) or rejected | 14 + 3 | |
| `cd <abs path>` as the first token | 2 895 | 28 % of all Bash |
| `W=<worktree path>; cd …` / `S=<scratchpad>; …` prefixes | 398 / 500+ | long paths retyped every call |
| `direnv exec` (the sanctioned no-cd form) | 437 | |
| `nix run .#worktree` / `.#sync` / `brief` | 439 / 332 / 311 | heavily used, working |
| greps for `protobufs`, `libs.versions.toml`, `git submodule` | 74 / 15 / 8 | pin lookups by hand |
| cross-repo dry run (4 repos) | 22 tool calls, 5 min | 4 sequential `brief` runs, 6 `cat`s of governance docs |
| repos entered | android 1 057, meshtastic-mcp 260, kzstd 126, firmware 112, apple 10 | |
| auto-mode denials | 11 | merges, approvals, run cancel, factory reset — correct guards |
| Bash timeouts | 26 | mostly Gradle, now behind the queue |

## The laptop half

Same shape, larger numbers, and one new fact.

| signal | laptop | desktop |
| --- | --- | --- |
| `gh` calls | 1 477 (10 %) | 1 482 (14 %) |
| `gh pr view` / `pr checks` / `run view`+`run list` / `api repos` / `api graphql` | 328 / 244 / 240 / 345 / 117 | 159 / 87 / 116 / 171 / 29 |
| `cd <abs path>` first token | 5 240 (36 %) | 2 895 (28 %) |
| `direnv exec` | 1 317 | 437 |
| greps for `libs.versions.toml` / `protobufs` / sdk version | 254 / 202 / 196 | 15 / 74 / 12 |
| `nix run .#worktree` / `.#brief` / `.#sync` | 59 / 52 / 26 | 439 / 332 / 311 |
| `pio` / `xcodebuild`+`simctl` / `adb` | 427 / 175 / 534 | 12 / 0 / 664 |
| repos entered | android 2 859, meshtastic-node-kmp 547, firmware 178, OTAFIX 142, api 86 | android 1 057, meshtastic-mcp 260, kzstd 126, firmware 112 |
| rejected / sleep-blocked / auto-mode denied | 36 / 25 / 29 | 17 / 14 / 11 |
| guard denials seen by the agent | raw `./gradlew` 33, worktree discipline 8 | 0 (guards arrived 2026-09-04) |

The new fact: the laptop barely uses the workspace tools. 97 sessions ran
`brief` 60 times and `sync` 26; the desktop's 84 sessions ran them 643 times.
Its sessions start inside `android/` or a worktree, where `nix run .#` does
not resolve (five `cd: no such file: android` errors are sessions that
assumed the root), and the Desktop app's own worktrees never see the plugin's
"run `just brief`" instruction because they are worktrees of the workspace
repo. The pin greps being 4–16× the desktop's says the same thing from the
other side: the android lead bumps SDK and proto pins by hand, often.

Auto-mode denials on the laptop were `gh workflow run` (release promotion),
`git push --force-with-lease`, `gh pr merge --admin`, `git checkout -- .`:
correct guards again.

## Do now (ranked)

1. **`nix run .#pr -- <repo> <n>`** (both machines' largest block) — one call answers what today takes five
   to ten: head SHA, checks *for that SHA* (not whatever is attached),
   `mergeStateStatus`, merge-queue position, unresolved review threads with
   author and file:line, conflicts, and a "test tick may be a cache replay"
   flag from the job log. Subcommands: `threads` (unresolved CodeRabbit
   threads, the 30-call pattern), `wait --until checks|merged` (blocks with a
   timeout like `gradle-queue`, so no `sleep` polling), `rereview` (posts the
   `full review` trigger the memory says is the only one that works). Encodes
   six memories in one tool.
2. **`nix run .#pins`** (652 hand greps on the laptop alone) — the coupling state in one screen: protobufs
   submodule SHA in `firmware` and `meshtastic-python` vs protobufs `master`
   and latest tag; `org.meshtastic:protobufs` and `meshtastic-sdk` versions in
   android's `libs.versions.toml`; apple's `Package.resolved` pins; `design`
   submodule in `meshtastic`; api `data/*.json` seeds vs android bundled
   assets (sha equal or not). Steps 1–2 of the cross-repo skill read this
   instead of grepping; `brief` can print the row for its repo.
3. **Worktree path ergonomics** — `.#worktree -- --path <repo> <branch>`
   prints the path; `just wt <repo> <branch> -- <cmd>` runs a command there
   through `direnv exec`. Kills the 398 retyped `W=` prefixes and a share of
   the 2 895 `cd`s. Small.
4. **`brief` for several repos in one call** (`just brief api android apple`)
   with a one-line-per-repo summary mode; the dry run spent most of its time
   here. Small.
5. **Make the workspace tools reachable from inside a repo.** The laptop
   data says sessions there never reach `.#brief`/`.#sync`. The forwarders
   already say `just brief <repo>`; `pins` and `pr` must work the same way
   (`just pins`, `just pr`), and the Desktop app's workspace-repo worktrees
   (agent-surface Follow-ups) need an answer before any of this helps there.

## Later

- A `proto-release` procedure as the first real `meshtastic-cross-repo`
  instance: protobufs tag → firmware and python submodule bumps → android
  pin → sdk. `pins` is its prerequisite.
- Raw `adb` (664 calls) beside the `android_*` MCP tools — check which is
  faster in practice before touching it.
- Skills exist for android (5) and apple (1); none for firmware, protobufs,
  sdk, python, api, web-flasher. Forwarders can only forward what exists.
- `fewer-permission-prompts` pass over the read-only `gh`/`git` shapes.

## Not worth doing

- The 11 auto-mode denials were all outward-facing or destructive actions.
  They are the guards working.
- Replacing `python3 -` heredoc edits (968): they are the edit mechanism
  under auto mode, not friction.
