# Agent ergonomics audit — what would help cross-repo work here

Measured 2026-09-05 on james-pc over every interactive workspace transcript
since 2026-08-12 (10 355 Bash calls). The laptop is not measured; it runs
mostly through the Claude Desktop app and may differ. Findings ranked by
measured weight, not by opinion. Nothing here is built yet.

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

## Do now (ranked)

1. **`nix run .#pr -- <repo> <n>`** — one call answers what today takes five
   to ten: head SHA, checks *for that SHA* (not whatever is attached),
   `mergeStateStatus`, merge-queue position, unresolved review threads with
   author and file:line, conflicts, and a "test tick may be a cache replay"
   flag from the job log. Subcommands: `threads` (unresolved CodeRabbit
   threads, the 30-call pattern), `wait --until checks|merged` (blocks with a
   timeout like `gradle-queue`, so no `sleep` polling), `rereview` (posts the
   `full review` trigger the memory says is the only one that works). Encodes
   six memories in one tool.
2. **`nix run .#pins`** — the coupling state in one screen: protobufs
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
5. **Run this audit on the laptop** before building 1–4; its session mix
   (Desktop app, work account, apple work) is different and unmeasured.

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
