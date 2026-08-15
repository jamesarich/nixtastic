# History archive — refs/old/*

When the pre-nixtastic workspaces (`~/StudioProjects`, `~/meshtastic`) were
retired (2026-08-15), every local branch, stash, and dirty worktree that held
work not on any remote was preserved inside the new clones as git refs under
`refs/old/`. They are invisible to `git branch` on purpose.

**These refs are machine-local.** They exist only in the clones on the machine
that ran the migration (James's laptop; the desktop ran its own gathering and
may hold a different set). `git clone`/`fetch` never copies them. Losing the
clone loses the archive — if any of it starts to matter, push it to a fork or
turn it into a real branch/PR.

## Namespaces

- `refs/old/studio/<branch>` — branches from `~/StudioProjects` checkouts
  whose tips were not on any remote. Agent/bot scratch (`claude/*`, `codex/*`,
  `renovate/*`) and fully-upstream branches were pruned; what survives is
  human-named work.
- `refs/old/old-mesh/<branch>` — same, from `~/meshtastic` (kzstd only).
- `refs/old/studio-stash/sN` — every git stash from the old checkouts,
  converted to refs (the stash description is the commit subject).
- `refs/old/studio-wip/<name>` — snapshot commits of dirty scratch worktrees
  that held real uncommitted source at migration time.

## Browse and recover

```bash
git -C <repo> for-each-ref refs/old --format='%(refname:short)  %(committerdate:short)  %(subject)'
git -C <repo> show --stat refs/old/studio/<branch>          # inspect
git -C <repo> branch <name> refs/old/studio/<branch>        # resurrect
git -C <repo> update-ref -d refs/old/studio/<branch>        # discard
```

## Inventory (2026-08-15)

| Repo | refs | Notable |
| --- | --- | --- |
| android | 158 | 22 stashes; WIP snapshots: issue-6316 deep-links, ML Kit message translation, AutoLinkText; branches incl. M3-expressive adoption, message-markdown-styling, usb-attach-detach-restart, car-play-policy, waypoint-picker-filter, the `pr####` review-rework branches (lockdown-v2 ~26 commits) |
| meshtastic-sdk | 15 | `feat/meshtastic-android-integration-gaps` (39 commits), speckit, protobuf-sdk-transition, publishing-convention WIP, 9 stashes |
| MQTTastic-Client-KMP | 15 | mqtt-3.1.1 support, probe API, connection-state reasons, TLS fixes, maven-central-autopublish |
| firmware | 3 | device-id-all-platforms (PR #10995 lineage), native-macos-udp-multicast (PR #10784, open) |
| meshtastic-mcp | 3 | FleetSuite web control plane + hardware bench harness (`fleetsuite-merge-v2`) |
| protobufs | 2 | `jamesarich/kmp-proto-library` (10 commits) |
| apple | 2 | pr-1898 spec work + its stash |
| kzstd | 2 | old-mesh ci branch (content since landed) |
| TAKPacket-SDK | 1 | **complete `takpacket-integrate` agent skill/plugin** (`studio-wip/takpacket-integrate-skill`) — exists nowhere else; a candidate to resurrect into the repo proper |

Counts drift as refs get resurrected or discarded; the `for-each-ref` command
above is the live truth.
