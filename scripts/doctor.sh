# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# nix run .#doctor — check the wiring that fails silently: wrong
# toolchain, inert JDK pinning, a dead MCP registration. Fix commands are
# printed next to every finding. direnv is deliberately NOT in
# runtimeInputs: it is the USER's install being checked.
# The flake exports NIXTASTIC_REPOS_TSV.

root="${MESHTASTIC_WORKSPACE:-$PWD}"
fails=0
warns=0

ok()   { printf '  ok    %-18s %s\n' "$1" "${2:-}"; }
warn() { printf '  WARN  %-18s %s\n' "$1" "${2:-}"; warns=$((warns + 1)); }
bad()  { printf '  FAIL  %-18s %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }
fix()  { printf '        %-18s -> %s\n' "" "$1"; }

echo ""
echo "  nixtastic doctor"
echo "  ────────────────────────────────────────────────────"

# --- the workspace itself -------------------------------
if [ -z "${MESHTASTIC_WORKSPACE:-}" ]; then
  # Everything downstream keys off this. Unset is the single
  # highest-consequence failure here: JDK pinning goes inert
  # and Gradle silently provisions its own toolchains.
  bad "workspace" "MESHTASTIC_WORKSPACE unset (guessed $root)"
  fix "cd $root && direnv allow"
elif [ ! -f "$root/flake.nix" ]; then
  bad "workspace" "$root has no flake.nix"
else
  ok "workspace" "$root"
fi

# --- direnv ---------------------------------------------
if ! command -v direnv >/dev/null 2>&1; then
  # Both packages: nix-direnv is only the bash library direnv
  # sources; it ships no bin/ and installing it alone would
  # leave this exact failure in place.
  bad "direnv" "not on PATH"
  fix "nix profile install nixpkgs#direnv nixpkgs#nix-direnv"
else
  ok "direnv" "$(command -v direnv)"
fi

drc="${XDG_CONFIG_HOME:-$HOME/.config}/direnv/direnvrc"
if [ ! -f "$drc" ]; then
  bad "direnvrc" "$drc missing"
  fix "mkdir -p $(dirname "$drc") && echo 'source \"$root/direnvrc\"' > $drc"
elif ! grep -qF "$root/direnvrc" "$drc"; then
  # Sourcing someone else's direnvrc is not neutral: this
  # repo's carries the use_nix override that keeps firmware
  # off upstream's PlatformIO choice.
  bad "direnvrc" "does not source $root/direnvrc"
  fix "echo 'source \"$root/direnvrc\"' > $drc"
else
  ok "direnvrc" "sources this repo"
fi

# direnv on PATH but never hooked into the shell is the
# same silent failure one level up: cd does nothing, no
# error, and every "direnv sets it" claim in the docs goes
# quietly false. DIRENV_DIR set right now is the strongest
# evidence — this very process is running under it.
if [ -n "${DIRENV_DIR:-}" ]; then
  ok "direnv hook" "active in this shell"
else
  shellrc=""
  case "${SHELL:-}" in
    */zsh) shellrc="$HOME/.zshrc" ;;
    */bash) shellrc="$HOME/.bashrc" ;;
  esac
  if [ -n "$shellrc" ] && grep -q 'direnv hook' "$shellrc" 2>/dev/null; then
    ok "direnv hook" "wired in $shellrc"
  else
    warn "direnv hook" "not active, and no 'direnv hook' line in ${shellrc:-your shell rc}"
    fix "add:  eval \"\$(direnv hook ${SHELL##*/})\""
  fi
fi

gitignore="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
missing=""
for pat in .envrc .direnv/ .envrc-workspace; do
  grep -qxF "$pat" "$gitignore" 2>/dev/null || missing="$missing $pat"
done
if [ -n "$missing" ]; then
  warn "git ignore" "missing:$missing"
  fix "mkdir -p $(dirname "$gitignore") && printf '%s\\n'$missing >> $gitignore"
else
  ok "git ignore" "direnv files excluded globally"
fi

