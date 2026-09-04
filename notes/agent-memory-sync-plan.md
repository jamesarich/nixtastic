# Agent Memory Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Claude Code session in this workspace, on both machines, reads and writes one memory store — `~/.nixtastic-agent/memory` — by making each `~/.claude/projects/<slug>/memory` a symlink into it, laid down and verified by the workspace's own tools.

**Architecture:** A new `scripts/memory.sh` (prepended to `sync`, `doctor`, `worktree` exactly as `lib.sh` is) holds the slug function, the three-rule link/import, the index renderer and the overlap report. `sync` gains a memory pass (pull → link/import → render → commit → push) plus `--install-hooks`, `--memory-only`, `--slug`. `doctor` gains five checks. `worktree` links at creation. Two user-scope hooks call a generated `bin/nixtastic-memory-hook` that pulls on `SessionStart` and commits+pushes on `Stop`, every step best-effort.

**Tech Stack:** bash under `writeShellApplication` (`set -euo pipefail`, ShellCheck at build), git, jq, gawk, GNU sed/coreutils; fixture tests in `scripts/tools-tests.sh` run inside the Nix sandbox by `nix flake check`.

**Spec:** `notes/agent-memory-sync.md` — read it first. Every design decision below is argued there; this plan only says how.

## Global Constraints

- Scripts run under `writeShellApplication`: `set -euo pipefail` is on. Any command that may legitimately fail needs `|| true`; a failing `x=$(cmd)` assignment kills the script.
- ShellCheck runs at build time. A ShellCheck warning is a build failure. Disable a check only with a comment saying why (see the `SC2016` precedents in `lib.sh`).
- Every tool a script calls must be in that tool's `runtimeInputs` in `flake.nix`. Something that works from the ambient `PATH` vanishes in the sandbox and silently makes the tests unable to run (`brief`'s `findutils` comment in `flake.nix` is the war story).
- The store lives **outside** the workspace: default `~/.nixtastic-agent`. Never inside `$MESHTASTIC_WORKSPACE`.
- The remote is **private**: default `git@github.com:jamesarich/nixtastic-agent.git`. Env overrides: `NIXTASTIC_MEMORY_STORE`, `NIXTASTIC_MEMORY_REMOTE`, `CLAUDE_CONFIG_DIR` (default `~/.claude`).
- Never overwrite a memory file that already exists in the store. Never delete a memory. Never overwrite a user's `settings.json` without a `.nixtastic-bak` copy beside it.
- No hook may block or fail a session: every step in the hook script ends `|| true` and the whole script ends `exit 0`.
- Comment style: terse WHY, 1–2 lines, matching the surrounding scripts. Commits: sentence-style, `scope: what`, no attribution footers (standing preference; see `notes/agent-memory-sync.md` commit history for the voice).
- The gate for every task is `just check` from the workspace root: `nix flake check --all-systems --no-build`, then `nix flake check` (builds the tools, runs ShellCheck and `tools-tests`).
- One commit per task in the `nixtastic` repo (this workspace root). Never commit into an org repo for this work.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `scripts/memory.sh` (new) | The memory library: `memory_store`, `memory_remote`, `claude_projects_dir`, `slug_of`, `memory_slug_dirs`, `memory_link`, `memory_render_index`, `memory_overlaps`, `write_memory_hook`, `install_memory_hooks`. No side effects at source time. Prepended after `lib.sh`. |
| `scripts/sync.sh` (modify) | New flags `--slug`, `--memory-only`, `--install-hooks`; the memory pass after the subagent/skills block. |
| `scripts/doctor.sh` (modify) | Five `memory *` checks before the final tally. |
| `scripts/worktree.sh` (modify) | One `memory_link` call after the worktree is created. |
| `scripts/tools-tests.sh` (modify) | Fixture bare store + env at the top; tests T17–T22 at the bottom. |
| `flake.nix` (modify) | Prepend `memory.sh` to `sync`, `worktree`, `doctor`; add `gawk` and `gnused` to their `runtimeInputs`; nothing else. |
| `CLAUDE.md`, `README.md`, `AGENTS.md` (modify) | One entry each: the fails-silently bullet, the human workflow, the generated-files convention. |
| `notes/agent-memory-sync.md` (modify) | One correction: the hook normalises with order-preserving dedupe, not `sort -u`, because `sort -u` would destroy the type ordering the same spec asks for. |

---

### Task 1: `memory.sh` — slug, paths, flake wiring, `sync --slug`

**Files:**
- Create: `scripts/memory.sh`
- Modify: `scripts/sync.sh:21-29` (arg parsing)
- Modify: `flake.nix` — the `sync`, `worktree`, `doctor` `writeShellApplication` blocks (search `text = builtins.readFile ./scripts/lib.sh`)
- Test: `scripts/tools-tests.sh` (append T17)

**Interfaces:**
- Produces: `memory_store` → prints store path; `memory_remote` → prints clone URL; `claude_projects_dir` → prints `<config>/projects`; `slug_of <abs-path>` → prints Claude Code's slug, returns 1 on a non-ASCII path.

- [ ] **Step 1: Write the failing test**

Append to `scripts/tools-tests.sh`, before the final `echo "all tests passed"`:

```bash
echo "--- T17: sync --slug reproduces Claude Code's project slug"
# Vectors lifted from the remember plugin's docs/slug-vectors.json
# (cygpath-agnostic, ASCII). Non-ASCII is refused, not guessed: Claude
# Code slugs one dash per code point and the workspace never needs it.
run "$sync" --slug /home/u/p
expect '^-home-u-p$'
run "$sync" --slug /Users/f/Documents/dvsi
expect '^-Users-f-Documents-dvsi$'
run "$sync" --slug //server/share/project
expect '^--server-share-project$'
run "$sync" --slug /tmp/x/C:/y
expect '^-tmp-x-C--y$'
run "$sync" --slug "$root/android/.claude/worktrees/feat-thing"
expect "^$(printf '%s' "$root" | sed 's/[^a-zA-Z0-9]/-/g')-android--claude-worktrees-feat-thing\$"
run_lax "$sync" --slug /tmp/café
expect 'non-ASCII'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix flake check 2>&1 | tail -20`
Expected: `tools-tests` fails at T17 with `unknown option: --slug`.

- [ ] **Step 3: Create `scripts/memory.sh`**

