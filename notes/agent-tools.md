# Agent tools for cross-repo work

Five additions to the workspace tooling, each answering a measured friction in
[agent-ergonomics-audit.md](./agent-ergonomics-audit.md): a PR status tool, a
coupling-state tool, a session orientation hook, worktree path ergonomics, and
multi-repo `brief`. Written 2026-09-05 as sub-project 3 of the agent-workspace
work, after [agent-memory-sync.md](./agent-memory-sync.md) and
[agent-surface.md](./agent-surface.md). Nothing here is built yet; the audit
holds the numbers.

## Why these five

| friction (both machines, since mid-August) | count | tool |
| --- | --- | --- |
| `gh` calls, mostly PR view / checks / run view / comment filtering | 2 959 | `pr` |
| memories that exist only to encode GitHub-status traps | 6 | `pr` |
| poll attempts blocked or rejected (`sleep N; gh …`) | 39 | `pr wait` |
| hand greps for protobufs, SDK and `libs.versions.toml` pins | 753 | `pins` |
| `cd <absolute path>` as the first shell token | 8 135 | `wt`, `in` |
| retyped worktree path prefixes (`W=…; cd`) | 776 | `worktree --path`, `wt` |
| laptop sessions that never reach `brief`/`sync` (start inside a repo or a worktree, where `nix run .#` does not resolve) | 97 sessions, 137 tool runs | orient hook, `just` spellings |
| cross-repo dry run: four sequential `brief` runs | 5 min | `brief --short` |

## Decisions

1. **The hook orients, it does not steer.** A session in a worktree of the
   workspace repo (the Desktop app in worktree mode, pointed at `~/nixtastic`)
   is told plainly that the org repos are not there. It is not told to `cd`
   elsewhere, and its memory slug is not linked. Rejected: linking (endorses a
   place where no repo work can happen) and steering (a hook telling the model
   to leave its own cwd fights the Desktop app's isolation and the worktree
   guard).
2. **`pr` and `pins` are Python; everything else stays bash.** Both merge
   several structured sources into one table; jq for that is a day of wrestling
   for no gain. Stdlib only, wrapped by the flake like the bash tools, `gh` and
   `git` shelled out. Rejected: MCP tools inside `meshtastic-mcp` (workspace
   coupling knowledge would land in a public org repo, and `just pr` would need
   the server running).
3. **`pr` is read-only** except `rereview`, which posts one comment on request.
   No merge, no approve, no enqueue: those are the actions auto mode denies
   today, correctly.
4. **Every tool has a `just` spelling that resolves the flake by the
   justfile's absolute path.** `nix run .#` dies inside a repo or a worktree;
   `just brief` already solved this and the new recipes copy it. The orient
   hook prints those spellings on the first turn.
5. **`pins` reports, it does not judge.** `behind` is a fact; whether a
   consumer should move is the release-order decision the cross-repo skill
   owns.

## `pr`

    nix run .#pr -- <repo> <n> [status|threads|wait|rereview] [--json] [--deep]
    just pr <repo> <n> …

`<repo>` is the workspace directory name, mapped to `org/repo` via the repo
table; a PR URL also works. `status` (default) is one screen:

    meshtastic/Meshtastic-Android #7000  feat: offline map fallback   OPEN  draft:no  by jamesarich
    head     a1b2c3d  pushed 12m ago   base main   behind base: 0
    merge    BLOCKED   unresolved threads: 2   queue: not enqueued   conflicts: none
    checks@a1b2c3d   ok 11  fail 0  pending 1   validate-and-build / Build Desktop Debug
    reviews  APPROVED 1 (garth)   CHANGES_REQUESTED 0
    threads  coderabbitai  app/…/MapScreen.kt:123  "Consider guarding the null…"
             jamesarich    core/…/Repo.kt:40       "this leaks the scope when…"
    next     resolve 2 threads; then checks; `gh pr merge --squash` here means enqueue

Each line encodes a memory:

- **checks are fetched for the head SHA** through the commits check-runs
  endpoint, never "whatever is attached to the PR"
  (`gh-pr-checks-hides-the-sha`);
- **unresolved threads** come from GraphQL `reviewThreads`, the thing
  android's branch protection blocks on with no visible signal
  (`android-requires-resolved-conversations`);
- **queue** reads `mergeQueueEntry` position and state
  (`dequeue-before-push-merge-queue`, `gh-pr-merge-strategy-error-still-enqueues`);
- **conflicts** reads `mergeable`, because a conflicted PR runs no workflows at
  all (`conflicted-pr-runs-no-workflows`);
- **`--deep`** fetches the completed test jobs' logs and flags `FROM-CACHE`
  replays (`ci-green-test-tick-may-be-cache-replay`). Off by default: it is
  one log download per job.

Subcommands:

- `threads`: unresolved threads in full, grouped by author, with path, line,
  first comment body, thread id. `--all` includes resolved.
- `wait --until checks|queue|merged [--timeout 900]`: polls every 30 s,
  prints only state changes, exit 0 when met, **exit 75 on timeout**, the
  `gradle-queue` convention. Replaces the `sleep N; gh …` shape the harness
  blocks.
- `rereview`: posts `@coderabbitai full review`, the only trigger that works
  while incremental review is off (`coderabbit-churn-batch-reviews`).

`--json` prints the merged object for any subcommand. Exit codes: 0; 2 usage;
3 `gh` failure, with `gh`'s message.

Sources, in order: `gh pr view --json …` (number, title, state, author,
headRefOid, headRefName, baseRefName, mergeStateStatus, mergeable,
reviewDecision, isDraft, url); one GraphQL query for `reviewThreads`,
`mergeQueueEntry` and `reviews`; `GET /repos/{o}/{r}/commits/{sha}/check-runs`;
with `--deep`, `GET /repos/{o}/{r}/actions/jobs/{id}/logs` per completed test
job.

## `pins`

    nix run .#pins [--fetch] [--json]
    just pins

