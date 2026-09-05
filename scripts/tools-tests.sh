# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# Fixture tests for the git-state logic in sync and worktree — the
# highest-consequence code in the workspace, exercised here against a fake
# workspace of tiny repos with local bare "origins", one per entry in the
# real repo table. Runs inside the Nix build sandbox: no network, which is
# the point — every behaviour tested is pure git state. (Deliberately not
# stating a repo count: the list below is the count, and a number in prose
# goes stale the moment a repo is registered.)
#
# Built as checks.<system>.tools-tests. The builder exports:
#   $sync      path to the built meshtastic-sync
#   $worktree  path to the built meshtastic-worktree
#   $brief     path to the built meshtastic-brief
#   $doctor    path to the built meshtastic-doctor
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
repos="Adafruit_nRF52_Bootloader_OTAFIX MQTTastic-Client-KMP TAKPacket-SDK android api apple design device-ui firmware gradle-flatpak-sources kzstd labeltastic meshtastic meshtastic-mcp meshtastic-node-kmp meshtastic-python meshtastic-sdk protobufs web-flasher"
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

# The memory store: a private GitHub repo in real life, a local bare here.
# Cloning an EMPTY bare is deliberate — that is what the first machine
# sees, and the first push has to set upstream itself.
git init -q --bare -b main "$origins/nixtastic-agent.git"
export NIXTASTIC_MEMORY_REMOTE="$origins/nixtastic-agent.git"
export NIXTASTIC_MEMORY_STORE="$HOME/.nixtastic-agent"
store="$NIXTASTIC_MEMORY_STORE"
projects="$HOME/.claude/projects"
slug() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

res=""
run() { res="$("$@" 2>&1)" || { echo "COMMAND FAILED: $*"; printf '%s\n' "$res"; exit 1; }; }
expect() { printf '%s\n' "$res" | grep -qE -- "$1" || { echo "EXPECT FAILED: $1"; printf '%s\n' "$res"; exit 1; }; }
refuse() { printf '%s\n' "$res" | grep -qE -- "$1" && { echo "REFUSE FAILED (matched): $1"; printf '%s\n' "$res"; exit 1; } || true; }
# `run` assigns res in the CALLER's shell, so `(cd … && run …)` would leave
# res holding the previous test's output and assert against that — silently
# green or bafflingly red. cd in this shell and change back.
run_in() { d="$1"; shift; prev="$PWD"; cd "$d"; run "$@"; cd "$prev"; }
# doctor exits 1 whenever anything FAILs, and in the sandbox (no direnv,
# no direnvrc) something always does — capture regardless and assert on
# the lines.
run_lax() { res="$("$@" 2>&1)" || true; }

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

echo "--- T14: a generated .envrc whose shell was renamed is repaired, not kept"
# Exactly the meshtastic-mcp case: the file sync wrote named `mcp`, the
# table now says `python`, and never-clobber kept the stale file through
# every sync while nix-direnv fell back to a cached environment.
sed -i 's/#python"/#mcp"/' "$root/meshtastic-mcp/.envrc"
grep -q '#mcp"' "$root/meshtastic-mcp/.envrc" || { echo "T14: fixture setup failed"; exit 1; }
run_lax "$doctor"
expect 'FAIL  envrc shells +stale generated file\(s\): meshtastic-mcp/\.envrc\(mcp: no such devShell, want python\)'
run "$sync"
expect 'meshtastic-mcp .*envrc updated \(shell mcp → python\)'
grep -q 'use flake "\$MESHTASTIC_WORKSPACE#python"' "$root/meshtastic-mcp/.envrc" || { echo "T14: stale envrc kept"; exit 1; }
# Editing revokes direnv's approval, so the footer must ask for it again.
expect "direnv allow $root/meshtastic-mcp"
run "$sync"
refuse 'envrc updated'
run_lax "$doctor"
refuse 'envrc shells +stale'
expect 'ok    envrc shells'
# The sidecar is ours too, by the same rule.
sed -i 's/#firmware"/#firmwar"/' "$root/firmware/.envrc-workspace"
run "$sync"
expect 'firmware .*envrc updated \(shell firmwar → firmware\)'
grep -q '#firmware"' "$root/firmware/.envrc-workspace" || { echo "T14: stale sidecar kept"; exit 1; }

echo "--- T15: a hand-written .envrc is warned about, never touched"
printf 'use flake "$MESHTASTIC_WORKSPACE#kotlin"\n' > "$root/labeltastic/.envrc"
before=$(cat "$root/labeltastic/.envrc")
run "$sync"
expect 'WARN +labeltastic: \.envrc selects kotlin, table says python — not ours, left alone'
refuse 'labeltastic .*envrc updated'
[ "$(cat "$root/labeltastic/.envrc")" = "$before" ] || { echo "T15: hand-written envrc was clobbered"; exit 1; }
run_lax "$doctor"
expect 'WARN  envrc shells +hand-written, wrong shell: labeltastic/\.envrc\(kotlin→python\)'
refuse 'FAIL  envrc shells'
rm "$root/labeltastic/.envrc"
run "$sync"
expect 'labeltastic .*envrc written'

echo "--- T16: a TRACKED .envrc is never touched, whatever it says"
# firmware's `use nix` selects no flake shell at all; make it name a wrong
# one outright and confirm both tools still keep their hands off.
(cd "$root/firmware" && printf 'use flake "$MESHTASTIC_WORKSPACE#kotlin"\n' > .envrc && git commit -qam "track a wrong shell" && git push -q)
run "$sync"
refuse 'firmware.*envrc updated'
refuse 'WARN +firmware'
[ -z "$(git -C "$root/firmware" status --porcelain --untracked-files=no)" ] \
  || { echo "T16: tracked envrc was modified"; exit 1; }
run_lax "$doctor"
refuse 'firmware/\.envrc\('
(cd "$root/firmware" && git checkout -q HEAD~1 -- .envrc && git commit -qam "restore use nix" && git push -q)

