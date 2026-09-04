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
git -C "$origins/nixtastic-agent.git" log --oneline | grep -q 'memory: import' || { echo "T18: import not pushed"; exit 1; }
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
run "$sync" --install-hooks
expect 'hooks installed'
[ -f "$cfg.nixtastic-bak" ] || { echo "T21: no backup"; exit 1; }
[ "$(jq -r .model "$cfg")" = opus ] || { echo "T21: unrelated setting lost"; exit 1; }
[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 2 ] || { echo "T21: herdr entry lost or ours missing"; exit 1; }
jq -e '.hooks.SessionStart[0].hooks[0].command == "herdr session"' "$cfg" >/dev/null || { echo "T21: existing hook rewritten"; exit 1; }
jq -e '.hooks.Stop[0].hooks[0].command | test("nixtastic-memory-hook.* stop$")' "$cfg" >/dev/null || { echo "T21: stop hook missing"; exit 1; }
[ -x "$root/bin/nixtastic-memory-hook" ] || { echo "T21: hook script missing"; exit 1; }
run "$sync" --install-hooks
expect 'hooks already installed'
[ "$(jq '.hooks.SessionStart | length' "$cfg")" = 2 ] || { echo "T21: second install duplicated the entry"; exit 1; }
# The hook: a memory written through the link is committed and pushed.
printf -- '---\nname: from-a-session\ndescription: "x"\nmetadata:\n  type: project\n---\nbody\n' > "$projects/$(slug "$root")/memory/from-a-session.md"
printf -- '- [dup line](from-a-session.md) — x\n- [dup line](from-a-session.md) — x\n' >> "$store/memory/MEMORY.md"
run "$root/bin/nixtastic-memory-hook" stop
git -C "$origins/nixtastic-agent.git" log --oneline | grep -q 'memory: ' || { echo "T21: hook did not push"; exit 1; }
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
run "$root/bin/nixtastic-memory-hook" start
[ -f "$store/memory/from-the-laptop.md" ] || { echo "T21: start hook did not pull"; exit 1; }

echo "--- T22: doctor — store, links, hooks, state, age"
run_lax "$doctor"
expect 'ok +memory links'
expect 'ok +memory hooks'
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

echo "all tests passed"
touch "$out"
