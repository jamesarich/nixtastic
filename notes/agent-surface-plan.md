# Agent Surface Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One workspace plugin, `nixtastic`, rendered locally by `sync`, installed on both machines, carrying the shared skills, forwarders to per-repo skills, the two workspace-rule guards, the memory hooks, the Gradle queue and the GitHub MCP server - plus a cross-repo process skill.

**Architecture:** Hand-written plugin source lives tracked at `plugin/`; `sync` renders it into gitignored `.cache/agent-marketplace/` together with generated forwarders and the bundled meshtastic-mcp skills, registers it as a local directory marketplace, migrates the old user-scope hooks out of `settings.json`, and links the queue script. `doctor` checks every step. Nothing for the plugin ever enters the shared memory store.

**Tech Stack:** POSIX sh / bash tool scripts assembled by `writeShellApplication` (ShellCheck at build), jq, sha256sum, fixture tests in `scripts/tools-tests.sh` run inside the Nix sandbox, `claude plugin` CLI at runtime only.

**Spec:** `notes/agent-surface.md`

## Global Constraints

- Workspace repo commits go straight to `main`, sentence-style, **no attribution footers** (`no-claude-attribution-in-commits`).
- Gate before every commit that touches `scripts/`, `plugin/` or `flake.nix`: `just check` (both `nix flake check` commands).
- `CLAUDE.md` stays a small router: the two edits in Task 8 add no net lines.
- No credential is tracked or rendered. The GitHub token is read from `gh` at connect time.
- The store `~/.nixtastic-agent` is never written by any plugin step.
- Nothing is deleted on the laptop by any task; `sync` there only removes settings entries it backs up first.
- New tracked files must be whitelisted in `.gitignore` (deny-by-default).
- Do not use `grep -q` on a chatty pipe inside `tools-tests.sh` (SIGPIPE under `pipefail`); use `expect`/`refuse` on a captured `$res`, or `grep -c`.
- Comments in scripts: terse, the invariant only, no dates or metrics.
- Spec amendments this plan makes (record them in Task 8): the three meshtastic skills are copied at render from `meshtastic-mcp/src/meshtastic_mcp/skills/` rather than moved into `plugin/skills/`; forwarders skip `speckit-*`; the memory hook is copied into the render from `bin/nixtastic-memory-hook`, which `memory_pass` already writes.

## File structure

| Path | Responsibility |
| --- | --- |
| `plugin/.claude-plugin/plugin.json` | manifest; `version` rewritten by `sync` in the render only |
| `plugin/hooks/hooks.json` | four hook entries, `${CLAUDE_PLUGIN_ROOT}` paths |
| `plugin/hooks/block-main-checkout-edits.sh` | worktree edit guard (ported from the laptop) |
| `plugin/hooks/gradle-queue-guard.sh` | Gradle queue guard (ported) |
| `plugin/bin/gradle-queue` | machine-wide Gradle semaphore (ported) |
| `plugin/bin/github-mcp-headers` | prints the bearer header from `gh auth token` |
| `plugin/.mcp.json` | GitHub read-only MCP via `headersHelper` |
| `plugin/skills/meshtastic-cross-repo/SKILL.md` | the process layer |
| `plugin/skills/meshtastic-cross-repo/references/umbrella-template.md` | the umbrella note shape |
| `scripts/plugin.sh` | render, hash, forwarders, register, migrate, queue link, `plugin_pass`, `plugin_input_hash` |
| `scripts/sync.sh` | calls `plugin_pass`; drops the `claude-ws` hint and the skills-install hint |
| `scripts/doctor.sh` | five plugin lines replace the `agent skills` line |
| `scripts/tools-tests.sh` | T24–T30 |
| `flake.nix` | `plugin.sh` in sync/doctor text; `NIXTASTIC_PLUGIN_SRC`; `plugin-lint` check; `pluginSrc` for tests |
| `.gitignore` | `!/plugin/` |
| `CLAUDE.md`, `AGENTS.md`, `README.md`, `notes/agent-memory-sync.md`, `notes/agent-surface.md` | docs |

---

### Task 1: Plugin source tree, gitignore, ShellCheck gate

**Files:**
- Create: `plugin/.claude-plugin/plugin.json`
- Create: `plugin/hooks/hooks.json`
- Create: `plugin/hooks/block-main-checkout-edits.sh`
- Create: `plugin/hooks/gradle-queue-guard.sh`
- Create: `plugin/bin/gradle-queue`
- Create: `plugin/bin/github-mcp-headers`
- Create: `plugin/.mcp.json`
- Modify: `.gitignore` (after the `!/justfile` line)
- Modify: `flake.nix` checks block (after `nix-lint`)

**Interfaces:**
- Produces: the source tree `plugin/` that `plugin_render` (Task 2) copies verbatim; the ported scripts the guard tests (Task 6) exercise.

The laptop's originals are in this session's scratchpad (`scratchpad/laptop/`); when executing from a fresh session fetch them again with `scp james@192.168.1.138:~/.claude/hooks/{block-main-checkout-edits.sh,gradle-queue-guard.sh} james@192.168.1.138:~/.claude/bin/gradle-queue <dir>/`. The port changes only: `/usr/bin/awk`→`awk`, `/usr/bin/grep`→`grep`, and the two references to `~/.claude/hooks/block-main-checkout-edits.sh` / `~/.claude/settings.json` in the worktree guard's denial text, which become "the nixtastic plugin".

- [ ] **Step 1: Manifest**

```json
{
  "name": "nixtastic",
  "version": "0.0.0",
  "description": "Meshtastic workspace: cross-repo process skill, forwarders to each repo's skills, worktree and Gradle guards, shared memory hooks, GitHub read-only MCP. Rendered by nix run .#sync - edit plugin/ in the workspace, never the render.",
  "author": { "name": "James Rich" },
  "license": "GPL-3.0-only"
}
```

Write to `plugin/.claude-plugin/plugin.json`.

- [ ] **Step 2: hooks.json**

```json
{
  "description": "Memory pull/push and the two workspace-rule guards. Scripts resolve under the plugin root.",
  "hooks": {
    "SessionStart": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/nixtastic-memory-hook start", "timeout": 10 } ] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/nixtastic-memory-hook stop", "timeout": 15 } ] }
    ],
    "PreToolUse": [
      { "matcher": "Edit|Write|MultiEdit", "hooks": [ { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/block-main-checkout-edits.sh" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/gradle-queue-guard.sh" } ] }
    ]
  }
}
```

- [ ] **Step 3: Port the worktree guard**

Copy the laptop's `block-main-checkout-edits.sh` to `plugin/hooks/block-main-checkout-edits.sh`. Replace its header comment with:

```bash
#!/usr/bin/env bash
# PreToolUse(Edit|Write|MultiEdit): inside a LINKED worktree, deny an edit whose
# target lands in the main checkout or a sibling worktree. Fails open on any
# internal error - its only job is the cross-tree mistake.
```

Replace the last paragraph of the `reason=` string so it ends:

```
(If you truly meant to edit the main checkout, do it via Bash/git. Blocked by the nixtastic plugin's worktree guard.)"
```

`chmod +x` the file.

- [ ] **Step 4: Port the Gradle guard**

Copy `gradle-queue-guard.sh` to `plugin/hooks/gradle-queue-guard.sh`. Apply:

```bash
sed -i 's|/usr/bin/awk|awk|g; s|/usr/bin/grep|grep|g' plugin/hooks/gradle-queue-guard.sh
chmod +x plugin/hooks/gradle-queue-guard.sh
```

Keep every `~/.claude/bin/gradle-queue` mention: that path is what `sync` links (Task 3) and what the upstream android agent probes.

- [ ] **Step 5: Port the queue**

Copy `gradle-queue` to `plugin/bin/gradle-queue`, then:

```bash
sed -i 's|/usr/bin/grep|grep|g' plugin/bin/gradle-queue
chmod +x plugin/bin/gradle-queue
```

- [ ] **Step 6: Headers helper and .mcp.json**

`plugin/bin/github-mcp-headers`:

```sh
#!/bin/sh
# headersHelper for the hosted GitHub MCP: the token comes from gh at connect
# time, so nothing on disk ever carries it. Empty object when gh is logged out.
tok=$(gh auth token 2>/dev/null) || tok=""
if [ -n "$tok" ]; then
  printf '{"Authorization":"Bearer %s"}\n' "$tok"
else
  printf '{}\n'
fi
```