```bash
# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# One memory store for every Claude Code session, on every machine —
# prepended after lib.sh to sync, doctor and worktree. The design, the
# measurements behind it and the two probes it rests on are in
# notes/agent-memory-sync.md; this file is the mechanism only.
#
# Claude Code keeps memory at <config>/projects/<slug>/memory, and <slug>
# is a function of the absolute cwd — so macOS and Linux can never share
# one, and every repo and worktree gets its own empty store. The fix is a
# mapping layer: every slug the workspace owns becomes a symlink into ONE
# store, a private git clone. Nothing here moves memory; it maps it.
#
# Env, all optional:
#   NIXTASTIC_MEMORY_STORE   the clone            (default ~/.nixtastic-agent)
#   NIXTASTIC_MEMORY_REMOTE  where to clone from  (default the private repo)
#   CLAUDE_CONFIG_DIR        Claude Code's tree   (default ~/.claude)

memory_store()  { printf '%s\n' "${NIXTASTIC_MEMORY_STORE:-$HOME/.nixtastic-agent}"; }
memory_remote() { printf '%s\n' "${NIXTASTIC_MEMORY_REMOTE:-git@github.com:jamesarich/nixtastic-agent.git}"; }
claude_projects_dir() { printf '%s/projects\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

# Claude Code's project slug: the absolute path with every byte outside
# [A-Za-z0-9] turned into a dash. The ASCII rule from the remember plugin's
# lib-slug.sh; its UTF-8 program (one dash per code point, two per astral
# pair) is not carried because every path this workspace slugs is one it
# enumerated itself, and those are ASCII by construction. A non-ASCII path
# is refused rather than mis-slugged into a directory Claude Code never
# creates.
slug_of() {
  if [ "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\177' | wc -c)" -gt 0 ]; then
    echo "slug_of: non-ASCII path, refusing to guess Claude Code's slug: $1" >&2
    return 1
  fi
  printf '%s\n' "$1" | sed 's/[^a-zA-Z0-9]/-/g'
}
```

- [ ] **Step 4: Wire `memory.sh` into the three tools in `flake.nix`**

In the `sync` block, change

```nix
            text = builtins.readFile ./scripts/lib.sh + builtins.readFile ./scripts/sync.sh;
```
to
```nix
            text =
              builtins.readFile ./scripts/lib.sh
              + builtins.readFile ./scripts/memory.sh
              + builtins.readFile ./scripts/sync.sh;
```

Do the same for `worktree` (`./scripts/worktree.sh`) and `doctor` (`./scripts/doctor.sh`). In all three `runtimeInputs` lists add:

```nix
              # memory.sh: gawk renders MEMORY.md and the overlap report in one
              # process each; sed is the slug. Undeclared they resolve off the
              # ambient PATH and vanish in the sandbox (brief's findutils story).
              pkgs.gawk
              pkgs.gnused
```

(`sync` and `doctor` already list `pkgs.gnused`; add only `pkgs.gawk` there.)

- [ ] **Step 5: Add `--slug` to `sync.sh`**

Replace the arg loop at `scripts/sync.sh:21-29` with:

```bash
# --slug <path>: print the Claude Code project slug for a path and exit.
# Not a mode — a lookup, for humans asking "which projects/ dir is mine?"
if [ "${1:-}" = --slug ]; then
  slug_of "${2:?usage: --slug <absolute path>}"
  exit
fi
pull=false
main=false
for arg in "$@"; do
  case "$arg" in
    --pull) pull=true ;;
    --main) main=true; pull=true ;;
    *) echo "unknown option: $arg" ; exit 1 ;;
  esac
done
```

- [ ] **Step 6: Run the gate**

Run: `just check`
Expected: both commands pass; `tools-tests` prints `--- T17` and `all tests passed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/memory.sh scripts/sync.sh scripts/tools-tests.sh flake.nix
git commit -m "tools: memory.sh with the project slug, and sync --slug to look one up"
```

---

### Task 2: `memory_link` and the `sync` memory pass

**Files:**
- Modify: `scripts/memory.sh` (append `memory_slug_dirs`, `memory_link`)
- Modify: `scripts/sync.sh` — insert the pass after the `write_claude_launcher` / skills block (after the `fi` that closes `if [ -n "$skill_repos" ]`, before `if write_mcp_json "$root" "$root"; then`)
- Modify: `scripts/tools-tests.sh` — fixture at the top (after the repo loop), T18 at the bottom
- Test: T18

**Interfaces:**
- Consumes: `slug_of`, `memory_store`, `memory_remote`, `claude_projects_dir` (Task 1); `NIXTASTIC_REPOS_TSV`.
- Produces: `memory_slug_dirs <root>` → lines of `<projects>/<slug>\t<label>`; `memory_link <projectdir> <store/memory>` → prints one of `linked`, `imported\t<n>\t<kept names>`, `warn\t<msg>`, or nothing.

- [ ] **Step 1: Add the fixture store**

In `scripts/tools-tests.sh`, after the `for r in $repos; do … done` loop and before `res=""`:

```bash
# The memory store: a private GitHub repo in real life, a local bare here.
# Cloning an EMPTY bare is deliberate — that is what the first machine
# sees, and the first push has to set upstream itself.
git init -q --bare -b main "$origins/nixtastic-agent.git"
export NIXTASTIC_MEMORY_REMOTE="$origins/nixtastic-agent.git"
export NIXTASTIC_MEMORY_STORE="$HOME/.nixtastic-agent"
store="$NIXTASTIC_MEMORY_STORE"
projects="$HOME/.claude/projects"
slug() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
```

- [ ] **Step 2: Write the failing test**

Append T18 before `echo "all tests passed"`:

```bash
echo "--- T18: memory pass — clone, link every slug, import without clobbering, idempotent"
# T1 already ran sync, so the store is cloned and the root + repos are
# linked. Assert that state rather than re-deriving it.
[ -d "$store/.git" ] || { echo "T18: store not cloned"; exit 1; }
[ "$(readlink "$projects/$(slug "$root")/memory")" = "$store/memory" ] \
  || { echo "T18: root slug not linked"; exit 1; }
[ "$(readlink "$projects/$(slug "$root/kzstd")/memory")" = "$store/memory" ] \
  || { echo "T18: repo slug not linked"; exit 1; }
grep -qx 'MEMORY.md merge=union' "$store/.gitattributes" || { echo "T18: no union merge attribute"; exit 1; }
# A pre-existing real memory dir is imported: new files copied, a
# same-named file KEPT in the store and the loser left beside the link.
pre="$projects/$(slug "$root/android")"
rm -rf "$pre/memory"; mkdir -p "$pre/memory"
printf -- '---\nname: only-here\ndescription: "lives on this machine"\nmetadata:\n  type: project\n---\nbody\n' > "$pre/memory/only-here.md"
printf -- '---\nname: dup\ndescription: "loser"\nmetadata:\n  type: project\n---\nLOSER\n' > "$pre/memory/dup.md"
printf -- '---\nname: dup\ndescription: "winner"\nmetadata:\n  type: project\n---\nWINNER\n' > "$store/memory/dup.md"
run "$sync"
expect '[^0-9]1 imported'
expect 'kept.*dup\.md'
grep -q WINNER "$store/memory/dup.md" || { echo "T18: store file was clobbered"; exit 1; }
[ -f "$store/memory/only-here.md" ] || { echo "T18: new file not imported"; exit 1; }
[ -f "$pre/memory.pre-sync/dup.md" ] || { echo "T18: loser not preserved beside the link"; exit 1; }
[ "$(readlink "$pre/memory")" = "$store/memory" ] || { echo "T18: android slug not linked after import"; exit 1; }
# The import is committed and pushed, so the other machine can pull it.
git -C "$origins/nixtastic-agent.git" log --oneline | grep -q 'memory: import' || { echo "T18: import not pushed"; exit 1; }
# Idempotent: a second run imports nothing and touches no mtime.
before=$(ls -l --time-style=full-iso "$store/memory")
run "$sync"
refuse 'imported [1-9]'
[ "$before" = "$(ls -l --time-style=full-iso "$store/memory")" ] || { echo "T18: second run changed mtimes"; exit 1; }
# A symlink pointing somewhere ELSE is not ours: warned, never replaced.
other="$projects/$(slug "$root/api")"
rm -rf "$other/memory"; mkdir -p "$other" "$HOME/elsewhere"; ln -s "$HOME/elsewhere" "$other/memory"
run "$sync"
expect 'WARN .*elsewhere'
[ "$(readlink "$other/memory")" = "$HOME/elsewhere" ] || { echo "T18: foreign symlink replaced"; exit 1; }
rm "$other/memory"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `nix flake check 2>&1 | tail -20`
Expected: `T18: store not cloned`.

- [ ] **Step 4: Append `memory_slug_dirs` and `memory_link` to `scripts/memory.sh`**

```bash

