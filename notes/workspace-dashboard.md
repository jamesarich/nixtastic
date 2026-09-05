# Workspace dashboard (`just dash`)

A single TUI for the state a workspace session actually runs on: which agent
sessions are in flight and what each is working on, which worktrees exist and
which are reapable, which PRs are yours and where they are stuck, and a strip
of system and Claude-usage numbers. Written 2026-09-05 as sub-project 4 of the
agent-workspace work, after [agent-tools.md](./agent-tools.md).

Nothing here is built yet. The tools it composes all exist:
[`pr.py`](../scripts/pr.py), [`pins.py`](../scripts/pins.py),
[`worktree.sh`](../scripts/worktree.sh), `herdr`, `gh`.

## Why a new tool rather than another pane

Today the same picture takes four panes and a lot of typing: `btop` for the
machine, `abtop` for the rate limits, `herdr`'s own pane list for sessions, and
`just worktree --list` / `just pr` / `just pins` typed on demand. Each answers
one question well.

None of them answer the question that actually comes up, which is a **join**:
*this* session is working in *that* worktree, whose branch has *this* PR, which
is blocked on *those* threads. No existing tool holds all four, and computing
it by hand is the friction.

So the panels are deliberately shallow. `btop`, `abtop` and `gh-dash` remain a
keystroke away for drill-down. What this owns is the join and the actions on
it.

## Decisions

1. **Textual, not ratatui, not another `rich` loop.** `python3Packages.textual`
   (8.2.8) and `textual-dev` (1.8.0) are both in nixpkgs, so packaging is the
   same `writeShellApplication` shape as `pins` and `pr`. Textual brings CSS
   layout, focus handling and `App.run_test()` for headless snapshots.
   Rejected: **ratatui** — Recon, a ratatui TUI for multiple Claude Code
   sessions, proves the fit, but it is tmux-native where this workspace is
   `herdr`, and a Rust crate puts a
   `cargoHash` in the flake that churns on every dep bump, in a repo that is
   otherwise Python and shell. Rejected: **a `rich` `Live` loop** — that is
   `notes/mtop.py`'s architecture (whole-frame redraw, no layout engine, no
   focus, hand-drawn braille) and it was not good enough to keep using.
   Rejected: **forking `gh-dash`** (4.25.2, also in nixpkgs) — best in class for
   the PR half, but forking means tracking upstream forever and it knows
   nothing about sessions, worktrees or pins. Borrow its sections-by-filter UX,
   not its code.

