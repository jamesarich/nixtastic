# Agent Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five workspace additions from `notes/agent-tools.md`: an orientation SessionStart hook in the plugin, `worktree --path` with `just wt`/`just in`, multi-repo `brief --short`, a `pins` coupling-state tool, and a `pr` status tool.

**Architecture:** `pins` and `pr` are stdlib-only Python scripts (`scripts/pins.py`, `scripts/pr.py`) wrapped by `writeShellApplication` like the bash tools; the hook and the `brief`/`worktree` changes are bash. Every tool gets a `just` recipe that resolves the flake by the justfile's absolute path so it works from inside any repo or worktree. Fixture tests run offline with stub `gh`/`direnv` binaries on PATH.

**Tech Stack:** bash, python3 (stdlib), jq, git, gh (runtime only), Nix `writeShellApplication`, `tools-tests.sh` fixtures.

**Spec:** `notes/agent-tools.md`

**Status 2026-09-05:** all eight tasks landed on `main` (6117b7a … f5ebcd9 plus
the `just`-fallback follow-up); acceptance recorded in `notes/agent-tools.md`
→ Evidence → Acceptance runs. The `- [ ]` boxes below are the record of the
steps, not open work.

## Global Constraints

- Workspace commits go straight to `main`, sentence-style, **no attribution footers**.
- Gate before every commit touching `scripts/`, `plugin/`, `flake.nix`, `justfile`: `just check`.
- Python: stdlib only (`json`, `subprocess`, `re`, `sys`, `os`, `time`, `hashlib`, `argparse`, `urllib.parse`). No third-party packages.
- `pr` is read-only except `rereview`. No merge, approve, enqueue, dequeue.
- The orient hook never tells the model to `cd`, never prints memory, prints nothing outside the workspace.
- No `grep -q` on a chatty pipe in `tools-tests.sh`.
- Comments: terse, the invariant only.
- Spec amendments this plan makes (record in Task 7): apple pins protobufs as a submodule at `apple/protobufs`; no consumer pins `meshtastic-sdk`, so that row is dropped and `android → takpacket-sdk` (producer `TAKPacket-SDK`) is added; `just wt`/`just in` take the command without a `--` separator (just's `+CMD` already captures the rest); `brief --short` prints the pins verdict only when the `pins` binary is available to it.

## File structure

| Path | Responsibility |
| --- | --- |
| `plugin/hooks/orient.sh` | SessionStart orientation; reads `hooks/workspace-root` and `hooks/repos` written at render |
| `plugin/hooks/hooks.json` | second SessionStart entry |
| `scripts/plugin.sh` | render writes `hooks/workspace-root` and `hooks/repos` |
| `scripts/worktree.sh` | `--path` |
| `scripts/brief.sh` | several repos; `--short`; `PINS` line |
| `scripts/pins.py` | coupling state |
| `scripts/pr.py` | PR status, threads, wait, rereview |
| `flake.nix` | `pins`, `pr` packages; `python-lint` check; test attrs |
| `justfile` | `pins`, `pr`, `wt`, `in` |
| `scripts/tools-tests.sh` | T31–T35 |
| `.gitignore` | `!/scripts/*.py` |
| docs | `README.md`, `CLAUDE.md`, `AGENTS.md`, cross-repo skill, audit note, spec |

---

### Task 1: Orientation hook

**Files:**
- Create: `plugin/hooks/orient.sh`
- Modify: `plugin/hooks/hooks.json`
- Modify: `scripts/plugin.sh` (`plugin_render`)
- Test: `scripts/tools-tests.sh` — T31

**Interfaces:**
- Consumes: `NIXTASTIC_REPOS_TSV`; the rendered plugin dir from `plugin_render`.
- Produces: `hooks/workspace-root` (one line, absolute root) and `hooks/repos` (one dir name per line) in the render; `orient.sh` reading both from `$(dirname "$0")`.

- [ ] **Step 1: Failing test T31**

Append before `echo "all tests passed"`:

```bash
echo "--- T31: orient hook — five cwd cases, silence elsewhere, valid additionalContext"
oh="$root/.cache/agent-marketplace/nixtastic/hooks/orient.sh"
[ -x "$oh" ] || { echo "T31: orient.sh not rendered"; exit 1; }
[ "$(cat "$root/.cache/agent-marketplace/nixtastic/hooks/workspace-root")" = "$root" ] || { echo "T31: workspace-root not rendered"; exit 1; }
orient() { printf '{"cwd":%s,"hook_event_name":"SessionStart"}' "$(jq -Rn --arg c "$1" '$c')" | bash "$oh"; }
ctx() { orient "$1" | jq -r '.hookSpecificOutput.additionalContext'; }
[ "$(orient "$HOME")" = "" ] || { echo "T31: not silent outside the workspace"; orient "$HOME"; exit 1; }
orient "$root" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null || { echo "T31: bad JSON at root"; orient "$root"; exit 1; }
ctx "$root" | grep -q 'workspace root' || { echo "T31: root not classified"; ctx "$root"; exit 1; }
ctx "$root" | grep -q 'just brief <repo>' || { echo "T31: spellings missing"; exit 1; }
ctx "$root/android" | grep -q 'primary checkout of `android`' || { echo "T31: repo not classified"; ctx "$root/android"; exit 1; }
git -C "$root/kzstd" worktree add -q "$root/kzstd/.claude/worktrees/orient-wt" -b orient-wt
ctx "$root/kzstd/.claude/worktrees/orient-wt" | grep -q 'worktree `orient-wt` of `kzstd`' || { echo "T31: repo worktree not classified"; ctx "$root/kzstd/.claude/worktrees/orient-wt"; exit 1; }
ctx "$root/kzstd/.claude/worktrees/orient-wt" | grep -qF "$root/kzstd" || { echo "T31: primary path missing"; exit 1; }
git -C "$root" worktree add -q "$root/.claude/worktrees/ws-wt" -b ws-wt
ctx "$root/.claude/worktrees/ws-wt" | grep -q 'worktree of the workspace repo' || { echo "T31: workspace worktree not classified"; ctx "$root/.claude/worktrees/ws-wt"; exit 1; }
ctx "$root/.claude/worktrees/ws-wt" | grep -q 'org repos are NOT here' || { echo "T31: workspace worktree warning missing"; exit 1; }
[ "$(ctx "$root" | wc -l)" -le 14 ] || { echo "T31: too long: $(ctx "$root" | wc -l) lines"; exit 1; }
git -C "$root" worktree remove --force "$root/.claude/worktrees/ws-wt"; git -C "$root" branch -D ws-wt -q
git -C "$root/kzstd" worktree remove --force "$root/kzstd/.claude/worktrees/orient-wt"; git -C "$root/kzstd" branch -D orient-wt -q
```

Run: `nix build .#checks.x86_64-linux.tools-tests --no-link 2>&1 | grep -E 'error: Cannot build|all tests'` → FAIL `orient.sh not rendered`.

- [ ] **Step 2: `plugin/hooks/orient.sh`**

```bash
#!/usr/bin/env bash
# SessionStart: say where this session is standing and how to reach the
# workspace tools from there. Orients only — never tells the model to cd,
# never prints memory. Silent outside the workspace. Fails open.
here=$(cd "$(dirname "$0")" && pwd)
root=$(cat "$here/workspace-root" 2>/dev/null) || exit 0
[ -d "$root" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"
cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || exit 0
rootp=$(cd "$root" && pwd -P)

common=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null || true)
[ -n "$common" ] && common=$(cd "$cwd" && cd "$common" 2>/dev/null && pwd -P)
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)

where=""
case "$cwd" in
  "$rootp") where="You are at the workspace root: $root" ;;
  "$rootp"/*)
    rel=${cwd#"$rootp"/}; repo=${rel%%/*}
    if grep -qx -- "$repo" "$here/repos" 2>/dev/null; then
      if [ "$common" = "$rootp/$repo/.git" ] && [ "$top" != "$rootp/$repo" ]; then
        br=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
        where="You are in worktree \`${top##*/}\` of \`$repo\` (branch $br). Primary checkout: $root/$repo. Edits stay in this tree; the worktree guard denies the rest."
      else
        where="You are in the primary checkout of \`$repo\`: $root/$repo"
      fi
    elif [ "$common" = "$rootp/.git" ] && [ "$top" != "$rootp" ]; then
      where="This is a worktree of the workspace repo itself (flake, notes, CLAUDE.md only). The org repos are NOT here; they live at $root/<repo>. Nothing repo-related can be done from this tree."
    else
      where="You are under the workspace root ($root), not inside an org repo."
    fi ;;
  *)
    if [ -n "$common" ] && [ "$common" = "$rootp/.git" ]; then
      where="This is a worktree of the workspace repo itself (flake, notes, CLAUDE.md only). The org repos are NOT here; they live at $root/<repo>. Nothing repo-related can be done from this tree."
    else
      exit 0
    fi ;;
esac

ctx="$where
Workspace tools (work from any cwd; \`nix run .#\` does not resolve inside a repo):
  just brief <repo>            orient on one repo (docs to read, branch, drift)
  just brief --short a b c     one line per repo
  just pins                    cross-repo pin state (protobufs, design, api seeds)
  just pr <repo> <n>           PR status: checks for the head SHA, threads, queue
  just wt <repo> <name> <cmd>  run in a worktree with its env; just in <repo> <cmd> for the primary
  just worktree <repo> <br>    create a worktree the right way
  just sync | just doctor
Run just from $root (justfile: $root/justfile)."
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
exit 0
```

`chmod +x`.

- [ ] **Step 3: hooks.json and render**

Add to the `SessionStart` array in `plugin/hooks/hooks.json`, after the memory entry:

```json
      { "matcher": "*", "hooks": [ { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/orient.sh", "timeout": 5 } ] }
```

In `scripts/plugin.sh` `plugin_render`, after the memory-hook copy line, add:

```bash
  printf '%s\n' "$root" > "$tmp/$name/hooks/workspace-root"
  cut -f1 "$NIXTASTIC_REPOS_TSV" > "$tmp/$name/hooks/repos"
```

Both are render inputs now, so `plugin_input_hash` must see them or a repo added to the table leaves `hooks/repos` stale while `doctor` says ok. Add, as the first lines inside its brace group: `printf '%s\n' "$1"; cat "$NIXTASTIC_REPOS_TSV"`.

Add `orient.sh` to the `plugin-lint` shellcheck line in `flake.nix` (it is covered by `plugin/hooks/*.sh` already; confirm).

- [ ] **Step 4: Run, gate, commit**

`nix build .#checks.x86_64-linux.tools-tests --no-link` → `all tests passed`. `just check`.

```bash
git add plugin scripts/plugin.sh scripts/tools-tests.sh
git commit -m "plugin: SessionStart orient hook — where the session is, and the just spellings that work from there"
```

---

### Task 2: `worktree --path`, `just wt`, `just in`

**Files:**
- Modify: `scripts/worktree.sh` (usage + a `--path` case)
- Modify: `justfile`
- Test: `scripts/tools-tests.sh` — T34

- [ ] **Step 1: Failing test T34**

```bash
echo "--- T34: worktree --path resolves branch or dir name; unknown exits 1"
run "$worktree" kzstd feat/path-me
run "$worktree" --path kzstd feat/path-me
expect "^$root/kzstd/.claude/worktrees/feat-path-me\$"
run "$worktree" --path kzstd feat-path-me
expect "^$root/kzstd/.claude/worktrees/feat-path-me\$"
run_lax "$worktree" --path kzstd nope
expect 'no worktree'
run "$worktree" --remove kzstd feat-path-me
```

The justfile recipes are verified in Step 3 by `just --list` on the real workspace; the sandbox has no `just`.

Run: expect FAIL at `--path` (`unknown option` or usage).

- [ ] **Step 2: Implement `--path`**

In `scripts/worktree.sh` usage, add `  echo "  nix run .#worktree -- --path <repo> <branch|name>   print its path"`. In the `case`, before `--remove`:

```bash
  --path)
    dir="${2:-}"; want="${3:-}"
    [ -n "$dir" ] && [ -n "$want" ] || { usage; exit 1; }
    p="$root/$dir"
    [ -d "$p/.git" ] || { echo "$dir not cloned" >&2; exit 1; }
    # Branch or directory name: the create side derives one from the other,
    # the Desktop app names its own, so accept both.
    byname="$p/.claude/worktrees/$want"
    if [ -d "$byname" ]; then echo "$byname"; exit 0; fi
    byname="$p/.claude/worktrees/$(echo "$want" | tr '/' '-')"
    if [ -d "$byname" ]; then echo "$byname"; exit 0; fi
    found=$(git -C "$p" worktree list --porcelain | awk -v b="refs/heads/$want" '
      /^worktree /{w=substr($0,10)} /^branch /{if($2==b){print w; exit}}')
    if [ -n "$found" ]; then echo "$found"; exit 0; fi
    echo "no worktree of $dir named or on branch '$want'" >&2
    exit 1 ;;
```

- [ ] **Step 3: justfile recipes**

Append to `justfile`:

```make
# Cross-repo pin state: what pins protobufs, design and the api seeds, and
# whether each consumer is current. [no-cd] + absolute flake ref, like brief.
[no-cd]
pins *ARGS:
    nix run {{ justfile_directory() }}#pins -- {{ ARGS }}

# PR status for the HEAD SHA: checks, unresolved threads, queue, conflicts.
[no-cd]
pr *ARGS:
    nix run {{ justfile_directory() }}#pr -- {{ ARGS }}

# Run a command inside a worktree with that repo's environment, no cd:
#   just wt android feat-x ./gradlew :core:test
[no-cd]
wt repo name +CMD:
    direnv exec "$(nix run {{ justfile_directory() }}#worktree -- --path {{ repo }} {{ name }})" {{ CMD }}

# Same for a primary checkout:  just in firmware pio run -e tbeam
[no-cd]
in repo +CMD:
    direnv exec {{ justfile_directory() }}/{{ repo }} {{ CMD }}
```

Verify: `just --list | grep -E '^\s+(pins|pr|wt|in)\b'` prints four recipes. `just in kzstd pwd` prints `/home/james/meshtastic/kzstd`.

- [ ] **Step 4: Run, gate, commit**

Tests pass, `just check` (the `pins`/`pr` recipes reference apps that do not exist yet; `just --list` does not evaluate them, and `nix flake check` does not evaluate the justfile).

```bash
git add scripts/worktree.sh justfile scripts/tools-tests.sh
git commit -m "worktree: --path; just wt / just in run a command in a worktree or repo with its env"
```

---

### Task 3: `brief` for several repos, `--short`

**Files:**
- Modify: `scripts/brief.sh` (wrap the body in `brief_one`, add `brief_short`, loop)
- Test: `scripts/tools-tests.sh` — T35

**Interfaces:**
- Produces: `brief_short <dir>` printing one line `%-18s %-8s drift -N/+N  clean|dirty!  PRs N  pins: …`; the pins column reads `$NIXTASTIC_PINS` when set (Task 4 sets it), else `-`.

- [ ] **Step 1: Failing test T35**

```bash
echo "--- T35: brief takes several repos; --short is one line each"
run "$brief" api kzstd protobufs
[ "$(printf '%s\n' "$res" | grep -c '^  ────')" = 3 ] || { echo "T35: expected 3 sections"; exit 1; }
run "$brief" --short api kzstd protobufs
[ "$(printf '%s\n' "$res" | grep -c '^[a-zA-Z]')" = 3 ] || { echo "T35: expected 3 lines"; printf '%s\n' "$res"; exit 1; }
expect '^api +main +drift -0/\+0 +clean +PRs '
echo dirty >> "$root/kzstd/tracked.txt"
run "$brief" --short kzstd
expect '^kzstd .* dirty! '
git -C "$root/kzstd" checkout -q -- tracked.txt
```

Run → FAIL (`unknown repo: kzstd` because the second argument is ignored today, or `unknown repo: --short`).

- [ ] **Step 2: Restructure brief.sh**

Turn the body from `shell=""` (line ~16) through the end into a function `brief_one() { dir="$1"; … }` (the existing code verbatim, with `exit 1` → `return 1` for the two "unknown repo"/"not cloned" checks). Add before it:

```bash
repo_shell() { while IFS=$'\t' read -r d _ s; do [ "$d" = "$1" ] && { echo "$s"; return; }; done < "$NIXTASTIC_REPOS_TSV"; }

# One line: branch, drift, tree state, open PRs, pins verdict.
brief_short() {
  dir="$1"; p="$root/$dir"
  [ -n "$(repo_shell "$dir")" ] || { printf '%-18s unknown repo\n' "$dir"; return 1; }
  [ -d "$p/.git" ] || { printf '%-18s not cloned\n' "$dir"; return 1; }
  g="git -C $p"
  branch=$($g rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
  c="0	0"
  if u=$($g rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
    c=$($g rev-list --left-right --count "$u...HEAD" 2>/dev/null || echo "0	0")
  fi
  d=$($g status --porcelain --untracked-files=no | wc -l)
  state=clean; [ "$d" -gt 0 ] && state='dirty!'
  prs='?'
  if command -v gh >/dev/null; then
    prs=$(gh pr list --repo "meshtastic/$( $g remote get-url origin | sed 's|.*/||; s|\.git$||' )" --limit 50 --json number --jq 'length' 2>/dev/null || echo '?')
  fi
  pins='-'
  [ -n "${NIXTASTIC_PINS:-}" ] && pins=$("$NIXTASTIC_PINS" --repo "$dir" --short 2>/dev/null || echo '-')
  printf '%-18s %-8s drift -%s/+%s  %-6s PRs %-3s pins: %s\n' "$dir" "$branch" "$(echo "$c" | cut -f1)" "$(echo "$c" | cut -f2)" "$state" "$prs" "$pins"
}
```

Replace the argument handling at the top with:

```bash
short=false
[ "${1:-}" = --short ] && { short=true; shift; }
if [ $# -eq 0 ]; then
  echo "usage: nix run .#brief [--short] <repo>..."
  echo ""; echo "repos:"
  while IFS=$'\t' read -r d _ s; do printf '  %-24s %s\n' "$d" ".#$s"; done < "$NIXTASTIC_REPOS_TSV"
  exit 0
fi
rc=0
for dir in "$@"; do
  if [ "$short" = true ]; then brief_short "$dir" || rc=1; else brief_one "$dir" || rc=1; fi
done
exit $rc
```

`brief_one` must be defined above this loop. Keep the worktree-aware `p` logic inside `brief_one` untouched.

- [ ] **Step 3: Run, gate, commit**

```bash
git add scripts/brief.sh scripts/tools-tests.sh
git commit -m "brief: several repos per call, and --short for one line each"
```

---

### Task 4: `pins`

**Files:**
- Create: `scripts/pins.py`
- Modify: `flake.nix` (package `pins`, `python-lint` check, `pins` in tools-tests attrs, `NIXTASTIC_PINS` in brief's runtimeEnv)
- Modify: `.gitignore` (`!/scripts/*.py`)
- Modify: `scripts/brief.sh` (`PINS` line in `brief_one`)
- Test: `scripts/tools-tests.sh` — T33

**Interfaces:**
- Produces: `meshtastic-pins [--fetch] [--json] [--repo DIR] [--short]`. Rows as JSON objects `{kind: producer|consumer, repo, detail, pinned, resolves, verdict}`. `--repo DIR --short` prints one phrase such as `protobufs 2.8.0 current`, or `-` when DIR appears in no row.

- [ ] **Step 1: Failing test T33**

```bash
echo "--- T33: pins — submodule, toml, resolved, seed pairs; current/behind/unknown; --json; --repo --short"
# protobufs producer with two tags; firmware submodule at the latest tag, python at the older.
(cd "$root/protobufs" && git tag v2.7.26 && echo more > proto2 && git add proto2 && git commit -qm "v2.8.0" && git tag v2.8.0 && git push -q --tags origin main 2>/dev/null)
old=$(git -C "$root/protobufs" rev-parse v2.7.26); new=$(git -C "$root/protobufs" rev-parse v2.8.0)
addsub() { (cd "$root/$1" && git -c protocol.file.allow=always submodule add -q "$root/protobufs" "$2" >/dev/null 2>&1 && git -C "$2" checkout -q "$3" && git add -A && git commit -qm "pin protobufs"); }
addsub firmware protobufs "$new"
addsub meshtastic-python protobufs "$old"
mkdir -p "$root/android/gradle"; printf '[versions]\nmeshtastic-protobufs = "2.8.0"\ntakpacket-sdk = "0.9.1"\n' > "$root/android/gradle/libs.versions.toml"
mkdir -p "$root/meshtastic-sdk/gradle"; printf '[versions]\nmeshtasticProtobufs = "2.7.26"\n' > "$root/meshtastic-sdk/gradle/libs.versions.toml"
(cd "$root/TAKPacket-SDK" && git tag v0.9.1)
mkdir -p "$root/api/data" "$root/android/androidApp/src/main/assets"
echo '{"a":1}' > "$root/api/data/maintenanceUf2.json"; echo '{"a":1}' > "$root/android/androidApp/src/main/assets/maintenance_uf2.json"
echo '{"b":1}' > "$root/api/data/deviceLinks.json";     echo '{"b":2}' > "$root/android/androidApp/src/main/assets/device_links.json"
run "$pins"
expect 'producer +protobufs .*latest tag v2\.8\.0'
expect 'consumer +firmware .*v2\.8\.0 +current'
expect 'consumer +meshtastic-python .*v2\.7\.26 +behind: v2\.8\.0'
expect 'consumer +android .*org\.meshtastic:protobufs 2\.8\.0 .*current'
expect 'consumer +meshtastic-sdk .*2\.7\.26 .*behind: v2\.8\.0'
expect 'consumer +android .*takpacket-sdk 0\.9\.1 .*current'
expect 'consumer +apple .*unknown'
expect 'maintenance_uf2 same'
expect 'device_links DIFFERS'
run "$pins" --json
printf '%s\n' "$res" | jq -e 'map(select(.verdict=="behind: v2.8.0")) | length == 2' >/dev/null || { echo "T33: json verdicts"; exit 1; }
run "$pins" --repo meshtastic-python --short
expect '^protobufs v2\.7\.26 behind: v2\.8\.0$'
run "$pins" --repo labeltastic --short
expect '^-$'
# android has two consumer rows; the first (protobufs) is the phrase.
run "$pins" --repo android --short
expect '^protobufs v2\.8\.0 current$'
```

Run → FAIL (`$pins` unset / not built).

- [ ] **Step 2: `scripts/pins.py`**

```python
#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
"""Cross-repo pin state: who pins protobufs, design, TAKPacket-SDK and the api
seeds, and whether each consumer is current. Offline by default; reads local
checkouts and local tags. Reports, never judges. Design: notes/agent-tools.md."""
import argparse, hashlib, json, os, re, subprocess, sys

ROOT = os.environ.get("MESHTASTIC_WORKSPACE") or os.getcwd()

def git(repo, *args, default=None):
    try:
        return subprocess.run(["git", "-C", os.path.join(ROOT, repo), *args],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return default

def cloned(repo):
    return os.path.isdir(os.path.join(ROOT, repo, ".git"))

def vkey(tag):
    return tuple(int(x) if x.isdigit() else 0 for x in re.sub(r"^v", "", tag).split("."))

def latest_tag(repo):
    tags = (git(repo, "tag", "--list", "v*", default="") or "").split()
    return max(tags, key=vkey) if tags else None

def head_short(repo):
    return git(repo, "rev-parse", "--short", "HEAD", default="?")

def tag_at(repo, sha):
    """Exact tag at sha, else 'vX.Y.Z+N' when ahead of a tag, else None."""
    exact = git(repo, "describe", "--tags", "--exact-match", sha)
    if exact:
        return exact, exact
    d = git(repo, "describe", "--tags", sha)
    if d and re.search(r"-\d+-g[0-9a-f]+$", d):
        base = re.sub(r"-\d+-g[0-9a-f]+$", "", d)
        n = re.search(r"-(\d+)-g", d).group(1)
        return f"{base}+{n}", base
    return None, None

def verdict_vs(pinned_tag, latest):
    if not pinned_tag or not latest:
        return "unknown"
    if vkey(pinned_tag) == vkey(latest):
        return "current"
    return f"behind: {latest}" if vkey(pinned_tag) < vkey(latest) else "ahead"

def submodule_sha(consumer, path):
    out = git(consumer, "ls-tree", "HEAD", path)
    return out.split()[2] if out and len(out.split()) >= 3 else None

def toml_version(consumer, relfile, key):
    p = os.path.join(ROOT, consumer, relfile)
    if not os.path.isfile(p):
        return None
    for line in open(p, encoding="utf-8"):
        m = re.match(rf'^\s*{re.escape(key)}\s*=\s*"([^"]+)"', line)
        if m:
            return m.group(1)
    return None

def sha256(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()
    except OSError:
        return None

def row(kind, repo, detail, pinned="", resolves="", verdict=""):
    return {"kind": kind, "repo": repo, "detail": detail, "pinned": pinned, "resolves": resolves, "verdict": verdict}

def submodule_row(consumer, path, producer, latest):
    sha = submodule_sha(consumer, path)
    if not sha:
        return row("consumer", consumer, f"submodule {path}", "", "", "unknown")
    label, base = tag_at(producer, sha)
    resolves = label or sha[:7]
    return row("consumer", consumer, f"submodule {path} @ {sha[:7]}", sha[:7], resolves,
               verdict_vs(base, latest) if base else "unknown")

def rows():
    out = []
    # protobufs → firmware, meshtastic-python, apple (submodules); android, meshtastic-sdk (toml)
    if cloned("protobufs"):
        latest = latest_tag("protobufs")
        out.append(row("producer", "protobufs", f"master {head_short('protobufs')}", "", "", f"latest tag {latest or 'none'}"))
        for c in ("firmware", "meshtastic-python", "apple"):
            if cloned(c):
                out.append(submodule_row(c, "protobufs", "protobufs", latest))
        for c, key in (("android", "meshtastic-protobufs"), ("meshtastic-sdk", "meshtasticProtobufs")):
            if cloned(c):
                v = toml_version(c, "gradle/libs.versions.toml", key)
                out.append(row("consumer", c, f"org.meshtastic:protobufs {v or '?'} (gradle/libs.versions.toml)", v or "", f"v{v}" if v else "",
                               verdict_vs(f"v{v}", latest) if v else "unknown"))
    # TAKPacket-SDK → android
    if cloned("TAKPacket-SDK") and cloned("android"):
        latest = latest_tag("TAKPacket-SDK")
        out.append(row("producer", "TAKPacket-SDK", f"main {head_short('TAKPacket-SDK')}", "", "", f"latest tag {latest or 'none'}"))
        v = toml_version("android", "gradle/libs.versions.toml", "takpacket-sdk")
        out.append(row("consumer", "android", f"org.meshtastic:takpacket-sdk {v or '?'} (gradle/libs.versions.toml)", v or "", f"v{v}" if v else "",
                       verdict_vs(f"v{v}", latest) if v else "unknown"))
    # design → meshtastic (docs) submodule
    if cloned("design") and cloned("meshtastic"):
        out.append(row("producer", "design", f"master {head_short('design')}"))
        sha = submodule_sha("meshtastic", "static/design")
        if sha:
            behind = git("design", "rev-list", "--count", f"{sha}..HEAD")
            v = "current" if behind == "0" else (f"behind by {behind} commits" if behind else "unknown")
            out.append(row("consumer", "meshtastic", f"submodule static/design @ {sha[:7]}", sha[:7], sha[:7], v))
        else:
            out.append(row("consumer", "meshtastic", "submodule static/design", "", "", "unknown"))
    # api seeds → android assets
    if cloned("api") and cloned("android"):
        out.append(row("producer", "api", "data/*.json"))
        pairs = (("maintenanceUf2", "maintenance_uf2"), ("bootloaderOtaQuirks", "device_bootloader_ota_quirks"),
                 ("deviceLinks", "device_links"), ("eventFirmware", "event_firmware"))
        parts = []
        for a, b in pairs:
            ha = sha256(os.path.join(ROOT, "api", "data", f"{a}.json"))
            hb = sha256(os.path.join(ROOT, "android", "androidApp", "src", "main", "assets", f"{b}.json"))
            parts.append(f"{b} {'same' if ha and ha == hb else ('DIFFERS' if ha and hb else 'missing')}")
        out.append(row("consumer", "android assets", "  ".join(parts)))
    return out

def render(rs):
    for r in rs:
        tail = f"  {r['verdict']}" if r["verdict"] else ""
        print(f"{r['kind']:<9} {r['repo']:<18} {r['detail']}{tail}")

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fetch", action="store_true", help="git fetch --tags in the producers first")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--repo", help="only rows naming this repo")
    ap.add_argument("--short", action="store_true", help="with --repo: one phrase, or '-'")
    a = ap.parse_args()
    if a.fetch:
        for p in ("protobufs", "design", "TAKPacket-SDK"):
            if cloned(p):
                git(p, "fetch", "--quiet", "--tags", "origin")
    rs = rows()
    if a.repo:
        rs = [r for r in rs if r["repo"] == a.repo or r["repo"].startswith(a.repo + " ")]
        if a.short:
            cons = [r for r in rs if r["kind"] == "consumer" and r["verdict"]]
            if not cons:
                print("-"); return 0
            r = cons[0]
            prod = r["detail"].split()[0] if r["detail"].startswith("submodule") else r["detail"].split(":")[0].split()[0]
            name = r["detail"].split()[1] if r["detail"].startswith("submodule") else r["detail"].split()[0].split(":")[-1]
            print(f"{name} {r['resolves'] or r['pinned']} {r['verdict']}".strip()); return 0
    if a.json:
        json.dump(rs, sys.stdout, indent=1); print()
    else:
        render(rs)
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Flake, gitignore, brief**

`.gitignore`: after `!/scripts/*.sh` add `!/scripts/*.py`.

`flake.nix`, next to `brief`:

```nix
          # nix run .#pins — cross-repo pin state. Python (stdlib) because it
          # merges five pin formats into one table; jq for that is pain.
          pins = pkgs.writeShellApplication {
            name = "meshtastic-pins";
            runtimeInputs = [ pkgs.git pkgs.coreutils pkgs.python313 ];
            runtimeEnv = { NIXTASTIC_PINS_PY = "${./scripts/pins.py}"; };
            text = ''exec python3 "$NIXTASTIC_PINS_PY" "$@"'';
          };
```

`brief`'s `runtimeEnv` gains `NIXTASTIC_PINS = "${pins}/bin/meshtastic-pins";` (`pins` is in the same `let`). `tools-tests` attrs gain `pins = "${self.packages.${system}.pins}/bin/meshtastic-pins";`. Add a check after `plugin-lint`:

```nix
          python-lint = pkgs.runCommand "nixtastic-python-lint" { nativeBuildInputs = [ pkgs.python313 ]; } ''
            python3 -m py_compile ${self}/scripts/*.py
            touch "$out"
          '';
```

In `brief_one` (brief.sh), after the drift/tree lines and before `READ BEFORE EDITING`, add:

```bash
if [ -n "${NIXTASTIC_PINS:-}" ]; then
  pl=$("$NIXTASTIC_PINS" --repo "$dir" 2>/dev/null | sed 's/^/    /')
  [ -n "$pl" ] && { echo ""; echo "  PINS"; printf '%s\n' "$pl"; }
fi
```

- [ ] **Step 4: Run, fix, gate, commit**

`nix build .#checks.x86_64-linux.tools-tests --no-link` → `all tests passed` (T33 and T35's pins column). Then on the real workspace: `just pins` must print the python row as `behind: v2.8.0`, apple as `v2.8.0+2  ahead`, sdk `behind: v2.8.0`. `just check`.

```bash
git add scripts/pins.py scripts/brief.sh flake.nix .gitignore scripts/tools-tests.sh
git commit -m "pins: cross-repo pin state in one screen — protobufs, TAKPacket-SDK, design, api seeds; brief shows its repo's rows"
```

---

### Task 5: `pr`

**Files:**
- Create: `scripts/pr.py`
- Modify: `flake.nix` (package `pr`, `pr` in tools-tests attrs)
- Test: `scripts/tools-tests.sh` — T32 (with a stub `gh` and JSON fixtures written by the test)

**Interfaces:**
- Produces: `meshtastic-pr <repo|org/repo|url> <n> [status|threads|wait|rereview] [--json] [--deep] [--until X] [--timeout N] [--all]`. Env `NIXTASTIC_PR_POLL` (seconds, default 30) for tests.

- [ ] **Step 1: Failing test T32**

```bash
echo "--- T32: pr — status from the HEAD sha, threads, queue, conflicts, wait, rereview (stub gh)"
FIX="$HOME/prfix"; mkdir -p "$FIX" "$PWD/fakebin"
cat > "$PWD/fakebin/gh" <<'EOF'
#!/bin/sh
# Stub gh: replays fixtures by request shape; counts calls for the wait test.
n=$(cat "$PRFIX/calls" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$PRFIX/calls"
case "$*" in
  *"pr view"*)        cat "$PRFIX/view.json" ;;
  *graphql*)          if [ -f "$PRFIX/flip" ] && [ "$n" -ge "$(cat "$PRFIX/flip")" ]; then cat "$PRFIX/gql_after.json"; else cat "$PRFIX/gql.json"; fi ;;
  *"/check-runs"*)    case "$*" in *aaaaaaa*) cat "$PRFIX/checks_head.json" ;; *) cat "$PRFIX/checks_stale.json" ;; esac ;;
  *"/compare/"*)      echo '{"behind_by": 0}' ;;
  *"pr comment"*)     echo "$*" >> "$PRFIX/posted"; echo "https://github.com/x/y/pull/1#issuecomment-1" ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$PWD/fakebin/gh"; export PRFIX="$FIX"
cat > "$FIX/view.json" <<'EOF'
{"number":7000,"title":"feat: offline map fallback","state":"OPEN","isDraft":false,"author":{"login":"jamesarich"},"headRefOid":"aaaaaaa1111111111111111111111111111111111","headRefName":"feat/map","baseRefName":"main","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"APPROVED","url":"https://github.com/meshtastic/Meshtastic-Android/pull/7000"}
EOF
cat > "$FIX/gql.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"mergeQueueEntry":null,"reviews":{"nodes":[{"author":{"login":"garth"},"state":"APPROVED"}]},"reviewThreads":{"nodes":[
 {"id":"T1","isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"path":"app/MapScreen.kt","line":123,"body":"Consider guarding the null case here.\nmore"}]}},
 {"id":"T2","isResolved":false,"comments":{"nodes":[{"author":{"login":"jamesarich"},"path":"core/Repo.kt","line":40,"body":"this leaks the scope"}]}},
 {"id":"T3","isResolved":true,"comments":{"nodes":[{"author":{"login":"garth"},"path":"a.kt","line":1,"body":"done"}]}}]}}}}}
EOF
cat > "$FIX/gql_after.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"mergeQueueEntry":{"position":2,"state":"QUEUED"},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
EOF
cat > "$FIX/checks_head.json" <<'EOF'
{"check_runs":[{"id":1,"name":"validate-and-build / Build Desktop Debug","status":"in_progress","conclusion":null},{"id":2,"name":"Unit Tests","status":"completed","conclusion":"success"}]}
EOF
cat > "$FIX/checks_stale.json" <<'EOF'
{"check_runs":[{"id":9,"name":"Unit Tests","status":"completed","conclusion":"failure"}]}
EOF
oldpath="$PATH"; PATH="$PWD/fakebin:$PATH"; export PATH
run "$pr" android 7000
expect 'meshtastic/Meshtastic-Android #7000 +feat: offline map fallback +OPEN'
expect '^head +aaaaaaa'
expect '^merge +BLOCKED +unresolved threads: 2 +queue: not enqueued +conflicts: none'
expect '^checks@aaaaaaa +ok 1 +fail 0 +pending 1 +validate-and-build / Build Desktop Debug'
refuse 'fail 1'
expect '^reviews +APPROVED 1 \(garth\)'
expect 'coderabbitai +app/MapScreen.kt:123 +"Consider guarding the null case here\.'
expect '^next +resolve 2 threads'
run "$pr" android 7000 threads
expect 'T1'; expect 'T2'; refuse 'T3'
run "$pr" android 7000 threads --all
expect 'T3'
run "$pr" android 7000 --json
printf '%s\n' "$res" | jq -e '.threads_unresolved == 2 and .checks.pending == 1' >/dev/null || { echo "T32: json shape"; exit 1; }
# wait: the queue entry appears on the 3rd graphql call; poll fast.
echo 0 > "$FIX/calls"; echo 9 > "$FIX/flip"
NIXTASTIC_PR_POLL=0.1 run "$pr" android 7000 wait --until queue --timeout 30
expect 'queue: position 2'
echo 0 > "$FIX/calls"; rm -f "$FIX/flip"
NIXTASTIC_PR_POLL=0.1 run_lax "$pr" android 7000 wait --until queue --timeout 1
printf '%s\n' "$res" | grep -q 'timed out' || { echo "T32: no timeout message"; exit 1; }
( NIXTASTIC_PR_POLL=0.1 "$pr" android 7000 wait --until queue --timeout 1 >/dev/null 2>&1 ); [ $? = 75 ] || { echo "T32: timeout exit must be 75"; exit 1; }
run "$pr" android 7000 rereview
[ "$(grep -c 'full review' "$FIX/posted")" = 1 ] || { echo "T32: rereview did not post once"; exit 1; }
run_lax "$pr" notarepo 1
expect 'unknown repo'
PATH="$oldpath"; export PATH
```

Run → FAIL (`$pr` unset).

- [ ] **Step 2: `scripts/pr.py`**

```python
#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
"""PR status the way the merge queue sees it: checks for the HEAD sha (never
"whatever is attached"), unresolved review threads, queue position, conflicts.
Read-only except `rereview`. Design: notes/agent-tools.md."""
import argparse, json, os, re, subprocess, sys, time

def repos_tsv():
    out = {}
    p = os.environ.get("NIXTASTIC_REPOS_TSV")
    if p and os.path.isfile(p):
        for line in open(p, encoding="utf-8"):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                out[parts[0]] = parts[1]
    return out

def resolve_repo(arg, n):
    m = re.match(r"https?://github\.com/([^/]+/[^/]+)/pull/(\d+)", arg or "")
    if m:
        return m.group(1), int(m.group(2))
    if "/" in arg:
        return arg, int(n)
    table = repos_tsv()
    if arg not in table:
        sys.exit(f"unknown repo: {arg} (workspace dir name, org/repo, or a PR URL)")
    return table[arg], int(n)

def gh(*args):
    try:
        return subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError as e:
        sys.stderr.write(e.stderr or e.stdout or "")
        sys.exit(3)
    except FileNotFoundError:
        sys.exit("gh not found on PATH")

GQL = """query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){
 mergeQueueEntry{position state}
 reviews(last:30){nodes{author{login} state}}
 reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{author{login} path line body}}}}}}}"""

def fetch(repo, n, deep=False):
    owner, name = repo.split("/", 1)
    view = json.loads(gh("pr", "view", str(n), "--repo", repo, "--json",
                         "number,title,state,isDraft,author,headRefOid,headRefName,baseRefName,mergeStateStatus,mergeable,reviewDecision,url"))
    g = json.loads(gh("api", "graphql", "-f", f"query={GQL}", "-F", f"owner={owner}", "-F", f"name={name}", "-F", f"number={n}"))
    pr = g["data"]["repository"]["pullRequest"]
    sha = view["headRefOid"]
    checks = json.loads(gh("api", f"repos/{repo}/commits/{sha}/check-runs?per_page=100")).get("check_runs", [])
    behind = None
    try:  # informational: gh() exits 3 on failure; here that only drops the column
        behind = json.loads(gh("api", f"repos/{repo}/compare/{view['baseRefName']}...{sha}")).get("behind_by")
    except SystemExit:
        pass
    threads = [t for t in pr["reviewThreads"]["nodes"]]
    unresolved = [t for t in threads if not t["isResolved"]]
    ok = [c for c in checks if c["status"] == "completed" and c["conclusion"] in ("success", "skipped", "neutral")]
    fail = [c for c in checks if c["status"] == "completed" and c["conclusion"] not in ("success", "skipped", "neutral", None)]
    pending = [c for c in checks if c["status"] != "completed"]
    replayed = []
    if deep:
        for c in ok:
            if re.search(r"test", c["name"], re.I):
                log = gh("api", f"repos/{repo}/actions/jobs/{c['id']}/logs")
                if "FROM-CACHE" in log:
                    replayed.append(c["name"])
    reviews = {}
    for r in pr["reviews"]["nodes"]:
        reviews.setdefault(r["state"], []).append(r["author"]["login"])
    q = pr.get("mergeQueueEntry")
    return {
        "repo": repo, "number": view["number"], "title": view["title"], "state": view["state"], "draft": view["isDraft"],
        "author": view["author"]["login"], "url": view["url"], "head": sha, "head_branch": view["headRefName"],
        "base": view["baseRefName"], "behind_base": behind, "merge_state": view["mergeStateStatus"],
        "mergeable": view["mergeable"], "review_decision": view.get("reviewDecision"),
        "queue": {"position": q["position"], "state": q["state"]} if q else None,
        "checks": {"ok": len(ok), "fail": len(fail), "pending": len(pending),
                   "pending_names": [c["name"] for c in pending], "fail_names": [c["name"] for c in fail],
                   "replayed_from_cache": replayed, "deep": deep},
        "reviews": reviews, "threads_unresolved": len(unresolved),
        "threads": [{"id": t["id"], "resolved": t["isResolved"],
                     "author": (t["comments"]["nodes"] or [{}])[0].get("author", {}).get("login", "?"),
                     "path": (t["comments"]["nodes"] or [{}])[0].get("path"),
                     "line": (t["comments"]["nodes"] or [{}])[0].get("line"),
                     "body": (t["comments"]["nodes"] or [{}])[0].get("body", "")} for t in threads],
    }

def first_line(s, width=60):
    s = (s or "").strip().splitlines()[0] if (s or "").strip() else ""
    return s if len(s) <= width else s[: width - 1] + "…"

def render_status(d):
    print(f"{d['repo']} #{d['number']}  {d['title']}   {d['state']}  draft:{'yes' if d['draft'] else 'no'}  by {d['author']}")
    bb = "" if d["behind_base"] is None else f"   behind base: {d['behind_base']}"
    print(f"head     {d['head'][:7]}   branch {d['head_branch']}   base {d['base']}{bb}")
    q = d["queue"]; qs = f"position {q['position']} ({q['state']})" if q else "not enqueued"
    conf = {"CONFLICTING": "CONFLICTS — no workflows run until rebased", "MERGEABLE": "none"}.get(d["mergeable"], d["mergeable"] or "?")
    print(f"merge    {d['merge_state']}   unresolved threads: {d['threads_unresolved']}   queue: {qs}   conflicts: {conf}")
    c = d["checks"]; names = ", ".join(c["pending_names"][:2]) or ", ".join(c["fail_names"][:2])
    print(f"checks@{d['head'][:7]}   ok {c['ok']}  fail {c['fail']}  pending {c['pending']}   {names}".rstrip())
    if c["deep"]:
        print(f"cache    {len(c['replayed_from_cache'])} test job(s) replayed FROM-CACHE" + (": " + ", ".join(c["replayed_from_cache"]) if c["replayed_from_cache"] else ""))
    rv = "   ".join(f"{k} {len(v)} ({', '.join(v)})" for k, v in d["reviews"].items()) or "none"
    print(f"reviews  {rv}")
    for t in [t for t in d["threads"] if not t["resolved"]][:6]:
        print(f"threads  {t['author']:<13} {t['path']}:{t['line']}  \"{first_line(t['body'])}\"")
    nxt = []
    if d["threads_unresolved"]:
        nxt.append(f"resolve {d['threads_unresolved']} threads")
    if c["pending"]:
        nxt.append("then checks")
    if d["mergeable"] == "CONFLICTING":
        nxt.append("rebase onto base")
    if d["state"] == "OPEN" and not q:
        nxt.append("`gh pr merge --squash` here means enqueue")
    print("next     " + ("; ".join(nxt) if nxt else ("in queue" if q else "nothing pending")))

def render_threads(d, show_all):
    for t in d["threads"]:
        if t["resolved"] and not show_all:
            continue
        mark = "resolved" if t["resolved"] else "OPEN"
        print(f"{t['id']}  {mark:<8} {t['author']:<13} {t['path']}:{t['line']}")
        for line in (t["body"] or "").strip().splitlines()[:6]:
            print(f"    {line}")

def summary_line(d):
    q = d["queue"]
    return f"{d['state']} threads:{d['threads_unresolved']} pending:{d['checks']['pending']} queue: {'position %s' % q['position'] if q else 'none'}"

def wait(repo, n, until, timeout):
    poll = float(os.environ.get("NIXTASTIC_PR_POLL", "30"))
    deadline = time.time() + timeout
    last = None
    while True:
        d = fetch(repo, n)
        s = summary_line(d)
        if s != last:
            print(s); last = s
        met = {"checks": d["checks"]["pending"] == 0, "queue": d["queue"] is not None, "merged": d["state"] == "MERGED"}[until]
        if met:
            print(f"condition met: {until} ({s})"); return 0
        if time.time() >= deadline:
            print(f"timed out after {timeout}s waiting for {until}; last: {s}", file=sys.stderr); return 75
        time.sleep(poll)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("repo"); ap.add_argument("number", nargs="?", default="0")
    ap.add_argument("cmd", nargs="?", default="status", choices=["status", "threads", "wait", "rereview"])
    ap.add_argument("--json", action="store_true"); ap.add_argument("--deep", action="store_true")
    ap.add_argument("--all", action="store_true"); ap.add_argument("--until", choices=["checks", "queue", "merged"], default="checks")
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()
    repo, n = resolve_repo(a.repo, a.number)
    if a.cmd == "wait":
        return wait(repo, n, a.until, a.timeout)
    if a.cmd == "rereview":
        gh("pr", "comment", str(n), "--repo", repo, "--body", "@coderabbitai full review")
        print(f"posted '@coderabbitai full review' on {repo}#{n}"); return 0
    d = fetch(repo, n, deep=a.deep)
    if a.json:
        json.dump(d, sys.stdout, indent=1); print(); return 0
    if a.cmd == "threads":
        render_threads(d, a.all)
    else:
        render_status(d)
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Flake**

Next to `pins`:

```nix
          # nix run .#pr — PR status for the HEAD sha; encodes six memories.
          pr = pkgs.writeShellApplication {
            name = "meshtastic-pr";
            # gh is the user's install, resolved from PATH (like direnv for
            # doctor) — so the fixture's stub gh is what the tests exercise.
            runtimeInputs = [ pkgs.coreutils pkgs.python313 ];
            runtimeEnv = { NIXTASTIC_PR_PY = "${./scripts/pr.py}"; NIXTASTIC_REPOS_TSV = reposTsv; };
            text = ''exec python3 "$NIXTASTIC_PR_PY" "$@"'';
          };
```

`tools-tests` attrs gain `pr = "${self.packages.${system}.pr}/bin/meshtastic-pr";`.

- [ ] **Step 4: Run, fix, gate, commit**

`nix build .#checks.x86_64-linux.tools-tests --no-link` → `all tests passed`. Live: `just pr android <an open PR number>` prints the screen; check that `checks@<sha>` matches `gh pr view --json headRefOid`. `just check`.

```bash
git add scripts/pr.py flake.nix scripts/tools-tests.sh
git commit -m "pr: PR status for the head SHA — checks, unresolved threads, queue, conflicts; threads, wait (exit 75), rereview"
```

---

### Task 6: Wire the cross-repo skill and the render to the new tools

**Files:**
- Modify: `plugin/skills/meshtastic-cross-repo/SKILL.md` (steps 1, 2, 7)
- Test: existing T24 still passes (render).

- [ ] **Step 1: Skill edits**

Step 1 (Scope): after the coupling table add: "Run `just pins` first: it prints every consumer's pin and whether it is `current`, `behind` or `ahead`, so the implied list starts from facts."
Step 2 (Brief): replace "Run `just brief <repo>` for every confirmed repo." with "Run `just brief --short <repos…>` once, then the full `just brief <repo>` only for repos whose line shows drift, `dirty!`, or open PRs you need to read."
Step 7 (Verify): add "For each PR opened, `just pr <repo> <n>` before claiming anything about CI: it reads checks for the head SHA and the unresolved threads that block android's merge."

- [ ] **Step 2: Re-render, gate, commit**

`nix run .#sync 2>&1 | grep 'plugin '` shows `changed`. `just check`.

```bash
git add plugin/skills
git commit -m "cross-repo skill: pins before scoping, brief --short before full briefs, pr before CI claims"
```

---

### Task 7: Docs and spec amendments

**Files:**
- Modify: `README.md` (tool table), `CLAUDE.md` (one line in protocol step 1, one line trimmed elsewhere), `AGENTS.md` (section), `notes/agent-tools.md` (amendments), `notes/agent-ergonomics-audit.md` ("built" column)

- [ ] **Step 1: README tool table** — add rows for `nix run .#pins`, `nix run .#pr -- <repo> <n> [status|threads|wait|rereview]`, `nix run .#worktree -- --path`, `just wt`, `just in`, `nix run .#brief -- --short a b c`.
- [ ] **Step 2: CLAUDE.md** — in protocol step 1, append: "Every session gets the same spellings injected by the plugin's orient hook; `just pins` and `just pr <repo> <n>` answer coupling and PR state without `gh`." Trim one line elsewhere (the `.#brief` invocation-form sentence is the candidate) so `wc -l` does not grow.
- [ ] **Step 3: AGENTS.md** — under Agent surface add `### pr reads checks by SHA; the hook only orients` with three sentences: why attached checks lie, why threads come from GraphQL, why the hook never says `cd`.
- [ ] **Step 4: Spec amendments in `notes/agent-tools.md`** — pins table: apple row `submodule protobufs @ cd1d340 = v2.8.0+2  ahead`; drop the sdk producer row; add `TAKPacket-SDK → android takpacket-sdk`; `wt`/`in` without `--`; `--short` pins column conditional on the `pins` binary. Evidence: `apple/.gitmodules` has `protobufs`; `meshtastic-sdk` pins `meshtasticProtobufs = "2.7.26"`; nothing pins the SDK by version.
- [ ] **Step 5: Audit note** — add a `built` column to the "Do now" list: 1–5 → commit SHAs.
- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md AGENTS.md notes/agent-tools.md notes/agent-ergonomics-audit.md
git commit -m "docs: pins, pr, wt/in, brief --short and the orient hook; spec amendments from the pin survey"
```

---

### Task 8: Rollout and acceptance

- [ ] **Step 1: Desktop** — `nix run .#sync` (plugin `changed`, `update`), restart. Live proofs, recorded under Evidence → Acceptance runs in `notes/agent-tools.md`:
  - `just pins` — python row `behind: v2.8.0`, apple `ahead`, sdk `behind`.
  - `just pr android <open PR>` — compare `checks@` SHA with `gh pr view --json headRefOid`.
  - Orient: `cd android/.claude/worktrees/<any> && claude -p "In one line: where are you and which primary checkout does this tree belong to?"` — answer names the worktree and `/home/james/meshtastic/android`.
  - `just wt android <wt> pwd` prints the worktree path; `just in kzstd pwd`.
- [ ] **Step 2: Laptop over ssh** (`zsh -lc`, `MESHTASTIC_WORKSPACE` exported): `git pull --ff-only`, `nix run .#sync`, then `just pins`, `just brief --short android apple firmware`, and the orient probe from `~/nixtastic/.claude/worktrees/android-unit-localization-626f77` — the answer must say the org repos are not there.
- [ ] **Step 3: Record, push, memory** — append both machines' results; `git push`; update the shared memory `subproject-2-agent-surface-handoff` (or a new `subproject-3-agent-tools` memory) with status and remaining items.