# Every Claude Code project directory this workspace owns — the root, each
# cloned repo, every worktree of each repo — as "<projects>/<slug>\t<label>".
# The label is what a human reads in a report ("android/feat-thing", not
# the 80-character slug). Only REAL directories are slugged: the workspace
# never guesses a slug for a path that does not exist. $1 = workspace root.
memory_slug_dirs() {
  pd=$(claude_projects_dir)
  s=$(slug_of "$1") && printf '%s/%s\troot\n' "$pd" "$s"
  while IFS=$'\t' read -r dir _ _; do
    [ -d "$1/$dir/.git" ] || continue
    s=$(slug_of "$1/$dir") && printf '%s/%s\t%s\n' "$pd" "$s" "$dir"
    git -C "$1/$dir" worktree list --porcelain | sed -n 's/^worktree //p' | tail -n +2 |
    while read -r wt; do
      [ -d "$wt" ] || continue
      s=$(slug_of "$wt") && printf '%s/%s\t%s/%s\n' "$pd" "$s" "$dir" "${wt##*/}"
    done
  done < "$NIXTASTIC_REPOS_TSV"
}

# The three-rule link (design: "Import: the sync code path, not a migration
# script"). Already our symlink: nothing. A real directory: copy its files
# into the store, SKIP any name already there, then replace it with the
# link — the original is renamed beside the link, never deleted, because a
# skipped file may be the only copy of what it says. Missing: mkdir + link.
# MEMORY.md is never copied — it is derived, and sync re-renders it.
#
# $1 = <projects>/<slug>, $2 = the store's memory/ dir. Prints one line:
#   linked                        a link was created (nothing to import)
#   imported<TAB>N<TAB>a.md b.md  N files copied, the named ones kept
#   warn<TAB>message              a symlink that is not ours
# or nothing when the link was already right.
memory_link() {
  m="$1/memory"
  if [ -L "$m" ]; then
    [ "$(readlink "$m")" = "$2" ] && return 0
    printf 'warn\t%s -> %s, expected %s — not ours, left alone\n' "$m" "$(readlink "$m")" "$2"
    return 0
  fi
  n=0; kept=""; had=false
  if [ -d "$m" ]; then
    had=true
    for f in "$m"/*.md; do
      [ -f "$f" ] || continue
      b=${f##*/}
      [ "$b" = MEMORY.md ] && continue
      if [ -e "$2/$b" ]; then kept="$kept $b"; continue; fi
      cp -p "$f" "$2/$b"
      n=$((n + 1))
    done
    bak="$1/memory.pre-sync"
    [ -e "$bak" ] && bak="$bak.$(date +%s)"
    mv "$m" "$bak"
  fi
  mkdir -p "$1"
  ln -s "$2" "$m"
  if [ "$had" = true ]; then
    printf 'imported\t%s\t%s\n' "$n" "${kept# }"
  else
    echo linked
  fi
}
```

- [ ] **Step 5: Add the memory pass to `scripts/sync.sh`**

Insert after the skills block (the `fi` closing `if [ -n "$skill_repos" ]; then … fi`) and before `if write_mcp_json "$root" "$root"; then`:

```bash

# --- memory: one store, every slug a symlink into it -------------------
# Design and measurements: notes/agent-memory-sync.md. The order is pull →
# link/import → render → commit → push, so a run on either machine both
# takes the other's memories and hands over its own. Every git step past
# the clone is best-effort: no network is a report line, not a failure.
memory_pass() {
  st=$(memory_store)
  if [ ! -d "$st/.git" ]; then
    if git clone --quiet "$(memory_remote)" "$st" 2>/dev/null; then
      echo "  memory    cloned $st"
    else
      echo "  memory    no store at $st and clone failed — pass skipped"
      echo "            (private repo: needs git access to $(memory_remote))"
      return 0
    fi
  fi
  mkdir -p "$st/memory"
  # Seed the two repo-level files once; never clobber a hand edit.
  [ -e "$st/.gitattributes" ] || echo 'MEMORY.md merge=union' > "$st/.gitattributes"
  [ -e "$st/.gitignore" ] || printf '*.jsonl\n.credentials.json\n' > "$st/.gitignore"
  # A merge left behind by a killed hook would hand the next session a
  # MEMORY.md full of conflict markers. Abort it; doctor reports diverged.
  [ -e "$st/.git/MERGE_HEAD" ] && git -C "$st" merge --abort >/dev/null 2>&1
  git -C "$st" pull --no-rebase --autostash --quiet >/dev/null 2>&1 || true

  total=0; newly=0; imported=0; kept=""
  while IFS=$'\t' read -r pdir label; do
    [ -n "$pdir" ] || continue
    total=$((total + 1))
    out=$(memory_link "$pdir" "$st/memory")
    case "$out" in
      warn*)     echo "  WARN      ${out#*$'\t'}" ;;
      linked)    newly=$((newly + 1)) ;;
      imported*) n=$(printf '%s' "$out" | cut -f2); k=$(printf '%s' "$out" | cut -f3)
                 imported=$((imported + n)); newly=$((newly + 1))
                 [ -n "$k" ] && kept="$kept $label:{$k}" ;;
    esac
  done <<< "$(memory_slug_dirs "$root")"

  count=$(find "$st/memory" -maxdepth 1 -name '*.md' ! -name MEMORY.md | wc -l)
  printf '  memory    %s slugs -> %s/memory  (%s memories, %s newly linked, %s imported)\n' \
    "$total" "$st" "$count" "$newly" "$imported"
  [ -n "$kept" ] && echo "            kept in store, originals beside each link as memory.pre-sync/:$kept"

  git -C "$st" add -A >/dev/null 2>&1 || true
  if ! git -C "$st" diff --cached --quiet 2>/dev/null; then
    git -C "$st" commit --quiet -m "memory: import $imported from $(hostname -s 2>/dev/null || echo host)" >/dev/null 2>&1 || true
    # -u every time: the first push into an empty remote has no upstream,
    # and repeating it later is harmless.
    if git -C "$st" push --quiet -u origin HEAD >/dev/null 2>&1; then
      echo "            committed and pushed"
    else
      echo "            committed; push failed (offline?) — doctor will report unpushed"
    fi
  fi
}
memory_pass
```

- [ ] **Step 6: Run the gate**

Run: `just check`
Expected: T18 passes. If T1–T16 now print new `memory` lines that is expected; they assert only on their own lines.

- [ ] **Step 7: Commit**

```bash
git add scripts/memory.sh scripts/sync.sh scripts/tools-tests.sh
git commit -m "sync: the memory pass — clone the store, link every slug, import without clobbering"
```

---

### Task 3: `memory_render_index` and `memory_overlaps`

**Files:**
- Modify: `scripts/memory.sh` (append two functions)
- Modify: `scripts/sync.sh` — in `memory_pass`, between the report line and the `git add`
- Test: T19

**Interfaces:**
- Consumes: the store's `memory/` dir.
- Produces: `memory_render_index <memory-dir>` writes `<memory-dir>/MEMORY.md`; `memory_overlaps <memory-dir> <file-of-new-basenames>` prints `  a ~ b` lines or nothing.

- [ ] **Step 1: Write the failing test**

Append T19:

```bash
echo "--- T19: MEMORY.md is rendered by type with the machine tag inline, and is byte-stable"
rm -f "$store"/memory/*.md
mk() { printf -- '---\nname: %s\ndescription: "%s"\nmetadata:\n  type: %s\n%s---\nbody\n' "$1" "$2" "$3" "${4:-}" > "$store/memory/$1.md"; }
mk zeta-project   "a project fact"            project
mk alpha-project  "another project fact"      project
mk some-feedback  "how James wants it done"   feedback
mk who-james-is   "the operator"              user
mk bench-serials  "bench USB serials"         reference "  machine: james-pc
"
run "$sync"
idx="$store/memory/MEMORY.md"
head -1 "$idx" | grep -qx '# Memory' || { echo "T19: no header"; exit 1; }
# Order: user, feedback, reference, project; alphabetical within.
want='who-james-is some-feedback bench-serials alpha-project zeta-project'
got=$(sed -n 's/^- \[[^]]*\](\([^)]*\)\.md).*/\1/p' "$idx" | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$want" ] || { echo "T19: order was: $got"; exit 1; }
grep -q '^- \[Bench serials\](bench-serials.md) — \[james-pc\] bench USB serials$' "$idx" \
  || { echo "T19: tag not inline / title not derived"; cat "$idx"; exit 1; }