2. **In-process workers with a disk cache, not a collector daemon.** Each
   source owns a `@work(thread=True)` worker on its own interval; the network
   tiers write JSON under `~/.cache/nixtastic-dash/`, so startup paints from
   cache and never blocks on GitHub. Rejected: **a collector daemon** — it wins
   only when a second consumer exists (a statusline, the laptop reading the
   desktop's state), and it buys that with daemon lifecycle, a `doctor` check,
   and a failure mode where the UI looks alive while nothing updates. That is
   the exact class of silent failure `CLAUDE.md` keeps a list of. The disk
   cache *is* the shared state file, minus the process that can die; promoting
   to a daemon later is moving the workers, not a rewrite. Rejected: **polling
   only what is visible** — a tab switch would mean a three-second empty panel
   every time, which loses the only property that matters.

3. **The dashboard implements nothing.** Every action shells out to a tool that
   already exists (`herdr`, `just`, `gh`) and the status line shows the exact
   command it ran. The tools stay the source of truth, every action is
   auditable, and the dashboard cannot drift from what `just worktree --gc`
   actually does.

4. **A session's work comes from its transcript, not its cwd.** See
   [The join](#the-join). `herdr`'s `foreground_cwd` is not trustworthy: on
   2026-09-05 it reported `meshtastic-mcp` for four of five live sessions,
   including one that had never touched that repo. Rejected: **joining on
   `cwd`** — most sessions run from the workspace root, so it resolves nothing.

5. **No panel ever goes blank, and no source can kill the app.** Every source
   carries `(value, fetched_at, error)`. A panel shows its age once it exceeds
   twice its interval; an errored source keeps rendering its last good value
   with the error in the header. Failure is a rendering state, not an
   exception.

## Data layer

Every source is one object: id, fetch callable, interval, cache policy,
degradation. Nothing else in the app knows how data arrives.

| id | fetch | interval | cache | if unavailable |
| --- | --- | --- | --- | --- |
| `sessions.herdr` | `herdr agent list` | 2 s | memory | skip (absent on the laptop) |
| `sessions.claude` | `claude agents --json` | 10 s | memory | skip |
| `sessions.files` | `~/.claude/sessions/*.json` + `kill -0` liveness | 3 s | memory | always available |
| `sessions.work` | tail each live session's transcript JSONL | 10 s | memory | row shows no repo |
| `worktrees` | `git worktree list --porcelain` per repo | 15 s | memory | — |
| `git` | branch, ahead/behind, dirty count | 15 s | memory | — |
| `prs.hot` | per-PR detail, reusing `pr.py` | 60 s, staggered | disk | cache + age |
| `prs.org` | `gh search prs --owner meshtastic --state open` | 5 min | disk | cache + age |
| `issues.org` | `gh search issues --owner meshtastic --state open` | 5 min | disk | cache + age |
| `pins` | `pins.py` | 5 min | disk | cache + age |
| `limits` | `~/.claude/abtop-rate-limits.json` (by mtime) | 5 s | memory | hide the segment |
| `system` | `psutil` | 2 s | memory | — |

Two tiers, one panel, `gh-dash`-style sections. The **hot** tier is repos with a
live session, a worktree, or an open PR of yours: per-PR detail, refreshed each
minute. The **cold** tier is the whole org in *two* calls, because
`gh search` is org-scoped rather than per-repo — the cost does not scale with
repo count, and only the deep detail is per-item. Steady state is roughly ten
GitHub calls a minute against a 5 000/hour REST budget and 30/minute for
search.

Cache files are `~/.cache/nixtastic-dash/<source>.json` holding
`{fetched_at, value}`, written tmp+rename so a killed process cannot leave a
half-file.

Each source has one in-flight fetch at a time (`@work(exclusive=True,
group=<source id>)`); a slow `gh` call must not queue up behind itself.

## The join

The joined entity is the **session**, annotated by the work it is doing — not
the worktree annotated by sessions. That is forced by decision 4: most sessions
run with `cwd=/home/james/meshtastic`, so a path-based join resolves nothing.

Resolution order for "what is this session working on":

1. Tail the session's transcript at
   `~/.claude/projects/<slug>/<sessionId>.jsonl`, take file paths out of recent
   tool calls, and map the most frequent one to a repo and worktree. This is
   ground truth and it is the primary signal.
2. Fall back to the session's `cwd` when it resolves inside a worktree or a
   repo checkout.
3. Otherwise show no repo. Do not guess from `foreground_cwd`.

Once a session has a repo and branch, the rest chains: PR by
`(repo, branch)` against `headRefName`, pin drift by repo, worktree by path.

The heuristic in step 1 can be wrong. It is presented as what the session has
been touching, never as a claim about intent, and the row stays useful without
it.

## Layout

Three always-on regions stacked full width, at a nominal 120x45. Both tables
want horizontal room for titles, so columns would cost more than they save.

```
 nixtastic ▏ cpu 34% ▁▂▄▃▂ ▏ mem 18.2/64G ▏ load 2.1 ▏ 5h ███████▉░ 93% ↻14:30 ▏ 7d ▏░░ 3% ▏ 10:22

╭─ In flight ───────────────────────────────────────────────── herdr · 5 sessions · 4 busy ─╮
│ ◑ Nixtastic TUI dashboard     busy    3m  nixtastic       main                   +2 ~1    │
│ ◑ Ant evaluation              busy   12m  meshtastic-mcp  main                   +7       │
│ ✳ Otafix worktree             idle   41m  OTAFIX          feat-lazy-erase-report #42 ✓12  │
│ ✳ Discord noise sweep         idle    2h  meshtastic-mcp  main                   —        │
│ ● Serial HAL client      bg blocked   4d  meshtastic-sdk  main                   —        │
╰───────────────────────────────────────────────────────────────────────────────────────────╯
╭─ Pull requests · mine ───────────────────────────────────────────────────── as of 38s ────╮
│ ● android   #7020  fix(map): guard MapLibre style reload      ✓18 ⊘0  ⧗queued             │
│ ○ OTAFIX      #42  feat: factory erase via UF2 family         ✓12 ⊘2  2 threads           │
│ ● firmware #11742  docs(agents): exempt test headers          ✓ 6 ⊘0  BLOCKED  conflicts  │
╰───────────────────────────────────────────────────────────────────────────────────────────╯
╭─ [1] Worktrees 24 · [2] Org PRs 34 · [3] Issues 26 · [4] Pins 3⚠ ───────── as of 4m ──────╮
│ android    feat-map-offline-fallback   ahead 3   dirty 1   PR #7020 open                  │
│ android    pr-7020                     merged    empty     ← gc candidate                 │
│ firmware   dmshell                     ahead 38  dirty 0   PR #10123 closed  ← gc         │
╰───────────────────────────────────────────────────────────────────────────────────────────╯
 ↑↓ move · enter focus · o open · r refresh · g gc · / filter · ? keys · q quit
```

Tab titles carry their own counts, so three pin warnings are visible without
switching to the tab that explains them. Marks: `●` the PR has a live session,
`○` it does not; `✓18 ⊘2` is checks passed and unresolved threads. Every
non-zero count is coloured, so the screen stays grey until something needs
attention.

Narrower than about 100 columns, CSS breakpoints drop the branch column, then
the age column. Below 30 rows the tab region collapses to its title line. Below
60x20 the app renders a "too small" message rather than a broken layout.

## Actions

| Where | Key | Runs |
| --- | --- | --- |
| Sessions | `enter` | `herdr agent focus <pane_id>` |
| Sessions | `enter` (background session) | no pane exists; copies `claude --resume <id>` and says so |
| Sessions | `w` | jump to the worktree that session is working in |
| PRs | `enter` | expand in place: checks by head SHA, unresolved threads, queue state (`pr.py`) |
| PRs | `o` | `gh pr view --web` |
| PRs | `c` | `just worktree <repo> <branch>` |
| Worktrees | `enter` | `just worktree --path`, then open it |
| Worktrees | `g` | `just worktree --gc --apply <one>`, behind a confirm modal |
| Worktrees | `n` | new worktree, prompts for repo and branch |
| Global | | `1`-`4` tabs, `r` refresh panel, `R` refresh all, `/` filter, `?` keys, `q` quit |

Destructive actions open a modal naming the exact command and what it removes.
`g` on a worktree with 38 unpushed commits must be hard to do by accident, and
`worktree --gc` already knows how to classify that.

Action results go to a one-line status bar on success. On failure a scrollable
modal shows stderr: a silently failing action is precisely the category this
workspace keeps a list of.

**Out of scope on purpose.** Sending prompts to sessions (`herdr agent prompt`
exists, but a dashboard that types into your agents is a different product),
killing sessions, and merging PRs. This reads, jumps, and reaps.

## Testing

One seam makes the whole app deterministic: `NIXTASTIC_DASH_FIXTURES=<dir>`
makes every source read a file instead of running a subprocess.

1. **Parsers are pure functions**, bytes to dataclass, for `herdr agent list`,
   `claude agents --json`, `gh search` JSON, `git worktree list --porcelain`
   and the transcript JSONL. They hold the real risk — the transcript
   heuristic above all — and get the most tests.
2. **Frame snapshots.** `--snapshot` renders one frame as plain text through
   `App.run_test()` and exits; `tools-tests.sh` diffs it against a golden
   fixture, the same shape as T31-T35.
3. **Key-driven snapshots.** `--snapshot --keys 2,down,enter` drives the pilot
   before rendering, covering tab switching and row expansion without a
   terminal.

Fixtures needed: one capture each of `herdr agent list`, `claude agents
--json`, `gh search prs`, `gh search issues`, `git worktree list --porcelain`,
a `pins` run, and a trimmed transcript JSONL.

## Degradation

Each row is a first-class state with its own rendering, not an exception path.

| Missing | Behaviour |
| --- | --- |
| `herdr` (the laptop) | sessions come from `~/.claude/sessions/*.json` plus `claude agents --json`; `enter` is disabled and the help says why |
| `gh`, or not authenticated | PR panels keep their cache, the header says so, and there is no retry storm |
| network | cached values with a visible age; startup never blocks |
| `abtop-rate-limits.json` | the limits segment leaves the strip |
| workspace root | resolved from `MESHTASTIC_WORKSPACE`, else the justfile's directory; a clear error if neither |
| terminal under 60x20 | a "too small" message |

## Packaging

`scripts/dash/` as a package directory rather than the flat single files the
other tools use — this is an order of magnitude more code than `pins.py`.
Wrapped exactly like `pins`:

```nix
dash = pkgs.writeShellApplication {
  name = "meshtastic-dash";
  runtimeInputs = [ pkgs.git pkgs.coreutils dashPython ];
  runtimeEnv = { NIXTASTIC_DASH = "${./scripts/dash}"; };
  text = ''PYTHONPATH="$NIXTASTIC_DASH/.." exec python3 -m dash "$@"'';
};
```

with `dashPython = pkgs.python313.withPackages (ps: [ ps.textual ps.psutil ])`.
`gh` and `herdr` resolve from `PATH` like `doctor` does with `direnv`, so the
fixture tests can stub them.

Three things that fail silently if forgotten:

- **The flake exports by an explicit `inherit` list.** A package not added
  there makes `nix run .#dash` report a missing attribute.
- **`.gitignore` denies by default** and currently whitelists only
  `/scripts/*.sh` and `/scripts/*.py`. A package directory needs
  `!/scripts/dash/` and `!/scripts/dash/*.py` or the whole tool is invisible to
  git.
- **`just dash` needs `[no-cd]`** so the app can mark the session you are
  running it from, the same reason `brief`, `pins` and `pr` carry it.