echo "--- T17: sync --slug reproduces Claude Code's project slug"
# Vectors lifted from the remember plugin's docs/slug-vectors.json
# (cygpath-agnostic, ASCII). Non-ASCII is refused, not guessed: Claude
# Code slugs one dash per code point and the workspace never needs it.
run "$sync" --slug /home/u/p
expect '^-home-u-p$'
run "$sync" --slug /Users/f/Documents/dvsi
expect '^-Users-f-Documents-dvsi$'
run "$sync" --slug //server/share/project
expect '^--server-share-project$'
run "$sync" --slug /tmp/x/C:/y
expect '^-tmp-x-C--y$'
run "$sync" --slug "$root/android/.claude/worktrees/feat-thing"
expect "^$(printf '%s' "$root" | sed 's/[^a-zA-Z0-9]/-/g')-android--claude-worktrees-feat-thing\$"
run_lax "$sync" --slug /tmp/café
expect 'non-ASCII'

echo "--- T18: memory pass — clone, link every slug, import without clobbering, idempotent"
# T1 already ran sync, so the store is cloned and the root + repos are
# linked. Assert that state rather than re-deriving it.
[ -d "$store/.git" ] || { echo "T18: store not cloned"; exit 1; }
[ "$(readlink "$projects/$(slug "$root")/memory")" = "$store/memory" ] \
  || { echo "T18: root slug not linked"; exit 1; }
[ "$(readlink "$projects/$(slug "$root/kzstd")/memory")" = "$store/memory" ] \
  || { echo "T18: repo slug not linked"; exit 1; }
grep -qx 'MEMORY.md merge=union' "$store/.gitattributes" || { echo "T18: no union merge attribute"; exit 1; }
# A pre-existing real memory dir is imported: new files copied, a
# same-named file KEPT in the store and the loser left beside the link.
pre="$projects/$(slug "$root/android")"
rm -rf "$pre/memory"; mkdir -p "$pre/memory"
printf -- '---\nname: only-here\ndescription: "lives on this machine"\nmetadata:\n  type: project\n---\nbody\n' > "$pre/memory/only-here.md"
printf -- '---\nname: dup\ndescription: "loser"\nmetadata:\n  type: project\n---\nLOSER\n' > "$pre/memory/dup.md"
printf -- '---\nname: dup\ndescription: "winner"\nmetadata:\n  type: project\n---\nWINNER\n' > "$store/memory/dup.md"
run "$sync"
expect '[^0-9]1 imported'
expect 'kept.*dup\.md'
grep -q WINNER "$store/memory/dup.md" || { echo "T18: store file was clobbered"; exit 1; }
[ -f "$store/memory/only-here.md" ] || { echo "T18: new file not imported"; exit 1; }
[ -f "$pre/memory.pre-sync/dup.md" ] || { echo "T18: loser not preserved beside the link"; exit 1; }
[ "$(readlink "$pre/memory")" = "$store/memory" ] || { echo "T18: android slug not linked after import"; exit 1; }
# The import is committed and pushed, so the other machine can pull it.
# Not grep -q: it closes the pipe on the first match and pipefail then
# reports git log's SIGPIPE as a failure — a race that flips as the log grows.
git -C "$origins/nixtastic-agent.git" log --oneline | grep 'memory: import' >/dev/null || { echo "T18: import not pushed"; exit 1; }
# Idempotent: a second run imports nothing and touches no mtime.
before=$(ls -l --time-style=full-iso "$store/memory")
run "$sync"
refuse 'imported [1-9]'
[ "$before" = "$(ls -l --time-style=full-iso "$store/memory")" ] || { echo "T18: second run changed mtimes"; exit 1; }
# A symlink pointing somewhere ELSE is not ours: warned, never replaced.
other="$projects/$(slug "$root/api")"
rm -rf "$other/memory"; mkdir -p "$other" "$HOME/elsewhere"; ln -s "$HOME/elsewhere" "$other/memory"
run "$sync"
expect 'WARN .*elsewhere'
[ "$(readlink "$other/memory")" = "$HOME/elsewhere" ] || { echo "T18: foreign symlink replaced"; exit 1; }
rm "$other/memory"

echo "--- T19: MEMORY.md is rendered by type with the machine tag inline, and is byte-stable"
rm -f "$store"/memory/*.md
mk() { printf -- '---\nname: %s\ndescription: "%s"\nmetadata:\n  type: %s\n%s---\nbody\n' "$1" "$2" "$3" "${4:-}" > "$store/memory/$1.md"; }
mk zeta-project   "a project fact"            project
mk alpha-project  "another project fact"      project
mk some-feedback  "how James wants it done"   feedback
mk who-james-is   "the operator"              user
mk bench-serials  "bench USB serials"         reference "  machine: james-pc
"
# A YAML-escaped inner quote must render bare, not as a backslash-quote.
mk quoted-desc    "says \\\"hi\\\" to you"       project
run "$sync"
idx="$store/memory/MEMORY.md"
head -1 "$idx" | grep -qx '# Memory' || { echo "T19: no header"; exit 1; }
# Order: user, feedback, reference, project; alphabetical within.
want='who-james-is some-feedback bench-serials alpha-project quoted-desc zeta-project'
got=$(sed -n 's/^- \[[^]]*\](\([^)]*\)\.md).*/\1/p' "$idx" | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$want" ] || { echo "T19: order was: $got"; exit 1; }
grep -q '^- \[Bench serials\](bench-serials.md) — \[james-pc\] bench USB serials$' "$idx" \
  || { echo "T19: tag not inline / title not derived"; cat "$idx"; exit 1; }
grep -q '^- \[Quoted desc\](quoted-desc.md) — says "hi" to you$' "$idx" \
  || { echo "T19: escaped quote leaked into the index"; cat "$idx"; exit 1; }