# --- per-repo shells ------------------------------------
cloned=0
noenvrc=""
while IFS=$'\t' read -r dir _ _; do
  [ -d "$root/$dir/.git" ] || continue
  cloned=$((cloned + 1))
  # firmware tracks its own .envrc, so the sidecar is the
  # file that matters there — see AGENTS.md.
  if [ ! -e "$root/$dir/.envrc" ] && [ ! -e "$root/$dir/.envrc-workspace" ]; then
    noenvrc="$noenvrc $dir"
  fi
done < "$NIXTASTIC_REPOS_TSV"

if [ "$cloned" -eq 0 ]; then
  bad "repos" "none cloned"
  fix "nix run .#sync"
elif [ -n "$noenvrc" ]; then
  bad "repos" "$cloned cloned; no .envrc:$noenvrc"
  fix "nix run .#sync"
else
  ok "repos" "$cloned cloned, each with a shell"
fi

if [ -d "$root/firmware/.git" ] && [ ! -e "$root/firmware/.envrc-workspace" ]; then
  warn "firmware envrc" "no .envrc-workspace sidecar"
  fix "nix run .#sync"
fi

# --- envrc shell drift ----------------------------------
# A generated .envrc names a dev shell; flake.nix can rename that shell
# later (meshtastic-mcp's `mcp` became `python`) and sync's never-clobber
# rule used to keep the stale file alive forever. The symptom is one
# nix-direnv evaluation error scrolling past and a fallback to the
# cached environment — unpinned, and silent thereafter. Compared against
# the TABLE (what sync would write) and against the flake's actual
# devShells (what can evaluate at all). Worktrees carry their own copy
# when they sit outside the repo or the repo tracks .envrc, so they are
# walked too. Hand-written files are reported but are the user's call.
shells=" ${NIXTASTIC_SHELLS:-} "
drift=""
foreign=""
nenvrc=0
check_envrc_shell() { # $1 = file, $2 = wanted shell, $3 = label
  [ -f "$1" ] || return 0
  have=$(envrc_shell_of "$1")
  [ -n "$have" ] || return 0 # `use nix` and friends select no flake shell
  nenvrc=$((nenvrc + 1))
  [ "$have" = "$2" ] && return 0
  why="${have}→${2}"
  if [ -n "${NIXTASTIC_SHELLS:-}" ]; then
    case "$shells" in *" $have "*) ;; *) why="$have: no such devShell, want $2" ;; esac
  fi
  if envrc_is_generated "$1"; then
    drift="$drift $3($why)"
  else
    foreign="$foreign $3($why)"
  fi
}
while IFS=$'\t' read -r dir _ shell; do
  [ -d "$root/$dir/.git" ] || continue
  for f in .envrc .envrc-workspace; do
    git -C "$root/$dir" ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
    check_envrc_shell "$root/$dir/$f" "$shell" "$dir/$f"
  done
  while read -r wt; do
    [ -d "$wt" ] || continue
    for f in .envrc .envrc-workspace; do
      git -C "$wt" ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
      check_envrc_shell "$wt/$f" "$shell" "$dir/${wt##*/}/$f"
    done
  done <<< "$(git -C "$root/$dir" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)"
done < "$NIXTASTIC_REPOS_TSV"
if [ -n "$drift" ]; then
  bad "envrc shells" "stale generated file(s):$drift"
  fix "nix run .#sync   (rewrites generated files; then direnv allow)"
fi
if [ -n "$foreign" ]; then
  warn "envrc shells" "hand-written, wrong shell:$foreign"
  fix "rm <file> && nix run .#sync   (or fix the use flake line yourself)"
fi
if [ -z "$drift" ] && [ -z "$foreign" ]; then
  ok "envrc shells" "$nenvrc file(s) match the table"
fi

