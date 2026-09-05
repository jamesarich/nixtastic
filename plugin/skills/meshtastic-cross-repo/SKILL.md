---
name: meshtastic-cross-repo
description: Drive a change that touches more than one Meshtastic repo in this workspace - a .proto or wire-contract change, a shared api.meshtastic.org resource, a firmware↔app handshake change, a version bump that must land in several repos, or any feature spanning firmware, protobufs, the SDK, android, apple, web-flasher, python or docs. Maps the request onto the coupling graph, briefs each repo, writes one umbrella note, gates on plan mode, then executes in release order with one worktree per repo and each repo's own conventions. Use from the workspace root; not for single-repo work.
license: GPL-3.0-only
---

# Cross-repo change in the Meshtastic workspace

You are at the root of a workspace of ~19 independent org repos. Nothing
off the shelf knows they are coupled. This skill does. It **orchestrates**;
it does not teach design, TDD or debugging - plan mode is the design gate,
each repo's own docs are the rules inside it.

Read first, in this order, and keep them open:

1. `CLAUDE.md` at the workspace root - the repo table (role, shell, default
   branch, commit style, agent docs) and the **Cross-repo coupling** section.
2. `notes/cross-repo-contracts.md` - phone↔device handshake, proto change
   rules, MQTT topics, **release order**.
3. For each candidate repo: `just brief <repo>` (from the root) - live
   branch, drift, and the docs that repo expects read. Read those docs.
4. If `<repo>/.specify/memory/constitution.md` exists, read it: it is that
   repo's governance and outranks other agent docs there. Do **not** create
   Spec Kit spec/plan/tasks files; the lifecycle is not used in practice.

## Steps

### 1. Scope

From the request, list every repo touched and *why*, then add what the
coupling graph implies even if unasked:

| if the change touches | it also touches |
| --- | --- |
| a `.proto` in `protobufs` | `firmware` (submodule bump), `meshtastic-python` (submodule bump), `android` (`org.meshtastic:protobufs` version in `gradle/libs.versions.toml`), `meshtastic-sdk`, `apple` |
| `meshtastic-sdk` public API | `android`, `apple` |
| an `api` `data/*.json` resource | `android` (bundled seed + repository), `apple` (hand-mirrored map), `web-flasher` |
| firmware↔app handshake or BLE/serial framing | `firmware`, `android`, `apple`, `meshtastic-python`, `meshtastic-sdk` |
| a `design` token or asset | `android`, `apple`, `meshtastic` (submodule) |
| `Adafruit_nRF52_Bootloader_OTAFIX` release | `api` data, `apple` hand copy |

Run `just pins` first: it prints every consumer's pin and whether it is
`current`, `behind` or `ahead`, so the implied list starts from facts.

Present the list with one line of reason per repo and **ask for
confirmation** before anything else. A repo the user removes stays out.

### 2. Brief

Run `just brief --short <repos…>` once, then the full `just brief <repo>`
only for repos whose line shows drift, `dirty!`, or open PRs you need to
read. Stop and report if any
checkout is dirty, on an unexpected branch, or behind its origin: another
session may own it (see the memory `foreign-live-session-in-sibling-repo`).
Never work in a dirty primary checkout.

### 3. Umbrella note

Write `notes/<yyyy-mm-dd>-<feature-slug>.md` from
`references/umbrella-template.md`. It is the **only** durable artefact of the
cross-repo work and must be updated as things land. Commit it to the
workspace repo (sentence-style message, no attribution footer).

### 4. Design gate - plan mode

Enter plan mode. The plan lists, per repo in release order: files, the
change, the contract it implements or consumes, its verification command,
and its commit/PR convention from the repo table. Do not edit any repo
until the plan is approved. With `--dry-run` in the request, **stop here**
after writing the umbrella note and the plan.

### 5. Worktrees

For each repo: `nix run .#worktree -- <repo> <branch>` from the workspace
root (never a hand-rolled `git worktree`; never the harness's own worktree
isolation - see `CLAUDE.md` → Worktrees). Branch names follow that repo's
convention (`feat/…`, `fix/…`; Conventional-commit repos use the type as
prefix). Record each worktree path in the umbrella note.

### 6. Execute in release order

Producers before consumers, from `notes/cross-repo-contracts.md`:
`protobufs` → `firmware` and `meshtastic-python` (submodule bumps) →
`meshtastic-sdk` → `android`, `apple`, `web-flasher`, `meshtastic` (docs).
Inside a worktree the repo's own rules win: its commit style, PR vs direct,
CodeRabbit where it runs, its `AGENTS.md`/`CLAUDE.md`. Use that repo's
forwarded skills (`nixtastic:<repo>-<skill>`) and subagents
(`gradle-runner` for any Gradle build). A consumer that needs a published
artefact (a proto release, an SDK version) waits for it; note the pin it
will bump.

### 7. Verify

Each repo's own gate (the one its docs name). Where a device and an app
both changed, run the cross-plane check with `nixtastic:meshtastic-e2e`.
Report proven vs unproven plainly; never call the feature working from one
side alone. For each PR opened, `just pr <repo> <n>` before claiming anything
about CI: it reads checks for the head SHA and the unresolved threads that
block android's merge.

### 8. Close

Fill the *landed* column of the umbrella note (commit SHA or PR URL per
repo), set status, commit the note. List what is still unproven.

## Never

- Mix commits across repos, or commit from the workspace root into a repo.
- Edit a primary checkout when a worktree exists for the work.
- Write Spec Kit lifecycle files.
- Skip step 1's confirmation or step 4's approval.
