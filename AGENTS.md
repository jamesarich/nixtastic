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

### clangd needs three things, not one

`clang-tools` is the one deliberate exception to the rule above, and it is safe
for a checkable reason: the package ships **no bare compiler driver**. Its
`bin/` holds `clangd`, `clang-format`, `clang-tidy` and friends — no `clang`,
`clang++`, `cc` or `gcc` to shadow PlatformIO's cross-compilers.

Getting from "clangd is installed" to "clangd works" took three pieces. Each
was invisible until the previous one was fixed, and the error count on
`src/main.cpp` went 37 → 13 → 9 → **0**:

1. **A compile database.** `pio run -e heltec-v3 -t compiledb` writes 714
   entries to `firmware/compile_commands.json` (~33 MB). Upstream already
   gitignores `/compile_commands.json`, so generating it leaves the tree clean.

2. **`--query-driver`.** The database records
   `xtensa-esp32s3-elf-g++` invocations, and clangd cannot guess that driver's
   builtin system include paths. Without it every translation unit dies at the
   first libc header — `'machine/endian.h' file not found`. This is a clangd
   **command-line flag**; `.clangd` config cannot set it. So the flake wraps
   the binary (`clangdPio`) rather than asking each editor to pass it, and that
   wrapper is listed **first** in the firmware shell so it shadows the plain
   `clangd` in `clang-tools`. Do not reorder. Confirm with:

   ```bash
   command -v clangd    # must be the .../clangd/bin/clangd wrapper
   ```

3. **A `.clangd` file.** The database quotes GCC flags clang rejects outright
   (`-mlongcalls`, `-mtext-section-literals`, `-fstrict-volatile-bitfields`,
   `-fno-tree-switch-conversion`, `-freorder-blocks`, `-fno-jump-tables`), plus
   one include chain that reaches a host glibc header expecting `__GLIBC_USE`,
   which newlib does not define. Upstream tracks no `.clangd`, so ours is local
   and globally ignored. Recreate `firmware/.clangd` as:

   ```yaml
   CompileFlags:
     Remove:
       - -mlongcalls
       - -mtext-section-literals
       - -fstrict-volatile-bitfields
       - -fno-tree-switch-conversion
       - -freorder-blocks
       - -fno-jump-tables
     Add:
       - "-D__GLIBC_USE(x)=0"
   ```

   This affects clangd only. The real build never sees it.

Verify the whole chain with `clangd --check=src/main.cpp`. Note that `--check`
reports its refactoring probe as errors: eight `ExtractFunction ==> FAIL:
Cannot extract break/continue` lines are expected and are **not** diagnostics.
Read the `[diagnostic_name]` lines, not the total.

**Formatting is not clangd's job here.** firmware's tracked
`.vscode/settings.json` sets `editor.defaultFormatter` to `trunk.io` for
`[cpp]`, and trunk fetches its own `clang-format`. The `clang-format` on PATH
from `clang-tools` is incidental — do not wire an editor to it and end up
fighting trunk over the same files.

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

### Per-repo `.envrc` files are generated, never hand-written

direnv loads only the **nearest** `.envrc`. A repo with none falls back to the
workspace-root file and gets `.#default` — wrong toolchain, no error. So
`nix run .#sync` writes one per repo, idempotently, never clobbering.

Two ordering constraints, both silent when violated:

1. **`export MESHTASTIC_WORKSPACE` must precede `use flake`.** nix-direnv runs
   the flake's `shellHook` during `use_flake` — verified, not assumed: entering
   `meshtastic-sdk` via `direnv exec` yields `GRADLE_USER_HOME` set and
   `./gradlew javaToolchains` reporting auto-detect and auto-download
   `Disabled`, with all six JDKs `Detected by: Gradle property`. Export it
   afterwards and the hook has already run against an unset variable.
2. **Derive the workspace path.** Repos are direct children, so
   `$(dirname "$PWD")` is correct and survives relocation. Worktrees sit three
   levels down, so `.#worktree` hardcodes the root instead.

