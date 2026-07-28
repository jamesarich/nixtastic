# meshtastic-workspace

A Nix flake that provides the toolchains for working on Meshtastic code and
talking to Meshtastic nodes. It does not vendor the repos — it clones them and
supplies the compilers, SDKs and CLIs each one needs.

Everything below has been run on Linux. The `apple` shell is untested (needs
macOS + Xcode).

## Bootstrap on a new machine

```bash
# 1. Install Nix (flakes enabled by default)
curl -fsSL https://install.determinate.systems/nix | sh -s -- install

# 2. Clone this workspace
git clone git@github.com:jamesarich/meshtastic-workspace.git ~/meshtastic
cd ~/meshtastic

# 3. Clone every Meshtastic repo into it
MESHTASTIC_WORKSPACE=$PWD nix run .#sync

# 4. Install the Android SDK packages (needs an existing cmdline-tools)
MESHTASTIC_WORKSPACE=$PWD nix run .#bootstrap-sdk

# 5. Optional but recommended — auto-activate on cd
nix profile install nixpkgs#nix-direnv
mkdir -p ~/.config/direnv
echo 'source "$HOME/.nix-profile/share/nix-direnv/direnvrc"' > ~/.config/direnv/direnvrc
direnv allow
```

> **`MESHTASTIC_WORKSPACE` matters.** JDK pinning only engages when it is set.
> `direnv` exports it automatically; without direnv, export it yourself or
> Gradle will silently auto-provision its own JDKs. The shell warns you.

## Shells

```bash
nix develop .#kotlin        # meshtastic-sdk, MQTTastic-Client-KMP, kzstd,
                            # gradle-flatpak-sources
nix develop .#android       # Meshtastic-Android
nix develop .#firmware      # firmware (PlatformIO)
nix develop .#mcp           # meshtastic-mcp (Python + uv)
nix develop .#protobufs     # protobufs (buf, deno, gradle, cargo)
nix develop .#apple         # Meshtastic-Apple (macOS only)
nix develop .#nodes         # serial/BLE/flashing, no build toolchain
```

## Keeping repos current

```bash
nix run .#sync                # fetch + report drift. Never modifies a tree.
nix run .#sync -- --pull      # fast-forward current branches where safe
nix run .#sync -- --main      # switch to each repo's default branch, then pull
```

`--pull` and `--main` only ever fast-forward. They never merge, never rebase,
and skip any repo whose tracked files are modified. Default branches are
resolved per-repo from `origin/HEAD` — they are not all `main`.

## Android SDK

Nix supplies the JDKs and CLIs; the SDK itself stays host-managed and writable
at `$ANDROID_HOME` (default `~/Android/Sdk`), with its contents declared in
[`android-sdk-packages.txt`](./android-sdk-packages.txt).

This is deliberate. An `androidenv` SDK lives read-only in `/nix/store`, and
AGP wants to write into `$ANDROID_HOME` — the documented
`aapt2FromMavenOverride` problem. The trade-off is that the SDK is pinned by
version but not by hash.

## Adding a file to this repo

`.gitignore` ignores everything by default and whitelists specific paths, so
that Nix copies ~35 KB into the store instead of the ~15 GB of checked-out
repos. **A new file will not be tracked until you add it to that whitelist.**

See [`AGENTS.md`](./AGENTS.md) for the non-obvious constraints.
