# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# nix run .#brief <repo> — orient before touching a repo. Generated live
# so it cannot go stale; its job is to say WHAT TO READ, not to inline it.
# The flake exports NIXTASTIC_REPOS_TSV (<dir>\t<org/repo>\t<shell>).

root="${MESHTASTIC_WORKSPACE:-$PWD}"

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

# The full orientation for one repo.
brief_one() {
  dir="$1"
  shell=""
  while IFS=$'\t' read -r d _ s; do
    [ "$d" = "$dir" ] && shell="$s"
  done < "$NIXTASTIC_REPOS_TSV"

  [ -n "$shell" ] || { echo "unknown repo: $dir"; return 1; }
  primary="$root/$dir"
  [ -d "$primary/.git" ] || { echo "$dir not cloned — run: nix run .#sync"; return 1; }

  # A worktree is a full checkout on its own branch, so answering from the
  # primary checkout while the caller stands in a worktree is worse than
  # saying nothing: the protocol makes this tool the thing you trust over
  # the table, and it would name a different branch, drift and commit style
  # than the files about to be edited. Match on --git-common-dir rather than
  # a path prefix so worktrees parked outside the repo tree count too.
  p="$primary"
  if common=$(git rev-parse --git-common-dir 2>/dev/null); then
    if [ "$(cd "$common" 2>/dev/null && pwd)" = "$primary/.git" ]; then
      p=$(git rev-parse --show-toplevel)
    fi
  fi
  g="git -C $p"

  # `nix run .#…` resolves the flake from the caller's cwd and will not cross
  # a git-repo boundary, so the short form only works from the workspace repo
  # itself — inside any org repo or worktree it dies with "is not part of a
  # flake". Print the form that will actually run from where the caller is.
  ref=".#"
  [ "$(git rev-parse --show-toplevel 2>/dev/null || echo "")" = "$root" ] || ref="$root#"

  echo ""
  echo "  $dir"
  echo "  ────────────────────────────────────────────────────"
  printf '  shell        nix develop %s%s\n' "$ref" "$shell"
  [ "$p" != "$primary" ] && printf '  checkout     worktree %s\n' "${p##*/}"

  branch=$($g rev-parse --abbrev-ref HEAD)
  def=""
  if r=$($g symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
    def="${r#refs/remotes/origin/}"
  fi
  printf '  branch       %s' "$branch"
  [ -n "$def" ] && [ "$branch" != "$def" ] && printf '   (default: %s)' "$def"
  echo ""

  if u=$($g rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
    c=$($g rev-list --left-right --count "$u...HEAD" 2>/dev/null || echo "0	0")
    printf '  drift        -%s / +%s vs %s\n' "$(echo "$c" | cut -f1)" "$(echo "$c" | cut -f2)" "$u"
  fi
  d=$($g status --porcelain --untracked-files=no | wc -l)
  [ "$d" -gt 0 ] && printf '  tree         %s tracked file(s) modified\n' "$d"

  echo ""
  echo "  READ BEFORE EDITING (in precedence order)"
  any=false
  for f in .specify/memory/constitution.md AGENTS.md CLAUDE.md CONTRIBUTING.md GOVERNANCE.md CODEOWNERS CONVENTIONS.md llms.txt; do
    if [ -f "$p/$f" ]; then
      printf '    %-42s %6s\n' "$dir/$f" "$(( $(wc -c <"$p/$f") ))b"
      any=true
    fi
  done
  if [ -f "$root/notes/$dir.md" ]; then
    printf '    %-42s %6s  (workspace-local)\n' "notes/$dir.md" "$(( $(wc -c <"$root/notes/$dir.md") ))b"
    any=true
  fi
  [ "$any" = false ] && echo "    (none found — read the code)"

  # Spec Kit repos run a lifecycle; ad-hoc edits are the wrong shape.
  if [ -d "$p/.specify" ]; then
    echo ""
    echo "  SPEC KIT — work flows through the spec lifecycle"
    [ -f "$p/.specify/memory/constitution.md" ] && \
      echo "    constitution outranks other agent docs"
    if [ -d "$p/specs" ]; then
      printf '    %s spec(s); most recent:\n' "$(find "$p/specs" -maxdepth 1 -mindepth 1 -type d | wc -l)"
      find "$p/specs" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
        | sort | tail -3 | sed 's/^/      /'
    fi
  fi

  for k in skills agents commands; do
    if [ -d "$p/.claude/$k" ]; then
      printf '\n  .claude/%s\n' "$k"
      find "$p/.claude/$k" -maxdepth 1 -mindepth 1 -printf '    %f\n' 2>/dev/null | sort | head -12
    fi
  done

  echo ""
  echo "  COMMIT STYLE (last 5 on this branch — match it)"
  $g log --oneline -5 --format='    %s' | cut -c1-74

  if command -v gh >/dev/null; then
    echo ""
    echo "  OPEN PRs"
    gh pr list --repo "meshtastic/$( $g remote get-url origin | sed 's|.*/||; s|\.git$||' )" \
      --limit 5 --json number,title \
      --template '{{range .}}    #{{.number}} {{.title}}{{"\n"}}{{end}}' 2>/dev/null \
      || echo "    (unavailable)"
  fi

  echo ""
  # Worktrees live under the primary checkout, so count them there — a
  # worktree has no .claude/worktrees of its own.
  if [ -d "$primary/.claude/worktrees" ]; then
    n=$(find "$primary/.claude/worktrees" -maxdepth 1 -mindepth 1 -type d | wc -l)
    [ "$n" -gt 0 ] && printf '  %s active worktree(s) — nix run %sworktree --list %s\n\n' "$n" "$ref" "$dir"
  fi
  return 0
}

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
