# herdr - the two-machine terminal rig

Workspace-local note. `herdr` is the terminal workspace manager the agent
sessions in this workspace run inside (`HERDR_ENV=1`, `HERDR_PANE_ID`, and the
rest injected per pane). Wired across both machines 2026-09-10.

Not a Meshtastic repo - this is workspace infrastructure, the same category as
the Nix shells and the bench.

- **Binary:** homebrew-core (`brew install herdr`), so the same formula on both
  machines. `herdr --skill` prints the agent-facing control doc; the installed
  binary is the authority for command syntax, not the doc.
- **Config:** `~/.config/herdr/config.toml`
- **Logs:** `~/.config/herdr/herdr.log`, `herdr-client.log`, `herdr-server.log`

## The rig

| | james-pc | the laptop |
| --- | --- | --- |
| host | `james-pc.local` (192.168.1.168) | `Jamess-MacBook-Air.local` (192.168.1.138) |
| OS | Linux | macOS 26.6.2 arm64 |
| workspace path | `/home/james/meshtastic` | `/Users/james/nixtastic` |
| herdr | 0.9.0 | 0.9.0 (`/opt/homebrew/bin`, on the interactive PATH via `.zprofile`) |
| profile for the other | `macbook` | `desktop` |

mDNS resolves both directions, so the `.local` names are the addresses to use.
The IPs are DHCP and will rot. **LAN only** - no tailscale on either machine, so
none of this works off the network.

The two workspace paths differ, which means a different Claude memory slug per
machine. That is what the slug-linking in `.#sync` exists for; see
[agent-memory-sync.md](./agent-memory-sync.md).

## `--remote` is not the multi-machine view

The distinction that actually costs time:

| | what you get |
| --- | --- |
| `herdr` | the local server's workspaces **plus every enabled machine profile's** - the aggregated sidebar |
| `herdr --remote <target>` | a single-endpoint attach. Only that one server's workspaces. Your own local ones are not shown. |

So the laptop sees both halves by running plain `herdr` with a `desktop`
profile saved, not by running `--remote`. `--remote` is for a one-off attach to
a box you have no profile for.

**The aggregation is a TUI feature. The CLI stays per-server.** `herdr agent
list` on the laptop never lists james-pc's agents even while the sidebar shows
them side by side, because pane and agent IDs are scoped to one server and two
machines can both have `w1:p1`. To drive the other machine's panes from an
agent, `ssh` there and run `herdr` on that host with its own session.

## `!attention` on a machine row is almost always ssh-agent scope

A machine row going `!attention` means herdr's **client** could not ssh to that
host. It is not a blocked agent. Diagnose it in `herdr-client.log`:

```
endpoint needs attention endpoint=ssh:<id> generation=2
error=remote platform detection failed: james@<host>:
      Permission denied (publickey,password,keyboard-interactive)
```

The trap is that a hand-run `ssh <host>` from your shell **succeeds** while
herdr fails, because your shell has an agent and herdr's client process does
not. Both machines here hit a different flavour of it:

- **james-pc has no default identity on disk.** `~/.ssh/id_*` does not exist.
  The only key the laptop accepts is `~/.ssh/omv_ed25519` (comment
  `claude-omv-mgmt`), a non-default filename, so ssh only ever offered it
  through the GNOME Keyring agent at `/run/user/1000/gcr/ssh`. Fixed with an
  `IdentityFile` entry in `~/.ssh/config` covering the hostname, **its
  lowercase form** (what herdr actually passes) and the short alias. That key
  has no passphrase, so it needs no agent at all.
- **The laptop's `~/.ssh/id_ed25519` has a passphrase.** It works because
  `AddKeysToAgent`/`UseKeychain` put it in the macOS agent. A `Host` block for
  james-pc needs those two lines as well, since `UseKeychain` is per-`Host` and
  was originally scoped to `github.com` only.

Proving it is one command: run the same ssh with the agent removed. If it fails
identically, it is agent scope and not the key or the hostname.

**The running client latches the failure and does not retry.** `herdr machine
disable`/`enable` does not clear it and neither does waiting. Restart the TUI
client after fixing the auth.

## Agent state comes from a per-agent integration

`herdr integration status` lists them; `--outdated-only` is the check worth
running. The `claude` integration is a hook at `~/.claude/hooks/herdr-agent-state.sh`
registered on **`SessionStart` only** - that single entry in
`~/.claude/settings.json` is the complete wiring, so one hook line is not a
sign of a broken install.

It reports the Claude session id as `agent_session`, which is what `[session]
resume_agents_on_restore` needs to put a pane back into its own conversation
after a server restart. **A pane started under an older integration has no
`agent_session` and will not resume** - check with `herdr agent list` before
assuming a long-running session is safe across a restart.

`nix run .#sync` preserves herdr's hook entries untouched when it rewrites
`settings.json`; `scripts/tools-tests.sh` covers that.

## Gotchas

- **Never use `herdr worktree`.** It creates worktrees under
  `~/.herdr/worktrees` with no `.envrc` and no `.mcp.json`, which is exactly the
  stray that `AGENTS.md`'s worktree `--gc` parks and reports. Use `nix run
  .#worktree` / `just worktree`. If you want it a keystroke away, bind the real
  tool as a `[[keys.command]]` popup instead.
- **`[experimental] allow_nested = false`** means an agent running inside a
  herdr pane cannot launch the TUI. It can still drive `herdr pane` and `herdr
  agent`, which is the supported path.
- **`herdr machine add` opens the ssh connection at add time** and wants an
  interactive terminal if the remote install is missing or incompatible. Run it
  from a real shell, not from an agent tool call, or it fails on auth exactly
  like the `!attention` case above.
- **Long builds belong in a sibling pane, not in an agent's shell tool.**
  `herdr pane split --current --direction right --cwd "$PWD" --no-focus`, then
  `pane run` and `pane wait-output`, survives a tool timeout and the session.
  Relevant to the Gradle daemon, `pio run` and xcodebuild alike.
