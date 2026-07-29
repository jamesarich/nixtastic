# meshtastic-workspace

One base directory for working across every Meshtastic repo, with the right
toolchain for each supplied by Nix.

It does not vendor the repos — it clones them, gives each one a dev shell, and
keeps them oriented. Ten repos, eight shells, one place to start.

```
~/meshtastic/
├── flake.nix              the toolchains
├── CLAUDE.md              agent router — repo index + protocol
├── AGENTS.md              why the constraints exist
├── notes/                 orientation for repos with no agent docs
├── firmware/  android/  apple/  meshtastic-sdk/  …   ← the repos
└── .cache/                workspace-local Gradle cache
```

---

## One-time setup

```bash
# 1. Nix (flakes on by default)
curl -fsSL https://install.determinate.systems/nix | sh -s -- install

# 2. This workspace
git clone git@github.com:jamesarich/meshtastic-workspace.git ~/meshtastic
cd ~/meshtastic

# 3. Auto-activate on cd — do this, everything below assumes it
nix profile install nixpkgs#nix-direnv
mkdir -p ~/.config/direnv
echo 'source "$HOME/.nix-profile/share/nix-direnv/direnvrc"' > ~/.config/direnv/direnvrc
direnv allow

# 4. Clone every Meshtastic repo
nix run .#sync

# 5. Android SDK packages (needs cmdline-tools already present)
nix run .#bootstrap-sdk
```

Without direnv, `MESHTASTIC_WORKSPACE` is unset and **JDK pinning silently does
nothing**. Set it manually if you skip step 3.

---

## The daily loop

### Morning — see what moved

```bash
cd ~/meshtastic
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

**Work on the SDK**

```bash
cd meshtastic-sdk
./gradlew :core:build          # JVM + Android + iOS klibs, tests, ABI check
```

iOS targets compile to klibs on Linux; linking and iOS tests are `SKIPPED` —
that's correct, not a failure.

**Talk to a node without a build toolchain**

```bash
nix develop ~/meshtastic#nodes
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
| `nix run .#sync` | fetch all, report drift. Read-only. |
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
| Gradle downloads its own JDKs | `MESHTASTIC_WORKSPACE` unset | `direnv allow` at the workspace root |
| Worktree missing tools (e.g. no `scrcpy`) | created by hand, got the default shell | make it with `nix run .#worktree` |
| `./gradlew` can't start a daemon | repo needs a JDK vendor/version not present | all six JDKs must stay in `flake.nix` |
| A repo looks clean but is behind | single-branch clone | `nix run .#sync -- --pull` widens the refspec |
| `firmware` dirty right after a pull | upstream moved the submodule pointer | `--pull` re-syncs automatically; else `git submodule update --init --recursive` |
| `bwrap: setting up uid map` | FHS-wrapped `platformio` vs Ubuntu AppArmor | already fixed — the flake uses `platformio-core` |

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
