# design - meshtastic/design

Workspace-local note. The repo **does** have agent docs now - `AGENTS.md` and
`CLAUDE.md`, both a writing-style guide (they diverged, see Gotchas).

- **Role:** cross-platform design standards, design tokens and brand assets.
  The source of truth for how every Meshtastic client should look, and since
  section 11, for how everything is written.
- **Default branch:** `master`
- **Shell:** `.#design`

## Work starts on the board, not in the tree

Most work here is driven through the org design board rather than by browsing
files:

**https://github.com/orgs/meshtastic/projects/16**

```bash
gh issue list --repo meshtastic/design --state open
gh issue view <n> --repo meshtastic/design
```

Expect an issue to be the unit of work, often describing a change that must
then land in `android`, `apple` and `web` - this repo defines the standard,
the client repos implement it.

## The standards, and how to link them

`standards/README.md` is the index, and it is **the thing to link**:

```
https://github.com/meshtastic/design/tree/master/standards
```

That URL renders the index, always names the current version, and never needs
updating in the repo doing the linking. Added by #155 for exactly that reason.

| Version | Status |
| --- | --- |
| v1.5 (`meshtastic_design_standards_v1_5.md`) | **current** |
| v1.4, v1.3, v1.2, v1.0 | superseded - published records, never edited |

Cutting a version is **four edits in one commit**: add the file, repoint the
`meshtastic_design_standards_latest.md` symlink, change the version named at
the top of `standards/README.md` and its `current-version` marker, add the
table row and mark the previous one superseded. `CLAUDE.md` spells this out;
`AGENTS.md` does not (see Gotchas).

## Section 11 is the writing standard

Section 11 of v1.5 governs **documentation prose**, not just UI: the docs
site, the written material in this repo, and the text inside the clients
(11.15, in-product labels, errors and empty states). Subsections 11.1-11.16,
closing with 11.16, a checklist of the rules a reviewer can check without
judgement.

Two things to know before editing a client's docs:

- **11.1 - client docs are written in the client repo, not the docs repo.**
  `docs/software/android/` and `docs/software/apple/` (plus their image dirs)
  are synced **weekly from each client's latest release**, not its default
  branch. A docs-repo PR touching those paths is failed by CI and reverted by
  the next sync. So a merged client docs change reaches meshtastic.org only
  once it ships in a release.
- **11.11 - synced client docs are exempt from `:::` admonitions.** Their
  source has to render in two renderers at once, so the client repo's own
  guide owns the callout form. `android`'s is the emoji-blockquote form.

`android` already defers to section 11 (PR #7125); its remaining local rules
are repo mechanics plus the emoji admonitions - see the
`android-docs-style-guide` memory.

## Layout

| Path | What it is |
| --- | --- |
| `standards/` | `README.md` is the index and the link target. `meshtastic_design_standards_v1_5.md` is current; older versions are frozen. Plus `audits/` and `docs/`. |
| `tokens/` | design tokens - `tokens.json` built by `build.mjs` via **style-dictionary** (`npm run build`) |
| `styleguide/` | colors, margins, sizes, typeface - paired `.svg` + `.png` |
| `logo/`, `typelogo/`, `hardware/`, `web/`, `merch store/` | brand assets |
| `bin/generate-pngs.sh` | regenerates PNGs from SVGs using **inkscape** |

## Gotchas

- **Never link `meshtastic_design_standards_latest.md` over HTTP.** It is a
  symlink, and GitHub serves a symlink as its target's *filename*: both the
  blob view and `raw.githubusercontent.com` return **35 bytes** reading
  `meshtastic_design_standards_v1_5.md`, with a 200 and no error. Verified
  2026-09-14. It still works on a filesystem, so a local clone can
  `cat standards/meshtastic_design_standards_latest.md`; a tool needing it
  over HTTP must use the contents API, which does resolve the symlink:

  ```bash
  gh api repos/meshtastic/design/contents/standards/meshtastic_design_standards_latest.md \
    -H "Accept: application/vnd.github.raw"
  ```

  **Two consumers in `apple` have this bug live.**
  `.specify/memory/constitution.md` cites the raw URL twice and tells agents
  they MUST fetch it before any UI change - and the constitution outranks
  every other agent doc there, so an agent obeying it gets 35 bytes and no
  error. `.github/workflows/sync_design_standards.yml` `curl`s the same URL
  into `.standards/`; a successful run would open a PR containing those 35
  bytes, and it has only escaped that because it has never fired
  (`.standards/` holds just `.gitkeep`, and its `repository_dispatch` trigger
  `design-standards-updated` is not sent by this repo).
- **Don't edit a superseded version file.** `.github/workflows/`
  `standards-version-guard.yml` (#151) fails a PR that touches one, and also
  checks that `standards/README.md`'s `current-version` marker and the
  symlink agree. Changes belong in the current version.
- **PNGs are generated, not hand-edited.** Change the `.svg`, then re-run
  `bin/generate-pngs.sh`. The flake supplies inkscape specifically because the
  script hardcodes it - swapping in another SVG renderer changes output
  subtly and ships altered brand assets.
- **Tokens are consumed downstream.** A `tokens.json` change is a
  cross-repo change; treat it like a protobuf change in blast radius.
- `.#design` omits inkscape on non-Linux (closure size); asset regeneration is
  Linux-only in this workspace.
- **`AGENTS.md` and `CLAUDE.md` have drifted.** Both open "This applies to
  everyone writing in this repo, human or agent", but #155 added the "Cutting
  a standards version" section to `CLAUDE.md` only. Read `CLAUDE.md`; treat
  `AGENTS.md` as the older copy.
- **This repo's house style is not the workspace's.** Its writing guide bans
  hard-wrapping (one line per paragraph and per bullet) and bans bold-lead
  bullets - both of which the workspace notes use throughout. Match the
  design repo when writing *in* it, including issues, PRs and commits.