`chmod +x`. `plugin/.mcp.json`:

```json
{
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp/readonly",
      "headersHelper": "${CLAUDE_PLUGIN_ROOT}/bin/github-mcp-headers"
    }
  }
}
```

- [ ] **Step 7: Whitelist and lint check**

`.gitignore`, after `!/justfile`:

```
# The workspace plugin's hand-written source. sync renders it (plus generated
# forwarders) into .cache/agent-marketplace/, which stays ignored.
!/plugin/
```

`flake.nix`, inside `checks`, after the `nix-lint` attribute:

```nix
          # ShellCheck over the plugin's own scripts. writeShellApplication
          # gates scripts/*.sh at build; these ship verbatim, so nothing
          # else reads them.
          plugin-lint =
            pkgs.runCommand "nixtastic-plugin-lint"
              {
                nativeBuildInputs = [ pkgs.shellcheck ];
              }
              ''
                shellcheck -s bash ${self}/plugin/hooks/*.sh ${self}/plugin/bin/gradle-queue
                shellcheck -s sh ${self}/plugin/bin/github-mcp-headers
                touch "$out"
              '';
```

- [ ] **Step 8: Run the lint check, fix findings**

Run: `git add -A plugin .gitignore flake.nix && nix build .#checks.x86_64-linux.plugin-lint --no-link`
Expected: succeeds. If ShellCheck reports on the ported scripts, fix in place (quote variables, `read -r`), never suppress without a reason comment.

- [ ] **Step 9: Commit**

```bash
git add plugin .gitignore flake.nix
git commit -m "plugin: source tree for the nixtastic workspace plugin - manifest, hooks, ported guards and queue, GitHub MCP"
```

---

### Task 2: Render, forwarders, content hash

**Files:**
- Create: `scripts/plugin.sh`
- Modify: `flake.nix` - `toolEnv` gets `NIXTASTIC_PLUGIN_SRC`; `sync` and `doctor` `text` include `plugin.sh`; `tools-tests` gets `pluginSrc`
- Modify: `scripts/sync.sh` - replace the `claude-ws` hint block and the skills-missing hint with `plugin_pass`
- Test: `scripts/tools-tests.sh` - T24, T25

**Interfaces:**
- Consumes: `NIXTASTIC_REPOS_TSV` (dir, repo, shell), `$root/bin/nixtastic-memory-hook` written by `memory_pass`.
- Produces: `plugin_render <root>` (prints `rendered <n-forwarders> <changed|unchanged> <version>`), `plugin_input_hash <root>`, `plugin_render_dir <root>` = `$root/.cache/agent-marketplace`, `plugin_pass <root>`; constant `NIXTASTIC_FORWARD_SKIP='speckit-'`. Task 3 adds register/migrate/link into `plugin_pass`.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/tools-tests.sh` before `echo "all tests passed"`:

```bash
echo "--- T24: plugin render - source copied, bundled skills copied, forwarders generated and prefixed, speckit skipped"
# Two repos shipping the same skill name, one unique, one speckit, one symlinked.
mkskill() { mkdir -p "$1"; printf -- '---\nname: %s\ndescription: %s\n---\nbody\n' "$2" "$3" > "$1/SKILL.md"; }
mkskill "$root/android/.claude/skills/code-review"  code-review "Review android the repo way"
mkskill "$root/android/.claude/skills/baseline"     baseline    "Run the android baseline"
mkskill "$root/apple/.claude/skills/code-review"    code-review "Review apple the repo way"
mkskill "$root/apple/.claude/skills/speckit-plan"   speckit-plan "Spec Kit plan"
mkdir -p "$root/apple/.agents/skills/marketing"
printf -- '---\nname: marketing\ndescription: Capture marketing shots\n---\nbody\n' > "$root/apple/.agents/skills/marketing/SKILL.md"
ln -s ../../.agents/skills/marketing "$root/apple/.claude/skills/marketing"
mkskill "$root/meshtastic-mcp/src/meshtastic_mcp/skills/meshtastic-device-ops" meshtastic-device-ops "Drive devices"
run "$sync"
expect 'plugin +rendered'
rd="$root/.cache/agent-marketplace"
[ -f "$rd/.claude-plugin/marketplace.json" ] || { echo "T24: no marketplace.json"; exit 1; }
[ "$(jq -r '.plugins[0].source' "$rd/.claude-plugin/marketplace.json")" = ./nixtastic ] || { echo "T24: marketplace source"; exit 1; }
p="$rd/nixtastic"
[ -f "$p/hooks/hooks.json" ] && [ -x "$p/hooks/gradle-queue-guard.sh" ] && [ -x "$p/bin/gradle-queue" ] || { echo "T24: source not copied"; exit 1; }
[ -x "$p/hooks/nixtastic-memory-hook" ] || { echo "T24: memory hook not rendered into the plugin"; exit 1; }
[ -f "$p/skills/meshtastic-device-ops/SKILL.md" ] || { echo "T24: bundled mcp skill not copied"; exit 1; }
for f in android-code-review android-baseline apple-code-review apple-marketing; do
  [ -f "$p/skills/$f/SKILL.md" ] || { echo "T24: forwarder $f missing"; ls "$p/skills"; exit 1; }
done
[ ! -e "$p/skills/apple-speckit-plan" ] || { echo "T24: speckit forwarded"; exit 1; }
grep -q '^name: android-code-review$' "$p/skills/android-code-review/SKILL.md" || { echo "T24: forwarder name"; exit 1; }
grep -q '^description: "\[android\] Review android the repo way"$' "$p/skills/android-code-review/SKILL.md" || { echo "T24: forwarder description"; cat "$p/skills/android-code-review/SKILL.md"; exit 1; }
grep -qF "$root/android/.claude/skills/code-review" "$p/skills/android-code-review/SKILL.md" || { echo "T24: forwarder lacks absolute target"; exit 1; }
grep -qF 'just brief android' "$p/skills/android-code-review/SKILL.md" || { echo "T24: forwarder lacks brief"; exit 1; }
# Version is not the source placeholder.
[ "$(jq -r .version "$p/.claude-plugin/plugin.json")" != 0.0.0 ] || { echo "T24: version not written"; exit 1; }
# The root skills dir holding only bundled copies is retired.
mkdir -p "$root/.claude/skills/meshtastic-device-ops"; : > "$root/.claude/skills/meshtastic-device-ops/SKILL.md"
run "$sync"
[ ! -d "$root/.claude/skills" ] || { echo "T24: root .claude/skills kept"; exit 1; }
# A root skills dir with a foreign entry is left alone, warned.
mkdir -p "$root/.claude/skills/mine"; : > "$root/.claude/skills/mine/SKILL.md"
run "$sync"
expect 'WARN .*\.claude/skills'
[ -d "$root/.claude/skills/mine" ] || { echo "T24: foreign root skill removed"; exit 1; }
rm -rf "$root/.claude/skills"

echo "--- T25: plugin render is idempotent; a source change bumps the version once"
v1=$(jq -r .version "$p/.claude-plugin/plugin.json")
before=$(find "$p" -type f -exec ls -l --time-style=full-iso {} + | sort)
run "$sync"
expect 'plugin +rendered .*unchanged'
[ "$v1" = "$(jq -r .version "$p/.claude-plugin/plugin.json")" ] || { echo "T25: version churned"; exit 1; }
[ "$before" = "$(find "$p" -type f -exec ls -l --time-style=full-iso {} + | sort)" ] || { echo "T25: files rewritten"; exit 1; }
sleep 1
printf -- '---\nname: baseline\ndescription: Run the android baseline, now different\n---\nbody\n' > "$root/android/.claude/skills/baseline/SKILL.md"
run "$sync"
expect 'plugin +rendered .*changed'
v2=$(jq -r .version "$p/.claude-plugin/plugin.json")
[ "$v1" != "$v2" ] || { echo "T25: version not bumped"; exit 1; }
grep -q 'now different' "$p/skills/android-baseline/SKILL.md" || { echo "T25: forwarder not refreshed"; exit 1; }
run "$sync"
expect 'plugin +rendered .*unchanged'
[ "$v2" = "$(jq -r .version "$p/.claude-plugin/plugin.json")" ] || { echo "T25: version churned after bump"; exit 1; }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix build .#checks.x86_64-linux.tools-tests --no-link 2>&1 | tail -5`
Expected: FAIL at T24 with `EXPECT FAILED: plugin +rendered`.

- [ ] **Step 3: Write `scripts/plugin.sh`**