# --- worktrees ------------------------------------------
# Hand- or harness-made worktrees fail silently two ways:
# no .mcp.json (the MCP tools are just absent), and — where
# the repo tracks its own .envrc — no sidecar, which for
# firmware means upstream's bwrap-broken platformio.
stray=""
nwt=0
while IFS=$'\t' read -r dir _ _; do
  [ -d "$root/$dir/.git" ] || continue
  tracks=false
  git -C "$root/$dir" ls-files --error-unmatch .envrc >/dev/null 2>&1 && tracks=true
  while read -r wt; do
    [ -d "$wt" ] || continue
    nwt=$((nwt + 1))
    miss=""
    [ ! -f "$wt/.mcp.json" ] && miss="mcp"
    [ "$tracks" = true ] && [ ! -e "$wt/.envrc-workspace" ] && miss="${miss:+$miss+}envrc"
    if [ -n "$miss" ]; then
      stray="$stray $dir/${wt##*/}($miss)"
    fi
  done <<< "$(git -C "$root/$dir" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)"
done < "$NIXTASTIC_REPOS_TSV"
if [ -n "$stray" ]; then
  warn "worktrees" "unoutfitted:$stray"
  fix "nix run .#sync   (adopts worktrees it did not create)"
else
  ok "worktrees" "$nwt found, all outfitted"
fi

# --- JDK pinning ----------------------------------------
# The failure this catches is silent and expensive: Gradle
# downloading its own JDKs behind Nix's back.
guh="${GRADLE_USER_HOME:-$root/.cache/gradle}"
if [ ! -f "$guh/gradle.properties" ]; then
  warn "jdk pinning" "no gradle.properties in $guh"
  fix "enter any JVM shell once: nix develop .#kotlin"
elif ! grep -q 'auto-download=false' "$guh/gradle.properties"; then
  bad "jdk pinning" "auto-download not disabled"
else
  ok "jdk pinning" "$guh"
fi

# --- Android SDK ----------------------------------------
# Reconcile against the DECLARED list, not just existence.
# bootstrap-sdk applies android-sdk-packages.txt on demand,
# but nothing detected drift between runs — and a missing
# package surfaces as an AGP resolution error naming
# nothing. The slash-form coordinates map 1:1 onto SDK
# directories (platforms/android-37.0 is literally
# $sdk/platforms/android-37.0), so presence of each
# directory is the check.
sdk="${ANDROID_HOME:-$HOME/Android/Sdk}"
pkglist="$root/android-sdk-packages.txt"
if [ ! -d "$sdk/platform-tools" ]; then
  warn "android sdk" "no platform-tools in $sdk"
  fix "nix run .#bootstrap-sdk"
elif [ ! -f "$pkglist" ]; then
  warn "android sdk" "no android-sdk-packages.txt at $root"
else
  declared=0
  sdkmissing=""
  while read -r coord; do
    case "$coord" in ""|\#*) continue ;; esac
    declared=$((declared + 1))
    if [ ! -d "$sdk/$coord" ]; then
      sdkmissing="$sdkmissing $coord"
    fi
  done < "$pkglist"
  if [ -n "$sdkmissing" ]; then
    warn "android sdk" "declared but not installed:$sdkmissing"
    fix "nix run .#bootstrap-sdk"
  else
    ok "android sdk" "$sdk — $declared declared, all present"
  fi
fi

# --- MCP registration -----------------------------------
# Store paths are the whole point of checking this: they go
# stale on `nix flake update` and the server then fails to
# start with nothing said anywhere.
mcp="$root/.mcp.json"
if [ ! -f "$mcp" ]; then
  warn "mcp registration" "no .mcp.json"
  fix "nix run .#sync"
elif ! jq -e . "$mcp" >/dev/null 2>&1; then
  bad "mcp registration" ".mcp.json does not parse"
  fix "nix run .#sync"
else
  cmd=$(jq -r '.mcpServers.meshtastic.command // ""' "$mcp")
  if [ -z "$cmd" ] || [ ! -x "$cmd" ]; then
    bad "mcp registration" "command missing: ${cmd:-unset}"
    fix "nix run .#sync   (store paths go stale on flake update)"
  else
    ok "mcp registration" "command resolves"
  fi
fi

