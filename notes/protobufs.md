# protobufs - meshtastic/protobufs

Workspace-local note. This repo has **no agent docs of any kind** - no
`AGENTS.md`, no `CLAUDE.md`, no Spec Kit, no `CONTRIBUTING.md` - so
orientation has to come from the code. (`meshtastic-python` is the other repo
in that position; the rest of the `notes/` entries cover repos that publish
*some* docs, just not agent-facing ones.)

- **Role:** the shared `.proto` definitions every other Meshtastic project
  builds against. Changes here ripple everywhere.
- **Default branch:** `master`
- **Shell:** `.#protobufs`

## Layout

| Path | What it is |
| --- | --- |
| `meshtastic/` | the `.proto` sources - the actual product |
| `buf.yaml`, `buf.gen.yaml` | buf v2 config |
| `nanopb.proto` | nanopb options, consumed by firmware |
| `packages/ts` | Deno (`deno.json` + `deno.lock`), **not** npm |
| `packages/kmp` | Gradle 9.6.1 wrapper, no daemon JVM criteria |
| `packages/rust` | Cargo |

## Gotchas

- **Vendored as a git submodule inside `firmware/protobufs`.** Edit here, then
  bump the submodule pointer in `firmware`. A firmware build can be broken by a
  change that never touched the firmware repo.
- **`buf generate` needs network** - `buf.gen.yaml` uses the remote plugin
  `buf.build/bufbuild/es:v2.1.0`. `protoc-gen-es` is deliberately not pinned in
  the flake. `buf lint` works offline.
- **Commit style is mixed** - merge commits alongside Conventional Commits
  (`ci:`, `docs:`). Match recent history on the branch rather than assuming.
- **Generated output is NOT committed.** `packages/*/` tracks only build
  scaffolding (19 files; `packages/rust/src/generated/` is a bare `.gitkeep`).
  Real proto commits touch the `.proto` and nothing else - see
  `Add telemetry protos for soil and water metrics (#1055)`. `publish.yml` and
  `publish-kmp.yml` build the artifacts; `snapshot-kmp.yml` publishes a KMP
  snapshot on every master push touching `meshtastic/**/*.proto`, which is how
  a consumer previews a change before it is tagged.
- **`buf lint` bare fails in a worktree** - `buf.yaml`'s module path is `.` and
  its excludes don't cover `.direnv/`, so it walks nixpkgs' nanopb test protos
  and reports `SimpleMessage declared multiple times`. Scope it:
  `buf lint --path meshtastic` (and the same for `buf breaking`).

## Before changing a `.proto`

Field numbers and wire compatibility are load-bearing across firmware, the
Android/Apple apps and the SDK simultaneously. Treat any renumbering or field
removal as a breaking change to every downstream repo in this workspace.
