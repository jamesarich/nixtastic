# nixtastic

One base directory for working across every Meshtastic repo, with the right
toolchain for each supplied by Nix.

It does not vendor the repos — it clones them, gives each one a dev shell, and
keeps them oriented. Ten repos, eight shells, one place to start.

The checkout directory can be named anything and live anywhere — everything
derives from `MESHTASTIC_WORKSPACE`. Verified by bootstrapping a second host
into `~/meshtastic-workspace`, a different name from the one used below.

```
$MESHTASTIC_WORKSPACE/         (any path, any name)
├── flake.nix              the toolchains
├── direnvrc               sourced by ~/.config/direnv/direnvrc
├── CLAUDE.md              agent router — repo index + protocol
├── AGENTS.md              why the constraints exist
├── notes/                 orientation for repos with no agent docs
├── firmware/  android/  apple/  meshtastic-sdk/  …   ← the repos
└── .cache/                workspace-local Gradle cache
```

---

## One-time setup

```bash
# 0. Where it lives. Any path, any name — every step below derives from this.
WORKSPACE=~/meshtastic

# 1. Nix (flakes on by default)
curl -fsSL https://install.determinate.systems/nix | sh -s -- install

# 2. This repo — substitute your own fork if you have one
git clone https://github.com/jamesarich/nixtastic.git "$WORKSPACE"
#    Private copy? The new machine needs credentials first:
#      SSH key on the box:  git clone git@github.com:OWNER/nixtastic.git "$WORKSPACE"
#      otherwise:           gh auth login && gh repo clone OWNER/nixtastic "$WORKSPACE"
#    Neither? Bundle it across from a machine that already has it, so no
#    token ever lands on the new box:
#      git -C EXISTING_CHECKOUT bundle create /tmp/nixtastic.bundle --all
#      scp /tmp/nixtastic.bundle newbox:/tmp/
#      ssh newbox "git clone -b main /tmp/nixtastic.bundle $WORKSPACE"
cd "$WORKSPACE"

# 3. Auto-activate on cd — do this, everything below assumes it
nix profile install nixpkgs#nix-direnv
mkdir -p ~/.config/direnv
echo "source \"$WORKSPACE/direnvrc\"" > ~/.config/direnv/direnvrc
direnv allow

# 4. Exclude direnv files globally, so they never dirty a cloned repo
mkdir -p ~/.config/git
printf '.envrc\n.direnv/\n.envrc-workspace\n' >> ~/.config/git/ignore

# 5. Clone every repo and give each one its shell
nix run .#sync          # then run the `direnv allow` lines it prints

# 6. Android SDK packages (needs cmdline-tools already present)
nix run .#bootstrap-sdk
```

Step 3 points at [`direnvrc`](./direnvrc) in this repo rather than pasting a
snippet: it sources nix-direnv *and* carries the override that keeps `firmware`
off upstream's broken PlatformIO. It is the one line that must name your
checkout path — everything else derives.

Step 4 lists three files, and `.mcp.json` is deliberately not among them —
plenty of projects track one, and a global ignore would hide it everywhere. It
is handled per repo instead: `.#worktree` writes it into that repo's
`.git/info/exclude`, and the root copy is caught by this repo's deny-by-default
`.gitignore`.

Step 5 writes a `.envrc` into each repo, which is what makes `cd android` select
`.#android`. `direnv` requires explicit consent per file, so `sync` prints the
`direnv allow` commands rather than running them.

It also writes `.mcp.json` at the workspace root, registering the
`meshtastic-mcp` server for whatever MCP client you run here. That needs its own
one-time consent — start the client and approve it (`/mcp` in Claude Code) — and
the bundled agent skills are a separate command, which `sync` prints when they
are missing:

```bash
(cd meshtastic-mcp && uv run meshtastic-mcp skills install --dest ../.claude/skills)
```

Without direnv, `MESHTASTIC_WORKSPACE` is unset and **JDK pinning silently does
nothing**. Set it manually if you skip step 3.

---

## The daily loop

### Morning — see what moved

