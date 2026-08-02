# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# Fixture tests for the git-state logic in sync and worktree — the
# highest-consequence code in the workspace, exercised here against a fake
# workspace of ten tiny repos with local bare "origins". Runs inside the
# Nix build sandbox: no network, which is the point — every behaviour
# tested is pure git state.
#
# Built as checks.<system>.tools-tests. The builder exports:
#   $sync      path to the built meshtastic-sync
#   $worktree  path to the built meshtastic-worktree
# (runCommand turns its attrs into env vars.)

set -euo pipefail

export HOME="$PWD/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.email test@example.invalid
git config --global user.name "fixture"
git config --global init.defaultBranch main

root="$PWD/ws"
origins="$PWD/origins"
mkdir -p "$root" "$origins"
export MESHTASTIC_WORKSPACE="$root"

# The real workspace is itself a git repo, and that is not incidental: nix
# stops walking up for flake.nix at a git-repo boundary, which is the whole
# reason `.#` resolves from the root and dies inside an org repo. A fixture
# root that is a plain directory cannot exercise that split.
git init -q -b main "$root"
(cd "$root" && : > flake.nix && git add flake.nix && git commit -qm workspace)

# The repo table is baked into the tools (NIXTASTIC_REPOS_TSV), so the
# fixture directories must carry the REAL names. firmware tracks .envrc
# upstream and android tracks .mcp.json — mirror both, they are exactly
# the cases the tools special-case.
repos="MQTTastic-Client-KMP TAKPacket-SDK android apple design firmware gradle-flatpak-sources kzstd meshtastic-mcp meshtastic-sdk protobufs"
for r in $repos; do
  git init -q --bare -b main "$origins/$r.git"
  git init -q -b main "$root/$r"
  (
    cd "$root/$r"
    echo content > tracked.txt
    git add tracked.txt
    if [ "$r" = firmware ]; then
      echo "use nix" > .envrc
      git add .envrc
    fi
    if [ "$r" = android ]; then
      echo '{"upstream":true}' > .mcp.json
      git add .mcp.json
    fi
    git commit -qm init
    git remote add origin "$origins/$r.git"
    git push -qu origin main 2>/dev/null
  )
done

res=""
run() { res="$("$@" 2>&1)" || { echo "COMMAND FAILED: $*"; printf '%s\n' "$res"; exit 1; }; }
expect() { printf '%s\n' "$res" | grep -qE -- "$1" || { echo "EXPECT FAILED: $1"; printf '%s\n' "$res"; exit 1; }; }
refuse() { printf '%s\n' "$res" | grep -qE -- "$1" && { echo "REFUSE FAILED (matched): $1"; printf '%s\n' "$res"; exit 1; } || true; }
# `run` assigns res in the CALLER's shell, so `(cd … && run …)` would leave
# res holding the previous test's output and assert against that — silently
# green or bafflingly red. cd in this shell and change back.
run_in() { d="$1"; shift; prev="$PWD"; cd "$d"; run "$@"; cd "$prev"; }

echo "--- T1: first run — all current, envrc written per repo, sidecar for firmware"
run "$sync"
# Anchored: the footer's own help text also says "current".
# Derived from $repos, not hardcoded: adding a repo to the table in flake.nix
# should not require editing a magic number here.
repo_count=$(printf '%s\n' $repos | grep -c .)
[ "$(printf '%s\n' "$res" | grep -cE '^  current ')" = "$repo_count" ] || { echo "T1: expected $repo_count current rows"; printf '%s\n' "$res"; exit 1; }
expect 'envrc written'
expect 'envrc-workspace written \(upstream tracks \.envrc\)'
[ -f "$root/kzstd/.envrc" ] || { echo "T1: kzstd/.envrc missing"; exit 1; }
[ -f "$root/firmware/.envrc-workspace" ] || { echo "T1: firmware sidecar missing"; exit 1; }
[ ! -e "$root/android/.envrc-workspace" ] || { echo "T1: android wrongly got a sidecar"; exit 1; }
grep -q 'use flake "\$MESHTASTIC_WORKSPACE#kotlin"' "$root/kzstd/.envrc" || { echo "T1: kzstd envrc wrong shell"; exit 1; }
grep -qxF '.mcp.json' "$root/kzstd/.git/info/exclude" || { echo "T1: ensure_excludes did not reach kzstd"; exit 1; }
[ -f "$root/.mcp.json" ] || { echo "T1: root .mcp.json missing"; exit 1; }
jq -e '.mcpServers.meshtastic' "$root/.mcp.json" >/dev/null || { echo "T1: root .mcp.json malformed"; exit 1; }
[ -x "$root/bin/meshtastic-mcp-launch" ] || { echo "T1: stable launcher missing or not executable"; exit 1; }
grep -qF "export MESHTASTIC_WORKSPACE=\"$root\"" "$root/bin/meshtastic-mcp-launch" \
  || { echo "T1: launcher lacks the workspace root"; exit 1; }
