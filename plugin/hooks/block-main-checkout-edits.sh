#!/usr/bin/env bash
# PreToolUse(Edit|Write|MultiEdit): inside a LINKED worktree, deny an edit whose
# target lands in the main checkout or a sibling worktree. Fails open on any
# internal error - its only job is the cross-tree mistake.

input=$(cat)

# jq is required to parse the hook payload; without it, fail open.
command -v jq >/dev/null 2>&1 || exit 0

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Where the tool is running. The hook inherits the session cwd; prefer the
# explicit field, fall back to PWD.
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd="$PWD"
[ -d "$cwd" ] || exit 0

# Resolve a directory path to its physical absolute form (relative to cwd).
resolve_dir() {
  local p="$1"
  case "$p" in /*) : ;; *) p="$cwd/$p" ;; esac
  if [ -d "$p" ]; then (cd "$p" 2>/dev/null && pwd -P); else printf '%s' "$p"; fi
}

# Git dirs from the session cwd. Not a repo -> nothing to enforce.
git_dir_raw=$(git -C "$cwd" rev-parse --git-dir 2>/dev/null) || exit 0
common_raw=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null) || exit 0
git_dir=$(resolve_dir "$git_dir_raw")
common_dir=$(resolve_dir "$common_raw")
[ -n "$git_dir" ] && [ -n "$common_dir" ] || exit 0

# Linked worktree iff per-worktree git dir != shared common dir.
# Equal -> we are in the main checkout -> no enforcement.
[ "$git_dir" = "$common_dir" ] && exit 0

wt_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$wt_root" ] || exit 0
main_root=$(dirname "$common_dir")   # common dir is <main_root>/.git

# Absolute target path (may be passed relative to cwd).
case "$file_path" in
  /*) abs="$file_path" ;;
  *)  abs="$cwd/$file_path" ;;
esac

# Outside the main repo tree entirely (memory dir, /tmp, other repos) -> allow.
case "$abs" in
  "$main_root"/*) : ;;
  *) exit 0 ;;
esac

# Inside the current worktree -> allow.
case "$abs" in
  "$wt_root"/*) exit 0 ;;
esac

# Otherwise the edit targets the main checkout or a sibling worktree -> DENY.
rel=${abs#"$main_root"/}
reason="Worktree discipline: this session is in the worktree
  $wt_root
but this edit targets
  $abs
which is in the MAIN checkout (or a sibling worktree) rooted at
  $main_root

Re-target the path under the current worktree instead, e.g.
  $wt_root/$rel

(If you truly meant to edit the main checkout, do it via Bash/git. Blocked by the nixtastic plugin's worktree guard.)"

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
