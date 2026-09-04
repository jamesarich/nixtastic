# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# nix run .#worktree — create, list, remove and prune worktrees that
# arrive fully outfitted. Assembled by the flake: lib.sh is prepended and
# the NIXTASTIC_* env vars are exported there.

root="${MESHTASTIC_WORKSPACE:-$PWD}"
usage() {
  echo "usage:"
  echo "  nix run .#worktree -- <repo> <branch> [name]   create"
  echo "  nix run .#worktree -- --list [repo]            list"
  echo "  nix run .#worktree -- --remove <repo> <name>   remove one"
  echo "  nix run .#worktree -- --prune [repo]           drop dead registrations"
}

repo_shell() {
  while IFS=$'\t' read -r d _ s; do
    [ "$d" = "$1" ] && { echo "$s"; return; }
  done < "$NIXTASTIC_REPOS_TSV"
}
all_repos() {
  while IFS=$'\t' read -r d _ _; do echo "$d"; done < "$NIXTASTIC_REPOS_TSV"
}

# Explicit if/else rather than `A && B || C`: with the latter,
# C also runs when A succeeds but B fails.
targets() {
  if [ -n "${1:-}" ]; then echo "$1"; else all_repos; fi
}

case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;
  --list)
    while read -r d; do
      [ -d "$root/$d/.git" ] || continue
      out=$(git -C "$root/$d" worktree list | tail -n +2)
      if [ -n "$out" ]; then
        echo "  $d:"
        while IFS= read -r line; do printf '      %s\n' "$line"; done <<< "$out"
      fi
    done <<< "$(targets "${2:-}")"
    exit 0 ;;
  --remove)
    # The create side generates the path, so the remove side
    # should not make you retype it. `git worktree remove` alone
    # means knowing where the tool put it.
    dir="${2:-}"; name="${3:-}"
    [ -n "$dir" ] && [ -n "$name" ] || { usage; exit 1; }
    p="$root/$dir"
    [ -d "$p/.git" ] || { echo "$dir not cloned"; exit 1; }
    wt="$p/.claude/worktrees/$name"
    [ -d "$wt" ] || { echo "no such worktree: $wt"; exit 1; }

    # Refuse on uncommitted work. `git worktree remove` already
    # does, but say so in this tool's own voice rather than
    # letting a plumbing error surface.
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      echo "  refusing: $wt has uncommitted changes"
      echo "  commit, stash, or: git -C $p worktree remove --force $wt"
      exit 1
    fi

    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    git -C "$p" worktree remove "$wt"
    echo "  removed  $wt"

    # Only delete the branch when git agrees it is merged: -d
    # refuses otherwise, and that refusal is the safety check.
    # An unmerged branch is the whole point of having made a
    # worktree, so losing it silently would be the worst
    # possible outcome here.
    if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
      if git -C "$p" branch -d "$branch" >/dev/null 2>&1; then
        echo "  deleted  branch $branch (merged)"
      else
        echo "  kept     branch $branch (not merged)"
        echo "           git -C $p branch -D $branch   to force"
      fi
    fi
    exit 0 ;;
  --prune)
    while read -r d; do
      [ -d "$root/$d/.git" ] || continue
      # --dry-run reports on STDERR, not stdout. Redirecting
      # it to /dev/null silently makes the count always zero,
      # so this must capture 2>&1 or --prune never fires.
      n=$(git -C "$root/$d" worktree prune --dry-run 2>&1 | wc -l)
      if [ "$n" -gt 0 ]; then
        git -C "$root/$d" worktree prune
        echo "  $d: pruned $n dead registration(s)"
      fi
    done <<< "$(targets "${2:-}")"
    exit 0 ;;
esac

dir="$1"; branch="${2:-}"; name="${3:-$(echo "$branch" | tr '/' '-')}"
[ -n "$branch" ] || { usage; exit 1; }
shell=$(repo_shell "$dir")
[ -n "$shell" ] || { echo "unknown repo: $dir"; exit 1; }
p="$root/$dir"
[ -d "$p/.git" ] || { echo "$dir not cloned"; exit 1; }

wt="$p/.claude/worktrees/$name"
[ -e "$wt" ] && { echo "already exists: $wt"; exit 1; }

# Keep the host repo's tracked files untouched; the reasoning
# (and the 7388ecb war story) lives with the shared helper.
ensure_excludes "$p"

git -C "$p" fetch --quiet origin 2>/dev/null || true
if git -C "$p" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
  git -C "$p" worktree add --quiet "$wt" "$branch"
elif git -C "$p" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
  git -C "$p" worktree add --quiet --track -b "$branch" "$wt" "origin/$branch"
else
  git -C "$p" worktree add --quiet -b "$branch" "$wt"
fi

# A worktree is a full checkout, so it carries any .envrc the
# repo tracks. firmware tracks one (`use nix`, resolving to
# upstream's flake), and overwriting it would leave the worktree
# dirty the moment it is created. Write the sidecar the workspace
# direnvrc prefers instead.
if git -C "$p" ls-files --error-unmatch .envrc >/dev/null 2>&1; then
  envrc_file="$wt/.envrc-workspace"
else
  envrc_file="$wt/.envrc"
fi
write_worktree_envrc "$envrc_file" "$shell"

# A worktree is its own cwd, so it is its own Claude Code
# project: a registration made at the workspace root does
# not reach it, and the MCP tools would simply be absent
# with no error. Same failure shape as the .envrc above.
# The env still points at the REAL repos — a worktree of
# one repo is not a workspace.
#
# But upstream may TRACK .mcp.json (android, firmware and
# meshtastic-mcp do — android's registers context7 for the
# team). This tool used to overwrite it unconditionally,
# which dirtied every such worktree at creation and stomped
# the team's registrations — the exact failure class the
# .envrc sidecar exists to avoid, one file over. A tracked
# file wins; the meshtastic-mcp tools are then not project-
# registered in that worktree (run the client from the
# workspace root when you need them).
mcp=""
if git -C "$wt" ls-files --error-unmatch .mcp.json >/dev/null 2>&1; then
  mcp="upstream's (tracked) — meshtastic-mcp tools not registered here"
elif write_mcp_json "$wt" "$root"; then
  mcp="written (approve once via /mcp)"
fi

# Its own cwd is its own Claude Code project, so without this the first
# session here starts with no memory and every later one keeps its own
# blind store — the android/=2-memories hole, once per branch. The
# projects/ dir does not exist until a session writes it, hence mkdir in
# memory_link. Design: notes/agent-memory-sync.md.
mem=""
if [ -d "$(memory_store)/.git" ]; then
  s=$(slug_of "$wt") && mem=$(memory_link "$(claude_projects_dir)/$s" "$(memory_store)/memory")
fi

echo "  created  $wt"
echo "  envrc    ${envrc_file#"$wt"/}"
[ -n "$mcp" ] && echo "  mcp      .mcp.json $mcp"
case "$mem" in
  linked) echo "  memory   linked -> $(memory_store)/memory" ;;
  warn*)  echo "  memory   WARN ${mem#*$'\t'}" ;;
esac
echo "  branch   $branch"
echo "  shell    .#$shell"
echo ""
echo "  cd $wt && direnv allow"
# Absolute flake ref on purpose: the line above tells you to cd INTO the
# worktree, and `.#` resolves against cwd without crossing a git-repo
# boundary — so the short form errors with "is not part of a flake" from
# exactly the directory this is telling you to stand in.
echo "  nix run $root#brief -- $dir"