Offline by default: local checkouts, local tags. `--fetch` runs `git fetch
--tags` in the producers first. One screen:

    producer  protobufs          master 970fb19   latest tag v2.8.0
    consumer  firmware           submodule protobufs @ 7b2464c = v2.8.0       current
    consumer  meshtastic-python  submodule protobufs @ da60cee = v2.7.26      behind: v2.8.0
    consumer  android            org.meshtastic:protobufs 2.8.0  (gradle/libs.versions.toml)   current
    consumer  apple              submodule protobufs @ cd1d340 = v2.8.0+2    ahead of v2.8.0
    consumer  meshtastic-sdk     org.meshtastic:protobufs 2.7.26 (gradle/libs.versions.toml)  behind: v2.8.0
    producer  TAKPacket-SDK      main 3e85d93     latest tag v0.9.1
    consumer  android            org.meshtastic:takpacket-sdk 0.9.1 (gradle/libs.versions.toml)  current
    producer  design             master <sha>
    consumer  meshtastic         submodule static/design @ 77fafb2            behind by N commits
    producer  api                data/*.json
    consumer  android assets     maintenance_uf2 same   device_bootloader_ota_quirks same
                                 device_links DIFFERS   event_firmware DIFFERS

Rules:

- A **producer** row is a repo others pin: protobufs, TAKPacket-SDK, design,
  api data. Nothing pins `meshtastic-sdk` by version (android and apple build
  it from source), so it has no row. A **consumer** row names the file
  the pin lives in, the pinned value, what it resolves to (tag or short SHA),
  and one verdict: `current`, `behind: <what>`, `ahead`, `unknown`.
- One reader per pin format: the submodule SHA from `git ls-tree HEAD`; a
  TOML `[versions]` key; byte comparison for the JSON seed
  pairs (`maintenanceUf2`↔`maintenance_uf2`,
  `bootloaderOtaQuirks`↔`device_bootloader_ota_quirks`,
  `deviceLinks`↔`device_links`, `eventFirmware`↔`event_firmware`). Adding a pin
  is one function and one row.
- **Apple's proto pin is a submodule too**: `apple/.gitmodules` names
  `protobufs`, so the same reader serves it. `Package.resolved` holds only
  `swift-protobuf` and is not read. A submodule past the latest tag reports
  `vX.Y.Z+N  ahead of vX.Y.Z`, never `current`.
- `brief <repo>` gains one `PINS` line with that repo's rows. The cross-repo
  skill's scope step says "run `just pins`" instead of grepping.

Measured 2026-09-05: firmware and android are on protobufs v2.8.0,
meshtastic-python is on v2.7.26, and two of the four api seeds differ from
android's bundled assets.

## Orientation hook

A second SessionStart entry in the plugin's `hooks.json`, `hooks/orient`,
rendered by `sync` with the workspace root baked in, like the memory hook.
Reads the cwd from the hook's stdin JSON, classifies it, and returns
`hookSpecificOutput.additionalContext`, the documented SessionStart channel
into the model's context. No network; git limited to `rev-parse`; under 50 ms.

| cwd is | the hook says |
| --- | --- |
| the workspace root | root path; the spellings |
| an org repo checkout | "you are in `android`, primary checkout"; `just brief android`; the spellings |
| a worktree of an org repo | "worktree `feat/x` of `android`, primary at `<root>/android`"; edits stay in this tree (the guard enforces it); the spellings |
| a worktree of the workspace repo itself | "this is a worktree of the workspace repo: flake, notes, `CLAUDE.md` only. The org repos are **not** here; they live at `<root>/<repo>`. Nothing repo-related can be done from this tree." Then the spellings |
| anything else | nothing at all |

The spellings block, identical everywhere and at most eight lines:
`just brief <repo>`, `just brief --short a b c`, `just pins`,
`just pr <repo> <n>`, `just wt <repo> <name> <cmd>`, `just in <repo> <cmd>`,
`just worktree <repo> <branch>`, `just sync`, `just doctor`. (No `--` before
the command: `just` takes `+CMD` variadics as-is.)

It does not tell the model to `cd` (decision 1) and it does not print memory
(the store does that).

## Worktree paths and multi-repo `brief`

- `nix run .#worktree -- --path <repo> <branch-or-name>` prints the absolute
  worktree path, nothing else; exit 1 with a one-line reason if none. Branch
  and directory name both resolve, since `.#worktree` derives names from
  branches (`feat/x` → `feat-x`) and the Desktop app names its own.
- `just wt <repo> <name> <cmd…>` = `cd "$(worktree --path …)" && direnv exec
  . cmd…`. `just in <repo> <cmd…>` = `cd <root>/<repo> && direnv exec . cmd…`.
  Both `[no-cd]`, both resolving the flake by the justfile's path. The `cd`
  is load-bearing: `direnv exec DIR` loads DIR's env but leaves the cwd
  alone (measured 2026-09-05: `just in kzstd pwd` printed the root without
  it).
- `brief` accepts several repos and prints each full brief separated by a
  rule. `brief --short a b c` prints one line per repo: branch, drift, clean
  or `dirty!`, open-PR count, the `pins` verdict. Drift, dirty and PRs are
  what `brief` computes today; the pins column shells out to the `pins`
  binary (`NIXTASTIC_PINS`, set by the flake) and prints `-` without it. The
  cross-repo skill's brief step becomes one `--short` call, then full briefs
  only where needed.

## Testing

All in `tools-tests.sh`, all offline. Python files get `python3 -m
py_compile` in the flake check beside ShellCheck.

1. **Orient hook.** Five cwd cases fed as hook JSON; exact classification
   text; "elsewhere" prints nothing; output parses as JSON with
   `additionalContext`.
2. **`pr`.** A stub `gh` on PATH (the `claude-ws` fixture pattern) replays
   recorded JSON per invocation. Cases: blocked by two unresolved threads;
   queued at position 2; checks attached to a stale SHA while the head has
   none (must report the head's, not the attached); conflicted; merged.
   `wait` against a stub that flips on the third call, and one that never
   flips with `--timeout 1` for exit 75. `rereview` posts exactly one comment
   containing `full review`.
3. **`pins`.** Fixture repos get a real submodule, a `libs.versions.toml`, a
   `Package.resolved`, two JSON seed pairs (one equal, one different).
   `current`, `behind`, `unknown` each appear once; `--json` parses.
4. **`worktree --path`, `wt`, `in`.** Path by branch and by directory name;
   unknown name exits 1; `wt` and `in` run in the right cwd (a stub `direnv`
   records the directory it was given).
5. **`brief`.** Three repos in one call give three sections; `--short` gives
   exactly three lines with the columns above.

No `grep -q` on a chatty pipe in the fixture.

## Docs

`README.md` tool table gains `pins`, `pr`, `wt`, `in`, `brief --short`.
`CLAUDE.md` gets one line under protocol step 1 naming the orient hook and the
`just` spellings, paid for by trimming a line elsewhere. `AGENTS.md` gets a
short section: why `pr` fetches checks by SHA, why the hook only orients. The
cross-repo skill's scope and brief steps switch to `just pins` and
`just brief --short`. The audit note gets a "built" column.

## Rollout

Desktop first: `nix run .#sync`, restart, then live proofs: `just pr android
<open PR>` against a real PR, `just pins` (the python row must read v2.7.26
today), the orient probe from an android worktree (`claude -p "where are
you"`). Then the laptop over ssh, the same three, plus the orient probe from
one of its Desktop-app worktrees of the workspace repo, the case that
motivated the hook.

## Out of scope

A `proto-release` procedure (the first real cross-repo instance; `pins` is
its prerequisite). Skills for repos that have none. A permissions allowlist
pass. Raw `adb` vs the `android_*` MCP tools. Turning the Desktop app's
worktree mode off, which is James's setting, not the workspace's.

## Evidence

**Measurement.** Every interactive workspace transcript on both machines,
scanned for Bash commands, tool errors, rejections and auto-mode denials;
method and full tables in [agent-ergonomics-audit.md](./agent-ergonomics-audit.md).

**Hook channel.** The installed Claude Code build (2.1.261) carries the
SessionStart output schema with `additionalContext`, `initialUserMessage`
and `sessionTitle` under `hookSpecificOutput`, and merges `additionalContext`
into the session. The plugin's SessionStart memory hook was proven to fire
from both the terminal and the Desktop app on 2026-09-04.

**Desktop worktree mode.** `~/.claude.json` on the laptop lists several
hundred `.claude/worktrees/<adjective-name-hash>` entries across every repo it
has been pointed at, and three under `~/nixtastic/.claude/worktrees/` whose
`.git` files point at `~/nixtastic/.git/worktrees/…`: worktrees of the
workspace repo, containing `flake.nix`, `notes/`, `CLAUDE.md` and no org repo.

**Pins today.** `firmware` submodule `protobufs` @ 7b2464c = v2.8.0;
`meshtastic-python` @ da60cee = v2.7.26; android `meshtastic-protobufs =
"2.8.0"`; protobufs `master` 970fb19, latest tag v2.8.0; `meshtastic`
submodule `static/design` @ 77fafb2 (60 commits behind `design` master);
`apple` submodule `protobufs` @ cd1d340 = v2.8.0+2; `meshtastic-sdk`
`meshtasticProtobufs = "2.7.26"`; android `takpacket-sdk = "0.9.1"` =
TAKPacket-SDK's latest tag; `apple/MeshtasticProtobufs/Package.resolved` pins
only `swift-protobuf 1.36.1`.

**Acceptance runs.** Appended per machine when the rollout lands.
