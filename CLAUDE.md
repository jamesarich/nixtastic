# CLAUDE.md

Workspace root for multi-repo Meshtastic work. This file is the **router** —
deliberately small, because the per-repo agent docs are far too large to all
be loaded.

- [`README.md`](./README.md) — human workflow
- [`AGENTS.md`](./AGENTS.md) — canonical detail and the reasoning behind every
  constraint. If the two ever disagree, `AGENTS.md` wins.

## Protocol — before editing under any `<repo>/`

1. **`nix run .#brief -- <repo>`** — live branch, drift, correct shell, and
   every agent/governance doc that repo actually has. Run from inside a
   worktree it describes *that* worktree — named on a `checkout` line — not
   the primary checkout. The bare `.#` form only works **from the workspace
   root**: `.#` resolves the flake from your cwd and stops at a git-repo
   boundary, so inside any repo or worktree it dies with "is not part of a
   flake". From there use **`just brief <repo>`** (cwd-preserving by design,
   so it stays worktree-aware) or `nix run "$MESHTASTIC_WORKSPACE"#brief --
   <repo>`. The tools print whichever form suits where you are standing.
2. **Read that repo's own docs first.** Precedence:
   `.specify/memory/constitution.md` → `AGENTS.md` → `CLAUDE.md` →
   `CONTRIBUTING.md`. A repo with no `AGENTS.md` is not undocumented — check
   [`notes/`](./notes/).
3. **Match that repo's conventions, not the workspace's.** Commit style,
   review process and governance differ per repo.
4. **Never mix commits across repos.** Each is independent; this workspace is
   its own repo too.

A precondition, not a suggestion — a bare "read AGENTS.md" pointer has already
been skipped in practice, which is why `.#brief` exists.

## The repos

| Repo | Role | Stack | Shell | Branch | Commits | Agent docs |
| --- | --- | --- | --- | --- | --- | --- |
| `firmware` | device firmware | C++ / PlatformIO | `.#firmware` | `develop` | sentence-style, ad-hoc prefixes | `AGENTS.md` |
| `android` | Android + desktop app | Kotlin / Compose | `.#android` | `main` | Conventional | `AGENTS.md`, Spec Kit, skills, subagents |
| `apple` | Apple platform clients | Swift / Xcode | `.#apple` | `main` | Conventional | Spec Kit → [`notes/apple.md`](./notes/apple.md) |
| `meshtastic-sdk` | KMP client SDK | Kotlin MP | `.#kotlin` | `main` | Conventional | `AGENTS.md`, `GOVERNANCE.md`, `CODEOWNERS`, Spec Kit |
| `MQTTastic-Client-KMP` | MQTT 5 client lib | Kotlin MP | `.#kotlin` | `main` | Conventional | `AGENTS.md` |
| `kzstd` | zstd codec lib | Kotlin MP | `.#kotlin` | `main` | Conventional | `AGENTS.md` |
| `gradle-flatpak-sources` | Flathub manifest plugin | Kotlin / Gradle | `.#kotlin` | `main` | Conventional | → [`notes/gradle-flatpak-sources.md`](./notes/gradle-flatpak-sources.md) |
| `meshtastic-mcp` | MCP server + agent skills | Python / uv | `.#mcp` | `master` | Conventional | `AGENTS.md`, `CONVENTIONS.md`, `llms.txt`, cursor + windsurf rules |
| `protobufs` | shared `.proto` definitions | buf · deno · gradle · cargo | `.#protobufs` | `master` | mixed | → [`notes/protobufs.md`](./notes/protobufs.md) |
| `design` | design standards, tokens, assets | node · inkscape | `.#design` | `master` | Conventional | → [`notes/design.md`](./notes/design.md) |

The table is orientation; `nix run .#brief -- <repo>` is truth — it reads the
live branch, drift, and doc inventory (with sizes) every time.

Not in the workspace: `meshtastic-sniffer` (not the org), `meshtastic-backend`
(Gradle 7.3.1, predates JDK 21), `pluginmeshtastic` (non-redistributable ATAK
SDK).

## Cross-repo coupling

- `protobufs` is vendored as a submodule at `firmware/protobufs`. Edit in
  `protobufs`, bump the pointer in `firmware`. Wire compatibility affects
  firmware, both apps and the SDK **simultaneously**.
- `meshtastic-sdk` is consumed by `apple` and `android` — an ABI change breaks
  them without touching their repos.
- `gradle-flatpak-sources` packages `android`'s `:desktopApp` for Flathub.
- `design` defines standards that `android`, `apple` and `web` implement;
  tracked on <https://github.com/orgs/meshtastic/projects/16>, not in the repo.