cp "$idx" "$HOME/idx.before"
run "$sync"
cmp -s "$idx" "$HOME/idx.before" || { echo "T19: re-render is not byte-identical"; exit 1; }
# A session appends its own line with a hand-written title (the harness
# instruction says to). The title is the retrieval key, so it is kept; the
# hook is still the frontmatter description; the appended line is folded.
printf -- '- [Alpha, by hand](alpha-project.md) — a hook someone typed\n' >> "$idx"
run "$sync"
grep -q '^- \[Alpha, by hand\](alpha-project.md) — another project fact$' "$idx" \
  || { echo "T19: hand title lost on re-render"; cat "$idx"; exit 1; }
[ "$(grep -c 'alpha-project.md' "$idx")" = 1 ] || { echo "T19: appended line not folded"; exit 1; }
cp "$idx" "$HOME/idx.before2"
run "$sync"
cmp -s "$idx" "$HOME/idx.before2" || { echo "T19: re-render with a hand title is not byte-stable"; exit 1; }
# Overlap hint on import: two stems shared, reported, never merged.
pre="$projects/$(slug "$root/firmware")"
rm -rf "$pre/memory"; mkdir -p "$pre/memory"
mk2() { printf -- '---\nname: %s\ndescription: "x"\nmetadata:\n  type: project\n---\nbody\n' "$1" > "$pre/memory/$1.md"; }
mk2 firmware-native-tests-on-macos
printf -- '---\nname: firmware-native-tests-need-docker\ndescription: "x"\nmetadata:\n  type: project\n---\nbody\n' > "$store/memory/firmware-native-tests-need-docker.md"
run "$sync"
expect 'overlap'
expect 'firmware-native-tests-need-docker ~ firmware-native-tests-on-macos|firmware-native-tests-on-macos ~ firmware-native-tests-need-docker'
[ -f "$store/memory/firmware-native-tests-on-macos.md" ] && [ -f "$store/memory/firmware-native-tests-need-docker.md" ] \
  || { echo "T19: an overlap pair was merged or dropped"; exit 1; }

echo "--- T20: a new worktree is linked to the store before its first session"
run "$worktree" kzstd feat/mem
expect 'memory +linked'
wt="$root/kzstd/.claude/worktrees/feat-mem"
[ "$(readlink "$projects/$(slug "$wt")/memory")" = "$store/memory" ] \
  || { echo "T20: worktree slug not linked at creation"; exit 1; }
run "$worktree" --remove kzstd feat-mem

echo "--- T21: hooks — merged into settings.json once, existing entries kept; the hook commits, pushes, and respects the lock"
cfg="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
cat > "$cfg" <<'EOF'
{ "model": "opus", "hooks": { "SessionStart": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "herdr session", "timeout": 10 } ] } ] } }
EOF
run "$sync"
[ -x "$root/bin/nixtastic-memory-hook" ] || { echo "T21: hook script missing"; exit 1; }
# The hook: a memory written through the link is committed and pushed.
printf -- '---\nname: from-a-session\ndescription: "x"\nmetadata:\n  type: project\n---\nbody\n' > "$projects/$(slug "$root")/memory/from-a-session.md"
printf -- '- [dup line](from-a-session.md) — x\n- [dup line](from-a-session.md) — x\n' >> "$store/memory/MEMORY.md"
run "$root/bin/nixtastic-memory-hook" stop
git -C "$origins/nixtastic-agent.git" log --oneline | grep 'memory: ' >/dev/null || {
  echo "T21: hook did not push"; echo "--- origin log:"; git -C "$origins/nixtastic-agent.git" log --oneline --all -5
  echo "--- store:"; git -C "$store" status -sb | head -3; git -C "$store" log --oneline -3; ls -d "$store/.git/nixtastic-hook.lock" 2>/dev/null; exit 1; }
[ "$(grep -c 'dup line' "$store/memory/MEMORY.md")" = 1 ] || { echo "T21: union duplicate not collapsed"; exit 1; }
# A held lock means another session is mid-push: exit 0, do nothing.
mkdir "$store/.git/nixtastic-hook.lock"
echo more >> "$store/memory/from-a-session.md"
run "$root/bin/nixtastic-memory-hook" stop
[ -n "$(git -C "$store" status --porcelain)" ] || { echo "T21: hook ignored the lock"; exit 1; }
rmdir "$store/.git/nixtastic-hook.lock"
run "$root/bin/nixtastic-memory-hook" stop
[ -z "$(git -C "$store" status --porcelain)" ] || { echo "T21: hook did not commit after lock release"; exit 1; }
# start pulls: a commit made on the "other machine" arrives.
other="$HOME/other-machine"
git clone -q "$origins/nixtastic-agent.git" "$other"
printf -- '---\nname: from-the-laptop\ndescription: "x"\nmetadata:\n  type: project\n---\nbody\n' > "$other/memory/from-the-laptop.md"
(cd "$other" && git add -A && git commit -qm "memory: laptop" && git push -q)
# A pull landed under two minutes ago (the stop above): start skips the network.
touch "$store/.git/FETCH_HEAD"
run "$root/bin/nixtastic-memory-hook" start
[ ! -f "$store/memory/from-the-laptop.md" ] || { echo "T21: start pulled despite a fresh FETCH_HEAD"; exit 1; }
touch -d '10 minutes ago' "$store/.git/FETCH_HEAD"
run "$root/bin/nixtastic-memory-hook" start
[ -f "$store/memory/from-the-laptop.md" ] || { echo "T21: start hook did not pull"; exit 1; }
# The hook is user-scope and fires for every project on the machine; only a
# session whose cwd is a LINKED slug may touch the store. cwd arrives as JSON.
echo dirty >> "$store/memory/from-a-session.md"
printf '{"cwd":"/nowhere/linked","hook_event_name":"Stop"}' | run "$root/bin/nixtastic-memory-hook" stop
[ -n "$(git -C "$store" status --porcelain)" ] || { echo "T21: unlinked cwd committed to the store"; exit 1; }
printf '{"cwd":"%s","hook_event_name":"Stop"}' "$root" | run "$root/bin/nixtastic-memory-hook" stop
[ -z "$(git -C "$store" status --porcelain)" ] || { echo "T21: linked cwd did not commit"; exit 1; }

