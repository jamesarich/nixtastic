# Agent memory sync

One memory store for every Claude Code session in this workspace, on every
machine. Today there are twenty-plus stores across two machines that have never
met; this note is the design that collapses them into one.

Written 2026-09-04. Every count below was measured, not estimated - the
measurements and the one empirical proof the design rests on are in
[Evidence](#evidence) at the bottom.

## The problem

Claude Code keeps per-project memory at `~/.claude/projects/<slug>/memory/`,
where `<slug>` is the session's **absolute working directory** with every
non-alphanumeric character replaced by `-`. `MEMORY.md` in that directory is
injected into context at session start; the sibling `*.md` files are the
memories it indexes.

That path shape breaks two ways at once.

**Across machines.** macOS homes are `/Users/james`, Linux homes are
`/home/james`. The same workspace therefore has irreconcilable slugs:

    -home-james-meshtastic      (linux desktop, james-pc)
    -Users-james-nixtastic      (macbook air)

No transport fixes this. rsync, Syncthing, a database, and a git repo all fail
identically, because the two machines are reading *different directory names*.
Aligning the directory names does not help either - `/home` and `/Users` are
fixed by the operating systems.

**Within a machine.** Every repo and every worktree is its own cwd, hence its
own slug, hence its own empty store. A session started in `android/` cannot see
what a session started at the workspace root learned, and a fresh worktree
starts blind and stays blind.

The result today, measured:

| Machine | Workspace stores | Memory files |
| --- | --- | --- |
| james-pc (linux) | 2 | 42 |
| MacBook Air | 7 | 240 |
| **union** | **9** | **282** |

The laptop holds 5.7× the desktop's memory. Neither machine has ever read the
other's. Within the laptop, `-Users-james-nixtastic-android` alone holds 182
files while the desktop's equivalent holds 2.

## The fix: map, don't move

The store stops being a function of cwd. One canonical directory holds the
memory; every slug on every machine is a **symlink into it**.

    ~/.claude/projects/-home-james-meshtastic/memory              ─┐
    ~/.claude/projects/-home-james-meshtastic-android/memory       ├─→ ~/.nixtastic-agent/memory
    ~/.claude/projects/-home-james-meshtastic-android--claude-worktrees-*/memory  ─┘

    ~/.claude/projects/-Users-james-nixtastic/memory              ─┐
    ~/.claude/projects/-Users-james-nixtastic-android/memory       ├─→ ~/.nixtastic-agent/memory
    ~/.claude/projects/-Users-james-nixtastic-*/memory            ─┘

The slug differs per machine and per repo. The target does not. That is the
whole mechanism; everything below is plumbing around it.

The workspace is the only thing that can do this, because the workspace is the
only thing that already knows the full slug set - `NIXTASTIC_REPOS_TSV` plus
`<repo>/.claude/worktrees/*` plus the root. So the code lives in `scripts/`.

## Store layout

    ~/.nixtastic-agent/            git clone of jamesarich/nixtastic-agent (PRIVATE)
    ├── memory/                    282 memory files + a generated MEMORY.md
    │                              - this directory is the symlink target
    ├── .gitattributes             MEMORY.md merge=union
    └── .gitignore                 *.jsonl, .credentials.json

Outside both workspace checkouts, deliberately. `nixtastic` is public and
`.gitignore` there is deny-by-default; a store inside the tree is one
`git add -f` away from publishing bench serials, the operator's Discord
identity, and org-role notes. Outside the tree that mistake is not available.

The repo is **private**. The memories name hardware serials, an operator
identity, org permissions and unreleased work.

`nixtastic-agent`, not `nixtastic-memory`, because the agent-surface
consolidation (see [Follow-ups](#follow-ups)) will want the same repo and the
same transport rather than a second of each.

## Slug computation

`lib.sh` gains `slug_of <abs-path>`, lifted from the `remember` plugin's
`lib_slug` rather than reimplemented. The plugin ships `docs/slug-vectors.json`,
which becomes fixtures in `tools-tests.sh` for free.

The workspace never guesses a slug for a directory that does not exist: it
enumerates real checkouts and real worktrees, and computes the slug from each
one's absolute path.

## Import: the sync code path, not a migration script

`sync` meets non-empty `memory/` directories constantly - on both machines
today, and on any machine where a session ran before the link was laid. One
rule, applied every run, for every slug:

1. Already a symlink to the store → nothing to do.
2. A real directory → copy its files into the store, **skipping any filename
   that already exists there**, then replace the directory with the symlink.
   Skipped files are named in the output.
3. Does not exist → `mkdir -p` the parent, create the symlink.

Rule 2 never clobbers. A file that loses the race is left in place and reported,
not overwritten and not silently dropped.

This makes the one-time import of the existing 282 files *the same code* that
runs on every later sync, so the migration path is the steady-state path and
gets the same test coverage. It is idempotent: a second run reports `0
imported` and changes no mtimes.

`MEMORY.md` is regenerated after any import by reading each memory's
`description:` and `metadata:` frontmatter and emitting one pointer line each.
The **title** is harvested from the existing index first, last occurrence
winning, and derived from the filename only when no line for that file exists:
a session appends its own hand-written line (the harness says to), and a hand
title is a better retrieval key than `Ble ota test on battery not usb`. The
198 hand titles from the pre-rollout indexes were seeded back this way.
It is a derived file: 282 memory files in, one generated index out. No machine's
existing `MEMORY.md` is imported - they are all superseded by the regenerated
one.

The index is the **retrieval key**, not a table of contents. A second probe
(see [Evidence](#evidence)) showed that memory bodies are fetched on demand,
selected from their index line alone. So the index is written for selection:

- **Ordered by type, not alphabet:** `user` → `feedback` → `reference` →
  `project`, alphabetical within each. The merged set is 71 % `project`
  (perishable) and 1 % `user` + 16 % `feedback` (the memories that change
  behaviour every session). Alphabetical order would scatter the 47 durable
  ones among 199 perishable ones; type order front-loads them where a skim
  survives.
- **Machine tag rendered inline** when present:
  `- [Power-cycle with uhubctl](f.md) - [james-pc] cycle wedged bench radios…`.
  A tag that lives only in file frontmatter is read *after* the selection it
  was meant to inform.
- **Cross-store topic overlaps printed at import.** Filenames never collide
  (measured); facts can. `sync` lists pairs of imported names sharing two or
  more keyword stems for a five-minute human pass. It never merges them
  itself - of the nine pairs found, one is a true duplicate and the rest are
  distinct facts that happen to share words.

**Legacy stores are excluded, not imported.** `-Users-james-StudioProjects-*`
on the laptop are strict subsets of the corresponding `-Users-james-nixtastic-*`
stores - 0 files exist only in the legacy copy, and the files that differ are
newer on the `nixtastic` side, which was forked from them on 2026-08-15 and used
daily since. They stay on disk, untouched, unlinked.

## Tool surface

### `nix run .#sync`

Gains one pass, after the `.envrc` pass:

    memory   store ~/.nixtastic-agent (clean, up to date)
    memory   21 slugs linked, 0 imported

`--memory-only` re-links without the full fetch, for fast recovery after
worktree churn. The two hooks described below ship in the `nixtastic` plugin
since [agent-surface.md](./agent-surface.md); `--install-hooks` is retired.

### `nix run .#doctor`

Five checks, in the established `ok`/`warn`/`bad` + `fix` idiom:

| Check | Failure | `fix` |
| --- | --- | --- |
| store cloned | `bad "memory store" "not cloned"` | `nix run .#sync` |
| every slug linked | `bad "memory links" "3 unlinked: android, firmware, pr-7020"` | `nix run .#sync` |
| hooks registered | `warn "memory hooks" "not in ~/.claude/settings.json"` | `nix run .#sync --install-hooks` |
| store state | `warn "memory store" "7 commits unpushed"` / `"diverged"` | `git -C ~/.nixtastic-agent push` |
| staleness | `warn "memory age" "37 not updated since 2026-06-06 (113 undated)"` | review; delete what is wrong |

The staleness line reads frontmatter `modified:` - file mtimes are useless
here, the 2026-08-15 laptop migration reset every one - and reports the count
older than 90 days. It is a visibility signal, not a reaper. Nothing in this
design deletes a memory; the convention that wrong memories get deleted needs
a prompt, and this is it. 113 memories carry no `modified:` at all and never
will; they are counted in the `ok` line, never warned about - a warning that
cannot clear is noise.

### `nix run .#worktree`

Lays the link at creation, before Claude Code has ever run there.
`~/.claude/projects/<slug>/` does not exist until the first session writes to
it, so without this a new worktree is memory-blind for its whole first session -
which is the `android/ = 2 memories` hole, reproduced on every branch.

## Hooks

Two hooks in **user-scope** `~/.claude/settings.json`, written by
`sync --install-hooks` through `jq`, with a `.doctor-bak` backup (existing
precedent) and a marker key so re-running is idempotent. It **merges**: the
existing herdr and paseo entries are preserved untouched.

| Hook | Action | Timeout |
| --- | --- | --- |
| `SessionStart` | `flock` → `git pull --no-rebase --autostash \|\| true` | 10s |
| `Stop` | `flock` → `add -A`, `commit`, `pull --no-rebase`, dedupe `MEMORY.md`, `push` - all `\|\| true` | 15s |

`--no-rebase`, not `--rebase`, and the distinction is load-bearing: a merge
driver only runs during a *merge*. Under `pull --rebase` git replays commits one
at a time and a same-region `MEMORY.md` change stops the rebase - the union
driver never fires. One file per memory makes linear history worthless here
anyway, so the merge commits cost nothing.

**Commit always, push best-effort.** On a plane or off the LAN the commit still
lands and `doctor` reports `N commits unpushed`. No hook ever blocks or fails a
session; every step is `|| true` behind a timeout.

The `flock` covers `SessionStart` as well as `Stop`. Two sessions starting at
the same moment on one machine would otherwise both pull into the same store.

**Friction fixes, 2026-09-04 (same day, after an afternoon of use).** The
hook as first shipped cost 1.1 s of GitHub round-trips at the end of *every*
turn, in *every* project on the machine - `Stop` fires per turn and the
registration is user-scope. Four cheap exits now come before any network,
in this order: a cwd whose slug is not linked into the store (read from the
JSON Claude Code hands the hook on stdin) leaves at once; a clean store
leaves before the lock; a `SessionStart` pull under two minutes old is not
repeated (parallel sessions); and `ConnectTimeout=3` / `http.lowSpeedTime=3`
cap a stalled link so an offline laptop never waits out the hook timeout.
Measured after: 13 ms per turn.

Both machines need the hooks. They were first installed per machine with
`--install-hooks`; since [agent-surface.md](./agent-surface.md) they ship in
the plugin `sync` installs, and `doctor` is what keeps it honest.

**Worktrees made between syncs, 2026-09-05.** The Desktop app's worktree
mode and harness isolation both create a worktree and start a session in it
at once - before any `sync` could link its slug, so the "not linked, leave"
gate made exactly those sessions blind. Two changes: `memory_slug_dirs` now
lists the workspace repo's own worktrees (the laptop had three, each with
its own stranded memory dir), so `sync` links and imports them like any repo
worktree; and the `SessionStart` hook, on an unlinked cwd whose
`--git-common-dir` resolves under the workspace root, creates the link
itself when no memory dir exists there yet. A real directory is still left
for `sync`'s import rules; a repo outside the workspace is never touched.

## Conflicts

One file per memory means concurrent sessions almost never touch the same file.
The one shared file is `MEMORY.md`, a sorted list of one-line pointers, so it is
handled declaratively:

    MEMORY.md merge=union

Union merge keeps both sides' lines; the `Stop` hook then drops repeated lines
(`awk '!seen[$0]++'`). Two machines each appending a pointer therefore resolves
with no human in the loop. Not `sort -u`: that would undo the type ordering the
index is rendered in. The hook drops repeated lines and keeps their order;
`sync` re-renders properly on its next run.

The full regeneration from frontmatter is a **`sync` step, not a hook step** -
it runs once at install and after any import. The hooks only ever `sort -u`, so
no hook is doing work that could take a session-blocking amount of time.

Anything union merge cannot resolve: `git rebase --abort`, leave the local store
intact, and let `doctor` report `diverged`. The design never auto-resolves a
real content conflict.

**Parallel sessions on one machine** - several run routinely here - take a
`flock` on the store around commit and push. Concurrent writes to *distinct*
memory files need no lock, which is precisely why one-file-per-memory matters.

## The one silent-degradation risk

If a future Claude Code version ever replaces `memory/` rather than writing into
it - `rm -rf` plus `mkdir` on some compaction or migration path - the symlink
becomes a real directory again and that slug silently diverges back to today's
behaviour, with no error anywhere. `doctor`'s "every slug linked" check is what
catches it, which is why that check exists and why `doctor` should be run after
any Claude Code upgrade.

## Machine-specific memories

Some memories are true on exactly one machine: the bench fleet, `uhubctl`,
`/dev/serial/by-id`, and the 2.3 GB PlatformIO tree are all Linux-desktop-only;
`xcodebuild`, `simctl` and the iOS notes are all Mac-only.

One frontmatter line, nothing more:

    metadata:
      machine: james-pc        # or: darwin

Applied at import by filename heuristic - `ios-*`, `xcodebuild-*`, `*-macos*`
→ `darwin`; `uhubctl-*`, `rak-bench-*`, `tadpole-*`, `*-pio-*` → `james-pc` -
and corrected as encountered thereafter. 282 files are not hand-audited. The tag
is advisory: it tells a session to check before acting, and no filtering
machinery is built. It is rendered into the `MEMORY.md` line (above) because
that is where selection happens.

The case that shows why: `firmware-native-tests-need-docker` (desktop) and
`firmware-native-tests-on-macos` (laptop) share a conclusion - use
`bin/test-native-docker.sh` - for different reasons that are each true on
exactly one machine. They are not a duplicate to merge; they are two tagged
memories that coexist.

## Never synced

- `*.jsonl` transcripts. 100+ per machine, large, and low value relative to the
  distilled memories.
- `.credentials.json`. The two machines use different Claude accounts (work on
  the laptop, personal on the desktop) and auth must stay machine-local. Each
  machine has one `~/.claude` and one credential blob; nothing about this design
  touches either.
- `handoffs/*/logs/`.

## Testing

Fixtures in `tools-tests.sh`:

1. **Slug vectors** - `remember`'s `docs/slug-vectors.json`, used verbatim.
2. **Import idempotence** - run twice; the second reports `0 imported` and
   changes no mtimes.
3. **Never-clobber** - a same-named file with different content in the target
   survives; the incoming one is skipped and named in the output.
4. **Link-in-place** - a slug already symlinked is left alone, not re-created.
5. **Worktree** - `worktree.sh` creates the link before any session exists.
6. **Index rendering** - a fixture store with one memory of each type and one
   tagged memory renders in type order with the tag inline; a re-render of an
   unchanged store is byte-identical.

Gate is the existing one, `just check`: `nix flake check --all-systems
--no-build`, then `nix flake check`.

## Rollout

The order matters; step 0 is already done.

0. **Symlink proof.** Done - see [Evidence](#evidence).
1. Create private `jamesarich/nixtastic-agent`; seed from the desktop's 42.
2. Build and test the `sync` / `doctor` / `worktree` changes on the desktop.
3. Run `sync` on the laptop over SSH - imports its 240, pushes.
4. Run `sync` on the desktop - pulls; 282 in one store on both machines.
5. Machine-tag pass by heuristic.

Steps 1–4 are an afternoon. Step 5 is twenty minutes.

## Out of scope

- Transcripts stay machine-local.
- `notes/` and `CLAUDE.md` are untouched. They are the *public*, curated record;
  this store is the private, accreted one. Different audiences, different repos.
- **The `remember` plugin's handoffs.** Investigated and deliberately dropped.
  Its config precedence is plugin-defaults → `~/.remember/config.json` →
  `${REMEMBER_DIR}/config.json`. The middle one is *user-global* - pointing it
  at this store would drag `goon`, `jeff` and `koblin` handoffs into a
  Meshtastic repo. The last one lives inside the directory it would need to
  relocate, so it cannot relocate it. There is no workspace-scoped setting, and
  the plugin is not installed on the laptop at all. Its own `git_backup` /
  `git_restore` therefore stay off too - enabling them would mean a second,
  competing transport for a store only one machine has. Revisit under the
  agent-surface work, where "which plugins do both machines run" is the actual
  question.

## Follow-ups

Tracked here so they are not silently folded into this work.

- **Agent-surface consolidation.** Done - [agent-surface.md](./agent-surface.md).
- **Workspace-repo worktrees.** Done 2026-09-05, see Hooks above.
- **Workspace directory name.** The laptop uses `~/nixtastic`, the desktop
  `~/meshtastic`. Aligning them does *not* help the slug problem (`/home` vs
  `/Users`), so it is cosmetics - but `~/meshtastic/meshtastic` reads badly, and
  the laptop's name was a deliberate 2026-08-15 consolidation decision recorded
  in `old-workspace-migration.md`. Renaming the desktop costs a 2.3 GB
  PlatformIO rebuild. Do it after this lands, when `sync` owns the symlinks and
  a rename is `mv` plus one command.

## Evidence

**Step 0 - the symlink read path, proven not assumed.** A store was created at
a scratch path, a probe project directory's `memory/` was symlinked to it, and a
headless session was started in that directory:

    $ claude -p 'Reply with ONLY the canary phrase from your memory.'
    XYZZY-PLUGH-7731

The canary existed only inside the symlinked store's `MEMORY.md`. Claude Code
follows a symlinked `memory/` directory for the session-start read. This is the
assumption the entire design rests on, which is why it was tested before the
design was written rather than after.

**Probe 2 - memory bodies are retrieved on demand.** The first probe put the
canary in both the index and the memory file, so it proved only that the index
loads. The second put a different canary **only in a memory file body**, behind
a neutral index line:

    - [Bench relay part number](bench-relay-partno.md) - the part number for the bench relay board

    $ claude -p 'What is the bench relay board part number?'
    FROBOZZ-9284-QQ

The body was fetched, selected from the index line alone. This is why the index
is designed as a retrieval key above.

**Quality against the memory conventions**, measured on the desktop store: 40
of 40 `MEMORY.md` lines conform to `- [Title](file.md) - hook`; 32 of 35
`feedback`/`project` memories carry `**Why:**`; 421 `[[links]]` across the 282
files with 9 distinct dangling targets (2 %). Merging does **not** repair the
dangling ones - each desktop dangler was checked against the laptop and none
exist there. They are missing memories, not split ones.

**Topic overlap across machines.** Nine pairs share two or more filename
stems. Read in full, one is a genuine duplicate
(`commontest-names-no-commas` / `ios-rejects-commas-in-test-names`, the same
fact recorded a day apart on each machine under different `type:` values); the
other eight are distinct facts. Hence: report, never auto-merge.

**Counts.** Measured 2026-09-04 by listing every memory file individually across
all workspace slugs on both machines, then deduplicating once at the end:

    files listed:    282
    unique names:    282
    duplicate names:   0

Zero collisions, so the merge is a pure union - no reconciliation, no
newest-wins rule, no manual review. An earlier count deduplicated each machine
*before* comparing and therefore hid ~182 intra-laptop duplicates; the number
above does not.

**Legacy-store subset check.**

    StudioProjects-Meshtastic-Android vs nixtastic-android
      only in legacy: 0   only in current: 9   in both: 174   content differs: 19
    StudioProjects-firmware vs nixtastic-firmware
      only in legacy: 0   only in current: 0   in both:   4   content differs:  0
    StudioProjects-meshtastic-sdk vs nixtastic-meshtastic-sdk
      only in legacy: 0   only in current: 1   in both:   1   content differs:  0

Nothing exists only in the `StudioProjects-*` stores, so excluding them loses
nothing. The rollout found the claim did **not** hold for the fourth legacy
store, `-Users-james-meshtastic` (4 files): `meshtastic-kmp-alignment.md`
existed only there and was hand-copied into the store; the other three were
identical or older. Lesson kept in the plan: subset-check every legacy store,
not the ones that look biggest.

**Rollout result, 2026-09-04.** Desktop imported 43 (36 slugs linked), laptop
imported 241 (45 slugs), zero filename collisions on import - 284, then 285
with the legacy orphan, then 283 after the two true duplicates were merged by
hand (`commontest-names-no-commas` into `ios-rejects-commas-in-test-names`;
`no-ai-attribution` into `no-claude-attribution-in-commits`). Machine tags:
4 `darwin`, 8 `james-pc`. End-to-end proof: a headless session in
`~/meshtastic/android` on the desktop answered from `agp9-plugin-quirks`, a
memory that had only ever existed on the laptop. Desktop clones over HTTPS
(no GitHub SSH key there; `gh auth setup-git` supplies the hook's credential
helper); the laptop uses the default SSH remote.