```bash
cd "$MESHTASTIC_WORKSPACE"
nix run .#sync                 # read-only: fetch + report drift
nix run .#sync -- --pull       # fast-forward everything that safely can
```

`--pull` only ever fast-forwards. It never merges, never rebases, and skips any
repo with modified tracked files. Untracked files don't block it.

```
PULLED    android      main      .#android   -16 fast-forwarded
current   apple        main      .#apple
BEHIND    firmware     develop   .#firmware  -4 skipped, tree dirty
```

Uppercase wants your attention; lowercase is informational.

### Starting a task — orient first

```bash
nix run .#brief -- android
```

Tells you the current branch and drift, the exact shell to use, **which docs to
read before editing**, that repo's commit style, and its open PRs. Generated
live, so it can't go stale. Run it before touching a repo you haven't been in
lately.

### Doing the work

Either work in place:

```bash
cd android          # direnv activates .#android automatically
./gradlew :androidApp:assembleFdroidDebug
```

Or isolate it in a worktree — the right move when you're juggling branches or
running several agents:

```bash
nix run .#worktree -- android fix/6360-coarse-position
cd android/.claude/worktrees/fix-6360-coarse-position && direnv allow
```

The worktree gets **that repo's** shell. Creating one by hand with `git
worktree add` gets you the workspace default shell instead, silently — wrong
toolchain, no obvious error.

### Wrapping up

```bash
nix run .#worktree -- --list           # what's still open, everywhere
git -C android worktree remove <path>  # done with one
nix run .#worktree -- --prune          # clear dead registrations
```

---

## Recipes

**Fix an Android issue**

```bash
nix run .#brief -- android                      # read what it names
nix run .#worktree -- android fix/6360-thing
cd android/.claude/worktrees/fix-6360-thing && direnv allow
./gradlew :androidApp:assembleFdroidDebug
./gradlew :androidApp:testFdroidDebugUnitTest
```

**Change a protobuf** — the highest-blast-radius change here

```bash
cd protobufs
buf lint                       # offline
buf generate                   # NEEDS NETWORK (remote plugin)
# then bump the pointer in firmware:
cd ../firmware && git submodule update --remote protobufs
pio run -e heltec-v3           # confirm firmware still builds
```

Field numbers and wire compatibility are load-bearing across firmware, both
apps and the SDK simultaneously. Treat renumbering or removal as breaking
every downstream repo at once.

**Build and flash firmware**

```bash
cd firmware
pio run -e heltec-v3           # ~7m cold, artifacts in .pio/build/
pio run -e heltec-v3 -t upload
pio device monitor
```

Code intelligence needs a compile database — once per environment, and again
after changing `platformio.ini`:

```bash
pio run -e heltec-v3 -t compiledb   # ~40s, writes compile_commands.json
clangd --check=src/main.cpp         # optional: confirm it parses
```

The shell wraps `clangd` with `--query-driver` so it can read the xtensa
toolchain's system headers, and `firmware/.clangd` strips the GCC-only flags.
Both are already in place; the shell warns if either goes missing. Any editor
with an LSP client picks it up.

**Work on the SDK**

```bash
cd meshtastic-sdk
./gradlew :core:build          # JVM + Android + iOS klibs, tests, ABI check
```

iOS targets compile to klibs on Linux; linking and iOS tests are `SKIPPED` —
that's correct, not a failure.

**Talk to a node without a build toolchain**

```bash
nix develop "$MESHTASTIC_WORKSPACE#nodes"   # or the path to this checkout
uvx meshtastic --port /dev/ttyUSB0 --info
esptool chip_id
```

**Design standards** — work starts on the
[board](https://github.com/orgs/meshtastic/projects/16), not in the tree

```bash
gh issue list --repo meshtastic/design
cd design && cd tokens && npm ci && npm run build
```

---

## Reference

### Shells

| Shell | Repos |
| --- | --- |
| `.#kotlin` | `meshtastic-sdk`, `MQTTastic-Client-KMP`, `kzstd`, `gradle-flatpak-sources` |
| `.#android` | `android` |
| `.#firmware` | `firmware` |
| `.#mcp` | `meshtastic-mcp` |
| `.#protobufs` | `protobufs` |
| `.#design` | `design` |
| `.#apple` | `apple` (macOS only) |
| `.#nodes` | serial/BLE/flashing, no build toolchain |
| `.#default` | everything light, for roaming |