# --- MCP user scope -----------------------------------------
# Project scope cannot follow you into android/, firmware/ or their
# worktrees — upstream tracks its own .mcp.json there, and ours is
# never written beside it. A user-scope registration pointing at the
# STABLE launcher (bin/meshtastic-mcp-launch, rewritten by sync with
# fresh store paths) covers every directory and survives flake updates.
launcher="$root/bin/meshtastic-mcp-launch"
ucmd=$(jq -r '.mcpServers.meshtastic.command // ""' "$HOME/.claude.json" 2>/dev/null || true)
if [ ! -x "$launcher" ]; then
  warn "mcp user scope" "no launcher at bin/meshtastic-mcp-launch"
  fix "nix run .#sync"
elif [ "$ucmd" = "$launcher" ]; then
  ok "mcp user scope" "registered via the stable launcher"
elif [ -n "$ucmd" ]; then
  warn "mcp user scope" "registered, but not via the launcher: $ucmd"
  fix "claude mcp remove --scope user meshtastic && claude mcp add --scope user meshtastic -- $launcher"
else
  warn "mcp user scope" "not registered — tools absent in android/, firmware/, worktrees"
  fix "claude mcp add --scope user meshtastic -- $launcher"
fi

if [ -d "$root/.claude/skills/meshtastic-device-ops" ]; then
  ok "agent skills" "$root/.claude/skills"
else
  warn "agent skills" "bundled skills not installed"
  fix "(cd $root/meshtastic-mcp && uv run meshtastic-mcp skills install --dest $root/.claude/skills)"
fi

# Repo subagents are copied to the root because a root-rooted session cannot
# see them where they live (rationale with agent_pairs in lib.sh). A stale or
# missing copy fails the way this whole file exists to catch: the Agent tool
# just says "not found", or worse answers from an outdated definition.
agent_exp=$(mktemp)
trap 'rm -f "$agent_exp"' EXIT
while IFS=$'\t' read -r dir _ _; do
  agent_pairs "$dir" "$root" >> "$agent_exp"
done < "$NIXTASTIC_REPOS_TSV"
if [ -s "$agent_exp" ]; then
  a_missing=0; a_stale=0; a_total=0
  while IFS=$'\t' read -r src dest; do
    a_total=$((a_total + 1))
    if [ ! -f "$root/.claude/agents/$dest" ]; then
      a_missing=$((a_missing + 1))
    elif ! cmp -s "$src" "$root/.claude/agents/$dest"; then
      a_stale=$((a_stale + 1))
    fi
  done < "$agent_exp"
  if [ "$a_missing" -gt 0 ] || [ "$a_stale" -gt 0 ]; then
    warn "repo subagents" "$a_missing missing, $a_stale stale of $a_total"
    fix "nix run .#sync"
  else
    ok "repo subagents" "$a_total aggregated to .claude/agents"
  fi
fi


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
    [ -n "$f" ] || continue
    m_mod=$(sed -n 's/^  modified: *\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' "$f" | head -1)
    if [ -z "$m_mod" ]; then m_undated=$((m_undated + 1))
    elif [[ "$m_mod" < "$m_cutoff" ]]; then m_stale=$((m_stale + 1)); fi
  done <<< "$(find "$mstore/memory" -maxdepth 1 -name '*.md' ! -name MEMORY.md 2>/dev/null)"
  # Undated is reported, never warned: pre-rollout files carry no modified:
  # line and never will, and a warning that cannot clear is noise.
  if [ "$m_stale" -gt 0 ]; then
    warn "memory age" "$m_stale not updated since $m_cutoff ($m_undated undated)"
    fix "review them; a wrong memory is worse than a missing one — delete it"
  else
    ok "memory age" "none older than 90 days ($m_undated undated of $m_count)"
  fi
fi

echo ""
if [ "$fails" -gt 0 ]; then
  printf '  %s failure(s), %s warning(s)\n\n' "$fails" "$warns"
  exit 1
fi
printf '  all clear (%s warning(s))\n\n' "$warns"

