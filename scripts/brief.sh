# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# nix run .#brief <repo> — orient before touching a repo. Generated live
# so it cannot go stale; its job is to say WHAT TO READ, not to inline it.
# The flake exports NIXTASTIC_REPOS_TSV (<dir>\t<org/repo>\t<shell>).

root="${MESHTASTIC_WORKSPACE:-$PWD}"
dir="${1:-}"
if [ -z "$dir" ]; then
  echo "usage: nix run .#brief <repo>"
  echo ""
  echo "repos:"
  while IFS=$'\t' read -r d _ s; do printf '  %-24s %s\n' "$d" ".#$s"; done < "$NIXTASTIC_REPOS_TSV"
  exit 0
fi

shell=""
while IFS=$'\t' read -r d _ s; do
  [ "$d" = "$dir" ] && shell="$s"
done < "$NIXTASTIC_REPOS_TSV"

[ -n "$shell" ] || { echo "unknown repo: $dir"; exit 1; }
p="$root/$dir"
[ -d "$p/.git" ] || { echo "$dir not cloned — run: nix run .#sync"; exit 1; }
g="git -C $p"

echo ""
echo "  $dir"
echo "  ────────────────────────────────────────────────────"
printf '  shell        nix develop .#%s\n' "$shell"

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
if [ -d "$p/.claude/worktrees" ]; then
  n=$(find "$p/.claude/worktrees" -maxdepth 1 -mindepth 1 -type d | wc -l)
  [ "$n" -gt 0 ] && printf '  %s active worktree(s) — nix run .#worktree --list %s\n\n' "$n" "$dir"
fi