echo "--- T22: doctor — store, links, hooks, state, age"
run_lax "$doctor"
expect 'ok +memory links'
refuse 'memory hooks'
expect 'ok +memory store'
# Unlinked slug is named by its label, not its 80-character slug.
rm "$projects/$(slug "$root/kzstd")/memory"
run_lax "$doctor"
expect 'FAIL +memory links +1 of [0-9]+ unlinked: kzstd'
run "$sync"
# Unpushed commits and dirty files are reported, with the fix.
echo more >> "$store/memory/from-a-session.md"
run_lax "$doctor"
expect 'WARN +memory store .*1 uncommitted'
run "$root/bin/nixtastic-memory-hook" stop
# Undated alone is not stale: it must not warn forever.
run_lax "$doctor"
expect 'ok +memory age .*undated'
# Age: a memory last modified years ago, and one with no date at all.
printf -- '---\nname: old\ndescription: "x"\nmetadata:\n  type: project\n  modified: 2020-01-01T00:00:00Z\n---\nbody\n' > "$store/memory/old.md"
run_lax "$doctor"
expect 'WARN +memory age +1 not updated since'
expect 'undated'
# Store missing entirely is a FAIL with the fix.
mv "$store" "$store.away"
run_lax "$doctor"
expect 'FAIL +memory store +not cloned'
mv "$store.away" "$store"

echo "--- T23: --memory-only runs the memory pass and nothing else"
run "$sync" --memory-only
expect 'memory .*slugs ->'
refuse 'current +kzstd'
refuse 'clone '

echo "--- T24: plugin render — source copied, bundled skills copied, forwarders generated and prefixed, speckit skipped"
# Two repos shipping the same skill name, one unique, one speckit, one symlinked.
mkskill() { mkdir -p "$1"; printf -- '---\nname: %s\ndescription: %s\n---\nbody\n' "$2" "$3" > "$1/SKILL.md"; }
mkskill "$root/android/.claude/skills/code-review"  code-review "Review android the repo way"
mkskill "$root/android/.claude/skills/baseline"     baseline    "Run the android baseline"
mkskill "$root/apple/.claude/skills/code-review"    code-review "Review apple the repo way"
mkskill "$root/apple/.claude/skills/speckit-plan"   speckit-plan "Spec Kit plan"
mkdir -p "$root/apple/.agents/skills/marketing"
printf -- '---\nname: marketing\ndescription: Capture marketing shots\n---\nbody\n' > "$root/apple/.agents/skills/marketing/SKILL.md"
ln -s ../../.agents/skills/marketing "$root/apple/.claude/skills/marketing"
mkskill "$root/meshtastic-mcp/src/meshtastic_mcp/skills/meshtastic-device-ops" meshtastic-device-ops "Drive devices"
run "$sync"
expect 'plugin +rendered'
rd="$root/.cache/agent-marketplace"
[ -f "$rd/.claude-plugin/marketplace.json" ] || { echo "T24: no marketplace.json"; exit 1; }
[ "$(jq -r '.plugins[0].source' "$rd/.claude-plugin/marketplace.json")" = ./nixtastic ] || { echo "T24: marketplace source"; exit 1; }
p="$rd/nixtastic"
[ -f "$p/hooks/hooks.json" ] && [ -x "$p/hooks/gradle-queue-guard.sh" ] && [ -x "$p/bin/gradle-queue" ] || { echo "T24: source not copied"; exit 1; }
[ -x "$p/hooks/nixtastic-memory-hook" ] || { echo "T24: memory hook not rendered into the plugin"; exit 1; }
[ -f "$p/skills/meshtastic-device-ops/SKILL.md" ] || { echo "T24: bundled mcp skill not copied"; exit 1; }
for f in android-code-review android-baseline apple-code-review apple-marketing; do
  [ -f "$p/skills/$f/SKILL.md" ] || { echo "T24: forwarder $f missing"; ls "$p/skills"; exit 1; }
done
[ ! -e "$p/skills/apple-speckit-plan" ] || { echo "T24: speckit forwarded"; exit 1; }
[ -f "$p/skills/meshtastic-cross-repo/SKILL.md" ] || { echo "T24: cross-repo skill missing from render"; exit 1; }
grep -q '^name: meshtastic-cross-repo$' "$p/skills/meshtastic-cross-repo/SKILL.md" || { echo "T24: cross-repo name"; exit 1; }
[ -f "$p/skills/meshtastic-cross-repo/references/umbrella-template.md" ] || { echo "T24: umbrella template missing"; exit 1; }
grep -q '^name: android-code-review$' "$p/skills/android-code-review/SKILL.md" || { echo "T24: forwarder name"; exit 1; }
grep -q '^description: "\[android\] Review android the repo way"$' "$p/skills/android-code-review/SKILL.md" || { echo "T24: forwarder description"; cat "$p/skills/android-code-review/SKILL.md"; exit 1; }
grep -qF "$root/android/.claude/skills/code-review" "$p/skills/android-code-review/SKILL.md" || { echo "T24: forwarder lacks absolute target"; exit 1; }
grep -qF 'just brief android' "$p/skills/android-code-review/SKILL.md" || { echo "T24: forwarder lacks brief"; exit 1; }
# Version is not the source placeholder.
[ "$(jq -r .version "$p/.claude-plugin/plugin.json")" != 0.0.0 ] || { echo "T24: version not written"; exit 1; }
# The root skills dir holding only bundled copies is retired.
mkdir -p "$root/.claude/skills/meshtastic-device-ops"; : > "$root/.claude/skills/meshtastic-device-ops/SKILL.md"
run "$sync"
[ ! -d "$root/.claude/skills" ] || { echo "T24: root .claude/skills kept"; exit 1; }
# A root skills dir with a foreign entry is left alone, warned.
mkdir -p "$root/.claude/skills/mine"; : > "$root/.claude/skills/mine/SKILL.md"
run "$sync"
expect 'WARN .*\.claude/skills'
[ -d "$root/.claude/skills/mine" ] || { echo "T24: foreign root skill removed"; exit 1; }
rm -rf "$root/.claude/skills"

