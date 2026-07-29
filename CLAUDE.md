# CLAUDE.md

Workspace root for multi-repo Meshtastic work. Canonical guidance for **this
repo** is [`AGENTS.md`](./AGENTS.md); if they diverge, `AGENTS.md` wins.

This file is the **router**. It is deliberately small because the per-repo
agent docs below total ~66 KB and cannot all be loaded.

## Protocol — before editing under any `<repo>/`

1. Run `nix run .#brief <repo>`. It reports the live branch, drift, correct dev
   shell, and every agent/governance doc that repo actually has.
2. **Read that repo's own docs before making changes.** Precedence:
   `.specify/memory/constitution.md` → `AGENTS.md` → `CLAUDE.md` →
   `CONTRIBUTING.md`. A repo with no `AGENTS.md` is not undocumented — see
   [`notes/`](./notes/).
3. Match **that repo's** conventions, not the workspace's. Commit style,
   review process and governance differ per repo (see table).
4. Never commit workspace-level changes into a sub-repo, or vice versa. They
   are independent repos.

This is a precondition, not a suggestion. A bare "read AGENTS.md" pointer has
already been skipped in practice, which is why `.#brief` exists.

## The repos

| Repo | Role | Stack | Shell | Branch | Commits | Agent docs |
| --- | --- | --- | --- | --- | --- | --- |
| `firmware` | device firmware | C++ / PlatformIO | `.#firmware` | `develop` | sentence-style, ad-hoc prefixes (`ESP32:`, `MUI:`) | `AGENTS.md` 20 KB |
| `android` | Android + desktop app | Kotlin / Compose / AGP | `.#android` | `main` | Conventional | `AGENTS.md` 3 KB, Spec Kit, skills, subagents |
| `apple` | iOS/macOS/watchOS clients | Swift / Xcode | `.#apple` | `main` | Conventional | **none** → [`notes/apple.md`](./notes/apple.md), Spec Kit |
| `meshtastic-sdk` | KMP client SDK | Kotlin MP | `.#kotlin` | `main` | Conventional | `AGENTS.md` 6 KB, `GOVERNANCE.md`, `CODEOWNERS`, Spec Kit |
| `MQTTastic-Client-KMP` | MQTT 5 client lib | Kotlin MP | `.#kotlin` | `main` | Conventional | `AGENTS.md` 14 KB |
| `kzstd` | zstd codec lib | Kotlin MP | `.#kotlin` | `main` | Conventional | `AGENTS.md` 3 KB |
| `gradle-flatpak-sources` | Flathub manifest plugin | Kotlin / Gradle | `.#kotlin` | `main` | Conventional | **none** → [`notes/gradle-flatpak-sources.md`](./notes/gradle-flatpak-sources.md) |
| `meshtastic-mcp` | MCP server + agent skills | Python / uv | `.#mcp` | `master` | Conventional | `AGENTS.md` 20 KB, `CONVENTIONS.md`, `llms.txt`, cursor + windsurf rules |
| `protobufs` | shared `.proto` definitions | buf · deno · gradle · cargo | `.#protobufs` | `master` | mixed | **none** → [`notes/protobufs.md`](./notes/protobufs.md) |
| `design` | design standards, tokens, brand assets | node · inkscape | `.#design` | `master` | Conventional | **none** → [`notes/design.md`](./notes/design.md) |

## Cross-repo coupling

- `protobufs` is vendored as a submodule at `firmware/protobufs`. Edit in
  `protobufs`, bump the pointer in `firmware`.
- `meshtastic-sdk` is consumed by `apple` and `android`; an ABI change breaks
  them without touching their repos.
- `gradle-flatpak-sources` packages `android`'s `:desktopApp` for Flathub.
- `design` defines standards that `android`, `apple` and `web` implement; its
  work is tracked on the org board
  <https://github.com/orgs/meshtastic/projects/16> rather than in the repo.

## Spec Kit

`android`, `apple` and `meshtastic-sdk` use Spec Kit. Their
`.specify/memory/constitution.md` (8–12 KB) **outranks** other agent docs.
`apple/CLAUDE.md` is Spec Kit-managed and dynamic — it points at the currently
active `specs/<feature>/plan.md`. Read it to find the live plan; never hand-edit
it.

## Worktrees

Use `nix run .#worktree <repo> <branch>` — it creates the worktree under
`<repo>/.claude/worktrees/` and writes an `.envrc` selecting the **correct**
dev shell. Without it a worktree inherits the workspace default shell, so you
get the wrong toolchain silently.

## Constraints that fail silently

- **`MESHTASTIC_WORKSPACE` must be set** or JDK pinning is inert and Gradle
  auto-provisions its own JDKs. `direnv` sets it.
- **Six JDKs are required**, satisfying three separate Gradle mechanisms
  (compile toolchains, per-repo daemon JVM criteria, per-module vendor
  toolchains). Removing any one breaks a specific repo.
- **Toolchain config belongs in `gradle.properties`, never `GRADLE_OPTS`** —
  the daemon never sees the launcher's environment.
- **Default branches are not all `main`** — see the table.
- **This repo's `.gitignore` ignores everything by default.** A new file is
  untracked until whitelisted.
- **`nix flake check` only evaluates shells, it does not build them.**