grep -qF '"$@"' "$root/bin/meshtastic-mcp-launch" \
  || { echo "T1: launcher lost its argument passthrough"; exit 1; }
# No ~/.claude.json in the sandbox, so sync must print the one-time hint.
expect 'claude mcp add --scope user meshtastic'

echo "--- T2: behind is reported, and --pull fast-forwards"
(cd "$root/kzstd" && echo more >> tracked.txt && git commit -aqm more && git push -q && git reset -q --hard HEAD~1)
run "$sync"
expect 'behind +kzstd .*-1 \(run with --pull\)'
run "$sync" --pull
expect 'PULLED +kzstd .*-1 fast-forwarded'
run "$sync"
expect ' current +kzstd '

echo "--- T3: a dirty tree blocks the fast-forward"
(cd "$root/android" && echo more >> tracked.txt && git commit -aqm more && git push -q && git reset -q --hard HEAD~1 && echo local-edit >> tracked.txt)
run "$sync" --pull
expect 'BEHIND +android .*skipped, tree dirty'
(cd "$root/android" && git checkout -q -- tracked.txt)
run "$sync" --pull
expect 'PULLED +android '

echo "--- T4: ahead and diverged are named, never touched"
(cd "$root/apple" && echo ahead >> tracked.txt && git commit -aqm ahead)
run "$sync" --pull
expect 'ahead +apple .*\+1'
(cd "$root/design" && echo mine >> tracked.txt && git commit -aqm mine)
(cd "$origins/design.git" && git_dir_commit=$(git commit-tree -p main -m theirs "main^{tree}") && git update-ref refs/heads/main "$git_dir_commit")
run "$sync" --pull
expect 'DIVERGED +design .*\+1/-1'
(cd "$root/apple" && git reset -q --hard origin/main)
(cd "$root/design" && git fetch -q && git reset -q --hard origin/main)

echo "--- T5: single-branch clones are detected, --pull widens the refspec"
git -C "$root/protobufs" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
run "$sync"
expect 'protobufs .*single-branch clone'
run "$sync" --pull
[ "$(git -C "$root/protobufs" config remote.origin.fetch)" = '+refs/heads/*:refs/remotes/origin/*' ] \
  || { echo "T5: refspec not widened"; exit 1; }

echo "--- T6: adoption — hand-made worktree under the repo gets .mcp.json only"
git -C "$root/kzstd" worktree add -q .claude/worktrees/stray -b test/stray
run "$sync"
expect 'adopted +kzstd/stray +mcp\.json'
[ -f "$root/kzstd/.claude/worktrees/stray/.mcp.json" ] || { echo "T6: adopted mcp missing"; exit 1; }
[ ! -e "$root/kzstd/.claude/worktrees/stray/.envrc" ] || { echo "T6: needless envrc written (ancestor covers it)"; exit 1; }
run "$sync"
refuse 'adopted +kzstd/stray'

echo "--- T7: adoption respects a TRACKED .mcp.json, writes firmware's sidecar"
git -C "$root/android" worktree add -q .claude/worktrees/stray -b test/stray
git -C "$root/firmware" worktree add -q .claude/worktrees/stray -b test/stray
run "$sync"
expect 'adopted +firmware/stray +envrc-workspace'
refuse 'adopted +android/stray'
grep -q '"upstream":true' "$root/android/.claude/worktrees/stray/.mcp.json" \
  || { echo "T7: tracked .mcp.json was clobbered"; exit 1; }