`direnv` picks these automatically per directory. `nix develop .#<shell>` to
enter one explicitly.

### Commands

| Command | Does |
| --- | --- |
| `nix run .#sync` | fetch all, report drift. Read-only *for git*; always regenerates `.envrc` and `.mcp.json`. |
| `nix run .#sync -- --pull` | fast-forward where safe |
| `nix run .#sync -- --main` | switch each repo to its default branch, then pull |
| `nix run .#brief -- <repo>` | orient: branch, shell, docs to read, PRs |
| `nix run .#worktree -- <repo> <branch>` | worktree with the correct shell |
| `nix run .#worktree -- --list \| --prune` | manage worktrees across all repos |
| `nix run .#bootstrap-sdk` | install Android SDK packages from the pinned list |

---

## When something looks wrong

These fail **quietly** — no error, just wrong behaviour.

| Symptom | Cause | Fix |
| --- | --- | --- |
| Gradle downloads its own JDKs | `MESHTASTIC_WORKSPACE` unset, or a hand-written repo `.envrc` that exports it *after* `use flake` | `nix run .#sync` regenerates the file correctly; then `direnv allow` |
| `cd <repo>` gives the wrong toolchain | that repo has no `.envrc`, so the workspace-root one loads and you get `.#default` | `nix run .#sync` |
| `pio` dies with `bwrap` in `firmware` | upstream's tracked `.envrc` (`use nix`) won over ours | check `~/.config/direnv/direnvrc` sources this repo's `direnvrc`, and that `firmware/.envrc-workspace` exists |
| Worktree missing tools (e.g. no `scrcpy`) | created by hand, got the default shell | make it with `nix run .#worktree` |
| No `meshtastic-mcp` tools in the client | `.mcp.json` is per directory — a worktree, or a repo subdirectory, is not the workspace root | `nix run .#worktree` writes one per worktree; elsewhere run the client from the workspace root |
| `meshtastic-mcp` server stops starting | its `.mcp.json` names store paths, which `nix flake update` invalidates | `nix run .#sync` regenerates it |
| `./gradlew` can't start a daemon | repo needs a JDK vendor/version not present | all six JDKs must stay in `flake.nix` |
| A repo looks clean but is behind | single-branch clone | `nix run .#sync -- --pull` widens the refspec |
| `firmware` dirty right after a pull | upstream moved the submodule pointer | `--pull` re-syncs automatically; else `git submodule update --init --recursive` |
| `bwrap: setting up uid map` | FHS-wrapped `platformio` vs Ubuntu AppArmor | already fixed — the flake uses `platformio-core` |
| `nix: command not found` over SSH or in a script | Nix's profile snippet isn't sourced by non-interactive shells, **even with `bash -lc`** | use the absolute path: `export PATH=/nix/var/nix/profiles/default/bin:$PATH` |

Verify JDK pinning is live:

```bash
cd meshtastic-sdk && ./gradlew javaToolchains   # auto-detect/download: Disabled
```

[`AGENTS.md`](./AGENTS.md) explains why each constraint exists — every one was
found by a failing build.

---

## Housekeeping

`.gitignore` denies everything by default and whitelists specific paths, so Nix
copies ~40 KB into the store instead of the ~15 GB of checked-out repos. **A new
file here is untracked until you whitelist it.**

`.cache/` is the workspace-local Gradle cache and grows to several GB. It's
disposable; deleting it costs a re-download, nothing else.

---

## License

GPL-3.0-only — see [LICENSE](./LICENSE). Chosen to match the Meshtastic org,
where `firmware` and `meshtastic-mcp` are both GPL-3.0, so donating this repo
upstream would need no relicensing conversation.

It covers this repo only: the flake, `direnvrc`, and the docs. The ten repos it
clones are separate projects under their own licenses, and nothing here vendors
any of their code.