echo "--- T25: plugin render is idempotent; a source change bumps the version once"
v1=$(jq -r .version "$p/.claude-plugin/plugin.json")
before=$(find "$p" -type f -exec ls -l --time-style=full-iso {} + | sort)
run "$sync"
expect 'plugin +rendered .*unchanged'
[ "$v1" = "$(jq -r .version "$p/.claude-plugin/plugin.json")" ] || { echo "T25: version churned"; exit 1; }
[ "$before" = "$(find "$p" -type f -exec ls -l --time-style=full-iso {} + | sort)" ] || { echo "T25: files rewritten"; exit 1; }
sleep 1
printf -- '---\nname: baseline\ndescription: Run the android baseline, now different\n---\nbody\n' > "$root/android/.claude/skills/baseline/SKILL.md"
run "$sync"
expect 'plugin +rendered .*changed'
v2=$(jq -r .version "$p/.claude-plugin/plugin.json")
[ "$v1" != "$v2" ] || { echo "T25: version not bumped"; exit 1; }
grep -q 'now different' "$p/skills/android-baseline/SKILL.md" || { echo "T25: forwarder not refreshed"; exit 1; }
run "$sync"
expect 'plugin +rendered .*unchanged'
[ "$v2" = "$(jq -r .version "$p/.claude-plugin/plugin.json")" ] || { echo "T25: version churned after bump"; exit 1; }

echo "--- T26: hook migration — only after the plugin is installed; ours removed, others kept, backup once"
cfg="$HOME/.claude/settings.json"
cat > "$cfg" <<EOF
{ "model": "opus", "hooks": {
  "SessionStart": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "herdr session" } ] },
                    { "matcher": "*", "hooks": [ { "type": "command", "command": "$root/bin/nixtastic-memory-hook start" } ] } ],
  "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "command": "$root/bin/nixtastic-memory-hook stop" } ] } ],
  "PreToolUse": [ { "matcher": "Edit|Write|MultiEdit", "hooks": [ { "type": "command", "command": "bash \"\$HOME/.claude/hooks/block-main-checkout-edits.sh\"" } ] },
                  { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"\$HOME/.claude/hooks/gradle-queue-guard.sh\"" } ] },
                  { "matcher": "Bash", "hooks": [ { "type": "command", "command": "paseo hooks claude PreToolUse" } ] } ] } }
EOF
rm -f "$HOME/.claude/plugins/installed_plugins.json"
run "$sync"
expect 'plugin +register +skipped'
expect 'plugin +hooks +kept in settings.json until the plugin is installed'
[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 2 ] || { echo "T26: migrated before install"; exit 1; }
# Pretend the CLI installed it.
mkdir -p "$HOME/.claude/plugins"
v=$(jq -r .version "$root/.cache/agent-marketplace/nixtastic/.claude-plugin/plugin.json")
jq -n --arg v "$v" '{version: 2, plugins: {"nixtastic@nixtastic": [{scope: "user", version: $v}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
jq -n --arg p "$root/.cache/agent-marketplace" '{nixtastic: {source: {source: "directory", path: $p}, installLocation: $p}}' > "$HOME/.claude/plugins/known_marketplaces.json"
run "$sync"
expect 'plugin +hooks +migrated 4'
[ -f "$cfg.nixtastic-bak-plugin" ] || { echo "T26: no backup"; exit 1; }
[ "$(jq -r .model "$cfg")" = opus ] || { echo "T26: unrelated setting lost"; exit 1; }
[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 1 ] || { echo "T26: memory start not removed / herdr lost"; cat "$cfg"; exit 1; }
jq -e '.hooks.SessionStart[0].hooks[0].command == "herdr session"' "$cfg" >/dev/null || { echo "T26: herdr rewritten"; exit 1; }
[ "$(jq '.hooks.Stop | length' "$cfg")" = 0 ] || { echo "T26: memory stop not removed"; exit 1; }
[ "$(jq '.hooks.PreToolUse | length' "$cfg")" = 1 ] || { echo "T26: guards not removed / paseo lost"; cat "$cfg"; exit 1; }
jq -e '.hooks.PreToolUse[0].hooks[0].command | test("paseo")' "$cfg" >/dev/null || { echo "T26: paseo lost"; exit 1; }
expect 'restart claude'
cp "$cfg.nixtastic-bak-plugin" "$HOME/bak1"
run "$sync"
expect 'plugin +hooks +nothing to migrate'
cmp -s "$HOME/bak1" "$cfg.nixtastic-bak-plugin" || { echo "T26: backup rewritten on a no-op"; exit 1; }
# --install-hooks now points at the plugin instead of writing.
run "$sync" --install-hooks
expect 'hooks ship in the nixtastic plugin'
[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 1 ] || { echo "T26: --install-hooks wrote entries"; exit 1; }

echo "--- T27: queue symlink — created, idempotent, a real file is backed up; register reports version drift"
q="$HOME/.claude/bin/gradle-queue"
[ -L "$q" ] || { echo "T27: no symlink"; exit 1; }
[ "$(readlink "$q")" = "$root/.cache/agent-marketplace/nixtastic/bin/gradle-queue" ] || { echo "T27: wrong target $(readlink "$q")"; exit 1; }
run "$sync"
expect 'plugin +queue +current'
rm "$q"; echo old > "$q"
run "$sync"
expect 'plugin +queue +linked .*backup'
[ -f "$q.pre-plugin" ] && [ -L "$q" ] || { echo "T27: real file not backed up"; exit 1; }
# Installed version behind the render: register says so (claude absent, so it cannot act).
jq '.plugins["nixtastic@nixtastic"][0].version = "0.1.0"' "$HOME/.claude/plugins/installed_plugins.json" > "$HOME/ip" && mv "$HOME/ip" "$HOME/.claude/plugins/installed_plugins.json"
run "$sync"
expect 'plugin +register +skipped .*claude plugin update'

