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

The store binary is only a launcher. It unpacks the real ~84 MB CLI into
`~/.android/bin/android-cli` and self-updates it there. Treat its version as
unpinned; `flake.lock` does not control it.

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
