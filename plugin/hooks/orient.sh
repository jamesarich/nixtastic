#!/usr/bin/env bash
# SessionStart: say where this session is standing and how to reach the
# workspace tools from there. Orients only - never tells the model to cd,
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

ws_wt="This is a worktree of the workspace repo itself (flake, notes, CLAUDE.md only). The org repos are NOT here; they live at $root/<repo>. Nothing repo-related can be done from this tree."
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
      where="$ws_wt"
    else
      where="You are under the workspace root ($root), not inside an org repo."
    fi ;;
  *)
    if [ -n "$common" ] && [ "$common" = "$rootp/.git" ]; then
      where="$ws_wt"
    else
      exit 0
    fi ;;
esac

# The just recipes are the short forms; a machine without just on PATH (the
# laptop's login shell) gets the nix run spellings, which always resolve.
if command -v just >/dev/null 2>&1; then
  tools="Workspace tools (work from any cwd; \`nix run .#\` does not resolve inside a repo):
  just brief <repo>            orient on one repo (docs to read, branch, drift)
  just brief --short a b c     one line per repo
  just pins                    cross-repo pin state (protobufs, design, api seeds)
  just pr <repo> <n>           PR status: checks for the head SHA, threads, queue; reviewed | resolve | wait
  just review                  local CodeRabbit pass on a finished change (3/hour), before the PR
  just wt <repo> <name> <cmd>  run in a worktree with its env; just in <repo> <cmd> for the primary
  just worktree <repo> <br>    create a worktree the right way
  just sync | just doctor
Run just from any cwd under $root (justfile: $root/justfile)."
else
  tools="Workspace tools (\`just\` is not on PATH here; \`nix profile install nixpkgs#just\` gives the short forms):
  nix run $root#brief -- <repo>                orient on one repo (docs to read, branch, drift)
  nix run $root#brief -- --short a b c         one line per repo
  nix run $root#pins                            cross-repo pin state (protobufs, design, api seeds)
  nix run $root#pr -- <repo> <n>                PR status: checks for the head SHA, threads, queue; reviewed | resolve | wait
  nix run $root#worktree -- --path <repo> <name>   a worktree's path; then cd there && direnv exec . <cmd>
  nix run $root#worktree -- <repo> <br>         create a worktree the right way
  nix run $root#sync | nix run $root#doctor"
fi
ctx="$where
$tools"
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
exit 0