cp "$idx" "$HOME/idx.before"
run "$sync"
cmp -s "$idx" "$HOME/idx.before" || { echo "T19: re-render is not byte-identical"; exit 1; }
# Overlap hint on import: two stems shared, reported, never merged.
pre="$projects/$(slug "$root/firmware")"
rm -rf "$pre/memory"; mkdir -p "$pre/memory"
mk2() { printf -- '---\nname: %s\ndescription: "x"\nmetadata:\n  type: project\n---\nbody\n' "$1" > "$pre/memory/$1.md"; }
mk2 firmware-native-tests-on-macos
printf -- '---\nname: firmware-native-tests-need-docker\ndescription: "x"\nmetadata:\n  type: project\n---\nbody\n' > "$store/memory/firmware-native-tests-need-docker.md"
run "$sync"
expect 'overlap'
expect 'firmware-native-tests-need-docker ~ firmware-native-tests-on-macos|firmware-native-tests-on-macos ~ firmware-native-tests-need-docker'
[ -f "$store/memory/firmware-native-tests-on-macos.md" ] && [ -f "$store/memory/firmware-native-tests-need-docker.md" ] \
  || { echo "T19: an overlap pair was merged or dropped"; exit 1; }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix flake check 2>&1 | tail -20`
Expected: `T19: no header` (no `MEMORY.md` is rendered yet).

- [ ] **Step 3: Append the two functions to `scripts/memory.sh`**

```bash

# MEMORY.md, derived from frontmatter. The index is the RETRIEVAL KEY — a
# probe showed memory bodies are fetched on demand, selected from their
# index line alone — so it is written for selection: user → feedback →
# reference → project (durable first; the merged set is 71 % project),
# alphabetical within each, the machine tag inline where one is set.
# Deterministic, so re-rendering an unchanged store is byte-identical and
# never churns a commit. $1 = the memory dir.
memory_render_index() {
  {
    echo '# Memory'
    echo
    find "$1" -maxdepth 1 -name '*.md' ! -name MEMORY.md -print0 | sort -z | xargs -0 gawk '
      function val(s) { sub(/^[^:]*:[ \t]*/, "", s); gsub(/^"|"$/, "", s); return s }
      function title(s,  t) { t = s; gsub(/[-_]+/, " ", t); return toupper(substr(t, 1, 1)) substr(t, 2) }
      function emit(  stem, rank, tag) {
        stem = FILENAME; sub(/.*\//, "", stem); sub(/\.md$/, "", stem)
        rank = (type == "user") ? 0 : (type == "feedback") ? 1 : (type == "reference") ? 2 : (type == "project") ? 3 : 4
        tag = (mach != "") ? "[" mach "] " : ""
        printf "%d\t%s\t- [%s](%s.md) — %s%s\n", rank, stem, title(stem), stem, tag, desc
      }
      BEGINFILE { inFm = 0; done = 0; type = ""; desc = ""; mach = "" }
      FNR == 1 && $0 == "---" { inFm = 1; next }
      inFm && $0 == "---"     { emit(); done = 1; nextfile }
      inFm && /^description:/ { desc = val($0) }
      inFm && /^  type:/      { type = val($0) }
      inFm && /^  machine:/   { mach = val($0) }
      ENDFILE { if (!done) emit() }
    ' | sort -t "$(printf '\t')" -k1,1n -k2,2 | cut -f3-
  } > "$1/MEMORY.md.new"
  # Replace only on difference: an unchanged store keeps its inode and
  # mtime, so nothing here churns a commit or trips the idempotence test.
  if cmp -s "$1/MEMORY.md.new" "$1/MEMORY.md"; then
    rm -f "$1/MEMORY.md.new"
  else
    mv "$1/MEMORY.md.new" "$1/MEMORY.md"
  fi
}

# Pairs of memory names sharing two or more keyword stems, where at least
# one side was just imported — a hint for a five-minute human pass, never
# an auto-merge: measured, nine such pairs held ONE true duplicate. One
# gawk process, because n² over a few hundred names is nothing to awk and
# minutes to a bash loop. $1 = memory dir, $2 = file of imported basenames.
memory_overlaps() {
  find "$1" -maxdepth 1 -name '*.md' ! -name MEMORY.md -exec basename {} .md \; | sort |
  gawk -v newf="$2" '
    BEGIN {
      while ((getline l < newf) > 0) { sub(/\.md$/, "", l); isnew[l] = 1 }
      n = split("the and not for with are its from into", s, " "); for (i = 1; i <= n; i++) stop[s[i]] = 1
    }
    {
      names[NR] = $0
      n = split($0, t, /[-_]/)
      for (i = 1; i <= n; i++) if (length(t[i]) > 3 && !(t[i] in stop)) toks[NR][t[i]] = 1
    }
    END {
      for (a = 1; a <= NR; a++) for (b = a + 1; b <= NR; b++) {
        if (!(names[a] in isnew) && !(names[b] in isnew)) continue
        c = 0; for (k in toks[a]) if (k in toks[b]) c++
        if (c >= 2) print "              " names[a] " ~ " names[b]
      }
    }'
}
```

- [ ] **Step 4: Call them from `memory_pass` in `scripts/sync.sh`**

`memory_link` prints the kept names but not the imported ones; the overlap report needs the imported names. Change the `imported*)` case in `memory_pass` to also record them, then render. Replace the block from `total=0; newly=0; imported=0; kept=""` through the `kept in store` echo with:

```bash
  total=0; newly=0; imported=0; kept=""
  newnames=$(mktemp)
  while IFS=$'\t' read -r pdir label; do
    [ -n "$pdir" ] || continue
    total=$((total + 1))
    # Names present AFTER the link that were absent BEFORE are the imports.
    before=$(find "$st/memory" -maxdepth 1 -name '*.md' -exec basename {} \; | sort)
    out=$(memory_link "$pdir" "$st/memory")
    case "$out" in
      warn*)     echo "  WARN      ${out#*$'\t'}" ;;
      linked)    newly=$((newly + 1)) ;;
      imported*) n=$(printf '%s' "$out" | cut -f2); k=$(printf '%s' "$out" | cut -f3)
                 imported=$((imported + n)); newly=$((newly + 1))
                 [ -n "$k" ] && kept="$kept $label:{$k}"
                 find "$st/memory" -maxdepth 1 -name '*.md' -exec basename {} \; | sort |
                   comm -13 <(printf '%s\n' "$before") - >> "$newnames" ;;
    esac
  done <<< "$(memory_slug_dirs "$root")"

  memory_render_index "$st/memory"
  count=$(find "$st/memory" -maxdepth 1 -name '*.md' ! -name MEMORY.md | wc -l)
  printf '  memory    %s slugs -> %s/memory  (%s memories, %s newly linked, %s imported)\n' \
    "$total" "$st" "$count" "$newly" "$imported"
  [ -n "$kept" ] && echo "            kept in store, originals beside each link as memory.pre-sync/:$kept"
  if [ -s "$newnames" ]; then
    ov=$(memory_overlaps "$st/memory" "$newnames")
    if [ -n "$ov" ]; then
      echo "            overlap — same topic on both machines? read both, merge by hand if so:"
      printf '%s\n' "$ov"
    fi
  fi
  rm -f "$newnames"
