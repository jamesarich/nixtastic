# AGENTS.md

Guidance for agents working in this workspace. See [`README.md`](./README.md)
for bootstrap instructions.

This repo tracks **only** the workspace definition. The Meshtastic repos inside
it are independent git repos and must never be committed here.

## Layout

| Directory | Shell | Notes |
| --- | --- | --- |
| `firmware` | `.#firmware` | PlatformIO. Default branch is **`develop`**. |
| `android` | `.#android` | compileSdk 37, minSdk 24 |
| `apple` | `.#apple` | macOS + Xcode only; cannot build on Linux |
| `meshtastic-sdk` | `.#kotlin` | KMP |
| `MQTTastic-Client-KMP` | `.#kotlin` | KMP |
| `kzstd` | `.#kotlin` | KMP |
| `gradle-flatpak-sources` | `.#kotlin` | Gradle plugin |
| `meshtastic-mcp` | `.#mcp` | Python ≥3.11 + uv. Default branch **`master`**. |
| `protobufs` | `.#protobufs` | buf · deno · gradle · cargo. Default **`master`**. |

Deliberately absent: `meshtastic-sniffer` (not the org), `meshtastic-backend`
(Gradle 7.3.1, predates JDK 21), `pluginmeshtastic` (needs the
non-redistributable ATAK SDK).

## Constraints that bite

These were each found by a failing build. Do not "simplify" them away.

### `MESHTASTIC_WORKSPACE` must be set

JDK pinning and `GRADLE_USER_HOME` only engage when it is. `direnv` sets it.
Without it Gradle auto-provisions its own JDKs into `~/.gradle/jdks` and the
pinning is silently inert.

### Six JDKs, three different mechanisms

Gradle resolves JDKs three separate ways, and all three must be satisfied:

1. **Compile toolchains** — `jvmToolchain(...)` in build scripts.
2. **Daemon JVM criteria** — per-repo `gradle/gradle-daemon-jvm.properties`.
   Stricter than a version: `meshtastic-sdk` requires vendor **JETBRAINS** 21,
   `android` requires **25**. Without a match the daemon will not start at all.
3. **Per-module vendor toolchains** — `android`'s `:desktopApp` requires
   JetBrains **25** (`desktopApp/build.gradle.kts:129`), even though its daemon
   runs on plain 25.

Hence `jdk21`, `jdk17`, `temurin-bin-11`, `jetbrains.jdk-21`, `jdk25`,
`jetbrains.jdk`. Removing any one breaks a specific repo.

### Toolchain config goes in `gradle.properties`, never `GRADLE_OPTS`

`GRADLE_OPTS` configures the *launcher* JVM. Toolchain resolution happens in
the **daemon**, which never sees it. The flake writes a `gradle.properties`
into `GRADLE_USER_HOME`. Verify with `./gradlew javaToolchains` — auto-detect
and auto-download must both read `Disabled`.

### Do not install Gradle

Every repo pins its own via `./gradlew` (9.5.1 / 9.6.1). Nix supplies JDKs only.

### The Android SDK is host-managed on purpose

Not `androidenv`. An `androidenv` SDK is read-only in `/nix/store` and AGP wants
to write into `$ANDROID_HOME` — the documented `aapt2FromMavenOverride`
problem. Versions are declared in `android-sdk-packages.txt`, applied with
`nix run .#bootstrap-sdk`. Coordinates use android-cli's slash form
(`platforms/android-37.0`), not sdkmanager's semicolon form.

### `android-cli` is NOT pinned by Nix

Two compounding reasons, so never treat its version as reproducible:

1. The nixpkgs binary is only a **launcher** — it unpacks the real ~84 MB CLI
   into `~/.android/bin/android-cli` and self-updates it there.
2. **`cmdline-tools` 22.0.0+ ships the android CLI itself**, and that copy is
   newer (1.0.15857036 vs nixpkgs 1.0.15498356). `androidHook` puts
   `$ANDROID_HOME/cmdline-tools/latest/bin` on PATH, so the SDK's copy wins.

