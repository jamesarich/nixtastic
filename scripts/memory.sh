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