```

`comm` is in coreutils, already a runtime input.

- [ ] **Step 5: Run the gate**

Run: `just check`
Expected: T19 passes.

- [ ] **Step 6: Commit**

```bash
git add scripts/memory.sh scripts/sync.sh scripts/tools-tests.sh
git commit -m "sync: render MEMORY.md by type with the machine tag inline; report topic overlaps at import"
```

---

### Task 4: `worktree` links at creation

**Files:**
- Modify: `scripts/worktree.sh:155-159` (the report block)
- Test: T20

**Interfaces:**
- Consumes: `memory_store`, `memory_link`, `slug_of`, `claude_projects_dir` (Tasks 1–2).

- [ ] **Step 1: Write the failing test**

Append T20:

```bash
echo "--- T20: a new worktree is linked to the store before its first session"
run "$worktree" kzstd feat/mem
expect 'memory +linked'
wt="$root/kzstd/.claude/worktrees/feat-mem"
[ "$(readlink "$projects/$(slug "$wt")/memory")" = "$store/memory" ] \
  || { echo "T20: worktree slug not linked at creation"; exit 1; }
run "$worktree" --remove kzstd feat-mem
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix flake check 2>&1 | tail -20`
Expected: `EXPECT FAILED: memory +linked`.

- [ ] **Step 3: Link in `scripts/worktree.sh`**

After the `mcp=""` … `fi` block (line 153) and before `echo "  created  $wt"`, add:

```bash
# Its own cwd is its own Claude Code project, so without this the first
# session here starts with no memory and every later one keeps its own
# blind store — the android/=2-memories hole, once per branch. The
# projects/ dir does not exist until a session writes it, hence mkdir in
# memory_link. Design: notes/agent-memory-sync.md.
mem=""
if [ -d "$(memory_store)/.git" ]; then
  s=$(slug_of "$wt") && mem=$(memory_link "$(claude_projects_dir)/$s" "$(memory_store)/memory")
fi
```

And after `[ -n "$mcp" ] && echo "  mcp      .mcp.json $mcp"`:

```bash
case "$mem" in
  linked) echo "  memory   linked -> $(memory_store)/memory" ;;
  warn*)  echo "  memory   WARN ${mem#*$'\t'}" ;;
esac
```

- [ ] **Step 4: Run the gate**

Run: `just check`
Expected: T20 passes; T9 unchanged.

- [ ] **Step 5: Commit**

```bash
git add scripts/worktree.sh scripts/tools-tests.sh
git commit -m "worktree: link the memory store at creation, before the first session"
```

---

### Task 5: the hook script and `sync --install-hooks`

**Files:**
- Modify: `scripts/memory.sh` (append `write_memory_hook`, `install_memory_hooks`)
- Modify: `scripts/sync.sh` (flag + call at the end of `memory_pass`)
- Modify: `notes/agent-memory-sync.md` (the `sort -u` correction)
- Test: T21

**Interfaces:**
- Produces: `write_memory_hook <root>` writes `<root>/bin/nixtastic-memory-hook`; `install_memory_hooks <root>` returns 0 when it wrote, 1 when already present.

- [ ] **Step 1: Write the failing test**

Append T21:

```bash
echo "--- T21: hooks — merged into settings.json once, existing entries kept; the hook commits, pushes, and respects the lock"
cfg="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
cat > "$cfg" <<'EOF'
{ "model": "opus", "hooks": { "SessionStart": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "herdr session", "timeout": 10 } ] } ] } }
EOF
run "$sync" --install-hooks
expect 'hooks installed'
[ -f "$cfg.nixtastic-bak" ] || { echo "T21: no backup"; exit 1; }
[ "$(jq -r .model "$cfg")" = opus ] || { echo "T21: unrelated setting lost"; exit 1; }
[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 2 ] || { echo "T21: herdr entry lost or ours missing"; exit 1; }
jq -e '.hooks.SessionStart[0].hooks[0].command == "herdr session"' "$cfg" >/dev/null || { echo "T21: existing hook rewritten"; exit 1; }
jq -e '.hooks.Stop[0].hooks[0].command | test("nixtastic-memory-hook.* stop$")' "$cfg" >/dev/null || { echo "T21: stop hook missing"; exit 1; }
[ -x "$root/bin/nixtastic-memory-hook" ] || { echo "T21: hook script missing"; exit 1; }
run "$sync" --install-hooks
expect 'hooks already installed'
[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 2 ] || { echo "T21: second install duplicated the entry"; exit 1; }
# The hook: a memory written through the link is committed and pushed.
printf -- '---\nname: from-a-session\ndescription: "x"\nmetadata:\n  type: project\n---\nbody\n' > "$projects/$(slug "$root")/memory/from-a-session.md"
printf -- '- [dup line](from-a-session.md) — x\n- [dup line](from-a-session.md) — x\n' >> "$store/memory/MEMORY.md"
run "$root/bin/nixtastic-memory-hook" stop
git -C "$origins/nixtastic-agent.git" log --oneline | grep -q 'memory: ' || { echo "T21: hook did not push"; exit 1; }
[ "$(grep -c 'dup line' "$store/memory/MEMORY.md")" = 1 ] || { echo "T21: union duplicate not collapsed"; exit 1; }
# A held lock means another session is mid-push: exit 0, do nothing.
mkdir "$store/.git/nixtastic-hook.lock"
echo more >> "$store/memory/from-a-session.md"
run "$root/bin/nixtastic-memory-hook" stop
[ -n "$(git -C "$store" status --porcelain)" ] || { echo "T21: hook ignored the lock"; exit 1; }
rmdir "$store/.git/nixtastic-hook.lock"
run "$root/bin/nixtastic-memory-hook" stop
[ -z "$(git -C "$store" status --porcelain)" ] || { echo "T21: hook did not commit after lock release"; exit 1; }
# start pulls: a commit made on the "other machine" arrives.
other="$HOME/other-machine"
git clone -q "$origins/nixtastic-agent.git" "$other"
printf -- '---\nname: from-the-laptop\ndescription: "x"\nmetadata:\n  type: project\n---\nbody\n' > "$other/memory/from-the-laptop.md"
(cd "$other" && git add -A && git commit -qm "memory: laptop" && git push -q)
run "$root/bin/nixtastic-memory-hook" start
[ -f "$store/memory/from-the-laptop.md" ] || { echo "T21: start hook did not pull"; exit 1; }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix flake check 2>&1 | tail -20`
Expected: `unknown option: --install-hooks`.

- [ ] **Step 3: Append the two functions to `scripts/memory.sh`**

```bash

