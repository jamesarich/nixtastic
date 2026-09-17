# meshtastic-bot

Workspace-local note. The repo publishes no `AGENTS.md`, `CLAUDE.md` or
`CONTRIBUTING.md` - `README.md`, `PRIVACY.md` and `TERMS.md` are all of it.

- **Role:** the Meshtastic community Discord bot. Turns a Discord modal into a
  GitHub issue, answers `/faq` from a YAML list, and diffs two firmware
  releases with `/changelog`.
- **Stack:** Go (`go 1.25.4` in `go.mod`, CI pins 1.25), `discordgo` +
  `go-github/v57`, `yaml.v3`, `godotenv`. Shipped as a container.
- **Default branch:** `main`. Conventional commits, merged via PR.
- **Shell:** `.#go`
- **Joined the workspace:** 2026-09-17.

## Why it is here

`config.yaml` maps a **Discord channel ID** to an issue-template URL in a
client repo:

```yaml
- command: bug
  template_url: https://github.com/meshtastic/Meshtastic-Android/blob/main/.github/ISSUE_TEMPLATE/bug_report.yml
  channel_id: ["871539863307055134"]
  exclude_fields: [screen-media]
```

`internal/config/modal.go` **fetches and parses that template at runtime**
(`FetchGitHubTemplate`, `GetAllFieldsForModal`) and builds the Discord modal
from its fields. So a client repo renaming or removing a field in
`.github/ISSUE_TEMPLATE/` silently changes what the bot asks users for, and
`exclude_fields` entries here go stale with no error anywhere - the same shape
of undeclared cross-repo contract that put `api` in this workspace.

## Working here

Everything CI runs, from the repo root in `.#go`:

```
go build ./cmd/meshtastic-bot
go vet ./... && staticcheck ./...
gofmt -l .            # CI fails on ANY output
go test -race ./...
```

All five verified green on darwin, 2026-09-17. `run.sh` and the `Dockerfile`
are the deployment path (docker or podman, `--env-file .env.$APP_ENV`); the
shell deliberately provides neither, the same boundary `.#siteplanner` draws
around emscripten.

## Gotchas

- **The Go toolchain is newer than the repo asks for.** nixpkgs has removed
  `go_1_25` as end-of-life (the attribute throws), so `.#go` carries nixpkgs'
  current Go - 1.26.7 as of writing, against `go 1.25.4` in `go.mod`. That is
  fine: the directive is a floor. The shell exports `GOTOOLCHAIN=local` so a
  future `go 1.27` directive fails loudly instead of quietly downloading its
  own toolchain into GOPATH while the Nix one sits on `PATH`.
- **Upstream tracks its own `.envrc`, and it selects no shell.** It is
  `export APP_ENV=dev` + `dotenv ".env.$APP_ENV"`. `nix run .#sync` writes the
  usual `.envrc-workspace` sidecar (never edit the tracked file), but
  `direnvrc`'s original redirect is bound to `use_nix`, which this file never
  calls - so before 2026-09-17 direnv loaded it and you got whatever `go` was
  on `PATH`, with no error. `direnvrc` now sources the sidecar ahead of a
  tracked `.envrc` that names no shell of its own. It keys on `$PWD`, because
  direnv sources `direnvrc` before entering the directory and exports neither
  `DIRENV_DIR` nor `DIRENV_FILE` at that point: `cd meshtastic-bot`,
  `just in meshtastic-bot …` and `just wt …` all work, a bare
  `direnv exec meshtastic-bot …` from elsewhere does not.
- **The tracked `.envrc` had to be `direnv allow`ed by hand** - `.#sync` only
  ever approves files it generated, deliberately. direnv re-blocks on any
  content change, so an upstream edit needs a fresh `allow`.
- **`.env.dev` does not exist and direnv says so on every load.** `direnv:
  .env at .env.dev not found` is logged and the load continues (direnv 2.37.1),
  so the shell is still correct. Copy `.env.example` to `.env.dev` and fill in
  `DISCORD_TOKEN` / `GITHUB_TOKEN` only if you actually want to run the bot;
  both are gitignored upstream.
- **A bot token is not needed to build or test.** The test suite covers
  `internal/config` and `internal/discord/handlers` with no network.