[ -z "$(git -C "$root/android/.claude/worktrees/stray" status --porcelain)" ] \
  || { echo "T7: adoption dirtied the android worktree"; exit 1; }
[ -f "$root/firmware/.claude/worktrees/stray/.envrc-workspace" ] || { echo "T7: firmware sidecar missing"; exit 1; }

echo "--- T8: adoption — worktree parked OUTSIDE the repo tree gets a full .envrc"
git -C "$root/kzstd" worktree add -q "$PWD/outside-wt" -b test/outside
run "$sync"
expect 'adopted +kzstd/outside-wt +envrc'
grep -q "use flake \"$root#kotlin\"" "$PWD/outside-wt/.envrc" || { echo "T8: outside envrc wrong"; exit 1; }

echo "--- T9: worktree tool — create is outfitted, remove deletes only merged branches"
run "$worktree" kzstd feat/thing
expect 'created .*kzstd/.claude/worktrees/feat-thing'
expect 'mcp .*written'
[ -f "$root/kzstd/.claude/worktrees/feat-thing/.envrc" ] || { echo "T9: tool envrc missing"; exit 1; }
run "$worktree" android feat/thing
expect "upstream's \(tracked\)"
[ -z "$(git -C "$root/android/.claude/worktrees/feat-thing" status --porcelain)" ] \
  || { echo "T9: tool dirtied the android worktree"; exit 1; }
run "$worktree" --remove kzstd feat-thing
expect 'removed '
expect 'deleted +branch feat/thing \(merged\)'
(cd "$root/android/.claude/worktrees/feat-thing" && echo work >> tracked.txt && git commit -aqm wip)
run "$worktree" --remove android feat-thing
expect 'kept +branch feat/thing \(not merged\)'

echo "--- T10: worktree --list and --prune"
run "$worktree" --list
expect 'kzstd:'
rm -rf "$root/kzstd/.claude/worktrees/stray"
run "$worktree" --prune kzstd
expect 'kzstd: pruned'

echo "--- T11: brief describes the checkout you are standing in, not just the primary"
git -C "$root/kzstd" worktree add -q .claude/worktrees/brief-wt -b feat/brief-wt
# From the workspace root: the primary checkout, and the short flake ref.
run_in "$root" "$brief" kzstd
expect '  branch +main'
refuse 'checkout +worktree'
expect 'nix run \.#worktree --list kzstd'
expect 'nix develop \.#kotlin'
# From inside the worktree: its own branch, named as a worktree. Reporting
# main here was the original bug — silent, and precisely backwards for a
# tool the protocol says to trust over the table.
run_in "$root/kzstd/.claude/worktrees/brief-wt" "$brief" kzstd
expect 'checkout +worktree brief-wt'
expect '  branch +feat/brief-wt'
# `.#` cannot cross a git-repo boundary, so every command brief prints from
# in here must carry the absolute flake ref or it dies on "not part of a flake".
expect "nix run $root#worktree --list kzstd"
expect "nix develop $root#kotlin"
refuse 'nix run \.#'
refuse 'nix develop \.#'
# A worktree of ANOTHER repo must not hijack the answer.
run_in "$root/kzstd/.claude/worktrees/brief-wt" "$brief" android
refuse 'checkout +worktree'
# And the tool's own next-step suggestion has to survive the cd it tells you
# to make — this is the line that was broken. Asserted by shape, not by
# running it: `nix` is not in the build sandbox, and the behaviour it would
# have exercised is already covered directly above.
run "$worktree" kzstd feat/suggest
expect "nix run $root#brief -- kzstd"
refuse 'nix run \.#brief'