echo "--- T28: doctor — plugin render, install, hooks, queue, github mcp, extras"
run_lax "$doctor"
expect 'ok +plugin render'
expect 'WARN +plugin install .*0\.1\.0'
expect 'ok +plugin hooks'
expect 'ok +gradle queue'
expect 'ok +github mcp'
expect 'agent extras'
refuse 'agent skills'
# Stale render after a source edit.
printf -- '---\nname: baseline\ndescription: changed again\n---\nbody\n' > "$root/android/.claude/skills/baseline/SKILL.md"
run_lax "$doctor"
expect 'WARN +plugin render +stale'
run "$sync"
# Duplicate hook: a user-scope entry with a plugin hook's basename.
jq '.hooks.Stop = [{matcher: "", hooks: [{type: "command", command: "/elsewhere/nixtastic-memory-hook stop"}]}]' "$cfg" > "$HOME/c" && mv "$HOME/c" "$cfg"
run_lax "$doctor"
expect 'WARN +plugin hooks .*nixtastic-memory-hook'
jq 'del(.hooks.Stop)' "$cfg" > "$HOME/c" && mv "$HOME/c" "$cfg"
# GitHub registered twice: user scope too.
echo '{"mcpServers":{"github":{"type":"http","url":"x"}}}' > "$HOME/.claude.json"
run_lax "$doctor"
expect 'WARN +github mcp .*user scope'
rm "$HOME/.claude.json"
# Queue symlink gone.
rm "$HOME/.claude/bin/gradle-queue"
run_lax "$doctor"
expect 'WARN +gradle queue'
run "$sync"

echo "--- T29: gradle guard — raw gradlew denied, queued/bypass/introspection allowed, heredoc mention allowed, --stop denied"
gg="$pluginSrc/hooks/gradle-queue-guard.sh"
# Silence is allow: a guard that has nothing to say prints nothing.
decision() { out=$(cat); if [ -z "$out" ]; then echo allow; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; fi; }
decide() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" | bash "$gg" | decision; }
[ "$(decide './gradlew assembleDebug')" = deny ]  || { echo "T29: raw gradlew allowed"; exit 1; }
[ "$(decide 'cd android && ./gradlew test')" = deny ] || { echo "T29: prefixed gradlew allowed"; exit 1; }
[ "$(decide '~/.claude/bin/gradle-queue -- ./gradlew test')" = allow ] || { echo "T29: queued denied"; exit 1; }
[ "$(decide 'GRADLE_QUEUE_BYPASS=1 ./gradlew test')" = allow ] || { echo "T29: bypass denied"; exit 1; }
[ "$(decide './gradlew --version')" = allow ] || { echo "T29: --version denied"; exit 1; }
[ "$(decide './gradlew --stop')" = deny ] || { echo "T29: --stop allowed"; exit 1; }
[ "$(decide $'git commit -F - <<EOF\nmention ./gradlew in a message\nEOF')" = allow ] || { echo "T29: heredoc mention denied"; exit 1; }
[ "$(decide 'ls')" = allow ] || { echo "T29: unrelated command denied"; exit 1; }
printf '{"tool_name":"Bash","tool_input":{"command":"./gradlew build"}}' | bash "$gg" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -q 'gradle-queue -- build' || { echo "T29: denial does not name the replacement"; exit 1; }

echo "--- T30: worktree guard — cross-tree edit denied, in-tree and outside allowed, main checkout no-op"
wg="$pluginSrc/hooks/block-main-checkout-edits.sh"
edit() { printf '{"tool_name":"Edit","cwd":%s,"tool_input":{"file_path":%s}}' "$(jq -Rn --arg c "$1" '$c')" "$(jq -Rn --arg c "$2" '$c')" | bash "$wg" | decision; }
git -C "$root/kzstd" worktree add -q "$root/kzstd/.claude/worktrees/guard" -b guard
wt="$root/kzstd/.claude/worktrees/guard"
[ "$(edit "$wt" "$root/kzstd/tracked.txt")" = deny ]  || { echo "T30: main-checkout edit from worktree allowed"; exit 1; }
[ "$(edit "$wt" "$wt/tracked.txt")" = allow ]         || { echo "T30: in-worktree edit denied"; exit 1; }
[ "$(edit "$wt" "tracked.txt")" = allow ]             || { echo "T30: relative in-worktree edit denied"; exit 1; }
[ "$(edit "$wt" "$HOME/elsewhere.md")" = allow ]      || { echo "T30: outside edit denied"; exit 1; }
[ "$(edit "$root/kzstd" "$root/kzstd/tracked.txt")" = allow ] || { echo "T30: main checkout session blocked"; exit 1; }
git -C "$root/kzstd" worktree remove --force "$wt"; git -C "$root/kzstd" branch -D guard -q

