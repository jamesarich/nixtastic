# AGENTS.md

Canonical detail for this workspace. Start elsewhere:

- [`CLAUDE.md`](./CLAUDE.md) — the router: repo index, protocol, coupling
- [`README.md`](./README.md) — daily workflow and commands

This file is the **why**. Every constraint below was found by a failing build,
not reasoned about in advance. Do not "simplify" them away.

This repo tracks **only** the workspace definition. The Meshtastic repos inside
it are independent git repos and must never be committed here.

---

## Gradle and JDKs

### `MESHTASTIC_WORKSPACE` must be set

JDK pinning and `GRADLE_USER_HOME` only engage when it is; `direnv` sets it.
Without it Gradle auto-provisions its own JDKs into `~/.gradle/jdks` and the
pinning is silently inert — no error, just unpinned builds.

### Six JDKs, three separate mechanisms

Gradle resolves JDKs three different ways and **all three must be satisfied**:

1. **Compile toolchains** — `jvmToolchain(...)` in build scripts.
2. **Daemon JVM criteria** — per-repo `gradle/gradle-daemon-jvm.properties`.
   Stricter than a version: `meshtastic-sdk` requires vendor **JETBRAINS** 21,
   `android` requires **25**. Without a match the daemon will not start at all.
3. **Per-module vendor toolchains** — `android`'s `:desktopApp` requires
   JetBrains **25** (`desktopApp/build.gradle.kts:129`), even though its daemon
   runs happily on plain 25.

Hence `jdk21`, `jdk17`, `temurin-bin-11`, `jetbrains.jdk-21`, `jdk25`,
`jetbrains.jdk`. Each is load-bearing for a specific repo.

Each layer was invisible until the one before it was fixed. `nix flake check`
and `javaToolchains` both passed while real builds still failed.

### Toolchain config goes in `gradle.properties`, never `GRADLE_OPTS`

`GRADLE_OPTS` configures the **launcher** JVM. Toolchain resolution happens in
the **daemon**, which never sees it. The flake writes `gradle.properties` into
`GRADLE_USER_HOME`. Verify:

```bash
./gradlew javaToolchains    # auto-detect AND auto-download must read Disabled
```

### Do not install Gradle

Every repo pins its own via `./gradlew` (9.5.1 / 9.6.1). Nix supplies JDKs only.

---

## Android

### The SDK is host-managed on purpose

Not `androidenv`. An `androidenv` SDK is read-only in `/nix/store` while AGP
wants to write into `$ANDROID_HOME` — the documented `aapt2FromMavenOverride`
problem. Versions are declared in
[`android-sdk-packages.txt`](./android-sdk-packages.txt) and applied with
`nix run .#bootstrap-sdk`.

Coordinates use android-cli's slash form (`platforms/android-37.0`), not
sdkmanager's semicolon form (`platforms;android-37.0`).

Trade-off, stated plainly: pinned by version, **not** by hash.

### `android-cli` is not pinned by Nix

Two compounding reasons — never treat its version as reproducible:

1. The nixpkgs binary is only a **launcher**. It unpacks the real ~84 MB CLI
   into `~/.android/bin/android-cli` and self-updates it there.
2. **`cmdline-tools` 22.0.0+ ships the android CLI itself**, and that copy is
   newer (1.0.15857036 vs nixpkgs 1.0.15498356). `androidHook` puts
   `$ANDROID_HOME/cmdline-tools/latest/bin` on PATH, so the SDK's copy wins.

The dev shells therefore do **not** carry `android-cli`. It exists only in
`nix run .#bootstrap-sdk`, which must work on a machine with no SDK at all.

---

## PlatformIO

### Must be `platformio-core`, not `platformio`

`pkgs.platformio` is a `buildFHSEnv` **bubblewrap** wrapper. Ubuntu sets
`apparmor_restrict_unprivileged_userns=1`, denying unprivileged user namespaces
to unconfined binaries — everything in `/nix/store`. Every invocation dies with:

```
bwrap: setting up uid map: Permission denied
```

