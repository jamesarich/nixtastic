# meshtastic-python - meshtastic/python

Workspace-local note. This repo publishes **no agent docs of any kind** - no
`AGENTS.md`, no `CLAUDE.md`, no Spec Kit, no `CONTRIBUTING.md` - so
orientation has to come from the code.

- **Role:** the `meshtastic` CLI and Python API on PyPI. `labeltastic` and
  `meshtastic-mcp` both import it to reach a radio, so it sits underneath
  every Python-side device test in this workspace.
- **Default branch:** `master`
- **Shell:** `.#python`
- **Checked out as `meshtastic-python`, not `python`** - the upstream repo is
  `meshtastic/python`, but a `python/` directory sitting next to a `.#python`
  shell reads as the same thing and is not. Renaming on checkout is how
  `android` and `apple` are handled too.

## The one that catches people: Poetry, not uv

The `.#python` shell serves three repos and ships **both** managers. This one
is Poetry - `poetry.lock`, `[tool.poetry]` tables, `poetry-core` build
backend. `uv sync` cannot read a `poetry.lock`.

```bash
poetry install --all-extras --with dev,powermon   # what CI runs
poetry run meshtastic --version
```

`UV_PYTHON` does not apply here; Poetry takes the interpreter from `PATH`,
which the shell has already pointed at the same CPython 3.13. The repo
declares `^3.9,<3.15`, so 3.13 is in range.

`--with powermon` resolves `riden` **from git**, so that group needs network
even when everything else is cached.

## Gotchas

- **`ruff` is on `PATH` and is not this repo's formatter.** It is there for
  `meshtastic-mcp` and `labeltastic`. This repo lints with `pylint`
  (`.pylintrc`) and formats with `autopep8`, and `.trunk/` drives its own
  pinned versions. Running `ruff format` here will reformat the tree against
  a config the project does not use.
- **`protobufs` is a git submodule** at `protobufs/`, the same arrangement
  `firmware` has. `nix run .#sync` clones `--recurse-submodules` and re-syncs
  pointers after a fast-forward; a submodule left uninitialised fails later as
  missing proto sources rather than as a clone error. Note the `.gitmodules`
  URL is `http://`, not `https://` - upstream's, not ours to change here.
- **Commit style is sentence-style and merged via PR** ("Skip node DB fetch
  during `--ota-update`", "Improve CI job to fail faster"). Not Conventional
  Commits - match recent history on the branch.
- **Tests are marker-gated**, and most markers want hardware:

  | Marker | Needs |
  | --- | --- |
  | `unit` | nothing - `make test` |
  | `smokevirt` | the virtual/simulated radio - `make virt` |
  | `smoke1`, `smokemesh` | a real device, factory-reset and replugged |

  `make -j3 --output-sync=target ci` is the full gate CI runs (pylint, mypy
  and tests in parallel).

## Cross-repo coupling

A wire-format change in `protobufs` reaches this repo through its submodule,
and from here into `labeltastic` and `meshtastic-mcp` as a PyPI release. A
release of this package is therefore the delivery path by which a protobuf
change becomes visible to the Python side of the workspace.