echo "--- T31: orient hook — five cwd cases, silence elsewhere, valid additionalContext"
oh="$root/.cache/agent-marketplace/nixtastic/hooks/orient.sh"
[ -x "$oh" ] || { echo "T31: orient.sh not rendered"; exit 1; }
[ "$(cat "$root/.cache/agent-marketplace/nixtastic/hooks/workspace-root")" = "$root" ] || { echo "T31: workspace-root not rendered"; exit 1; }
orient() { printf '{"cwd":%s,"hook_event_name":"SessionStart"}' "$(jq -Rn --arg c "$1" '$c')" | bash "$oh"; }
ctx() { orient "$1" | jq -r '.hookSpecificOutput.additionalContext'; }
# Without just on PATH the hook must still name working spellings.
command -v just >/dev/null 2>&1 || { ctx "$root" | grep -qF "nix run $root#brief" || { echo "T31: no nix run fallback without just"; ctx "$root"; exit 1; }; }
mkdir -p "$PWD/fakebin"; printf '#!/bin/sh\n' > "$PWD/fakebin/just"; chmod +x "$PWD/fakebin/just"
oldpath="$PATH"; PATH="$PWD/fakebin:$PATH"; export PATH
[ "$(orient "$HOME")" = "" ] || { echo "T31: not silent outside the workspace"; orient "$HOME"; exit 1; }
orient "$root" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null || { echo "T31: bad JSON at root"; orient "$root"; exit 1; }
ctx "$root" | grep -q 'workspace root' || { echo "T31: root not classified"; ctx "$root"; exit 1; }
ctx "$root" | grep -q 'just brief <repo>' || { echo "T31: spellings missing"; exit 1; }
ctx "$root/android" | grep -q 'primary checkout of `android`' || { echo "T31: repo not classified"; ctx "$root/android"; exit 1; }
git -C "$root/kzstd" worktree add -q "$root/kzstd/.claude/worktrees/orient-wt" -b orient-wt
ctx "$root/kzstd/.claude/worktrees/orient-wt" | grep -q 'worktree `orient-wt` of `kzstd`' || { echo "T31: repo worktree not classified"; ctx "$root/kzstd/.claude/worktrees/orient-wt"; exit 1; }
ctx "$root/kzstd/.claude/worktrees/orient-wt" | grep -qF "$root/kzstd" || { echo "T31: primary path missing"; exit 1; }
git -C "$root" worktree add -q "$root/.claude/worktrees/ws-wt" -b ws-wt
ctx "$root/.claude/worktrees/ws-wt" | grep -q 'worktree of the workspace repo' || { echo "T31: workspace worktree not classified"; ctx "$root/.claude/worktrees/ws-wt"; exit 1; }
ctx "$root/.claude/worktrees/ws-wt" | grep -q 'org repos are NOT here' || { echo "T31: workspace worktree warning missing"; exit 1; }
[ "$(ctx "$root" | wc -l)" -le 14 ] || { echo "T31: too long: $(ctx "$root" | wc -l) lines"; exit 1; }
git -C "$root" worktree remove --force "$root/.claude/worktrees/ws-wt"; git -C "$root" branch -D ws-wt -q
git -C "$root/kzstd" worktree remove --force "$root/kzstd/.claude/worktrees/orient-wt"; git -C "$root/kzstd" branch -D orient-wt -q
PATH="$oldpath"; export PATH; rm -f "$PWD/fakebin/just"

echo "--- T34: worktree --path resolves branch or dir name; unknown exits 1"
run "$worktree" kzstd feat/path-me
run "$worktree" --path kzstd feat/path-me
expect "^$root/kzstd/.claude/worktrees/feat-path-me\$"
run "$worktree" --path kzstd feat-path-me
expect "^$root/kzstd/.claude/worktrees/feat-path-me\$"
run_lax "$worktree" --path kzstd nope
expect 'no worktree'
run "$worktree" --remove kzstd feat-path-me

echo "--- T35: brief takes several repos; --short is one line each"
run "$brief" api kzstd protobufs
[ "$(printf '%s\n' "$res" | grep -c '^  ────')" = 3 ] || { echo "T35: expected 3 sections"; exit 1; }
run "$brief" --short api kzstd protobufs
[ "$(printf '%s\n' "$res" | grep -c '^[a-zA-Z]')" = 3 ] || { echo "T35: expected 3 lines"; printf '%s\n' "$res"; exit 1; }
expect '^api +main +drift -0/\+0 +clean +PRs '
echo dirty >> "$root/kzstd/tracked.txt"
run "$brief" --short kzstd
expect '^kzstd .* dirty! '
git -C "$root/kzstd" checkout -q -- tracked.txt

echo "--- T33: pins — submodule, toml, resolved, seed pairs; current/behind/unknown; --json; --repo --short"
# protobufs producer with two tags; firmware submodule at the latest tag, python at the older.
(cd "$root/protobufs" && git tag v2.7.26 && echo more > proto2 && git add proto2 && git commit -qm "v2.8.0" && git tag v2.8.0 && git push -q --tags origin main 2>/dev/null)
old=$(git -C "$root/protobufs" rev-parse v2.7.26); new=$(git -C "$root/protobufs" rev-parse v2.8.0)
addsub() { (cd "$root/$1" && git -c protocol.file.allow=always submodule add -q "$root/protobufs" "$2" >/dev/null 2>&1 && git -C "$2" checkout -q "$3" && git add -A && git commit -qm "pin protobufs"); }
addsub firmware protobufs "$new"
addsub meshtastic-python protobufs "$old"
mkdir -p "$root/android/gradle"; printf '[versions]\nmeshtastic-protobufs = "2.8.0"\ntakpacket-sdk = "0.9.1"\n' > "$root/android/gradle/libs.versions.toml"
mkdir -p "$root/meshtastic-sdk/gradle"; printf '[versions]\nmeshtasticProtobufs = "2.7.26"\n' > "$root/meshtastic-sdk/gradle/libs.versions.toml"
(cd "$root/TAKPacket-SDK" && git tag v0.9.1)
mkdir -p "$root/api/data" "$root/android/androidApp/src/main/assets"
echo '{"a":1}' > "$root/api/data/maintenanceUf2.json"; echo '{"a":1}' > "$root/android/androidApp/src/main/assets/maintenance_uf2.json"
echo '{"b":1}' > "$root/api/data/deviceLinks.json";     echo '{"b":2}' > "$root/android/androidApp/src/main/assets/device_links.json"
run "$pins"
expect 'producer +protobufs .*latest tag v2\.8\.0'
expect 'consumer +firmware .*v2\.8\.0 +current'
expect 'consumer +meshtastic-python .*v2\.7\.26 +behind: v2\.8\.0'
expect 'consumer +android .*org\.meshtastic:protobufs 2\.8\.0 .*current'
expect 'consumer +meshtastic-sdk .*2\.7\.26 .*behind: v2\.8\.0'
expect 'consumer +android .*takpacket-sdk 0\.9\.1 .*current'
expect 'consumer +apple .*unknown'
expect 'maintenance_uf2 same'
expect 'device_links DIFFERS'
run "$pins" --json
printf '%s\n' "$res" | jq -e 'map(select(.verdict=="behind: v2.8.0")) | length == 2' >/dev/null || { echo "T33: json verdicts"; exit 1; }
run "$pins" --repo meshtastic-python --short
expect '^protobufs v2\.7\.26 behind: v2\.8\.0$'
run "$pins" --repo labeltastic --short
expect '^-$'
# android has two consumer rows; the first (protobufs) is the phrase.
run "$pins" --repo android --short
expect '^protobufs v2\.8\.0 current$'