### `firmware` tracks its own `.envrc`, and it points at upstream

`firmware/.envrc` is **upstream-tracked** and contains direnv's legacy
`use nix`. That resolves through `firmware/shell.nix` → flake-compat →
firmware's own `flake.nix:45`, whose devShell uses `pkgs.platformio` — the
bwrap-wrapped build that cannot run here. Allowing it hands you the exact
failure this workspace exists to avoid.

Overwriting it is not an option: it is tracked, so the repo would read dirty
forever (blocking `--pull`) and the change could land in an org PR. Instead
[`direnvrc`](./direnvrc) overrides `use_nix` to prefer an untracked
`.envrc-workspace` sidecar that `sync` writes alongside. With no sidecar
present the override is transparent, so unrelated projects are unaffected.

Verified: `direnv exec firmware` yields `pio` at the **same store path** as
`nix develop .#firmware`, `pio --version` runs, and `git status` in `firmware`
is empty even with `--untracked-files=all`.

### direnv's `allowed` codes read backwards

`direnv status` prints `Found RC allowed 0` for **allowed** and `1` for
**blocked**. Reading it the intuitive way inverts the meaning of every
diagnosis. Confirm with `direnv exec <dir> true`, which errors plainly if
blocked. Editing an `.envrc` revokes its approval — expect to re-`allow`
after any change here.

### Worktrees need their shell attached

A hand-made `git worktree` inherits only the workspace-root `.envrc` and gets
the **default** shell — verified: no `scrcpy`, wrong `android` binary, no error.
Use `nix run .#worktree`.

A worktree is a full checkout, so it carries whatever `.envrc` the repo tracks.
For `firmware` that means `.#worktree` writes the `.envrc-workspace` sidecar
rather than overwriting the tracked file, which would otherwise leave every new
firmware worktree dirty at creation.

Ignoring is done two ways, neither of them a tracked `.gitignore` — editing one
in an org repo is not ours to do. `.claude/worktrees/` goes in
`.git/info/exclude` (local, never committed) because only `android` ignores it
upstream. The direnv files go in `~/.config/git/ignore` — git's default
excludesfile location, so no `core.excludesfile` setting is needed.

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

### Fresh-machine bootstrap

Verified on a second x86_64 Ubuntu host with nothing but Nix installed — empty
store, no `~/.gradle`, no Android SDK, no `~/.platformio`:

- `nix flake check --all-systems` — clean
- all seven Linux shells (`kotlin`, `android`, `firmware`, `protobufs`, `mcp`,
  `design`, `nodes`) entered successfully, built cold
- **path-agnostic** — ran from `~/meshtastic-workspace`, not `~/meshtastic`.
  Nothing may hardcode the directory name; derive from
  `MESHTASTIC_WORKSPACE` or `$(dirname "$PWD")`.
- `.#android` with **no SDK at all** enters fine and prints the `sdkmanager`
  hint — confirming `androidHook`'s missing-SDK path warns rather than fails.

That run is also what exposed three documentation defects invisible on a
machine that already satisfies them: the workspace repo is private and needs
credentials before step 2; `nix` is absent from `PATH` in non-interactive
shells even under `bash -lc`; and the per-repo `.envrc` examples hardcoded
`~/meshtastic`.

Still open: `.#mcp` under `mkShellNoCC` is unproven — both test machines have
`/usr/bin/cc`, so `uv sync` never had to build a wheel from source. Settling it
needs a container without `build-essential`.

---

## Conventions for changing this repo

- New file → whitelist it in `.gitignore`, which denies by default.
- Changed `flake.nix` → `nix flake check --all-systems` before committing. It
  only **evaluates** shells; passing eval does not mean a repo builds.
- `writeShellApplication` runs ShellCheck and fails the build on warnings.
- Prefer verifying over asserting. Every claim above has a command behind it.