The dev shells therefore do **not** carry `android-cli`; it exists only in
`nix run .#bootstrap-sdk`, which must work on a machine with no SDK at all.

### Default branches differ

`main`, `master` (mcp, protobufs) and `develop` (firmware) are all in use.
Resolve `origin/HEAD` per repo — never hardcode `main`.

### Watch for single-branch clones

A clone with `remote.origin.fetch = +refs/heads/main:...` can never fetch other
branches, so their drift is invisible and `@{u}` fails even when the branch
exists on origin. `nix run .#sync` detects this; `--pull` widens the refspec.

### `buf generate` needs network

`protobufs` uses a remote plugin (`buf.build/bufbuild/es:v2.1.0`).
`protoc-gen-es` is deliberately not pinned locally. `buf lint` works offline.

## Third-party firmware artifacts

Not vendored here — fetch on demand rather than committing binaries.

**RAK4631 OTAFIX bootloader.** The nRF52840 SoftDevice+bootloader DFU bundle
comes from [`oltaco/Adafruit_nRF52_Bootloader_OTAFIX`](https://github.com/oltaco/Adafruit_nRF52_Bootloader_OTAFIX)
(Huw Duddy's fork of `adafruit/Adafruit_nRF52_Bootloader`, carrying the OTAFIX
patches). Meshtastic's own `Adafruit_nRF52_Bootloader` fork is a different
lineage and does **not** include them.

```bash
gh release download 0.9.2-OTAFIX2.2-BP1.3 \
  -R oltaco/Adafruit_nRF52_Bootloader_OTAFIX \
  -p 'wiscore_rak4631_board_bootloader-*_s140_6.1.1.zip'
# sha256 c002d103370651cf955333409e6e713c069df2540f5786c70fdfe4901ca3c7dc
```

The repo is deliberately not a workspace entry: it is third-party rather than
Meshtastic org, and *building* it needs the ARM GCC toolchain plus the nRF SDK
— a toolchain no shell here provides. Add one only if you start patching
bootloaders rather than flashing published ones.

## Multi-repo sessions

Start at the workspace root. [`CLAUDE.md`](./CLAUDE.md) is the router; read the
protocol there before editing under any `<repo>/`.

```bash
nix run .#brief -- <repo>            # orient: branch, shell, docs to read, PRs
nix run .#worktree -- <repo> <branch>  # isolated worktree WITH the right shell
nix run .#worktree -- --list           # all worktrees across all repos
nix run .#worktree -- --prune          # drop dead registrations
```

`.#brief` is generated live and reports what to read rather than inlining it —
per-repo agent docs total ~66 KB. Doc precedence is
`.specify/memory/constitution.md` → `AGENTS.md` → `CLAUDE.md` →
`CONTRIBUTING.md`, then [`notes/`](./notes/) for repos that publish none.

`.#worktree` writes a per-worktree `.envrc` selecting that repo's shell. Without
it a worktree inherits only the workspace-root `.envrc` and silently gets the
**default** shell — verified: no `scrcpy`, wrong `android` binary. Ignoring is
done via `.git/info/exclude` (local, never committed) because only `android`
gitignores `.claude/worktrees/`; editing a tracked `.gitignore` in an org repo
is not ours to do.

## Verification status

Confirmed working on x86_64-linux:

- `nix flake check --all-systems`
- `meshtastic-sdk` — `./gradlew :core:build` (JVM + Android + iOS klibs, tests,
  Kover, ABI check)
- `android` — `./gradlew :androidApp:assembleFdroidDebug` (3 APKs)
- `protobufs` — `buf lint`
- `meshtastic-mcp` — `uv sync --frozen`

Not verified: `.#apple` (no macOS), `pio run` for firmware.

## Conventions

- Add a file to this repo → also whitelist it in `.gitignore`, which ignores
  everything by default.
- Changing `flake.nix` → run `nix flake check --all-systems` before committing.
  Note it only *evaluates* shells; it does not build them. Eval passing does
  not mean a repo builds.
- `writeShellApplication` runs ShellCheck and fails the build on warnings.