```bash
# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# The nixtastic plugin: hand-written source in plugin/ (NIXTASTIC_PLUGIN_SRC,
# a store path), rendered per machine into .cache/agent-marketplace/ with the
# generated forwarders, the bundled meshtastic-mcp skills and the memory hook.
# Derived from the workspace plus local checkouts, so it never enters the
# memory store. Design: notes/agent-surface.md.

plugin_render_dir() { printf '%s/.cache/agent-marketplace\n' "$1"; }
plugin_name() { printf 'nixtastic\n'; }
NIXTASTIC_FORWARD_SKIP='speckit-'
NIXTASTIC_BUNDLED_SKILLS='meshtastic-device-ops meshtastic-e2e meshtastic-org-knowledge'

# Every input the render depends on, hashed in a stable order. Same
# function for sync (did it change?) and doctor (is the render stale?).
plugin_input_hash() {
  {
    find "$NIXTASTIC_PLUGIN_SRC" -type f | sort | while read -r f; do
      printf '%s\n' "${f#"$NIXTASTIC_PLUGIN_SRC"}"; cat "$f"
    done
    [ -f "$1/bin/nixtastic-memory-hook" ] && cat "$1/bin/nixtastic-memory-hook"
    [ -d "$1/meshtastic-mcp/src/meshtastic_mcp/skills" ] &&
      find "$1/meshtastic-mcp/src/meshtastic_mcp/skills" -type f | sort | while read -r f; do
        printf '%s\n' "${f#"$1"}"; cat "$f"
      done
    plugin_forward_pairs "$1" | while IFS=$'\t' read -r dir skill _; do
      printf '%s/%s\n' "$dir" "$skill"; cat "$1/$dir/.claude/skills/$skill/SKILL.md"
    done
  } | sha256sum | cut -c1-64
}

# "<dir>\t<skill>\t<description>" for every repo skill that gets a forwarder.
plugin_forward_pairs() {
  while IFS=$'\t' read -r dir _ _; do
    [ -d "$1/$dir/.claude/skills" ] || continue
    for s in "$1/$dir/.claude/skills"/*/; do
      s=${s%/}; name=${s##*/}
      [ -f "$s/SKILL.md" ] || continue
      case "$name" in "$NIXTASTIC_FORWARD_SKIP"*) continue ;; esac
      desc=$(sed -n 's/^description:[[:space:]]*//p' "$s/SKILL.md" | head -1 | sed 's/^"\(.*\)"$/\1/; s/\\"/"/g')
      printf '%s\t%s\t%s\n' "$dir" "$name" "$desc"
    done
  done < "$NIXTASTIC_REPOS_TSV"
}

# $1 = out dir, $2 = root, $3 = dir, $4 = skill, $5 = description.
plugin_write_forwarder() {
  mkdir -p "$1"
  target="$2/$3/.claude/skills/$4"
  {
    echo '---'
    printf 'name: %s-%s\n' "$3" "$4"
    printf 'description: "[%s] %s"\n' "$3" "$(printf '%s' "$5" | sed 's/"/\\"/g')"
    echo '---'
    printf '# %s: %s (forwarder)\n\n' "$3" "$4"
    printf 'This skill lives in the `%s` repo and is only reachable from a session\n' "$3"
    echo 'started inside it; this forwarder makes it visible from anywhere in the workspace.'
    echo
    printf '1. Run `just brief %s` from the workspace root (or `nix run .#brief -- %s`)\n' "$3" "$3"
    echo '   and read what it prints - branch, drift, and the docs that repo expects read.'
    printf '2. Read and follow, exactly as written:\n\n       %s/SKILL.md\n\n' "$target"
    printf '   Its base directory is `%s`; its `references/` and\n' "$target"
    echo '   scripts resolve relative to that directory, not to this plugin.'
    printf '3. Work inside `%s` (or a worktree of it) and follow that repo'"'"'s own conventions.\n' "$2/$3"
  } > "$1/SKILL.md"
}

# Render into a temp tree, compare the input hash with the stored one, then
# swap. Prints: rendered <forwarders> <changed|unchanged> <version>.
plugin_render() {
  root="$1"; rd=$(plugin_render_dir "$root"); name=$(plugin_name)
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.claude-plugin" "$tmp/$name"
  cp -R "$NIXTASTIC_PLUGIN_SRC"/. "$tmp/$name/"
  chmod -R u+w "$tmp"
  [ -f "$root/bin/nixtastic-memory-hook" ] && cp "$root/bin/nixtastic-memory-hook" "$tmp/$name/hooks/nixtastic-memory-hook"
  for s in $NIXTASTIC_BUNDLED_SKILLS; do
    src="$root/meshtastic-mcp/src/meshtastic_mcp/skills/$s"
    [ -d "$src" ] && cp -R "$src" "$tmp/$name/skills/$s"
  done
  n=0
  while IFS=$'\t' read -r dir skill desc; do
    [ -n "$dir" ] || continue
    plugin_write_forwarder "$tmp/$name/skills/$dir-$skill" "$root" "$dir" "$skill" "$desc"
    n=$((n + 1))
  done <<< "$(plugin_forward_pairs "$root")"
  jq -n --arg n "$name" '{name: $n, owner: {name: "James Rich"},
    plugins: [{name: $n, source: ("./" + $n), description: "Meshtastic workspace plugin, rendered by nix run .#sync"}]}' \
    > "$tmp/.claude-plugin/marketplace.json"
  hash=$(plugin_input_hash "$root")
  old=$(cat "$rd/.hash" 2>/dev/null || true)
  if [ "$hash" = "$old" ] && [ -f "$rd/$name/.claude-plugin/plugin.json" ]; then
    version=$(jq -r .version "$rd/$name/.claude-plugin/plugin.json")
    state=unchanged
  else
    version="0.$(date +%s).0"
    state=changed
  fi
  jq --arg v "$version" '.version = $v' "$tmp/$name/.claude-plugin/plugin.json" > "$tmp/pj" && mv "$tmp/pj" "$tmp/$name/.claude-plugin/plugin.json"
  find "$tmp" -type f -name '*.sh' -exec chmod +x {} +
  chmod +x "$tmp/$name/bin"/* "$tmp/$name/hooks/nixtastic-memory-hook" 2>/dev/null || true
  if [ "$state" = changed ] || [ ! -d "$rd/$name" ]; then
    mkdir -p "$rd"
    rm -rf "$rd/$name" "$rd/.claude-plugin"
    mv "$tmp/$name" "$rd/$name"; mv "$tmp/.claude-plugin" "$rd/.claude-plugin"
    printf '%s\n' "$hash" > "$rd/.hash"
  fi
  rm -rf "$tmp"
  printf 'rendered %s %s %s\n' "$n" "$state" "$version"
}

# The root .claude/skills held copies of the bundled three, installed by a
# uv command sync used to print. The plugin carries them now.
plugin_retire_root_skills() {
  d="$1/.claude/skills"
  [ -d "$d" ] || return 0
  for e in "$d"/*; do
    [ -e "$e" ] || continue
    case " $NIXTASTIC_BUNDLED_SKILLS " in
      *" ${e##*/} "*) ;;
      *) echo "  WARN      .claude/skills has ${e##*/}, not a bundled copy - left alone; move it into plugin/skills/ or delete it"; return 0 ;;
    esac
  done
  rm -rf "$d"
  echo "  plugin    retired .claude/skills (bundled copies now ship in the plugin)"
}

plugin_pass() {
  root="$1"
  out=$(plugin_render "$root")
  # shellcheck disable=SC2086
  set -- $out
  printf '  plugin    rendered %s forwarder(s) into %s  (%s, version %s)\n' "$2" "$(plugin_render_dir "$root")" "$3" "$4"
  plugin_retire_root_skills "$root"
}
```

- [ ] **Step 4: Wire into the flake**

In `flake.nix` `toolEnv`, add:

```nix
            NIXTASTIC_PLUGIN_SRC = "${./plugin}";
```

In the `sync` and `doctor` packages, insert `+ builtins.readFile ./scripts/plugin.sh` after the `memory.sh` line. In the `tools-tests` runCommand attrs add `pluginSrc = "${./plugin}";` (used by Task 6).

- [ ] **Step 5: Wire into sync.sh**

Replace the block from the comment `# Skills cannot be aggregated the way subagents were` through the `fi` that closes `if [ -n "$skill_repos" ]; then` with:

```bash
# The --add-dir launcher stays as an edge case (loads a repo's CLAUDE.md
# too); the plugin's forwarders are the everyday door to repo skills.
write_claude_launcher "$root"
```

Then, in the block after `memory_pass`, delete the four lines from `# The bundled skills are what turn 90 tool names into a` through the `fi` that prints the `uv run meshtastic-mcp skills install` hint. Add, immediately after the `memory_pass` call line:

```bash
plugin_pass "$root"
```

(`memory_pass` runs first so `bin/nixtastic-memory-hook` exists when the render copies it.)

- [ ] **Step 6: Run tests**

Run: `nix build .#checks.x86_64-linux.tools-tests --no-link 2>&1 | tail -5`
Expected: T24 and T25 pass; earlier tests still pass. Check the whole run printed `all tests passed` (the build succeeds).

- [ ] **Step 7: Gate and commit**

```bash
just check
git add scripts/plugin.sh scripts/sync.sh scripts/tools-tests.sh flake.nix
git commit -m "sync: render the nixtastic plugin - forwarders per repo skill, bundled skills, memory hook, content-hash version"
```

---

### Task 3: Register, migrate hooks, link the queue

**Files:**
- Modify: `scripts/plugin.sh` - add `plugin_installed_version`, `plugin_register`, `plugin_migrate_hooks`, `plugin_link_queue`; extend `plugin_pass`
- Modify: `scripts/sync.sh` - `--install-hooks` prints a pointer
- Test: `scripts/tools-tests.sh` - T26, T27

**Interfaces:**
- Consumes: `plugin_render_dir`, `plugin_name`, `claude_projects_dir` (memory.sh; `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects`).
- Produces: `plugin_installed_version` (prints version or empty), `plugin_register <root> <version>` (prints one status word: `skipped`, `added+installed`, `installed`, `updated`, `current`), `plugin_migrate_hooks` (prints `migrated <n>` or `nothing`), `plugin_link_queue <root>` (prints `linked`, `current`, or `linked backup=<path>`). Doctor (Task 4) reuses the first and the hook-basename list `NIXTASTIC_PLUGIN_HOOK_NAMES`.

- [ ] **Step 1: Write the failing tests**

Append before `echo "all tests passed"`:

```bash
echo "--- T26: hook migration - only after the plugin is installed; ours removed, others kept, backup once"
cfg="$HOME/.claude/settings.json"
cat > "$cfg" <<EOF
{ "model": "opus", "hooks": {
  "SessionStart": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "herdr session" } ] },
                    { "matcher": "*", "hooks": [ { "type": "command", "command": "$root/bin/nixtastic-memory-hook start" } ] } ],
  "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "command": "$root/bin/nixtastic-memory-hook stop" } ] } ],
  "PreToolUse": [ { "matcher": "Edit|Write|MultiEdit", "hooks": [ { "type": "command", "command": "bash \"\$HOME/.claude/hooks/block-main-checkout-edits.sh\"" } ] },
                  { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"\$HOME/.claude/hooks/gradle-queue-guard.sh\"" } ] },
                  { "matcher": "Bash", "hooks": [ { "type": "command", "command": "paseo hooks claude PreToolUse" } ] } ] } }
EOF
rm -f "$HOME/.claude/plugins/installed_plugins.json"
run "$sync"
expect 'plugin +register +skipped'
expect 'plugin +hooks +kept in settings.json until the plugin is installed'
[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 2 ] || { echo "T26: migrated before install"; exit 1; }
# Pretend the CLI installed it.
mkdir -p "$HOME/.claude/plugins"
v=$(jq -r .version "$root/.cache/agent-marketplace/nixtastic/.claude-plugin/plugin.json")
jq -n --arg v "$v" '{version: 2, plugins: {"nixtastic@nixtastic": [{scope: "user", version: $v}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
jq -n --arg p "$root/.cache/agent-marketplace" '{nixtastic: {source: {source: "directory", path: $p}, installLocation: $p}}' > "$HOME/.claude/plugins/known_marketplaces.json"
run "$sync"
expect 'plugin +hooks +migrated 4'
[ -f "$cfg.nixtastic-bak-plugin" ] || { echo "T26: no backup"; exit 1; }
[ "$(jq -r .model "$cfg")" = opus ] || { echo "T26: unrelated setting lost"; exit 1; }
[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 1 ] || { echo "T26: memory start not removed / herdr lost"; cat "$cfg"; exit 1; }
jq -e '.hooks.SessionStart[0].hooks[0].command == "herdr session"' "$cfg" >/dev/null || { echo "T26: herdr rewritten"; exit 1; }
[ "$(jq '.hooks.Stop | length' "$cfg")" = 0 ] || { echo "T26: memory stop not removed"; exit 1; }
[ "$(jq '.hooks.PreToolUse | length' "$cfg")" = 1 ] || { echo "T26: guards not removed / paseo lost"; cat "$cfg"; exit 1; }
jq -e '.hooks.PreToolUse[0].hooks[0].command | test("paseo")' "$cfg" >/dev/null || { echo "T26: paseo lost"; exit 1; }
expect 'restart claude'
cp "$cfg.nixtastic-bak-plugin" "$HOME/bak1"
run "$sync"
expect 'plugin +hooks +nothing to migrate'
cmp -s "$HOME/bak1" "$cfg.nixtastic-bak-plugin" || { echo "T26: backup rewritten on a no-op"; exit 1; }
# --install-hooks now points at the plugin instead of writing.
run "$sync" --install-hooks
expect 'hooks ship in the nixtastic plugin'
[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 1 ] || { echo "T26: --install-hooks wrote entries"; exit 1; }

echo "--- T27: queue symlink - created, idempotent, a real file is backed up; register reports version drift"
q="$HOME/.claude/bin/gradle-queue"
[ -L "$q" ] || { echo "T27: no symlink"; exit 1; }
[ "$(readlink "$q")" = "$root/.cache/agent-marketplace/nixtastic/bin/gradle-queue" ] || { echo "T27: wrong target $(readlink "$q")"; exit 1; }
run "$sync"
expect 'plugin +queue +current'
rm "$q"; echo old > "$q"
run "$sync"
expect 'plugin +queue +linked .*backup'
[ -f "$q.pre-plugin" ] && [ -L "$q" ] || { echo "T27: real file not backed up"; exit 1; }
# Installed version behind the render: register says so (claude absent, so it cannot act).
jq '.plugins["nixtastic@nixtastic"][0].version = "0.1.0"' "$HOME/.claude/plugins/installed_plugins.json" > "$HOME/ip" && mv "$HOME/ip" "$HOME/.claude/plugins/installed_plugins.json"
run "$sync"
expect 'plugin +register +skipped .*claude plugin update'
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix build .#checks.x86_64-linux.tools-tests --no-link 2>&1 | tail -5`
Expected: FAIL at T26, `EXPECT FAILED: plugin +register +skipped`.

- [ ] **Step 3: Implement register, migrate, link**

Append to `scripts/plugin.sh` (before `plugin_pass`), and replace `plugin_pass`:

```bash
NIXTASTIC_PLUGIN_HOOK_NAMES='nixtastic-memory-hook block-main-checkout-edits.sh gradle-queue-guard.sh'

plugin_config_dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

plugin_installed_version() {
  f="$(plugin_config_dir)/plugins/installed_plugins.json"
  [ -f "$f" ] || return 0
  jq -r --arg k "$(plugin_name)@$(plugin_name)" '.plugins[$k][0].version // empty' "$f" 2>/dev/null
}

plugin_marketplace_known() {
  f="$(plugin_config_dir)/plugins/known_marketplaces.json"
  [ -f "$f" ] && jq -e --arg k "$(plugin_name)" '.[$k]' "$f" >/dev/null 2>&1
}

# The CLI owns install state; we only call it, and only when needed. Without
# claude on PATH (the test sandbox, a server) say what would run.
# $1 = root, $2 = rendered version. Prints one status word, then the fix.
plugin_register() {
  rd=$(plugin_render_dir "$1"); name=$(plugin_name); inst=$(plugin_installed_version)
  want=""
  if ! plugin_marketplace_known; then want="claude plugin marketplace add $rd && claude plugin install $name@$name"
  elif [ -z "$inst" ]; then want="claude plugin install $name@$name"
  elif [ "$inst" != "$2" ]; then want="claude plugin update $name@$name"
  fi
  [ -z "$want" ] && { echo current; return 0; }
  if ! command -v claude >/dev/null 2>&1; then printf 'skipped\t%s\n' "$want"; return 0; fi
  if sh -c "$want" >/dev/null 2>&1; then
    case "$want" in *marketplace*) echo added+installed ;; *install*) echo installed ;; *) echo updated ;; esac
  else
    printf 'failed\t%s\n' "$want"
  fi
}

# Remove the user-scope entries the plugin now provides, matched by script
# basename so both machines' paths match. Only once the plugin is installed:
# removing first would leave sessions with no memory hook at all.
plugin_migrate_hooks() {
  cfg="$(plugin_config_dir)/settings.json"
  [ -f "$cfg" ] || { echo nothing; return 0; }
  [ -n "$(plugin_installed_version)" ] || { echo deferred; return 0; }
  pat=$(printf '%s' "$NIXTASTIC_PLUGIN_HOOK_NAMES" | tr ' ' '|')
  n=$(jq --arg p "$pat" '[.hooks // {} | .[] | .[] | .hooks[]? | select(.command | test($p))] | length' "$cfg")
  [ "$n" -gt 0 ] || { echo nothing; return 0; }
  cp "$cfg" "$cfg.nixtastic-bak-plugin"
  jq --arg p "$pat" '
    .hooks |= (with_entries(.value |= (map(.hooks |= map(select(.command | test($p) | not))) | map(select(.hooks | length > 0)))))
  ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  printf 'migrated %s\n' "$n"
}

# The upstream android agent and the guard probe this exact path.
plugin_link_queue() {
  q="$(plugin_config_dir)/bin/gradle-queue"; target="$(plugin_render_dir "$1")/$(plugin_name)/bin/gradle-queue"
  mkdir -p "${q%/*}"
  if [ -L "$q" ] && [ "$(readlink "$q")" = "$target" ]; then echo current; return 0; fi
  bak=""
  if [ -e "$q" ] && [ ! -L "$q" ]; then mv "$q" "$q.pre-plugin"; bak=" backup=$q.pre-plugin"; fi
  ln -sfn "$target" "$q"
  printf 'linked%s\n' "$bak"
}

plugin_pass() {
  root="$1"
  out=$(plugin_render "$root")
  # shellcheck disable=SC2086
  set -- $out
  version="$4"
  printf '  plugin    rendered %s forwarder(s) into %s  (%s, version %s)\n' "$2" "$(plugin_render_dir "$root")" "$3" "$version"
  plugin_retire_root_skills "$root"
  restart=false
  reg=$(plugin_register "$root" "$version")
  case "$reg" in
    current) printf '  plugin    register  current (%s)\n' "$version" ;;
    skipped*) printf '  plugin    register  skipped - claude not on PATH; run:  %s\n' "${reg#*$'\t'}" ;;
    failed*)  printf '  WARN      plugin register failed; run by hand:  %s\n' "${reg#*$'\t'}" ;;
    *) printf '  plugin    register  %s\n' "$reg"; restart=true ;;
  esac
  mig=$(plugin_migrate_hooks)
  case "$mig" in
    deferred) echo '  plugin    hooks     kept in settings.json until the plugin is installed' ;;
    nothing)  echo '  plugin    hooks     nothing to migrate' ;;
    *) printf '  plugin    hooks     migrated %s user-scope entr(ies) now provided by the plugin  (backup: settings.json.nixtastic-bak-plugin)\n' "${mig#migrated }"
       echo '            the old ~/.claude/hooks/*.sh files are unused; delete them when convenient'
       restart=true ;;
  esac
  printf '  plugin    queue     %s\n' "$(plugin_link_queue "$root")"
  [ "$restart" = true ] && echo '            restart claude to load the plugin hooks and MCP server'
  return 0
}
```

In `sync.sh`'s `memory_pass`, replace the `if [ "$hooks" = true ]; then ... fi` chain (from `if [ "$hooks" = true ]; then` through the matching `fi` that ends the `elif ! grep -q nixtastic-memory-hook` branch) with:

```bash
  if [ "$hooks" = true ]; then
    echo '            hooks ship in the nixtastic plugin now - nothing to install; sync registers the plugin'
  fi
```

Update the `--install-hooks` line in the header comment of `sync.sh` to: `#   --install-hooks  (retired) the hooks ship in the plugin; prints a pointer`.

- [ ] **Step 4: Run tests**

Run: `nix build .#checks.x86_64-linux.tools-tests --no-link 2>&1 | tail -5`
Expected: T21 still passes (it tests the hook script itself, and `--install-hooks` is only asserted in T26 now - **edit T21**: remove the lines from `run "$sync" --install-hooks` through `[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 2 ] || { echo "T21: second install duplicated the entry"; exit 1; }` and replace with `run "$sync"` plus `[ -x "$root/bin/nixtastic-memory-hook" ] || { echo "T21: hook script missing"; exit 1; }`). T22's `expect 'ok +memory hooks'` will change in Task 4; leave it for now and expect T22 to fail on that line only if doctor still checks user-scope hooks - it does, and the fixture cfg now lacks them. Fix by moving T26's migration to run *after* T22, or simplest: in T26 write the cfg fixture fresh (already does), and in T22 keep the assertion - T22 runs before T26 so it still sees the T21 state. Confirm order: T21, T22, T23, T24…T27. Good; no change needed.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add scripts/plugin.sh scripts/sync.sh scripts/tools-tests.sh
git commit -m "sync: register the plugin, migrate user-scope hooks into it, link the gradle queue"
```

---

### Task 4: doctor lines

**Files:**
- Modify: `scripts/doctor.sh` - replace the `agent skills` check; add five plugin lines and the extras line; retire the `memory hooks` user-scope check in favour of the plugin hook check
- Test: `scripts/tools-tests.sh` - T28; adjust T22's `expect 'ok +memory hooks'`

**Interfaces:**
- Consumes: `plugin_input_hash`, `plugin_render_dir`, `plugin_name`, `plugin_installed_version`, `plugin_marketplace_known`, `plugin_config_dir`, `NIXTASTIC_PLUGIN_HOOK_NAMES`.

- [ ] **Step 1: Write the failing test**

Append before `echo "all tests passed"`:

```bash
echo "--- T28: doctor - plugin render, install, hooks, queue, github mcp, extras"
run_lax "$doctor"
expect 'ok +plugin render'
expect 'WARN +plugin install .*0\.1\.0'
expect 'ok +plugin hooks'
expect 'ok +gradle queue'
expect 'ok +github mcp'
expect 'agent extras'
refuse 'agent skills'
# Stale render after a source edit.
printf -- '---\nname: baseline\ndescription: changed again\n---\nbody\n' > "$root/android/.claude/skills/baseline/SKILL.md"
run_lax "$doctor"
expect 'WARN +plugin render +stale'
run "$sync"
# Duplicate hook: a user-scope entry with a plugin hook's basename.
jq '.hooks.Stop = [{matcher: "", hooks: [{type: "command", command: "/elsewhere/nixtastic-memory-hook stop"}]}]' "$cfg" > "$HOME/c" && mv "$HOME/c" "$cfg"
run_lax "$doctor"
expect 'WARN +plugin hooks .*nixtastic-memory-hook'
jq 'del(.hooks.Stop)' "$cfg" > "$HOME/c" && mv "$HOME/c" "$cfg"
# GitHub registered twice: user scope too.
echo '{"mcpServers":{"github":{"type":"http","url":"x"}}}' > "$HOME/.claude.json"
run_lax "$doctor"
expect 'WARN +github mcp .*user scope'
rm "$HOME/.claude.json"
# Queue symlink gone.
rm "$HOME/.claude/bin/gradle-queue"
run_lax "$doctor"
expect 'WARN +gradle queue'
run "$sync"
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix build .#checks.x86_64-linux.tools-tests --no-link 2>&1 | tail -5`
Expected: FAIL at T28, `EXPECT FAILED: ok +plugin render`.

- [ ] **Step 3: Implement in doctor.sh**

Replace the `if [ -d "$root/.claude/skills/meshtastic-device-ops" ]; then … fi` block with:

```bash
# --- the plugin -----------------------------------------
# Rendered locally, installed by the CLI; every step here can be stale
# without an error anywhere else.
rd=$(plugin_render_dir "$root"); pname=$(plugin_name)
pj="$rd/$pname/.claude-plugin/plugin.json"
if [ ! -f "$pj" ]; then
  warn "plugin render" "not rendered"
  fix "nix run .#sync"
elif [ "$(cat "$rd/.hash" 2>/dev/null)" != "$(plugin_input_hash "$root")" ]; then
  warn "plugin render" "stale - plugin/ or a repo skill changed since"
  fix "nix run .#sync"
else
  ok "plugin render" "$rd  ($(find "$rd/$pname/skills" -mindepth 1 -maxdepth 1 -type d | wc -l) skills)"
fi
rv=$(jq -r .version "$pj" 2>/dev/null || true)
iv=$(plugin_installed_version)
mk=$(jq -r --arg k "$pname" '.[$k].source.path // empty' "$(plugin_config_dir)/plugins/known_marketplaces.json" 2>/dev/null || true)
if ! plugin_marketplace_known; then
  warn "plugin install" "marketplace not registered"
  fix "claude plugin marketplace add $rd && claude plugin install $pname@$pname"
elif [ "$mk" != "$rd" ]; then
  warn "plugin install" "marketplace points at $mk, render is $rd"
  fix "claude plugin marketplace remove $pname && nix run .#sync"
elif [ -z "$iv" ]; then
  warn "plugin install" "not installed"
  fix "claude plugin install $pname@$pname"
elif [ "$iv" != "$rv" ]; then
  warn "plugin install" "installed $iv, rendered $rv"
  fix "claude plugin update $pname@$pname   (sync does this when claude is on PATH)"
else
  ok "plugin install" "$pname@$pname $iv"
fi
cfg="$(plugin_config_dir)/settings.json"
dup=""
if [ -f "$cfg" ]; then
  for h in $NIXTASTIC_PLUGIN_HOOK_NAMES; do
    if jq -e --arg h "$h" '[.hooks // {} | .[] | .[] | .hooks[]? | select(.command | test($h))] | length > 0' "$cfg" >/dev/null 2>&1; then
      dup="$dup $h"
    fi
  done
fi
if [ -n "$dup" ]; then
  warn "plugin hooks" "also in user-scope settings.json - fire twice:$dup"
  fix "nix run .#sync   (migrates them once the plugin is installed)"
else
  ok "plugin hooks" "plugin only, no user-scope duplicate"
fi
q="$(plugin_config_dir)/bin/gradle-queue"
if [ -L "$q" ] && [ -x "$(readlink "$q")" ]; then
  ok "gradle queue" "$q"
else
  warn "gradle queue" "no symlink at $q"
  fix "nix run .#sync"
fi
if jq -e '.mcpServers.github' "$HOME/.claude.json" >/dev/null 2>&1; then
  warn "github mcp" "registered in user scope too - the plugin ships it; tools appear twice"
  fix "claude mcp remove -s user github"
else
  ok "github mcp" "plugin only"
fi
# Informational: what this machine has that the core does not.
np=$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value) | .key' "$cfg" 2>/dev/null | grep -vc "^$pname@" || true)
ns=$(find "$(plugin_config_dir)/skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
printf '  info  %-18s %s other plugin(s), %s user skill(s) outside the core\n' "agent extras" "$np" "$ns"
```

Then delete the whole `memory hooks` check block (the one that greps `settings.json` for `nixtastic-memory-hook` and prints `ok "memory hooks"`), since the hook now ships in the plugin and its presence is the `plugin hooks`/`plugin install` lines. In T22 change `expect 'ok +memory hooks'` to `refuse 'memory hooks'`.

- [ ] **Step 4: Run tests**

Run: `nix build .#checks.x86_64-linux.tools-tests --no-link 2>&1 | tail -5`
Expected: all pass, `all tests passed`.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add scripts/doctor.sh scripts/tools-tests.sh
git commit -m "doctor: five plugin lines and an extras count replace the root skills and user-scope hook checks"
```

---

### Task 5: Cross-repo skill

**Files:**
- Create: `plugin/skills/meshtastic-cross-repo/SKILL.md`
- Create: `plugin/skills/meshtastic-cross-repo/references/umbrella-template.md`
- Test: `scripts/tools-tests.sh` - extend T24 with two assertions

**Interfaces:**
- Consumes: `just brief`, `nix run .#worktree`, `notes/cross-repo-contracts.md`, the repo table in `CLAUDE.md`.
- Produces: skill `nixtastic:meshtastic-cross-repo`; umbrella notes at `notes/<yyyy-mm-dd>-<feature>.md`.

- [ ] **Step 1: Add the assertions to T24**

After the forwarder checks in T24 add:

```bash
[ -f "$p/skills/meshtastic-cross-repo/SKILL.md" ] || { echo "T24: cross-repo skill missing from render"; exit 1; }
grep -q '^name: meshtastic-cross-repo$' "$p/skills/meshtastic-cross-repo/SKILL.md" || { echo "T24: cross-repo name"; exit 1; }
[ -f "$p/skills/meshtastic-cross-repo/references/umbrella-template.md" ] || { echo "T24: umbrella template missing"; exit 1; }
```

Run: `nix build .#checks.x86_64-linux.tools-tests --no-link 2>&1 | tail -3` - expected FAIL `cross-repo skill missing`.

- [ ] **Step 2: Write SKILL.md**

