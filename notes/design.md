# design — meshtastic/design

Workspace-local note. The repo has **no agent docs** — only `README.md`.

- **Role:** cross-platform design standards, design tokens and brand assets.
  The source of truth for how every Meshtastic client should look.
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
then land in `android`, `apple` and `web` — this repo defines the standard,
the client repos implement it.

## Layout

| Path | What it is |
| --- | --- |
| `standards/` | **`meshtastic_design_standards_latest.md` is authoritative.** Versioned copies (`v1_0` … `v1_4`) sit beside it, plus `audits/` and `docs/`. |
| `tokens/` | design tokens — `tokens.json` built by `build.mjs` via **style-dictionary** (`npm run build`) |
| `styleguide/` | colors, margins, sizes, typeface — paired `.svg` + `.png` |
| `logo/`, `typelogo/`, `hardware/`, `web/`, `merch store/` | brand assets |
| `bin/generate-pngs.sh` | regenerates PNGs from SVGs using **inkscape** |

## Gotchas

- **Read `..._latest.md`, not a version-numbered file.** The versioned copies
  are history; picking `v1_2` because it sorts first is a real trap.
- **PNGs are generated, not hand-edited.** Change the `.svg`, then re-run
  `bin/generate-pngs.sh`. The flake supplies inkscape specifically because the
  script hardcodes it — swapping in another SVG renderer changes output
  subtly and ships altered brand assets.
- **Tokens are consumed downstream.** A `tokens.json` change is a
  cross-repo change; treat it like a protobuf change in blast radius.
- `.#design` omits inkscape on non-Linux (closure size); asset regeneration is
  Linux-only in this workspace.
