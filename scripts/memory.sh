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