## Spec Kit

`android`, `apple` and `meshtastic-sdk` use it. Their
`.specify/memory/constitution.md` (8–12 KB) **outranks** other agent docs, and
work is expected to flow through the spec lifecycle rather than ad-hoc edits.

`apple/CLAUDE.md` is Spec Kit-managed and **dynamic** — regenerated to point at
the active `specs/<feature>/plan.md`. Read it to find the live plan; never
hand-edit it.

## Worktrees

`nix run .#worktree -- <repo> <branch>` creates one under
`<repo>/.claude/worktrees/` with the repo's shell wired up and a `.mcp.json`
so the `meshtastic-mcp` tools follow you in — except where upstream tracks
its own `.mcp.json` (`android`, `firmware`): theirs wins, and the
**user-scope launcher registration** (`doctor` checks it, `sync` prints the
command) is what carries the meshtastic tools there instead. A worktree made any
other way (hand-rolled `git worktree`, agent skills) silently lacks these
files — for `firmware`, including the sidecar that keeps it off upstream's
broken PlatformIO; `nix run .#sync` adopts such strays and writes what's
missing.

**Never use the harness's own worktree isolation (`isolation: "worktree"`,
`EnterWorktree`) for repo work.** At the workspace root it creates a worktree
of the *workspace* repo, which contains none of the org repos — they are
untracked. Use `nix run .#worktree` instead.

## Changing the workspace itself

The tool scripts are real files in `scripts/` — edit them there, not in
`flake.nix`, and follow the Conventions section of `AGENTS.md`. The gate is
two commands (`just check` runs both): `nix flake check --all-systems
--no-build`, then `nix flake check` — the second builds the tools (ShellCheck)
and runs their fixture tests.

## Fails silently — check these first

`nix run .#doctor` checks most of this list and prints the fix for what it
finds — run it before diagnosing by hand.

- **`MESHTASTIC_WORKSPACE` unset** → JDK pinning inert, Gradle auto-provisions
  its own JDKs. `direnv` sets it. In a per-repo `.envrc` it must be exported
  **before** `use flake`, or the shellHook runs too early to see it.
- **Never hand-write a repo `.envrc`** — `nix run .#sync` generates them.
  `firmware` is special: it tracks its own (`use nix`, pointing at upstream's
  flake), so it gets an untracked `.envrc-workspace` sidecar instead. Never
  edit a tracked `.envrc`.
- **`.mcp.json` is generated too** — `.#sync` at the root, `.#worktree` per
  worktree. It names store paths, so `nix flake update` breaks the server until
  you re-run `.#sync`. A bare `claude mcp add` (local scope, store paths in
  `~/.claude.json`) is the trap; the sanctioned form is **user scope pointed
  at the stable `bin/meshtastic-mcp-launch`**, which `sync` rewrites — that
  one reaches `android/`, `firmware/` and every worktree, and never goes
  stale.
- **Per-repo subagents only exist at the root because `.#sync` copies them
  there.** Claude Code scans `.claude/agents/` from the cwd up to the
  enclosing repo root, and the org repos are not ancestors of the workspace —
  so `android`'s `gradle-runner` is unusable from a root session until sync
  aggregates it into `.claude/agents/<repo>--<agent>.md`. The copies keep
  upstream's frontmatter `name:` (that, not the filename, is what the Agent
  tool resolves), so `android/CLAUDE.md`'s "dispatch the `gradle-runner`
  subagent" works verbatim from here. `doctor` reports missing or stale
  copies; two repos sharing a name resolve by filesystem order, so `sync`
  warns rather than picking silently.
- **The direnv hook fires only in interactive shells** — scripts and agent
  subshells get no repo environment, so Gradle silently runs unpinned. From
  non-interactive contexts use `direnv exec <repo-or-worktree> <cmd>`.
- **`.#mcp` needs `LD_LIBRARY_PATH`** — `UV_PYTHON` pins the venv to the Nix
  interpreter, whose loader cannot see the system `libstdc++`/`libz` that
  manylinux wheels link. numpy, opencv and torch install fine and then fail to
  import, blaming neither library.
- **Six JDKs required**, satisfying three separate Gradle mechanisms. Removing
  any one breaks a specific repo.
- **Toolchain config belongs in `gradle.properties`, never `GRADLE_OPTS`** —
  the daemon never sees the launcher's environment.
- **Default branches are not all `main`** — see the table.
- **`.gitignore` here denies by default** — a new file is untracked until
  whitelisted.
- **`nix flake check` only evaluates shells** — passing eval does not mean a
  repo builds.
