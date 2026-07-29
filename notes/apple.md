# apple — Meshtastic-Apple

Workspace-local note. This repo has **no `AGENTS.md`**; this file records where
authority actually lives so an agent does not assume it is undocumented.

- **Role:** iOS · iPadOS · macOS · watchOS · visionOS clients
- **Stack:** Swift + SwiftUI, Xcode. **Cannot build on Linux.**
- **Shell:** `.#apple` (lint/format only on Linux; Xcode comes from the host)
- **Default branch:** `main`

## Read in this order

1. **`.specify/memory/constitution.md`** (~11.6 KB) — the governing document.
   Spec Kit constitution; outranks ad-hoc convention.
2. **`CLAUDE.md`** (~250 B) — *Spec Kit-managed and dynamic.* It is regenerated
   to point at the **currently active feature plan**, e.g.
   `specs/014-mesh-beacons/plan.md`. Do not treat it as static guidance, and do
   not hand-edit it — read it to discover which plan is live, then read that
   plan.
3. **`specs/<feature>/`** — the active plan, spec and tasks.
4. **`CONTRIBUTING.md`** (~5 KB) — PR and review process.

## Spec Kit

Driven through `.claude/skills/speckit-*` (analyze, checklist, clarify,
constitution, implement, plan, specify, tasks, taskstoissues). Work here is
expected to flow through that lifecycle rather than ad-hoc edits.

`.claude/skills/ios-marketing-capture` is a symlink into `.agents/skills/` —
a shared skills directory, so the same skill is reachable from multiple agent
runners.

## Gotchas

- Nothing in this repo builds under the flake on Linux. `.#apple` gives you
  `git`/`gh` for review work plus SwiftLint/swift-format on macOS only.
- `meshtastic-sdk`'s iOS targets are consumed here — an SDK ABI change can
  break this repo without any change landing in it.
