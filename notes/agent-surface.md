# Agent surface consolidation

One workspace plugin, installed on both machines, carrying the skills, hooks
and one MCP server that every Meshtastic session here actually uses — plus the
one thing nothing off the shelf provides: a process layer that knows this is a
directory of nineteen coupled repos, not one.

Written 2026-09-04 as sub-project 2 of the agent-workspace work; sub-project 1
was [agent-memory-sync.md](./agent-memory-sync.md). Every count below was
measured on both machines the same day, not estimated; the measurements and the
three spikes the design rests on are in [Evidence](#evidence).

## The problem

The two machines share exactly one plugin (`i-have-adhd`). Everything else on
the agent surface — process skills, per-repo skills, hooks that enforce
workspace rules, MCP registrations — exists on one machine only, was installed
by hand, and is invisible to `doctor`. Three consequences:

**The per-repo skills are unreachable from where sessions start.**
`android/.claude/skills` (5) and `apple/.claude/skills` (10) load only when the
session's cwd is inside that repo. On the desktop that happened in 4 of 84
workspace sessions; the rest started at the root, where those skills do not
exist. Nested-skill discovery does not help — it stops at the git-repo boundary
(spike 2 below), and the org repos are separate repos.

**Workspace rules live in one machine's `~/.claude`.** The laptop has two
PreToolUse guards — one denies edits that land in the main checkout from a
worktree session, one routes every Gradle build through a machine-wide queue.
Both encode rules that the desktop has been corrected on, and the desktop has
neither. They are untracked, untested and unknown to `sync`.

**No process layer knows about more than one repo.** `superpowers` (desktop
only, 18 calls this month) assumes one repo. Anthropic's own `feature-dev`
assumes one repo. Spec Kit is per repo by construction. A change that touches
`protobufs`, `firmware`, the SDK and both apps — the shape of every wire-level
change in this workspace — has no owner anywhere, and the release-order rules
in [cross-repo-contracts.md](./cross-repo-contracts.md) are applied from memory
or not at all.

## What is actually used

Interactive workspace sessions since 2026-08-12: desktop 84, laptop 92.
Automation transcripts (`sdk-cli` entrypoint) were excluded; they make no
skill, agent or MCP calls.

| Surface | Desktop | Laptop | Verdict |
| --- | --- | --- | --- |
| meshtastic MCP | 735 | 1126 | shared core |
| gradle-runner + aggregated agents | 115 | 290 | shared core, busiest thing on both |
| code-review, device-ops, workflow-authoring, artifact-design, chrome | 1–4 each | 3–8 each | shared core |
| superpowers (brainstorming 11, systematic-debugging 7) | yes | not installed | desktop only |
| github MCP (hosted read-only) | none, uses `gh` | 535 | laptop only |
| autofix, android-cli, r8-analyzer, code-review (CodeRabbit) | none | 4 of 20 user skills ever used | laptop only, third-party installers own them |
| the other 16 user skills (6 paseo, yt-dlp, agp-9, edge-to-edge, …) | 0 | 0 | unused |
| craft plugin | none | 2 skill calls, ~16 reviewer agents | not load-bearing here |
| PreToolUse guards | none | installed | laptop only, encode workspace rules |
| Datadog / Firebase | claude.ai connectors | plugins | same backends, different credential path |

Two facts from the same data shaped the design more than any count:

- **Skills are discovered, not typed.** James invoked a skill by name twice in
  the desktop's whole history and a handful of times on the laptop
  (`/speckit` 3, `/ultrareview` 6). Everything else was the model selecting
  from skill descriptions. A skill the model cannot see from a bare `claude`
  at the workspace root effectively does not exist.
- **Subagent aggregation already works.** The `.claude/agents/<repo>--<agent>.md`
  copies that `sync` lays at the root are the most-used agent surface on both
  machines. Skills cannot follow that pattern by copying — a skill directory's
  name is its identity and `code-review` exists in three places — so the
  question was how skills get the same reach.

## Decisions

Made in the brainstorm, in order, with the alternative each one rejected:

1. **Shared core plus local extras, plus one process layer.** Not full
   parity: the work-account laptop and personal-account desktop would have to
   carry each other's Datadog and GitHub tenancy.
2. **The process layer is bespoke, built on Anthropic-native primitives**
   (plan mode, subagents, `/code-review`, `.#worktree`). Not `superpowers` plus
   an adapter, not `feature-dev`, not `craft`: all three are single-repo, and
   the workspace's gap is the cross-repo shape. Nothing generic is rebuilt —
   the layer orchestrates, it does not teach brainstorming or TDD.
3. **Spec Kit: read the constitution, ignore the lifecycle.** Measured over
   90 days: 18 of 1119 android commits touched `specs/`, 57 of 1055 apple
   (one author), 2 of 94 sdk, 0 of 180 docs. Android abandoned it. The
   constitutions are real governance docs and are read where they exist; no
   spec/plan/tasks files are written. `CLAUDE.md`'s "work flows through the
   spec lifecycle" line is corrected.
4. **Per-repo skills reach the root as generated forwarder skills**, one per
   repo skill, `<repo>-<skill>`. Not symlinks (name collisions, per-machine
   targets), not "document `bin/claude-ws`" (4 of 84 sessions).
5. **The unit is one plugin, `nixtastic`.** It is the only container that
   carries skills, hooks and MCP together and installs identically on both
   machines; the harness namespaces its skills `nixtastic:<skill>`.
6. **Joins the core from the laptop:** the worktree edit guard, the Gradle
   queue guard with its queue script, and the GitHub MCP registration.
   **Stays local:** superpowers, remember, the CodeRabbit and Google skills,
   the LSP plugins, the Datadog and Firebase connectors/plugins. `doctor`
   reports extras, never writes them.
7. **The store carries nothing for the plugin.** Every part of it is derived
   from the workspace repo plus the local checkouts, so it is rendered locally
   and never crosses machines. Rendering into `~/.nixtastic-agent` would have
   both machines pushing different forwarder sets to one tracked path and
   breaking the memory push that sub-project 1 made reliable. Memory is
   state; the plugin is a build artefact.
8. **No credential is ever tracked or rendered.** The GitHub token is read
   from `gh` at connect time on each machine.

## Layout

```
meshtastic/                        workspace repo, tracked
  plugin/                          hand-written source
    .claude-plugin/plugin.json     name "nixtastic"; version written by sync
    skills/
      meshtastic-cross-repo/       the process layer (below)
      (meshtastic-device-ops, -e2e, -org-knowledge are copied at render from
       meshtastic-mcp/src/meshtastic_mcp/skills/, the source the root copies came from)
    hooks/hooks.json               memory hooks + two guards, ${CLAUDE_PLUGIN_ROOT} paths
    hooks/*.sh                     guard scripts
    bin/gradle-queue               plugin bin/ is on the Bash PATH while enabled
    bin/github-mcp-headers         prints the bearer header from `gh auth token`
    .mcp.json                      github read-only server
  .cache/agent-marketplace/        rendered by sync, gitignored
    .claude-plugin/marketplace.json
    nixtastic/                     copy of plugin/ plus generated:
      skills/<repo>-<skill>/       forwarders, one per repo skill found (speckit-* skipped)
      skills/meshtastic-*/         the three bundled meshtastic-mcp skills
      hooks/nixtastic-memory-hook  copied from bin/, which memory_pass writes per machine
```

`.claude/skills/` at the workspace root goes away: plugin skills are visible
from every cwd on the machine, worktrees and repo checkouts included, which is
more reach than the root-only copies had. `.claude/agents/` **stays**: plugin
agent naming is undocumented, and bare-name dispatch of `gradle-runner` from
`android/CLAUDE.md` is what works today on both machines.

A forwarder is one paragraph. Its frontmatter `name` is `<repo>-<skill>`; its
`description` is `[<repo>] ` followed by the target's own description, so the
model selects it on the same words it would have selected the original. Its
body names the absolute target directory — the harness announces a skill's
base directory when it loads normally, and a forwarder loses that, so the
target's `references/` and scripts would otherwise resolve wrong — and says to
run `just brief <repo>` first, then read and follow the target `SKILL.md`.

Forwarders skip `speckit-*` (decision 3: nine descriptions per session for an
unused lifecycle).

## The process layer: `meshtastic-cross-repo`

One skill, namespaced `nixtastic:meshtastic-cross-repo`. Its description names
the triggers so a bare root `claude` picks it up: a proto or wire-contract
change, a shared API resource, a feature that must land in several repos in
order, "bump X everywhere".

**Reads, in order:** the repo table in `CLAUDE.md`,
[cross-repo-contracts.md](./cross-repo-contracts.md), `just brief <repo>` for
each candidate repo, that repo's `.specify/memory/constitution.md` if one
exists, and memory. Nothing new is invented; it drives what the workspace
already knows.

**Eight steps:**

1. **Scope.** From the request, list the repos touched and why, then add the
   ones the coupling graph implies — a proto edit implies the two submodule
   bumps and an `android` version bump. Confirm the list.
2. **Brief.** `just brief` per repo. Stop and say so if a checkout is dirty
   or drifted; another session may own it.
3. **Umbrella note.** One file, `notes/<date>-<feature>.md`: goal, a
   touched-repos table with a column for the landed commit or PR, contract
   changes, release order, per-repo verification, status. The only durable
   artefact, updated as things land.
4. **Design gate.** Plan mode with the per-repo plan. Nothing is edited until
   the plan is approved there.
5. **Worktrees.** `nix run .#worktree -- <repo> <branch>` per repo, branch
   named per that repo's convention.
6. **Execute in release order.** Producers before consumers: `protobufs`,
   then `firmware` and the python submodule bump, then the SDK, then the
   apps. Inside each worktree the repo's own conventions rule: commit style
   from the table, PR or direct, CodeRabbit where it runs.
7. **Verify.** Each repo's own gate, plus `meshtastic-e2e` where a device and
   an app both changed.
8. **Close.** Fill the landed column in the umbrella note.

**Does not:** teach brainstorming, TDD or debugging; write Spec Kit files;
replace plan mode. A `--dry-run` form stops after step 4.

**Acceptance test, from a real feature.** Given "add a maintenance-UF2 quirk
endpoint and consume it" — the bootloader-quirks work `CLAUDE.md` describes —
the dry run must name `api`, `android`, `apple` and `web-flasher`, put `api`
first in the release order, and write the umbrella note. That run, not a
description of it, is the pass criterion.

## Hooks and MCP

`plugin/hooks/hooks.json`, four entries, all under `${CLAUDE_PLUGIN_ROOT}`:

| event | matcher | script | origin |
| --- | --- | --- | --- |
| SessionStart | | `hooks/nixtastic-memory-hook start` | copied by `sync` from `bin/nixtastic-memory-hook`, which `memory_pass` writes |
| Stop | | `hooks/nixtastic-memory-hook stop` | same |
| PreToolUse | `Edit\|Write\|MultiEdit` | `hooks/block-main-checkout-edits.sh` | laptop `~/.claude/hooks`, now tracked |
| PreToolUse | `Bash` | `hooks/gradle-queue-guard.sh` | same |

The guards get one portability fix on the way in: `/usr/bin/awk` and
`/usr/bin/grep` become PATH lookups. The gradle guard's denial text keeps
naming `~/.claude/bin/gradle-queue`, which `sync` satisfies with a symlink to
the rendered plugin's `bin/`, because the upstream `android` agent probes that
exact path. herdr and paseo hooks are not touched.

Hooks never hot-swap (documented); `sync` says "restart claude" whenever it
changed the hook set.

`plugin/.mcp.json`, one server:

```json
{ "mcpServers": { "github": {
    "type": "http",
    "url": "https://api.githubcopilot.com/mcp/readonly",
    "headersHelper": "${CLAUDE_PLUGIN_ROOT}/bin/github-mcp-headers" } } }
```

The helper prints an `Authorization: Bearer` header built from `gh auth token`
at connect time. No token in any file, nothing to export, and it works on both
machines because both are logged into `gh` as the same GitHub user. The docs
name `headersHelper` for dynamic and sensitive values but do not spell out its
output contract; the plan carries a five-minute spike for it, with
`"Authorization": "Bearer ${GITHUB_MCP_TOKEN}"` plus a direnv export as the
fallback. The `/readonly` endpoint is the safety layer regardless of token
scope (shared memory `github-mcp-bearer-auth`, 2026-06-18).

The meshtastic server stays on its user-scope launcher; moving it into the
plugin is a follow-up.

## Tool surface

### `nix run .#sync`

Gains one pass, `plugin`, after the memory pass. Five idempotent steps:

1. **Render.** Copy `plugin/` into `.cache/agent-marketplace/nixtastic/`; for
   every `<repo>/.claude/skills/*/SKILL.md` in the repo table write a
   forwarder; render the memory hook; write `marketplace.json`. Hash the
   rendered tree; if it differs from the stored hash, write a new version into
   `plugin.json`.
2. **Register.** Marketplace missing from `known_marketplaces.json`:
   `claude plugin marketplace add <render dir>`. Plugin not installed:
   `claude plugin install nixtastic@nixtastic`. Version changed:
   `claude plugin update`. Otherwise nothing. Skipped, and reported as
   skipped, when `claude` is not on PATH (the test sandbox).
3. **Migrate hooks.** Remove from `~/.claude/settings.json` the user-scope
   entries the plugin now owns, matched by script basename: the two memory
   hooks and the two guards. Back the file up first, print each removal. The
   old `~/.claude/hooks/*.sh` are left in place and named as now unused.
   `--install-hooks` becomes a message pointing here.
4. **Queue symlink.** `~/.claude/bin/gradle-queue` → rendered
   `bin/gradle-queue`; a pre-existing real file is backed up beside it.
5. **Report.** One line per step in the memory pass's shape, plus "restart
   claude to load hooks and MCP" whenever step 2 or 3 changed anything.

`sync` never edits `~/.claude.json` MCP entries. The laptop's user-scope GitHub
registration is reported by `doctor`; removing it
(`claude mcp remove -s user github`) is a named manual step.

A second run changes nothing and prints zero updates. That is the fixture.

### `nix run .#doctor`

| line | ok when | otherwise |
| --- | --- | --- |
| plugin render | stored hash matches source plus repo skills | "stale, run sync" |
| plugin install | installed, version equals rendered, marketplace path equals render dir | names the missing step |
| plugin hooks | no hook command basename in both plugin and user scope | warns, names the duplicate |
| gradle queue | symlink resolves | prints the fix |
| github mcp | registered exactly once | warns if also in `~/.claude.json` |

Plus one informational line, never a warning: how many plugins and user skills
this machine has outside the core. The existing `agent skills` line, which
checks `.claude/skills` at the root, is retired with that directory.

## Testing

Gate stays `just check`. ShellCheck's file list grows to cover
`plugin/hooks/*.sh`, `plugin/bin/*`. Fixtures in `tools-tests.sh` against a
fake workspace with two fake repos:

1. **Render.** Both fake repos carry a skill named `code-review`, one carries a
   unique one. Three forwarders, names prefixed, no collision, each body
   naming its absolute target, each description starting `[<repo>]`.
2. **Idempotence.** Second render: hash, version and output unchanged.
3. **Version bump.** Edit one fixture skill description: hash and version
   change, nothing else.
4. **Hook migration.** Fixture `settings.json` with the four old entries plus
   a paseo entry: four gone, paseo intact, backup written. Again: no-op, no
   second backup.
5. **Manifest.** `hooks.json` and `marketplace.json` parse; every referenced
   script exists in the render and is executable.
6. **Guards.** Feed PreToolUse JSON and check the decision: raw
   `./gradlew build` denied, `gradle-queue -- build` allowed, `--version`
   allowed, a heredoc that merely mentions gradlew allowed, `--stop` denied;
   an edit into the main checkout from a worktree cwd denied, an edit inside
   the worktree allowed, with a real `git worktree` in the fixture. The
   laptop's scripts have never had tests.
7. **doctor.** Stale render detected after a fixture skill edit; duplicate
   hook detected when a plugin hook's basename is also in fixture user
   settings.

Do not reintroduce `grep -q` on a chatty pipe in the fixture: under
`pipefail` it races SIGPIPE (found in sub-project 1).

Manual acceptance on both machines, recorded under [Evidence](#evidence):

- `claude -p` canary sees `nixtastic:meshtastic-cross-repo` and one forwarder.
- `/hooks` shows the four plugin hooks and no user-scope duplicate; `doctor`
  all green.
- GitHub MCP tools appear in a fresh session with no token on disk.
- The cross-repo dry run names the four repos and writes the umbrella note.

## Rollout

1. **Desktop first.** Land, `nix run .#sync`, restart, run the acceptance
   list. The desktop has no user-scope guards or queue, so migration touches
   only the two memory hooks.
2. **Laptop.** Pull the workspace, `nix run .#sync`. It removes the four
   user-scope hook entries, backs up and replaces `~/.claude/bin/gradle-queue`
   with the symlink, and `doctor` names the user-scope GitHub registration to
   remove by hand.
3. **A week later**, with the scheduled `memory.pre-sync` cleanup: delete
   `~/.claude/hooks/*.sh` on both machines. The laptop's 16 unused skills are
   James's to delete or keep; `doctor` counts them, nothing more.

## Docs

- `CLAUDE.md`, two edits, no net growth: the Spec Kit paragraph stops
  claiming work flows through the lifecycle; the "per-repo skills are not
  aggregated, launch with `bin/claude-ws`" bullet becomes the forwarder
  pointer.
- `AGENTS.md` gains an Agent surface section carrying the reasoning in
  [Decisions](#decisions).
- `README.md`: one setup line, "sync installs the plugin, restart claude".
- [agent-memory-sync.md](./agent-memory-sync.md) Follow-ups: the
  consolidation entry becomes a link here.
- The shared memory `subproject-2-agent-surface-handoff` is marked done and
  points here.

## Out of scope

Moving the meshtastic MCP or the aggregated agents into the plugin; the
laptop's permission allows as plugin `settings.json`; superpowers and remember
(local extras, unchanged); the `~/nixtastic` rename; deleting anything on the
laptop.

## Evidence

**Measurement method.** For each machine, every transcript under
`~/.claude/projects/*/` was scanned for `Skill` tool inputs, `subagent_type`
values and `mcp__<family>__` tool names, then split by slug into interactive
workspace sessions and everything else. The desktop's 113 `-tmp` transcripts
are `entrypoint: sdk-cli` and contain zero skill, agent or MCP calls. The
laptop's `-Users-james-StudioProjects-*` slugs predate the workspace and were
excluded from the "used here" counts; `craft`'s real use was there. Typed
slash commands came from `~/.claude/history.jsonl`. The laptop was measured
over ssh on the LAN (`james@192.168.1.138`); there is no ssh config entry for
it.

**Spike 1 — plugin reload semantics (desktop, 2026-09-04).** A throwaway
marketplace with one plugin and one canary skill was added from a scratch
directory and installed. The install copied the plugin to
`~/.claude/plugins/cache/<mkt>/<plugin>/0.0.1/`. The canary's description was
then edited *in the source* with no version bump and no command; the very next
`claude -p` reported the new text while the cache copy still held the old one.
`claude plugin update` at the same version said "already at the latest";
after a version bump it copied a `0.0.2/` and the new text showed there too.
Conclusion: for a directory-source marketplace, source edits are live at the
next session. The official docs say plugins are copied to the cache and are
silent on when directory-source edits show, so the design bumps the version
and runs `update` when the content hash changes — the documented path — and
treats live-read as a bonus, not a dependency. Uninstalled and removed after.

**Spike 2 — nested skill discovery across a repo boundary (desktop).** From
the workspace root, `claude -p` was asked to list skills containing
`baseline`, `proto-bump` or `crashlytics` (all in `android/.claude/skills`):
NONE, both before and after reading `android/AGENTS.md`. Invoking
`android:baseline` and `baseline` via the Skill tool: `Unknown skill`. The
docs' on-demand nested discovery (`packages/api:skill-name`) does not cross a
git-repo boundary. Forwarders stay.

**Spike 3 — official documentation review (code.claude.com/docs, 2026-09-04).**
Confirmed: plugin components and manifest fields, `version` optional,
`${CLAUDE_PLUGIN_ROOT}` in hooks and `.mcp.json`, `${VAR}` expansion in MCP
`headers`, `headersHelper` for dynamic headers, plugin `bin/` on the Bash PATH
while enabled, plugin `settings.json` as defaults, plugin skills namespaced
`plugin:skill` and visible from any cwd, hooks never hot-swap, `matcher` and
`permissionDecision: deny` in plugin PreToolUse hooks. Not documented: plugin
vs user-scope hook double firing (the reference says every matching hook
runs, which is why `sync` removes the old entries), plugin agent reference
syntax (why agents stay at the root), directory-source refresh semantics
(spike 1), and any guidance for a directory of many repos or for forwarder
skills. No marketplace plugin, Anthropic's or third-party, addresses a
multi-repo workspace.

**Gradle queue compatibility.** `android/.claude/agents/gradle-runner.md`
already probes `$HOME/.claude/bin/gradle-queue` and falls back to `./gradlew`,
and documents the guard's denial text and exit code 75. Shipping the guard to
the desktop therefore requires shipping the queue with it, and nothing else
changes for the most-used agent on either machine.

**Spec Kit activity, 90 days to 2026-09-04.** Commits touching `specs/` or
`.specify/` over all commits: android 18/1119, apple 57/1055 (single author,
last 2026-08-15), meshtastic-sdk 2/94, meshtastic 0/180. Only `apple` has the
`speckit-*` skills checked in; the other three carry constitution and
templates only.

**Acceptance runs.**

*james-pc, 2026-09-04.* First `nix run .#sync` after landing: `rendered 6
forwarder(s)`, `retired .claude/skills`, `register added+installed`, `hooks
migrated 2 user-scope entr(ies)`, `queue linked`. `doctor`: all five plugin
lines ok, `agent extras 4 other plugin(s), 0 user skill(s)`, all clear. A fresh
`claude -p` listed all ten `nixtastic:` skills (six forwarders — five android,
one apple; the three bundled meshtastic-mcp skills; `meshtastic-cross-repo`).
Asked, without file access, which skill fits "bump the protobufs pin everywhere
and land it in firmware, python, android and apple", it answered
`nixtastic:meshtastic-cross-repo`. `claude mcp list` showed
`plugin:nixtastic:github … ✔ Connected` with the `headersHelper` form, so the
`${GITHUB_MCP_TOKEN}` fallback was not needed; the helper prints
`{"Authorization":"Bearer gho_…"}` and no file carries the token. The plugin's
SessionStart hook was proven live, not assumed: with the store's `FETCH_HEAD`
aged ten minutes, one fresh `claude -p` advanced it. Both migrated hook entries
are in `settings.json.nixtastic-bak-plugin`; herdr and paseo entries are
untouched. The cross-repo dry run against the bootloader-quirks feature was
not executed at rollout (a nested fifteen-minute session was declined); it
runs on the first real cross-repo change and gets recorded here then.

*MacBook Air, 2026-09-04, over ssh from the desktop (login shell,
`MESHTASTIC_WORKSPACE` exported by hand).* `git pull --ff-only` to `e8d1785`,
then `nix run .#sync`: `rendered 6 forwarder(s)`, `retired .claude/skills`,
`register added+installed`, `hooks migrated 4 user-scope entr(ies)` (the two
memory hooks and the two guards; herdr and six paseo entries untouched, backup
in `settings.json.nixtastic-bak-plugin`), `queue linked
backup=~/.claude/bin/gradle-queue.pre-plugin`. `doctor`: five plugin lines ok
except `WARN github mcp registered in user scope too`, as designed; `agent
extras 8 other plugin(s), 20 user skill(s)`; memory lines unchanged. The plugin
SessionStart hook was proven the same way as on the desktop: an aged
`FETCH_HEAD` advanced after one `claude -p`, with no user-scope memory hook left
to have done it.

Unverified over ssh, to be checked in a GUI session on the laptop: the skill
list probe (`claude -p` reported "OAuth session expired" for the work account
in the non-interactive session, though its SessionStart hook still ran); the
headers helper printed `{}` because `gh auth token` reads the macOS keychain,
which is locked for a non-GUI ssh session; consequently whether
`plugin:nixtastic:github` connects there (`claude mcp list` over ssh showed
only the user-scope `github` entry connected). Once the plugin server is seen
connected in a GUI session, `claude mcp remove -s user github` clears the
doctor warning.

Unverified on both machines: whether a session launched from the Claude
Desktop app (160 of the laptop's 244 sessions) loads plugin hooks. Check: age
the store's `FETCH_HEAD` by ten minutes, open one Desktop-app session in the
workspace, `stat` it again.