# The hook Claude Code runs at SessionStart (pull) and Stop (commit, pull,
# push). A generated file at a STABLE path, like meshtastic-mcp-launch:
# settings.json names the path once, sync rewrites the contents. POSIX sh,
# because macOS runs it too — which is also why the lock is mkdir (atomic
# everywhere) and not flock(1) (absent there). Every step is best-effort
# and the script always exits 0: a hook must never block a session. A
# merge that conflicts is aborted, not left for the next session to load
# with markers in it; doctor reports it as diverged.
# $1 = workspace root.
# shellcheck disable=SC2016
write_memory_hook() {
  mkdir -p "$1/bin"
  {
    echo '#!/bin/sh'
    echo '# Generated by: nix run .#sync — regenerate, do not hand-edit.'
    echo '# SessionStart: pull. Stop: dedupe the index, commit, pull, push.'
    echo '# Every step best-effort; design in notes/agent-memory-sync.md.'
    printf 'store="%s"\n' "$(memory_store)"
    echo '[ -d "$store/.git" ] || exit 0'
    echo 'cd "$store" || exit 0'
    echo 'lock="$store/.git/nixtastic-hook.lock"'
    echo '# A lock older than a minute belongs to a crashed holder, not a live one.'
    echo 'if ! mkdir "$lock" 2>/dev/null; then'
    echo '  if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then'
    echo '    rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || exit 0'
    echo '  else exit 0; fi'
    echo 'fi'
    echo 'trap '"'"'rmdir "$lock" 2>/dev/null'"'"' EXIT'
    echo 'pull() { git pull --no-rebase --autostash -q >/dev/null 2>&1 || git merge --abort >/dev/null 2>&1 || true; }'
    echo 'case "${1:-}" in'
    echo '  start) pull ;;'
    echo '  stop)'
    echo '    # A union merge can leave a pointer line twice; drop repeats, KEEP'
    echo '    # order — sort would undo the type ordering sync renders.'
    echo '    if [ -f memory/MEMORY.md ]; then'
    echo '      awk '"'"'$0 == "" || !seen[$0]++'"'"' memory/MEMORY.md > memory/MEMORY.md.new && mv memory/MEMORY.md.new memory/MEMORY.md'
    echo '    fi'
    echo '    git add -A >/dev/null 2>&1 || true'
    echo '    git diff --cached --quiet || git commit -q -m "memory: $(hostname -s 2>/dev/null || echo host) $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 || true'
    echo '    pull'
    echo '    git push -q -u origin HEAD >/dev/null 2>&1 || true ;;'
    echo 'esac'
    echo 'exit 0'
  } > "$1/bin/nixtastic-memory-hook"
  chmod +x "$1/bin/nixtastic-memory-hook"
}