echo "--- T32: pr — status from the HEAD sha, threads, queue, conflicts, wait, rereview (stub gh)"
FIX="$HOME/prfix"; mkdir -p "$FIX" "$PWD/fakebin"
cat > "$PWD/fakebin/gh" <<'EOF'
#!/bin/sh
# Stub gh: replays fixtures by request shape; counts calls for the wait test.
n=$(cat "$PRFIX/calls" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$PRFIX/calls"
case "$*" in
  *"pr view"*)        cat "$PRFIX/view.json" ;;
  *graphql*)          if [ -f "$PRFIX/flip" ] && [ "$n" -ge "$(cat "$PRFIX/flip")" ]; then cat "$PRFIX/gql_after.json"; else cat "$PRFIX/gql.json"; fi ;;
  *"/check-runs"*)    case "$*" in *aaaaaaa*) cat "$PRFIX/checks_head.json" ;; *) cat "$PRFIX/checks_stale.json" ;; esac ;;
  *"/compare/"*)      echo '{"behind_by": 0}' ;;
  *"pr comment"*)     echo "$*" >> "$PRFIX/posted"; echo "https://github.com/x/y/pull/1#issuecomment-1" ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$PWD/fakebin/gh"; export PRFIX="$FIX"
cat > "$FIX/view.json" <<'EOF'
{"number":7000,"title":"feat: offline map fallback","state":"OPEN","isDraft":false,"author":{"login":"jamesarich"},"headRefOid":"aaaaaaa1111111111111111111111111111111111","headRefName":"feat/map","baseRefName":"main","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"APPROVED","url":"https://github.com/meshtastic/Meshtastic-Android/pull/7000"}
EOF
cat > "$FIX/gql.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"mergeQueueEntry":null,"reviews":{"nodes":[{"author":{"login":"garth"},"state":"APPROVED"}]},"reviewThreads":{"nodes":[
 {"id":"T1","isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"path":"app/MapScreen.kt","line":123,"body":"Consider guarding the null case here.\nmore"}]}},
 {"id":"T2","isResolved":false,"comments":{"nodes":[{"author":{"login":"jamesarich"},"path":"core/Repo.kt","line":40,"body":"this leaks the scope"}]}},
 {"id":"T3","isResolved":true,"comments":{"nodes":[{"author":{"login":"garth"},"path":"a.kt","line":1,"body":"done"}]}}]}}}}}
EOF
cat > "$FIX/gql_after.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"mergeQueueEntry":{"position":2,"state":"QUEUED"},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
EOF
cat > "$FIX/checks_head.json" <<'EOF'
{"check_runs":[{"id":1,"name":"validate-and-build / Build Desktop Debug","status":"in_progress","conclusion":null},{"id":2,"name":"Unit Tests","status":"completed","conclusion":"success"}]}
EOF
cat > "$FIX/checks_stale.json" <<'EOF'
{"check_runs":[{"id":9,"name":"Unit Tests","status":"completed","conclusion":"failure"}]}
EOF
oldpath="$PATH"; PATH="$PWD/fakebin:$PATH"; export PATH
run "$pr" android 7000
expect 'meshtastic/Meshtastic-Android #7000 +feat: offline map fallback +OPEN'
expect '^head +aaaaaaa'
expect '^merge +BLOCKED +unresolved threads: 2 +queue: not enqueued +conflicts: none'
expect '^checks@aaaaaaa +ok 1 +fail 0 +pending 1 +validate-and-build / Build Desktop Debug'
refuse 'fail 1'
expect '^reviews +APPROVED 1 \(garth\)'
expect 'coderabbitai +app/MapScreen.kt:123 +"Consider guarding the null case here\.'
expect '^next +resolve 2 threads'
run "$pr" android 7000 threads
expect 'T1'; expect 'T2'; refuse 'T3'
run "$pr" android 7000 threads --all
expect 'T3'
run "$pr" android 7000 --json
printf '%s\n' "$res" | jq -e '.threads_unresolved == 2 and .checks.pending == 1' >/dev/null || { echo "T32: json shape"; exit 1; }
# wait: the queue entry appears on the 3rd graphql call; poll fast.
echo 0 > "$FIX/calls"; echo 9 > "$FIX/flip"
NIXTASTIC_PR_POLL=0.1 run "$pr" android 7000 wait --until queue --timeout 30
expect 'queue: position 2'
echo 0 > "$FIX/calls"; rm -f "$FIX/flip"
NIXTASTIC_PR_POLL=0.1 run_lax "$pr" android 7000 wait --until queue --timeout 1
printf '%s\n' "$res" | grep -q 'timed out' || { echo "T32: no timeout message"; exit 1; }
rc=0; NIXTASTIC_PR_POLL=0.1 "$pr" android 7000 wait --until queue --timeout 1 >/dev/null 2>&1 || rc=$?
[ "$rc" = 75 ] || { echo "T32: timeout exit must be 75, got $rc"; exit 1; }
run "$pr" android 7000 rereview
[ "$(grep -c 'full review' "$FIX/posted")" = 1 ] || { echo "T32: rereview did not post once"; exit 1; }
run_lax "$pr" notarepo 1
expect 'unknown repo'
PATH="$oldpath"; export PATH

echo "all tests passed"
touch "$out"