echo "--- T12: per-repo subagents are aggregated to the root, kept fresh, and dropped when gone"
mkdir -p "$root/android/.claude/agents"
printf -- '---\nname: gradle-runner\n---\nbody v1\n' > "$root/android/.claude/agents/gradle-runner.md"
run "$sync"
expect '\.claude/agents  1 subagent\(s\) from android'
[ -f "$root/.claude/agents/android--gradle-runner.md" ] || { echo "T12: copy missing"; exit 1; }
cmp -s "$root/android/.claude/agents/gradle-runner.md" "$root/.claude/agents/android--gradle-runner.md" \
  || { echo "T12: copy is not byte-identical"; exit 1; }
# The frontmatter name is what the Agent tool resolves, so it must survive
# verbatim — renaming it would break android's own "dispatch the
# gradle-runner subagent" instruction from a root session.
grep -qx 'name: gradle-runner' "$root/.claude/agents/android--gradle-runner.md" \
  || { echo "T12: frontmatter name was rewritten"; exit 1; }
# An unchanged source must not be recopied — mtime churn would make
# staleness unanswerable by inspection.
run "$sync"
refuse 'copied \(source changed\)'
# A changed source must be picked up.
printf -- '---\nname: gradle-runner\n---\nbody v2\n' > "$root/android/.claude/agents/gradle-runner.md"
run "$sync"
expect '1 copied \(source changed\)'
grep -q 'body v2' "$root/.claude/agents/android--gradle-runner.md" || { echo "T12: stale copy kept"; exit 1; }
# Two repos claiming one name resolves by filesystem order — undefined, so
# it has to be said out loud rather than silently picked.
mkdir -p "$root/apple/.claude/agents"
printf -- '---\nname: gradle-runner\n---\nimpostor\n' > "$root/apple/.claude/agents/gradle-runner.md"
run "$sync"
expect 'duplicate subagent name\(s\)'
expect '        gradle-runner'
# Deleted upstream means gone here: an orphan copy would keep answering.
rm -rf "$root/apple/.claude/agents"
run "$sync"
expect '1 dropped \(source gone\)'
refuse 'duplicate subagent name'
[ ! -e "$root/.claude/agents/apple--gradle-runner.md" ] || { echo "T12: orphan copy kept"; exit 1; }
# Removing the LAST agent anywhere leaves nothing to iterate, so a drop pass
# nested under "any agents exist" would never run and the copy would answer
# forever. Exactly that bug shipped in the first draft.
rm -f "$root/android/.claude/agents/gradle-runner.md"
run "$sync"
expect '1 dropped \(source gone\)'
[ ! -e "$root/.claude/agents/android--gradle-runner.md" ] || { echo "T12: last orphan copy kept"; exit 1; }

echo "--- T13: claude-ws turns repo names into --add-dir and passes everything else through"
mkdir -p "$root/apple/.claude/skills/speckit-plan"
run "$sync"
expect 'bin/claude-ws .*repos shipping skills:.* apple'
[ -x "$root/bin/claude-ws" ] || { echo "T13: launcher missing or not executable"; exit 1; }
# Drive it against a stub claude: the point is the argv it builds, and the
# real binary is the user's install, deliberately resolved from PATH.
mkdir -p "$PWD/fakebin"
printf '#!/bin/sh\necho "ARGV: $*"\n' > "$PWD/fakebin/claude"
chmod +x "$PWD/fakebin/claude"
oldpath="$PATH"; PATH="$PWD/fakebin:$PATH"; export PATH
run "$root/bin/claude-ws" apple --model opus
expect "ARGV: --add-dir $root/apple --model opus"
# Two repos, and a flag that is not a repo stops the scan.
run "$root/bin/claude-ws" android apple -p hello
expect "ARGV: --add-dir $root/android --add-dir $root/apple -p hello"
# No repo named must be plain claude — the default has to stay cheap,
# because --add-dir also drags in that repo's CLAUDE.md.
run "$root/bin/claude-ws" --version
expect '^ARGV: --version$'
# A non-repo leading word is claude's problem, not ours: passed through, not
# silently swallowed or turned into a bogus --add-dir.
run "$root/bin/claude-ws" notarepo
expect '^ARGV: notarepo$'
PATH="$oldpath"; export PATH
rm -rf "$root/apple/.claude/skills"

echo "all tests passed"
touch "$out"