```markdown
---
name: meshtastic-cross-repo
description: Drive a change that touches more than one Meshtastic repo in this workspace - a .proto or wire-contract change, a shared api.meshtastic.org resource, a firmware↔app handshake change, a version bump that must land in several repos, or any feature spanning firmware, protobufs, the SDK, android, apple, web-flasher, python or docs. Maps the request onto the coupling graph, briefs each repo, writes one umbrella note, gates on plan mode, then executes in release order with one worktree per repo and each repo's own conventions. Use from the workspace root; not for single-repo work.
license: GPL-3.0-only
---

# Cross-repo change in the Meshtastic workspace

You are at the root of a workspace of ~19 independent org repos. Nothing
off the shelf knows they are coupled. This skill does. It **orchestrates**;
it does not teach design, TDD or debugging - plan mode is the design gate,
each repo's own docs are the rules inside it.

Read first, in this order, and keep them open:

1. `CLAUDE.md` at the workspace root - the repo table (role, shell, default
   branch, commit style, agent docs) and the **Cross-repo coupling** section.
2. `notes/cross-repo-contracts.md` - phone↔device handshake, proto change
   rules, MQTT topics, **release order**.
3. For each candidate repo: `just brief <repo>` (from the root) - live
   branch, drift, and the docs that repo expects read. Read those docs.
4. If `<repo>/.specify/memory/constitution.md` exists, read it: it is that
   repo's governance and outranks other agent docs there. Do **not** create
   Spec Kit spec/plan/tasks files; the lifecycle is not used in practice.

## Steps

### 1. Scope

From the request, list every repo touched and *why*, then add what the
coupling graph implies even if unasked:

| if the change touches | it also touches |
| --- | --- |
| a `.proto` in `protobufs` | `firmware` (submodule bump), `meshtastic-python` (submodule bump), `android` (`org.meshtastic:protobufs` version in `gradle/libs.versions.toml`), `meshtastic-sdk`, `apple` |
| `meshtastic-sdk` public API | `android`, `apple` |
| an `api` `data/*.json` resource | `android` (bundled seed + repository), `apple` (hand-mirrored map), `web-flasher` |
| firmware↔app handshake or BLE/serial framing | `firmware`, `android`, `apple`, `meshtastic-python`, `meshtastic-sdk` |
| a `design` token or asset | `android`, `apple`, `meshtastic` (submodule) |
| `Adafruit_nRF52_Bootloader_OTAFIX` release | `api` data, `apple` hand copy |

Present the list with one line of reason per repo and **ask for
confirmation** before anything else. A repo the user removes stays out.

### 2. Brief

Run `just brief <repo>` for every confirmed repo. Stop and report if any
checkout is dirty, on an unexpected branch, or behind its origin: another
session may own it (see the memory `foreign-live-session-in-sibling-repo`).
Never work in a dirty primary checkout.

### 3. Umbrella note

Write `notes/<yyyy-mm-dd>-<feature-slug>.md` from
`references/umbrella-template.md`. It is the **only** durable artefact of the
cross-repo work and must be updated as things land. Commit it to the
workspace repo (sentence-style message, no attribution footer).

### 4. Design gate - plan mode

Enter plan mode. The plan lists, per repo in release order: files, the
change, the contract it implements or consumes, its verification command,
and its commit/PR convention from the repo table. Do not edit any repo
until the plan is approved. With `--dry-run` in the request, **stop here**
after writing the umbrella note and the plan.

### 5. Worktrees

For each repo: `nix run .#worktree -- <repo> <branch>` from the workspace
root (never a hand-rolled `git worktree`; never the harness's own worktree
isolation - see `CLAUDE.md` → Worktrees). Branch names follow that repo's
convention (`feat/…`, `fix/…`; Conventional-commit repos use the type as
prefix). Record each worktree path in the umbrella note.

### 6. Execute in release order

Producers before consumers, from `notes/cross-repo-contracts.md`:
`protobufs` → `firmware` and `meshtastic-python` (submodule bumps) →
`meshtastic-sdk` → `android`, `apple`, `web-flasher`, `meshtastic` (docs).
Inside a worktree the repo's own rules win: its commit style, PR vs direct,
CodeRabbit where it runs, its `AGENTS.md`/`CLAUDE.md`. Use that repo's
forwarded skills (`nixtastic:<repo>-<skill>`) and subagents
(`gradle-runner` for any Gradle build). A consumer that needs a published
artefact (a proto release, an SDK version) waits for it; note the pin it
will bump.

### 7. Verify

Each repo's own gate (the one its docs name). Where a device and an app
both changed, run the cross-plane check with `nixtastic:meshtastic-e2e`.
Report proven vs unproven plainly; never call the feature working from one
side alone.

### 8. Close

Fill the *landed* column of the umbrella note (commit SHA or PR URL per
repo), set status, commit the note. List what is still unproven.

## Never

- Mix commits across repos, or commit from the workspace root into a repo.
- Edit a primary checkout when a worktree exists for the work.
- Write Spec Kit lifecycle files.
- Skip step 1's confirmation or step 4's approval.
```

- [ ] **Step 3: Write the umbrella template**

`plugin/skills/meshtastic-cross-repo/references/umbrella-template.md`:

```markdown
# <Feature> - cross-repo umbrella

Status: scoping | planned | in progress | landed | unproven: <what>
Started: <yyyy-mm-dd>

## Goal

<One paragraph: what changes for users or the wire, and why now.>

## Repos touched

| repo | change | branch / worktree | verification | landed (SHA or PR) |
| --- | --- | --- | --- | --- |
| protobufs | | | | |
| firmware | | | | |
| android | | | | |

## Contract changes

<Wire, proto, API resource or handshake changes, with the compatibility
rule from notes/cross-repo-contracts.md that each one satisfies.>

## Release order

1. <producer> - <what must be published before the next step>
2. <consumer>
3. …

## Open questions / unproven

- <item>
```

- [ ] **Step 4: Run tests, gate, commit**

Run: `nix build .#checks.x86_64-linux.tools-tests --no-link 2>&1 | tail -3` → `all tests passed`.

```bash
just check
git add plugin/skills scripts/tools-tests.sh
git commit -m "plugin: meshtastic-cross-repo skill - scope, brief, umbrella note, plan-mode gate, release-order execution"
```

---

### Task 6: Guard behaviour tests

**Files:**
- Test: `scripts/tools-tests.sh` - T29 (Gradle guard), T30 (worktree guard)

**Interfaces:**
- Consumes: `$pluginSrc` (store path, from Task 2's flake change), `bash`, `git`, `jq`.

- [ ] **Step 1: Write the tests**

Append before `echo "all tests passed"`:

```bash
echo "--- T29: gradle guard - raw gradlew denied, queued/bypass/introspection allowed, heredoc mention allowed, --stop denied"
gg="$pluginSrc/hooks/gradle-queue-guard.sh"
decide() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" | bash "$gg" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; }
[ "$(decide './gradlew assembleDebug')" = deny ]  || { echo "T29: raw gradlew allowed"; exit 1; }
[ "$(decide 'cd android && ./gradlew test')" = deny ] || { echo "T29: prefixed gradlew allowed"; exit 1; }
[ "$(decide '~/.claude/bin/gradle-queue -- ./gradlew test')" = allow ] || { echo "T29: queued denied"; exit 1; }
[ "$(decide 'GRADLE_QUEUE_BYPASS=1 ./gradlew test')" = allow ] || { echo "T29: bypass denied"; exit 1; }
[ "$(decide './gradlew --version')" = allow ] || { echo "T29: --version denied"; exit 1; }
[ "$(decide './gradlew --stop')" = deny ] || { echo "T29: --stop allowed"; exit 1; }
[ "$(decide $'git commit -F - <<EOF\nmention ./gradlew in a message\nEOF')" = allow ] || { echo "T29: heredoc mention denied"; exit 1; }
[ "$(decide 'ls')" = allow ] || { echo "T29: unrelated command denied"; exit 1; }
printf '{"tool_name":"Bash","tool_input":{"command":"./gradlew build"}}' | bash "$gg" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -q 'gradle-queue -- build' || { echo "T29: denial does not name the replacement"; exit 1; }

echo "--- T30: worktree guard - cross-tree edit denied, in-tree and outside allowed, main checkout no-op"
wg="$pluginSrc/hooks/block-main-checkout-edits.sh"
edit() { printf '{"tool_name":"Edit","cwd":%s,"tool_input":{"file_path":%s}}' "$(jq -Rn --arg c "$1" '$c')" "$(jq -Rn --arg c "$2" '$c')" | bash "$wg" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; }
git -C "$root/kzstd" worktree add -q "$root/kzstd/.claude/worktrees/guard" -b guard
wt="$root/kzstd/.claude/worktrees/guard"
[ "$(edit "$wt" "$root/kzstd/tracked.txt")" = deny ]  || { echo "T30: main-checkout edit from worktree allowed"; exit 1; }
[ "$(edit "$wt" "$wt/tracked.txt")" = allow ]         || { echo "T30: in-worktree edit denied"; exit 1; }
[ "$(edit "$wt" "tracked.txt")" = allow ]             || { echo "T30: relative in-worktree edit denied"; exit 1; }
[ "$(edit "$wt" "$HOME/elsewhere.md")" = allow ]      || { echo "T30: outside edit denied"; exit 1; }
[ "$(edit "$root/kzstd" "$root/kzstd/tracked.txt")" = allow ] || { echo "T30: main checkout session blocked"; exit 1; }
git -C "$root/kzstd" worktree remove --force "$wt"; git -C "$root/kzstd" branch -D guard -q
```

- [ ] **Step 2: Run, fix the scripts if a decision is wrong**

Run: `nix build .#checks.x86_64-linux.tools-tests --no-link 2>&1 | tail -5`
Expected: `all tests passed`. If a case fails, the fix goes in `plugin/hooks/*.sh` (the ported scripts have never been tested; a real defect found here is fixed and the test kept).

- [ ] **Step 3: Gate and commit**

```bash
just check
git add scripts/tools-tests.sh plugin/hooks
git commit -m "tests: decisions of the gradle and worktree guards"
```

---

### Task 7: headersHelper spike, then desktop rollout

**Files:**
- Modify (only if the spike fails): `plugin/.mcp.json`
- Modify: `notes/agent-surface.md` - Evidence → Acceptance runs (desktop)

- [ ] **Step 1: Sync, install, restart**

Run from the workspace root:

```bash
nix run .#sync 2>&1 | grep -A6 '  plugin'
```

Expected: `rendered N forwarder(s)`, `register  added+installed`, `hooks  2 user-scope entr(ies)…`, `queue  linked`, `restart claude…`. Then `nix run .#doctor` → the five plugin lines `ok`, `all clear`.

- [ ] **Step 2: Canary probes (fresh sessions)**

```bash
claude -p 'List the exact names of skills available to you that start with "nixtastic:". One per line.'
claude -p 'Without reading files, name the skill you would use for "bump the protobufs pin everywhere and land it in firmware, python, android and apple". Reply with the skill name only.'
```

Expected: the first lists `nixtastic:meshtastic-cross-repo`, `nixtastic:meshtastic-device-ops`, `nixtastic:android-baseline` and the other forwarders; the second answers `nixtastic:meshtastic-cross-repo`.

- [ ] **Step 3: Hooks and MCP**

In an interactive `claude`, run `/hooks` and confirm the four plugin hooks are listed and no user-scope `nixtastic-memory-hook` remains. Run `/mcp` and confirm `github` connects. If it shows "requires authentication": run `~/.cache/agent-marketplace/nixtastic/bin/github-mcp-headers` by hand (must print the JSON header), then try the fallback - replace `headersHelper` in `plugin/.mcp.json` with `"headers": { "Authorization": "Bearer ${GITHUB_MCP_TOKEN}" }` and add `export GITHUB_MCP_TOKEN="$(gh auth token)"` to the workspace `.envrc`; re-run sync, restart, re-check. Record which form worked in the Evidence section.

- [ ] **Step 4: Cross-repo dry run**

```bash
claude -p 'Use the nixtastic:meshtastic-cross-repo skill, --dry-run: add a maintenance-UF2 quirk endpoint to the api and consume it in the clients. Stop after the umbrella note and plan; do not create worktrees or edit repos.'
```

Expected: names `api`, `android`, `apple`, `web-flasher`; release order starts with `api`; writes `notes/<date>-maintenance-uf2-quirk.md`. Delete that note afterwards (`git status` must be clean of it) - it is a probe, not work.

- [ ] **Step 5: Record and commit**

Append the outcomes (probe outputs summarised, headersHelper result, doctor output) under **Acceptance runs** in `notes/agent-surface.md`, machine `james-pc`.

```bash
git add notes/agent-surface.md plugin/.mcp.json .envrc
git commit -m "notes(agent-surface): desktop acceptance - plugin live, probes, headersHelper result"
```

---

### Task 8: Docs

**Files:**
- Modify: `CLAUDE.md` lines 115–119 (Spec Kit paragraph) and 184–194 (skills bullet)
- Modify: `AGENTS.md` - new `## Agent surface` section before `## Git across repos`
- Modify: `README.md` lines 70–73 and 104–106
- Modify: `notes/agent-memory-sync.md` Follow-ups
- Modify: `notes/agent-surface.md` - the three spec amendments

- [ ] **Step 1: CLAUDE.md**

Replace:

```
`android`, `apple`, `meshtastic-sdk` and `meshtastic` use it. Their
`.specify/memory/constitution.md` (8–12 KB) **outranks** other agent docs, and
work is expected to flow through the spec lifecycle rather than ad-hoc edits.
```

with:

```
`android`, `apple`, `meshtastic-sdk` and `meshtastic` carry it. Their
`.specify/memory/constitution.md` (8–12 KB) **outranks** other agent docs -
read it. The specify→plan→tasks lifecycle is not used in practice (measured
2026-09, `notes/agent-surface.md`); do not create its files.
```

Replace the bullet starting `- **Per-repo *skills* are not aggregated - launch with` (through `need the launcher.`) with:

```
- **Per-repo *skills* reach every session as forwarders.** A skill directory's
  name is its identity, so repo skills cannot be copied like subagents. The
  `nixtastic` plugin that `.#sync` renders into `.cache/agent-marketplace/`
  and installs ships one forwarder per repo skill, `nixtastic:<repo>-<skill>`,
  whose body points at the real `SKILL.md`; it also carries the three bundled
  meshtastic-mcp skills, `meshtastic-cross-repo`, the worktree and Gradle
  guards, the memory hooks and the GitHub MCP. `bin/claude-ws <repo>`
  (`--add-dir`, loads that repo's `CLAUDE.md` too) remains for the rare case
  a skill must run in place. Design: `notes/agent-surface.md`.
```

Check: `wc -l CLAUDE.md` before and after; the count must not grow.

- [ ] **Step 2: AGENTS.md**

Insert before `## Git across repos`:

```markdown
## Agent surface

### One plugin, rendered locally, never in the memory store

`plugin/` is the hand-written source; `.#sync` renders it plus generated
forwarders, the bundled meshtastic-mcp skills and the per-machine memory hook
into `.cache/agent-marketplace/`, and registers that directory as a local
marketplace. Everything in the render is derived from this repo and the local
checkouts, so it never crosses machines - rendering it into `~/.nixtastic-agent`
would have two machines pushing different forwarder sets to one tracked path
and breaking the memory push. Memory is state; the plugin is a build artefact.

### Forwarders, not symlinks

A skill's directory name is its identity and `code-review` exists in three
repos, so per-repo skills cannot be copied or linked into one tree. Each
forwarder is one paragraph: the target's own description (so the model selects
it on the same words), the absolute target directory (a forwarder loses the
base-directory announcement the harness makes for a normally loaded skill, so
`references/` would otherwise resolve wrong), and "run `just brief <repo>`
first". `speckit-*` skills are skipped: nine descriptions per session for a
lifecycle that is not used.

### Subagents stay at the root

Plugin agent naming is undocumented; bare-name dispatch of `gradle-runner`
from `android/CLAUDE.md` is what works, measured on both machines, so the
`.claude/agents/` copies are unchanged.

### The version is a content hash, the CLI owns install state

Directory-source plugins are copied to `~/.claude/plugins/cache`, and the docs
are silent on when source edits show (a spike saw them live). `sync` therefore
bumps `version` when the input hash changes and runs `claude plugin update`,
the documented path. Hooks never hot-swap: restart after a hook change.

### Guards encode workspace rules, tested now

The worktree edit guard and the Gradle queue guard came from one machine's
`~/.claude/hooks`, untested. They ship in the plugin with decision tests
(`tools-tests.sh` T29/T30). The queue script is linked at
`~/.claude/bin/gradle-queue` because the upstream android agent probes that
exact path.
```

- [ ] **Step 3: README.md**

Replace the three `--install-hooks` lines (70–73) with:

```
nix run .#sync          # then run the `direnv allow` lines it prints; also
                        # renders + installs the nixtastic plugin (restart claude once)
```

Replace `The bundled agent skills are a separate command, printed when they are missing:` and the command line that follows with:

```
The bundled agent skills, the per-repo skill forwarders, the guards and the
memory hooks ship in the `nixtastic` plugin `sync` renders and installs; see
`notes/agent-surface.md`.
```

- [ ] **Step 4: Follow-ups and spec amendments**

In `notes/agent-memory-sync.md`, replace the `**Agent-surface consolidation.**` bullet body with: `Done - [agent-surface.md](./agent-surface.md).`

In `notes/agent-surface.md`: in Layout, change the three `moved from .claude/skills/` lines to `copied at render from meshtastic-mcp/src/meshtastic_mcp/skills/ (the source the root copies were installed from)`; add under Layout: "Forwarders skip `speckit-*` (decision 3: nine descriptions per session for an unused lifecycle)." In Hooks and MCP, change the memory hook row's origin to `copied by sync from bin/nixtastic-memory-hook, which memory_pass writes`.

- [ ] **Step 5: Verify and commit**

Run: `nix run .#brief -- android | head -20` (still works), `just check`.

```bash
git add CLAUDE.md AGENTS.md README.md notes/agent-memory-sync.md notes/agent-surface.md
git commit -m "docs: the plugin replaces claude-ws as the door to repo skills; Spec Kit lifecycle marked unused; agent-surface reasoning in AGENTS.md"
git push
```

---

### Task 9: Laptop rollout

**Files:**
- Modify: `notes/agent-surface.md` - Evidence → Acceptance runs (laptop)

- [ ] **Step 1: Pull and sync over ssh**

```bash
ssh james@192.168.1.138 'cd ~/nixtastic && git pull --ff-only && nix run .#sync 2>&1 | grep -A8 "  plugin"'
```

Expected: `register added+installed`, `hooks 4 user-scope entr(ies)…`, `queue linked backup=…/gradle-queue.pre-plugin`.

- [ ] **Step 2: Doctor**

```bash
ssh james@192.168.1.138 'cd ~/nixtastic && nix run .#doctor'
```

Expected: plugin lines ok except `WARN github mcp … user scope too`. Tell James the fix line (`claude mcp remove -s user github`); do not run it unasked.

- [ ] **Step 3: Probes**

```bash
ssh james@192.168.1.138 'cd ~/nixtastic && claude -p "List the exact names of skills available to you that start with nixtastic:. One per line." && ~/nixtastic/.cache/agent-marketplace/nixtastic/bin/github-mcp-headers | cut -c1-30'
```

Expected: the same skill list as the desktop; the helper prints `{"Authorization":"Bearer gho` (truncated).

- [ ] **Step 4: Record, commit, push; update memory**

Append the laptop outcome under Acceptance runs. Commit and push from the desktop after `git pull` if the laptop committed nothing (it should not).

```bash
git add notes/agent-surface.md
git commit -m "notes(agent-surface): laptop acceptance"
git push
```

Update the shared memory `subproject-2-agent-surface-handoff`: description → "DONE 2026-09-xx on both machines; design + evidence in notes/agent-surface.md; remaining: remove laptop user-scope github MCP by hand, delete ~/.claude/hooks/*.sh after a week".