# Register the hook in USER-scope settings.json — the one place that reaches
# every directory on the machine, worktrees included. Merged with jq, never
# overwritten: herdr and paseo already live in this file. Idempotent by the
# script's own name; the backup is the same courtesy doctor extends. Both
# machines need this, which is why doctor checks it.
# $1 = workspace root. Returns 1 when already present (nothing written).
install_memory_hooks() {
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  hook="$1/bin/nixtastic-memory-hook"
  write_memory_hook "$1"
  mkdir -p "${cfg%/*}"
  [ -f "$cfg" ] || echo '{}' > "$cfg"
  grep -q nixtastic-memory-hook "$cfg" && return 1
  cp "$cfg" "$cfg.nixtastic-bak"
  jq --arg h "$hook" '
    .hooks.SessionStart = ((.hooks.SessionStart // []) + [{matcher: "*", hooks: [{type: "command", command: ($h + " start"), timeout: 10}]}])
    | .hooks.Stop = ((.hooks.Stop // []) + [{matcher: "", hooks: [{type: "command", command: ($h + " stop"), timeout: 15}]}])
  ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
}
```

- [ ] **Step 4: Wire the flag in `scripts/sync.sh`**

In the arg loop add `--install-hooks) hooks=true ;;` and initialise `hooks=false` beside `pull=false`. At the end of `memory_pass`, after the commit/push block and before the closing `}`:

```bash
  # The hook script is rewritten every pass (stable path, fresh store
  # path); the settings.json entry is written only on request, because
  # editing a user-global file is consent the user gives once.
  write_memory_hook "$root"
  if [ "$hooks" = true ]; then
    if install_memory_hooks "$root"; then
      echo "            hooks installed in ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json (backup: settings.json.nixtastic-bak)"
    else
      echo "            hooks already installed"
    fi
  elif ! grep -q nixtastic-memory-hook "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null; then
    echo "            no hooks yet — sessions will not pull or push until, once per machine:"
    echo "                nix run .#sync -- --install-hooks"
  fi
```

Also update the mode header comment at the top of `sync.sh` (the `# Modes:` block) with:

```bash
#   --install-hooks  register the memory hooks in user-scope settings.json
#   --memory-only    the memory pass alone (Task 7)
#   --slug <path>    print a Claude Code project slug and exit
```

- [ ] **Step 5: Correct the spec**

In `notes/agent-memory-sync.md`, the Hooks table row for `Stop` says `sort -u` on `MEMORY.md`, and the Conflicts section says "the `Stop` hook then normalises with `sort -u`". Change both to say order-preserving dedupe (`awk '!seen[$0]++'`), with this sentence added to the Conflicts section: "Not `sort -u`: that would undo the type ordering the index is rendered in. The hook drops repeated lines and keeps their order; `sync` re-renders properly on its next run."

- [ ] **Step 6: Run the gate**

Run: `just check`
Expected: T21 passes.

- [ ] **Step 7: Commit**

```bash
git add scripts/memory.sh scripts/sync.sh scripts/tools-tests.sh notes/agent-memory-sync.md
git commit -m "sync: the memory hook — pull at SessionStart, commit and push at Stop — and --install-hooks"
```

---

### Task 6: five `doctor` checks

**Files:**
- Modify: `scripts/doctor.sh` — insert before the final `echo ""` / tally block
- Test: T22

**Interfaces:**
- Consumes: `memory_store`, `memory_slug_dirs`, `claude_projects_dir` (Tasks 1–2).

- [ ] **Step 1: Write the failing test**

Append T22:

```bash
echo "--- T22: doctor — store, links, hooks, state, age"
run_lax "$doctor"
expect 'ok +memory links'
expect 'ok +memory hooks'
expect 'ok +memory store'
# Unlinked slug is named by its label, not its 80-character slug.
rm "$projects/$(slug "$root/kzstd")/memory"
run_lax "$doctor"
expect 'FAIL +memory links +1 of [0-9]+ unlinked: kzstd'
run "$sync"
# Unpushed commits and dirty files are reported, with the fix.
echo more >> "$store/memory/from-a-session.md"
run_lax "$doctor"
expect 'WARN +memory store .*1 uncommitted'
run "$root/bin/nixtastic-memory-hook" stop
# Age: a memory last modified years ago, and one with no date at all.
printf -- '---\nname: old\ndescription: "x"\nmetadata:\n  type: project\n  modified: 2020-01-01T00:00:00Z\n---\nbody\n' > "$store/memory/old.md"
run_lax "$doctor"
expect 'WARN +memory age +1 not updated since'
expect 'undated'
# Store missing entirely is a FAIL with the fix.
mv "$store" "$store.away"
run_lax "$doctor"
expect 'FAIL +memory store +not cloned'
mv "$store.away" "$store"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix flake check 2>&1 | tail -20`
Expected: `EXPECT FAILED: ok +memory links`.

- [ ] **Step 3: Add the checks to `scripts/doctor.sh`**

Insert before the final `echo ""` that precedes `if [ "$fails" -gt 0 ]; then`:

```bash

# --- memory store --------------------------------------------
# Design: notes/agent-memory-sync.md. Each failure here is silent in
# exactly the way this file exists to catch: the session just starts
# without its memory, or with a store the other machine never sees. The
# link check is also the only thing that notices if a Claude Code upgrade
# ever replaces memory/ instead of writing into it — run doctor after one.
mstore=$(memory_store)
if [ ! -d "$mstore/.git" ]; then
  bad "memory store" "not cloned at $mstore"
  fix "nix run .#sync"
else
  m_total=0; m_unlinked=""
  while IFS=$'\t' read -r pdir label; do
    [ -n "$pdir" ] || continue
    m_total=$((m_total + 1))
    if [ ! -L "$pdir/memory" ] || [ "$(readlink "$pdir/memory")" != "$mstore/memory" ]; then
      m_unlinked="$m_unlinked $label"
    fi
  done <<< "$(memory_slug_dirs "$root")"
  if [ -n "$m_unlinked" ]; then
    bad "memory links" "$(echo "$m_unlinked" | wc -w) of $m_total unlinked:$m_unlinked"
    fix "nix run .#sync"
  else
    ok "memory links" "$m_total slugs -> $mstore/memory"
  fi

  mcfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  if grep -q nixtastic-memory-hook "$mcfg" 2>/dev/null && [ -x "$root/bin/nixtastic-memory-hook" ]; then
    ok "memory hooks" "SessionStart pulls, Stop pushes"
  else
    warn "memory hooks" "not in $mcfg — sessions neither pull nor push"
    fix "nix run .#sync -- --install-hooks"
  fi

  m_dirty=$(git -C "$mstore" status --porcelain 2>/dev/null | wc -l)
  m_count=$(find "$mstore/memory" -maxdepth 1 -name '*.md' ! -name MEMORY.md 2>/dev/null | wc -l)
  if [ -e "$mstore/.git/MERGE_HEAD" ]; then
    bad "memory store" "merge in progress — sessions would load conflict markers"
    fix "git -C $mstore merge --abort && nix run .#sync -- --memory-only"
  else
    m_ahead=$(git -C "$mstore" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    m_behind=$(git -C "$mstore" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
    if [ "$m_ahead" -gt 0 ] && [ "$m_behind" -gt 0 ]; then
      warn "memory store" "diverged +$m_ahead/-$m_behind"
      fix "nix run .#sync -- --memory-only   (pulls with the union merge, then pushes)"
    elif [ "$m_ahead" -gt 0 ] || [ "$m_dirty" -gt 0 ]; then
      warn "memory store" "$m_ahead unpushed, $m_dirty uncommitted"
      fix "nix run .#sync -- --memory-only"
    else
      ok "memory store" "clean, pushed ($m_count memories)"
    fi
  fi

  # Frontmatter `modified:`, not mtime — the laptop's 2026-08-15 migration
  # reset every mtime. A signal, not a reaper: nothing here deletes.
  m_cutoff=$(date -u -d '90 days ago' +%Y-%m-%d)
  m_stale=0; m_undated=0
  while IFS= read -r f; do
    m_mod=$(sed -n 's/^  modified: *\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' "$f" | head -1)
    if [ -z "$m_mod" ]; then m_undated=$((m_undated + 1))
    elif [[ "$m_mod" < "$m_cutoff" ]]; then m_stale=$((m_stale + 1)); fi
  done <<< "$(find "$mstore/memory" -maxdepth 1 -name '*.md' ! -name MEMORY.md 2>/dev/null)"
  if [ "$m_stale" -gt 0 ] || [ "$m_undated" -gt 0 ]; then
    warn "memory age" "$m_stale not updated since $m_cutoff, $m_undated undated"
    fix "review them; a wrong memory is worse than a missing one — delete it"
  else
    ok "memory age" "all $m_count updated within 90 days"
  fi
fi
```

- [ ] **Step 4: Run the gate**

Run: `just check`
Expected: T22 passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/doctor.sh scripts/tools-tests.sh
git commit -m "doctor: the memory store — cloned, every slug linked, hooks registered, pushed, and not stale"
```

---

### Task 7: `--memory-only`, docs

**Files:**
- Modify: `scripts/sync.sh` (flag; early exit)
- Modify: `CLAUDE.md` — the "Fails silently — check these first" list
- Modify: `README.md` — wherever `nix run .#sync` is introduced to a human
- Modify: `AGENTS.md` — the generated-files convention (search for `meshtastic-mcp-launch` and add beside it)
- Test: T23

- [ ] **Step 1: Write the failing test**

Append T23:

```bash
echo "--- T23: --memory-only runs the memory pass and nothing else"
run "$sync" --memory-only
expect 'memory .*slugs ->'
refuse 'current +kzstd'
refuse 'clone '
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix flake check 2>&1 | tail -20`
Expected: `unknown option: --memory-only`.

- [ ] **Step 3: Add the flag**

In `scripts/sync.sh`, add `memory_only=false` beside `pull=false`, `--memory-only) memory_only=true ;;` in the arg loop, and immediately after the `echo "workspace: $root$mode"` / `echo ""` lines:

```bash
# The memory pass alone: after worktree churn, or when doctor says
# unpushed. Everything else in sync is a fetch of nineteen repos.
if [ "$memory_only" = true ]; then
  memory_pass
  exit 0
fi
```

`memory_pass` is defined later in the file than this call. Move the whole `memory_pass() { … }` definition (Task 2/3/5) up to just below `write_envrc()`, leaving only the `memory_pass` *call* where it was. It then sits above the arg loop that sets `hooks` and `memory_only` — that is fine and must stay so: a function body reads variables when it *runs*, not when it is defined, and both calls happen after the loop. Do not move the flags up with it.

- [ ] **Step 4: Docs**

`CLAUDE.md`, append to the "Fails silently" list:

```markdown
- **Memory is per-slug and the slug is your absolute cwd** — so `android/`,
  every worktree, and the other machine each start with an empty
  `~/.claude/projects/<slug>/memory` and never see what the root session
  learned. `.#sync` links every slug it owns into one private store
  (`~/.nixtastic-agent`, repo `jamesarich/nixtastic-agent`), `.#worktree`
  links at creation, and two user-scope hooks (`.#sync --install-hooks`,
  once per machine) pull at `SessionStart` and push at `Stop`. `doctor`
  reports an unlinked slug, missing hooks, an unpushed store, and memories
  not touched in 90 days. Design: [`notes/agent-memory-sync.md`](./notes/agent-memory-sync.md).
```

`README.md`: in the human workflow where `nix run .#sync` is first explained, add one paragraph: "On a new machine, also `nix run .#sync -- --install-hooks` once — it registers the two hooks that keep `~/.nixtastic-agent` (Claude's memory, shared across machines) pulled and pushed. `nix run .#doctor` tells you if you forgot."

`AGENTS.md`: beside the entry for `bin/meshtastic-mcp-launch` in the generated-files list, add `bin/nixtastic-memory-hook` — "the SessionStart/Stop hook body at a stable path; settings.json names the path, sync rewrites the contents."

- [ ] **Step 5: Run the gate**

Run: `just check`
Expected: T23 passes, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/sync.sh scripts/tools-tests.sh CLAUDE.md README.md AGENTS.md
git commit -m "sync: --memory-only, and the docs for the memory store"
```

---

### Task 8: rollout (manual — the spec's steps 1–5)

Not TDD; a checklist, run by a person or an agent with the bench and SSH. Each step has a verification.

- [ ] **Step 1: Create the private repo**

```bash
gh repo create jamesarich/nixtastic-agent --private --description "Claude Code memory for the nixtastic workspace" 
gh repo view jamesarich/nixtastic-agent --json visibility -q .visibility   # must print PRIVATE
```

- [ ] **Step 2: Desktop — first sync, seed, hooks**

```bash
cd ~/meshtastic && nix run .#sync -- --memory-only
# expect: "memory    cloned ~/.nixtastic-agent", "N slugs -> …", "42 imported", "committed and pushed"
ls -l ~/.claude/projects/-home-james-meshtastic/memory        # -> ~/.nixtastic-agent/memory
ls ~/.nixtastic-agent/memory/*.md | wc -l                      # 43 (42 + MEMORY.md)
nix run .#sync -- --install-hooks
nix run .#doctor                                               # every memory * line ok
```

- [ ] **Step 3: Laptop — pull the workspace, sync, hooks**

```bash
ssh james@192.168.1.138 'cd ~/nixtastic && git pull -q && nix run .#sync -- --memory-only 2>&1 | tail -20'
# expect: cloned, 240 imported, an overlap line naming commontest-names-no-commas ~ ios-rejects-commas-in-test-names, committed and pushed
ssh james@192.168.1.138 'cd ~/nixtastic && nix run .#sync -- --install-hooks && nix run .#doctor 2>&1 | grep memory'
```

- [ ] **Step 4: Desktop — pull, verify the union**

```bash
cd ~/meshtastic && nix run .#sync -- --memory-only
ls ~/.nixtastic-agent/memory/*.md | grep -vc MEMORY.md        # 282
grep -c '^- ' ~/.nixtastic-agent/memory/MEMORY.md              # 282
head -5 ~/.nixtastic-agent/memory/MEMORY.md                    # user-type memories first
```

- [ ] **Step 5: Machine tags by heuristic, then the one known duplicate**

```bash
cd ~/.nixtastic-agent/memory
for f in ios-*.md xcodebuild-*.md *-macos*.md; do [ -f "$f" ] && grep -q '^  machine:' "$f" || sed -i '/^  type:/a\  machine: darwin' "$f"; done
for f in uhubctl-*.md rak-bench-*.md tadpole-*.md *-pio-*.md concurrent-sessions-share-pio-tree.md mvgrind-*.md; do [ -f "$f" ] && grep -q '^  machine:' "$f" || sed -i '/^  type:/a\  machine: james-pc' "$f"; done
# Merge the one true duplicate by hand: keep ios-rejects-commas-in-test-names.md (broader), fold
# "only allTests catches it" from commontest-names-no-commas.md into it, delete the latter.
cd ~/meshtastic && nix run .#sync -- --memory-only               # re-renders with tags inline, commits, pushes
grep '\[darwin\]\|\[james-pc\]' ~/.nixtastic-agent/memory/MEMORY.md | wc -l   # > 0
```

- [ ] **Step 6: Prove it end to end**

Start a session in `~/meshtastic/android` on the desktop (a slug that had 2 memories yesterday) and ask it about something only the laptop knew — e.g. "what does AGP 9 change about plugin application in this repo?" (`agp9-plugin-quirks`, laptop-only until today). Then on the laptop, `nix run .#doctor` — `memory store` must read `clean, pushed`.

---

## Self-review

**Spec coverage.** Store layout → T2 (seeding `.gitattributes`/`.gitignore`). Slug → T1. Import three rules, never-clobber, idempotent, `MEMORY.md` never copied → T2. Index by type / tag inline / overlaps → T3. `sync` surface (`--memory-only`, `--install-hooks`, `--slug`) → T7, T5, T1. Five doctor checks → T6. Worktree at creation → T4. Hooks, `--no-rebase`, lock on both, abort on conflict, commit-always/push-best-effort → T5. Never synced (`*.jsonl`, credentials) → T2 `.gitignore`. Machine tag heuristic → T8 step 5. Legacy stores excluded → by construction (only enumerated paths are linked); no task needed. Rollout → T8. Follow-ups → out of scope, unchanged.

**Placeholder scan.** None. The one judgment call left to the executor is the by-hand merge of the single duplicate in T8 step 5, which is the spec's stated intent ("report, never auto-merge").

**Type consistency.** `memory_link` output is `linked` | `imported\tN\tkept` | `warn\tmsg` in Task 2 and consumed exactly so in Tasks 2, 4. `memory_slug_dirs` emits `<dir>\t<label>` in Task 2 and is read with `IFS=$'\t' read -r pdir label` in Tasks 2 and 6. `memory_store`/`memory_remote`/`claude_projects_dir` are used only by name. The hook file is `bin/nixtastic-memory-hook` everywhere; the lock is `.git/nixtastic-hook.lock` in Task 5 and T21. `memory_pass` is defined before its first call after Task 7 moves it.
