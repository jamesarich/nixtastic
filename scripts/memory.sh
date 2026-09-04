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

# MEMORY.md, derived from frontmatter. The index is the RETRIEVAL KEY — a
# probe showed memory bodies are fetched on demand, selected from their
# index line alone — so it is written for selection: user → feedback →
# reference → project (durable first; the merged set is 71 % project),
# alphabetical within each, the machine tag inline where one is set.
# Deterministic, so re-rendering an unchanged store is byte-identical and
# never churns a commit. $1 = the memory dir.
#
# Titles are harvested from the EXISTING index before it is replaced: a
# session appends its own line with a hand-written title (the harness says
# to), and a hand title is a better retrieval key than one derived from the
# filename. Last occurrence wins, so a fresh append beats an old render;
# the hook is always the frontmatter description.
# SC2016: the $0 and $1 inside the quotes are awk's fields, and must reach
# awk unexpanded.
# shellcheck disable=SC2016
# SC2016 for the function: the $0 and $[0-9] in the awk program are awk's,
# reaching it literally by design — the same disable lib.sh uses for jq.
# shellcheck disable=SC2016
memory_render_index() {
  hand=$(mktemp)
  [ -f "$1/MEMORY.md" ] && sed -n 's/^- \[\([^]]*\)\](\([^)]*\)\.md).*/\2\t\1/p' "$1/MEMORY.md" > "$hand"
  {
    echo '# Memory'
    echo
    find "$1" -maxdepth 1 -name '*.md' ! -name MEMORY.md -print0 | sort -z | xargs -0 gawk -v handf="$hand" '
      BEGIN { while ((getline l < handf) > 0) { i = index(l, "\t"); hand[substr(l, 1, i - 1)] = substr(l, i + 1) } }
      # A quoted YAML scalar escapes its inner quotes; the index shows them bare.
      function val(s) { sub(/^[^:]*:[ \t]*/, "", s); gsub(/^"|"$/, "", s); gsub(/\\"/, "\"", s); return s }
      function title(s,  t) { if (s in hand) return hand[s]; t = s; gsub(/[-_]+/, " ", t); return toupper(substr(t, 1, 1)) substr(t, 2) }
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
  rm -f "$hand"
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
# SC2016: the $0 and $1 inside the quotes are awk's fields, and must reach
# awk unexpanded.
# shellcheck disable=SC2016
# SC2016 for the function: the $0 and $[0-9] in the awk program are awk's,
# reaching it literally by design — the same disable lib.sh uses for jq.
# shellcheck disable=SC2016
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

# The hook Claude Code runs at SessionStart (pull) and Stop (commit, pull,
# push). A generated file at a STABLE path, like meshtastic-mcp-launch:
# settings.json names the path once, sync rewrites the contents. POSIX sh,
# because macOS runs it too — which is also why the lock is mkdir (atomic
# everywhere) and not flock(1) (absent there). Every step is best-effort
# and the script always exits 0: a hook must never block a session. A
# merge that conflicts is aborted, not left for the next session to load
# with markers in it; doctor reports it as diverged.
#
# Cheap exits come first, because Stop fires at the end of EVERY turn and
# the registration is user-scope, so this runs for every project on the
# machine: a cwd whose slug is not linked into the store leaves at once, a
# clean store leaves before any network, and a pull under two minutes old
# is not repeated (parallel sessions). Measured before the gates: 1.1 s of
# GitHub round-trips per turn, everywhere.
# $1 = workspace root.
# SC2028 too: the backslashes in the sed line are for the generated script.
# shellcheck disable=SC2016,SC2028
write_memory_hook() {
  mkdir -p "$1/bin"
  {
    echo '#!/bin/sh'
    echo '# Generated by: nix run .#sync — regenerate, do not hand-edit.'
    echo '# SessionStart: pull. Stop: dedupe the index, commit, pull, push.'
    echo '# Every step best-effort; design in notes/agent-memory-sync.md.'
    printf 'store="%s"\n' "$(memory_store)"
    printf 'projects="%s"\n' "$(claude_projects_dir)"
    echo '[ -d "$store/.git" ] || exit 0'
    echo '# Only a session in a LINKED project touches the store. Claude Code hands'
    echo '# the cwd as JSON on stdin; a terminal (no stdin) is treated as linked.'
    echo 'if [ ! -t 0 ]; then'
    echo '  cwd=$(sed -n '"'"'s/.*"cwd" *: *"\([^"]*\)".*/\1/p'"'"' | head -1)'
    echo '  if [ -n "$cwd" ]; then'
    echo '    slug=$(printf '"'"'%s'"'"' "$cwd" | sed '"'"'s/[^a-zA-Z0-9]/-/g'"'"')'
    echo '    [ "$(readlink "$projects/$slug/memory" 2>/dev/null)" = "$store/memory" ] || exit 0'
    echo '  fi'
    echo 'fi'
    echo 'cd "$store" || exit 0'
    echo '# Never hang a session on a bad link: 3 s to connect, 3 s under 1 KB/s.'
    echo 'export GIT_SSH_COMMAND="ssh -o ConnectTimeout=3 -o BatchMode=yes"'
    echo 'git() { command git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=3 "$@"; }'
    echo 'case "${1:-}" in'
    echo '  start) [ -n "$(find .git/FETCH_HEAD -mmin -2 2>/dev/null)" ] && exit 0 ;;'
    echo '  stop)  [ -n "$(git status --porcelain 2>/dev/null)" ] || exit 0 ;;'
    echo '  *) exit 0 ;;'
    echo 'esac'
    echo 'lock="$store/.git/nixtastic-hook.lock"'
    echo '# A lock older than a minute belongs to a crashed holder, not a live one.'
    echo 'if ! mkdir "$lock" 2>/dev/null; then'
    echo '  if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then'
    echo '    rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || exit 0'
    echo '  else exit 0; fi'
    echo 'fi'
    echo 'trap '"'"'rmdir "$lock" 2>/dev/null'"'"' EXIT'
    echo 'pull() { git pull --no-rebase --autostash -q >/dev/null 2>&1 || git merge --abort >/dev/null 2>&1 || true; }'
    echo 'case "$1" in'
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