Confirmed to be the machine, not a tool sandbox. The FHS wrapper exists so
PlatformIO's downloaded, dynamically-linked toolchains run on NixOS; Ubuntu is
already FHS, so it buys nothing.

**On NixOS, swap back to `pkgs.platformio`** or those toolchains will not run.

Also: do not add `gcc-arm-embedded`. PlatformIO fetches its own cross-toolchains
into `PLATFORMIO_CORE_DIR`, and two on PATH produces baffling link errors.

---

## Git across repos

### Default branches differ

`main`, `master` (`meshtastic-mcp`, `protobufs`, `design`) and `develop`
(`firmware`) are all in use. Resolve `origin/HEAD` per repo — never hardcode.

### Single-branch clones hide drift

A clone with `remote.origin.fetch = +refs/heads/main:...` can never fetch other
branches, so their drift is invisible and `@{u}` fails **even when the branch
exists on origin**. That reports a clean state which is wrong.
`nix run .#sync` detects it; `--pull` widens the refspec.

### Fast-forwards move submodule pointers

`firmware/protobufs` re-reads dirty immediately after a pull whenever upstream
bumps the pointer. `--pull` re-syncs submodules automatically and reports
`+submodules`.

### `git stash` ignores submodule state

A submodule checked out at a different commit than recorded is **not** stashable
content — `git stash` returns "No local changes to save" and the state persists.

### Worktrees need their shell attached

A hand-made `git worktree` inherits only the workspace-root `.envrc` and gets
the **default** shell — verified: no `scrcpy`, wrong `android` binary, no error.
Use `nix run .#worktree`.

Ignoring is done via `.git/info/exclude` (local, never committed) because only
`android` gitignores `.claude/worktrees/`. Editing a tracked `.gitignore` in an
org repo is not ours to do.

---

## `buf generate` needs network

`protobufs` uses the remote plugin `buf.build/bufbuild/es:v2.1.0`.
`protoc-gen-es` is deliberately not pinned locally. `buf lint` works offline.

---

## Third-party firmware artifacts

Fetched on demand, never vendored.

**RAK4631 OTAFIX bootloader** — from
[`oltaco/Adafruit_nRF52_Bootloader_OTAFIX`](https://github.com/oltaco/Adafruit_nRF52_Bootloader_OTAFIX)
(Huw Duddy's fork of `adafruit/Adafruit_nRF52_Bootloader`). Meshtastic's own
`Adafruit_nRF52_Bootloader` fork is a **different lineage without** the OTAFIX
patches.

```bash
gh release download 0.9.2-OTAFIX2.2-BP1.3 \
  -R oltaco/Adafruit_nRF52_Bootloader_OTAFIX \
  -p 'wiscore_rak4631_board_bootloader-*_s140_6.1.1.zip'
# sha256 c002d103370651cf955333409e6e713c069df2540f5786c70fdfe4901ca3c7dc
```

Not a workspace entry: third-party rather than org, and building it needs ARM
GCC plus the nRF SDK — a toolchain no shell here provides.

---

## Verification status

Confirmed on x86_64-linux, by running them:

| Repo | Verified |
| --- | --- |
| — | `nix flake check --all-systems` |
| `meshtastic-sdk` | `./gradlew :core:build` — JVM + Android + iOS klibs, tests, Kover, ABI check |
| `android` | `./gradlew :androidApp:assembleFdroidDebug` — 3 APKs |
| `firmware` | `pio run -e heltec-v3` — flashable factory image, 7m40s |
| `protobufs` | `buf lint` |
| `meshtastic-mcp` | `uv sync --frozen` |

**Not verified:** `.#apple` — needs macOS + Xcode; nothing on Linux can close it.

---

## Conventions for changing this repo

- New file → whitelist it in `.gitignore`, which denies by default.
- Changed `flake.nix` → `nix flake check --all-systems` before committing. It
  only **evaluates** shells; passing eval does not mean a repo builds.
- `writeShellApplication` runs ShellCheck and fails the build on warnings.
- Prefer verifying over asserting. Every claim above has a command behind it.
