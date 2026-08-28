# AGENTS.md

Canonical detail for this workspace. Start elsewhere:

- [`CLAUDE.md`](./CLAUDE.md) — the router: repo index, protocol, coupling
- [`README.md`](./README.md) — daily workflow and commands

This file is the **why**. Every constraint below was found by a failing build,
not reasoned about in advance. Do not "simplify" them away.

One rule keeps it from going stale: prose here records **decisions and
reasons**, which age well. Live state — branches, drift, doc inventories,
wiring — belongs to the tools (`brief`, `sync`, `doctor`), which cannot go
stale. If a fact can be asked live, ask the tool; don't restate it here.

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

### Compose Desktop tests need `libGL` on the loader path

Skiko dlopens `libGL.so.1` at load time even for CPU raster rendering, and the
Nix JVM's glibc never reads the host's ld.so cache — so the host's mesa is
invisible and every Compose UI test in a `jvmTest` run dies with
`LibraryLoadException` (26 at once in Meshtastic-Android's
`:feature:settings`), the real cause buried in the last `Caused by:` line. The
JVM shells therefore put `libglvnd` on `LD_LIBRARY_PATH` on Linux — verified
sufficient for headless raster tests. Same failure class as the manylinux
wheels in `.#python`.

### The desktop app inherits the Gradle daemon's environment, not yours

`./gradlew :desktopApp:hotRun` forks the app from the **Gradle daemon**, so the
app sees the daemon's environment — and Gradle reuses any *compatible* daemon,
where compatibility covers JVM args and JDK but never environment variables. A
single daemon started from a non-graphical shell (an agent tool call, CI, a
plain `ssh`) therefore poisons the pool: every later `hotRun`, including one
launched from a desktop terminal that plainly has a display, dies with
`java.awt.HeadlessException: No X11 DISPLAY variable was set`. The error blames
X11 and the terminal, never the daemon, which is what makes it expensive.
`-Djava.awt.headless=true` in `android/gradle.properties` is a red herring — it
applies to the daemon JVM only.

Check which daemon would serve you before believing anything else:

    for p in $(pgrep -f GradleDaemon); do
      printf '%s: ' "$p"
      tr '\0' '\n' < /proc/$p/environ | grep -E '^(DISPLAY|XAUTHORITY)=' || echo NONE
    done

Run with `--no-daemon` and the display exported, which sidesteps the pool. AWT
reaches a Wayland session through XWayland, so `DISPLAY` and `XAUTHORITY` are
what matter — `WAYLAND_DISPLAY` alone does nothing:

    export DISPLAY=:0 XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.*
    direnv exec . ./gradlew --no-daemon :desktopApp:hotRun

Skiko then logs `RenderException: Cannot create Linux GL context` and falls back
to software, which renders fine. Do **not** chase that with
`LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu`: prepending the whole system library
path loads a second GLib beside the Nix one `libnotify` already pulled in,
GObject refuses to re-register its types (`cannot register existing type
'GInitable'`), and no window opens at all. Verified 2026-08-28.

### A comma in a backtick test name breaks Kotlin/Native, not the JVM

Kotlin/Native rejects `,` inside a backtick-quoted identifier. JVM and Android
accept it, so a `commonTest` function named ``fun `parses lat, lon`()`` compiles
and passes locally and on every Android check, then fails the iOS compile in
CI — the one target most likely to be running last, or on someone else's PR.

It has bitten this workspace twice in Meshtastic-Android alone (`435173767`,
then `b3ca2e940` "no comma in a common-test name — illegal in Kotlin/Native",
with `a821039e0` repairing the fallout). Every KMP repo here shares the
exposure: `meshtastic-sdk`, `MQTTastic-Client-KMP`, `kzstd`, `TAKPacket-SDK`
and `android` all publish an Apple target from `commonTest`.

Semicolons and parentheses are fine. Reach for a dash or "and" instead, and
treat "the iOS job failed but nothing else did" as this until proven otherwise.

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

### `platformio-core` by default, `platformio` in `.#firmware-fhs`

`pkgs.platformio` is a `buildFHSEnv` **bubblewrap** wrapper. Ubuntu sets
`apparmor_restrict_unprivileged_userns=1`, denying unprivileged user namespaces
to unconfined binaries — everything in `/nix/store`. Every invocation dies with:

```
bwrap: setting up uid map: Permission denied
```

Confirmed to be the machine, not a tool sandbox. The FHS wrapper exists so
PlatformIO's downloaded, dynamically-linked toolchains run on NixOS; Ubuntu is
already FHS, so it buys nothing.

Both are built. `.#firmware` ships `platformio-core` and suits any host that is
already FHS — every mainstream Linux, and macOS. `.#firmware-fhs` ships
`pkgs.platformio` for NixOS and anything else non-FHS, where those downloaded
toolchains cannot otherwise find `/lib64/ld-linux-x86-64.so.2`.

This is **not** conditional on the evaluating machine, and deliberately so.
`builtins.pathExists /etc/NIXOS` does evaluate inside a flake — checked, it does
not throw in pure eval — but branching on it would make the same flake and lock
produce different derivations on NixOS than on Ubuntu. `nix flake check
--all-systems` in CI would then be answering a question no NixOS contributor
asked, and two developers would silently get different `pio` binaries. So the
choice is a shell name, and each shell's hook detects the mismatch at *runtime*
and names the other one.

Worth knowing where upstream stands: `firmware/flake.nix` selects
`pkgs.platformio` — right for the NixOS users it targets, wrong on every host
that restricts user namespaces. That divergence is the whole reason the
workspace `direnvrc` overrides upstream's tracked `use nix`.

Also: do not add `gcc-arm-embedded`. PlatformIO fetches its own cross-toolchains
into `PLATFORMIO_CORE_DIR`, and two on PATH produces baffling link errors.

### `ccache` did nothing here — PlatformIO's own object cache replaced it

`ccache` sat in this shell's packages for a while and never once served a hit.
PlatformIO drives the compilers through SCons and never invokes it, and
firmware's `platformio.ini` sets no `build_cache_dir` either, so both halves of
the mechanism were absent — a package that looks like a build accelerator and
is inert costs more than it saves, because it stops anyone asking why the
rebuild is still slow.

The supported mechanism is PlatformIO's own object cache, and the environment
override is honoured — verified with `pio project config`, which reports the
value back. The shell exports `PLATFORMIO_BUILD_CACHE_DIR` into `.cache/`
beside the Gradle home, since that directory is already documented as
disposable. Do not re-add `ccache` on the assumption it was an oversight.

### `yaml-cpp` is in the shell for the native target

`variants/native/portduino.ini` links `-lyaml-cpp`, so `pio run -e native` —
the hardware-free virtual radio — needs the headers. `meshtastic-mcp doctor`
tells you to `sudo apt install libyaml-cpp-dev`, which would install it on one
machine, outside the flake, invisibly.

It sits in `packages`, not `buildInputs`: this is a native build, so
nativeBuildInputs contribute `-isystem` too. `bluez` already demonstrated that
— it is in `nodeTools` and its include dir was already reaching
`NIX_CFLAGS_COMPILE`, which is what made the one-line addition enough.

Since meshtastic-mcp `a156611`, `doctor` reads the compiler's include path
(`CPATH`, `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH` and the `-isystem` flags in
`NIX_CFLAGS_COMPILE`) rather than only `/usr/include`, so inside `.#firmware` it
now reports this **ok**. Outside any shell it still reports missing, correctly:
nothing has put yaml-cpp on that host's include path.

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

## The bench

The radios on this machine's USB are shared mutable state, and the sharing is
invisible from inside a session. Operational detail — recovery, identity,
known-bad pairings, where the fleet tooling lives — is in
[`notes/bench-fleet.md`](./notes/bench-fleet.md). Two invariants belong here,
because they are properties of *this workspace's wiring*, not of the hardware.

### Every session builds and flashes out of one `firmware/` checkout

`scripts/lib.sh` exports `MESHTASTIC_FIRMWARE_ROOT="$root/firmware"` from both
MCP entry points — the generated `.mcp.json` and the user-scope launcher
`bin/meshtastic-mcp-launch`. Deliberately not worktree-relative: the flash and
build tools must reach a real firmware tree from any cwd on the machine.

Nothing prints the consequence. A session in `android/.claude/worktrees/x`
builds in the primary `firmware/.pio`; so does every other concurrent session;
so does a `meshtastic-mcp` test whose mocked upload leaks. Both failure modes
were seen live on 2026-08-26 — another session's build wiped a finished
8-minute artifact between `build_poll` reporting `done` and the next `ls`, and
an orphaned `pio run -t upload` carrying an *invalid* port went to PlatformIO's
auto-detect fallback with real boards on the bus. Check `pgrep -af 'pio run'`
before a flash session, and flash the moment a build reports done.

### A serial port number is not a device identity

`/dev/ttyACM*` is assignment order. It changes on every replug, power cycle and
lockup recovery, and two boards of the same model are separable only by USB
serial — which has already mattered here (two RAK4631s on the bus at once,
2026-08-22). Resolve through `/dev/serial/by-id/` at the point of use. Any
tool, script or note that stores a port number across a session boundary is
storing a guess.

---

## Python

### One shell serves every Python repo, and it is named for the stack

`meshtastic-mcp`, `labeltastic` and `meshtastic-python` want the same things:
CPython 3.13, the serial/USB tools, and the `LD_LIBRARY_PATH` that keeps
manylinux wheels loadable (numpy and opencv in the first, Pillow in the
second — same failure, same fix). Separate shells would have meant
maintaining that list three times, and the divergence would only show up as a
wheel that imports in one repo and not the others.

So the shell is `.#python`, not `.#mcp`. It was renamed when `labeltastic`
was registered: a shell named after one of the repos it serves invites the
assumption that the others are misconfigured. `.#kotlin` — five repos, no
repo of that name — was already the precedent. `reposFor` derives the banner
from the workspace table so it cannot drift as repos are added.

What a given repo does not need — `nodejs_22`, `androidHook` — it gets
anyway, and that is deliberate: both are already paid for by `meshtastic-mcp`
and neither costs the others anything at runtime. `nodeTools` is not in that
category; **all three** need it. Each talks to a USB serial radio, and
`labeltastic` drives a Niimbot printer on a second port, which is also why
`serialHook`'s dialout-group warning matters here.

### Both uv and Poetry, on purpose

`meshtastic-mcp` and `labeltastic` are uv projects (`uv.lock`).
`meshtastic-python` is Poetry — `poetry.lock`, `[tool.poetry]` tables, and
`poetry install --all-extras --with dev,powermon` in its CI. uv cannot
install from a `poetry.lock`, so shipping only `uv` would leave that repo
unbuildable in a shell that looked correctly configured — the silent-failure
class this workspace exists to eliminate. The shell prints the rule rather
than the repo names, so it cannot go stale: **the lock file tells you which
manager to use.**

### Poetry does not inherit the pinned interpreter — pin it per repo

`UV_PYTHON`/`UV_PYTHON_DOWNLOADS` bind **uv only**. Poetry ignores them, and
Poetry 2.4 has no config key to say otherwise — `poetry config
virtualenvs.python` answers *"There is no virtualenvs.python setting"*. What
it does instead is scan for interpreters and take the **newest** one
satisfying the project's `requires-python`.

That turns two facts already recorded elsewhere in this file into a silent
wrong answer. `esptool` propagates its own CPython 3.14 onto `PATH` (the
reason `pythonHook` prepends ours at all), and `meshtastic-python` declares
`^3.9,<3.15` — so 3.14 is *allowed and newer*. Observed on a fresh clone:
bare `python3` and `uv` were the pinned 3.13.14 while `poetry install`
quietly built `…/virtualenvs/meshtastic-AkUHFRTl-py3.14`. Nothing errors; the
CLI runs; the repo is simply not being built against the interpreter Nix
pinned. `pythonHook`'s prepend cannot fix this, because Poetry enumerates
versions rather than taking the first `python3` on `PATH`.

The fix is explicit, and one-time per repo:

```bash
poetry env use "$UV_PYTHON"     # verified: yields 3.13.14
```

The `.#python` shellHook checks this on entry — when the directory has a
`poetry.lock` and the active env is off the pin, it prints that exact
command. A warning rather than an automatic `poetry env use`, matching
`androidHook` and `serialHook`: entering a shell should not mutate a venv.

### The `python` attribute is not the `python` shell

The devShells attrset now has a `python` attribute while the let block above
it binds `python = pkgs.python313`. They do not collide, because that attrset
is not `rec` — `${python}` inside the shell still resolves to the
interpreter. Adding `rec` would silently rebind it to the shell derivation.
Verified by `nix flake check`; the comment in `flake.nix` says so at the site.

---

## Org conventions

Repo shape across the org, and the invariants a KMP library here must hold.
Distilled 2026-08-17 from the 2026-07-21 KMP audit and re-verified against the
live repos; the corpus was point-in-time evidence and is gone. It and its
reusable audit prompt are at `b936d8c:notes/kmp-audit/`.

### `meshtastic/.github` supplies no community-health defaults

It holds only `LICENSE`, `README.md` and `profile/` — none of the filenames
GitHub inherits org-wide (`CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
`SECURITY.md`, `ISSUE_TEMPLATE/`, `PULL_REQUEST_TEMPLATE.md`, `FUNDING.yml`,
`SUPPORT.md`). Confirmed 2026-08-17 via
`gh api repos/meshtastic/.github/contents`.

There is no safety net: a repo without a `SECURITY.md` has none, and only ~10
of 155 repos do. Every repo ships its own. `CODE_OF_CONDUCT.md` points at
`meshtastic.org/docs/legal/conduct/` rather than restating one.
`.github/FUNDING.yml` names the **org** (`github: meshtastic`,
`open_collective: meshtastic`), never an individual — `apple`'s names a
person, which is the drift.

### `main` is the convention; the `master` plurality is vendored code

100 of 155 repos are on `master`, almost all vendored third-party embedded
libraries (`Adafruit_nRF52_Arduino`, `TinyGPSPlus`, `GxEPD2`, …) that
inherited the name upstream. Among repos Meshtastic authors, `main` wins;
`develop` is firmware's git-flow alone. `kzstd` and `TAKPacket-SDK` have since
renamed, leaving `protobufs` the last first-party holdout.

### `org.meshtastic` is the coordinate root; `com.geeksville.mesh` is not

Every published artifact and Kotlin package root in the org is
`org.meshtastic`. The Android app's `applicationId` is still
`com.geeksville.mesh` — legacy-locked Play Store identity, since changing it
loses the listing. Never copy it into anything new.

Dependency automation is **Renovate**, not Dependabot, in every Kotlin repo.
Tags are `v`-prefixed semver, and immutable — see
[`notes/cross-repo-contracts.md`](./notes/cross-repo-contracts.md).

### Three ways KMP CI reports green over an unguarded surface

- **A JVM-only ABI dump.** The klib (common/native) ABI changes freely
  underneath it. Validation must cover the klib dump, with `explicitApi()`
  strict mode as the prerequisite; a Konsist allowlist supplements it, never
  substitutes.
- **Cross-compiling a target is not testing it.** A matrix that builds Apple
  and native targets but executes only `jvmTest` reports success for targets
  that ran no assertion.
- **A tag→publish workflow that has never fired.** `protobufs` and `kzstd`
  both had one while every release was in fact manual.

Publishing runs on a **macOS runner** — Apple targets build nowhere else — and
vanniktech's maven-publish plugin is configuration-cache incompatible, so
publish tasks need `--no-configuration-cache`. Central accepts a 261-byte
empty javadoc stub without complaint; wire Dokka into the javadoc jar.

### Kover measures JVM/Android bytecode only

It is not multiplatform coverage; do not advertise it as such.

The coverage gate is a **Codecov project-status regression gate**
(`target: auto`, `threshold: 1%`), chosen over a fixed `koverVerify` floor
because it self-calibrates against each PR's base commit — no per-repo
threshold to pick or maintain. It is still `informational`, never flipped to
blocking.

### CodeQL cannot scan current Kotlin

CLI 2.26.1 rejects Kotlin 2.4.10 as "too recent" and the `java-kotlin`
autobuild fails. Every `codeql.yml` in the org's Kotlin repos therefore scans
`actions` only, with `java-kotlin` committed-but-commented — still the case in
all five on 2026-08-17. Upstream merged a 2.4.20 ceiling; re-enable when a CLI
carrying it ships.

On the rollback path CLAUDE.md keeps: the old shared HTTP build cache's
`GRADLE_CACHE_URL` **must include the `/cache/` path**. A bare host URL 401s on
read and Gradle silently disables the remote cache, reporting only "remote
build cache was disabled during the build due to errors".

### What had already rotted, and why nothing was promoted verbatim

- **"meshtastic-sdk is pinned to Kotlin 2.4.0; SKIE 0.10.13 rejects 2.4.10."**
  SKIE 0.10.14 added support; the SDK bumped in PR #95.
- **The decided per-repo `jvmToolchain` table**, including
  "`MQTTastic-Client-KMP` = 11, deliberately, for consumer reach". No
  `jvmToolchain(11)` survives there. The durable rule is only *pin it and be
  deliberate*; values live in the build scripts.
- **"`kzstd` and `TAKPacket-SDK` are on `master`."** Both renamed.

Version numbers were the rot. Renovate owns them and
`gradle/libs.versions.toml` is the source of truth; a version in prose is a
claim with an expiry date.

---

## Git across repos

### Default branches differ

`main`, `master` (`meshtastic-mcp`, `protobufs`, `design`, `meshtastic`, `api`)
and `develop` (`firmware`) are all in use. Resolve `origin/HEAD` per repo —
never hardcode.

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

### A CRLF blob in the index makes a clean worktree read dirty

`.#worktree --remove` refuses on uncommitted changes, which is correct — except
when the change is not one you made. A file committed with CRLF while
`.gitattributes` (or `core.autocrlf`) says LF re-reads as modified the instant
it is checked out, in every fresh clone and every new worktree, with nothing to
stage away. The worktree cannot be removed and the diff looks empty.

Found on `kzstd`'s `gradlew.bat`, fixed by renormalizing the blob
(`87fe98c`, PR #33), after which `--remove` worked. A sweep of the other repos
found no second instance, so this is a "recognise it, don't hunt for it" entry:
if `git status` insists a file you have never opened is modified, check the
blob's line endings before believing the worktree is dirty.

### Per-repo `.envrc` files are generated, never hand-written

direnv loads only the **nearest** `.envrc`. A repo with none falls back to the
workspace-root file and gets `.#default` — wrong toolchain, no error. So
`nix run .#sync` writes one per repo, idempotently, never clobbering — with
one exception: a file **it wrote** (generated header) whose `use flake` shell
the table has since renamed is rewritten and reported as `envrc updated`,
because the old never-clobber rule kept `meshtastic-mcp/.envrc` pointing at
the retired `#mcp` shell through every sync while nix-direnv silently fell
back to a cached, unpinned environment. Hand-written and tracked files are
only warned about; `doctor` reports the same drift as `envrc shells`.

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

**The hook only fires in interactive shells.** Scripts, CI steps and agent
subshells get none of this environment — Gradle then runs with unpinned JDKs,
the exact failure the `.envrc` exists to prevent, silently. From any
non-interactive context, run repo commands as
`direnv exec <repo-or-worktree> <cmd>`.

### `.mcp.json` is generated too

Same rule, same reason: regenerate it, never hand-edit it. `.#sync` writes one
at the workspace root and `.#worktree` writes one per worktree, both from
`write_mcp_json` in [`scripts/lib.sh`](./scripts/lib.sh), registering the
`meshtastic-mcp` server for whatever MCP client runs in that directory.

A bare `claude mcp add` would instead put **store paths** in `~/.claude.json`
— outside the workspace, where `.#sync` cannot rebuild them, going stale on
every flake update — and its default (local) scope binds the server to a
single directory, leaving every worktree silently without the tools.

**User scope is different, and sanctioned.** `.#sync` also writes
`bin/meshtastic-mcp-launch` — a *stable path* whose contents (the moving
store paths) sync rewrites every run. Registering **that** once,

```bash
claude mcp add --scope user meshtastic -- "$MESHTASTIC_WORKSPACE/bin/meshtastic-mcp-launch"
```

puts the meshtastic tools in **every** directory on the machine — including
the repos and worktrees project scope can never reach (below) — and survives
`nix flake update`, because the registration names the launcher, not the
store. Where a project `.mcp.json` defines the same server name, project
scope wins, so behaviour at the workspace root is unchanged. `doctor` checks
the registration; `sync` prints the command when it is missing.

Three consequences worth knowing:

- **It names store paths** — `uv`, the interpreter, and the loader path are
  resolved at generation time, so `nix flake update` invalidates them. Re-run
  `.#sync`, exactly as for anything else generated here.
- **`nix develop` is deliberately not in the command.** Wrapping it would keep
  the paths fresh, but measured 4.6s per server start; the client launches this
  on every session.
- **Project-scope servers need consent once per machine**, the same model as
  direnv. `.#sync` prints the reminder; approve with `/mcp`.

**Upstream may track its own `.mcp.json`** — `android`, `firmware` and
`meshtastic-mcp` all do (android's registers context7 for the team). A tracked
file always wins: neither `.#worktree` nor `.#sync` will write ours where one
exists, because overwriting would dirty the tree and stomp the team's
registrations. (`.#worktree` used to do exactly that, unconditionally — the
same failure class the `.envrc` sidecar exists to avoid, one file over.) The
consequence: in an `android` or `firmware` worktree the meshtastic-mcp tools
are never *project*-registered — the user-scope launcher registration above
is what carries them there.

The bundled agent skills are *not* installed from here — on a fresh machine that
would trigger a full `uv sync` inside a git tool. `.#sync` prints the command
when `.claude/skills/` is missing.

### Per-repo subagents are copied to the root, and why copies

Claude Code resolves project subagents by walking `.claude/agents/` from the
cwd up to the enclosing repo root. The org repos are **not** ancestors of the
workspace root, so a session rooted here cannot see them: `.#brief -- android`
would list `gradle-runner` while the Agent tool answered "not found" —
advertised and unusable. That gap sent a Gradle baseline to a generic
subagent on 2026-08-01, which returned a report with no verdict in it and cost
a full re-run.

`.#sync` therefore copies every `<repo>/.claude/agents/*.md` to
`.claude/agents/<repo>--<agent>.md`, from `agent_pairs` in
[`scripts/lib.sh`](./scripts/lib.sh). Four decisions worth the words:

- **Copies, not symlinks.** Skills document symlink support; subagents do
  not. An agent that silently fails to load is the exact failure class this
  workspace refuses to ship, and byte-identical copies also put staleness one
  `cmp` away — which is how `doctor` checks them.
- **The frontmatter `name:` is kept verbatim.** That, not the filename, is
  what the Agent tool resolves, so `android/CLAUDE.md`'s "dispatch the
  `gradle-runner` subagent" keeps working from the root. The `<repo>--`
  filename prefix is for humans and to stop two repos overwriting each other.
- **Duplicate names are warned about, never resolved.** Two repos shipping
  one `name:` resolve by filesystem read order — undefined. `sync` says so;
  prefixed filenames cannot fix it.
- **Deletions propagate.** A copy whose source is gone is removed, because an
  orphan that keeps answering is worse than one that is absent. The drop pass
  runs even when *no* repo has agents left — nesting it under "any agents
  exist" was a real bug, caught by `T12`.

`doctor` reports missing or stale copies with `.#sync` as the fix. `lib.sh`
fronts `doctor` as well as `sync` for this reason: one definition of where a
copy belongs, or the two drift and doctor blesses files sync would not write.

**The copy tracks the primary checkout's working tree, not the repo's
upstream.** `sync` reads `<repo>/.claude/agents/*.md` as they sit on disk, so
the root's copy is whatever branch the primary checkout is parked on, and a
subagent fix made on a **branch** does not reach root sessions until that PR
merges, `main` is pulled, and `sync` runs again. Both directions bite: an agent
repaired in a worktree keeps failing at the root, and a checkout left on a
feature branch quietly publishes that branch's agents workspace-wide. Fixing a
subagent is therefore not done when the commit lands locally — it is done when
`doctor` says the root copy matches.

### Per-repo skills need `bin/claude-ws`, and it names one repo at a time

Skills could not take the same route. A skill is a *directory* whose name is
its identity, so copying `android`'s four and `apple`'s ten to the root would
fork fourteen living directories against their upstreams. Symlinks are
documented to work for skills — but the only mechanism that loads a skill
*and* keeps it where it lives is `--add-dir`, and there is no `settings.json`
equivalent: it must be passed at launch.

`.#sync` writes `bin/claude-ws` (stable path, regenerated each run so a repo
added to the table is picked up):

```bash
bin/claude-ws android          # android's skills + subagents, from the root
bin/claude-ws android apple -p "…"   # several repos, then claude's own args
bin/claude-ws                  # no repo named — exactly plain claude
```

Leading arguments matching a repo become `--add-dir`; the first non-repo
argument stops the scan and everything after it reaches `claude` untouched.

**Repos are named, never all-added by default, and that is the design.**
`--add-dir` also loads that directory's `CLAUDE.md`, and the root `CLAUDE.md`
is a deliberately small router *precisely because* the per-repo agent docs are
too large to all be loaded. Blanket-adding ten repos would defeat the thing
this workspace is built around. `claude-ws android` pays for android and
nothing else — the same "load only what this task needs" rule `.#brief`
exists to enforce.

Note the asymmetry that follows: **subagents work from a bare `claude`**
(they are copied to the root), **skills need the launcher**. That is not a
preference, it is what each mechanism supports.

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

### Worktrees need outfitting — and `sync` now adopts strays

An earlier claim here — that a hand-made `git worktree` gets the **default**
shell — went stale when the per-repo `.envrc` files landed (f6b6888) and has
been re-verified the other way: a bare worktree **under** the repo (e.g.
`android/.claude/worktrees/x`) inherits the repo's own `.envrc` from the
nearest ancestor, evaluated with cwd at the repo, so it gets the right shell
*and* the right `MESHTASTIC_WORKSPACE`. What a bare worktree still lacks, all
silent:

- **`.mcp.json`** — it is per directory, so without a user-scope
  registration the MCP tools are simply absent. (Where upstream tracks its
  own, as `android` and `firmware` do, theirs wins and ours is never written
  beside it — the user-scope launcher registration is the only route in;
  see the `.mcp.json` section above.)
- **The `.envrc-workspace` sidecar** where the repo tracks its own `.envrc`.
  A bare `firmware` worktree runs upstream's `use nix` → bwrap-broken
  platformio. (`.#worktree` writes the sidecar rather than overwriting the
  tracked file, which would leave the worktree dirty at creation.)
- **Any shell at all** if parked outside the repo tree — nothing to inherit.

`nix run .#worktree` writes all of this up front; `nix run .#sync` **adopts**
worktrees created behind its back (hand-made, agent skills, harness
isolation), writing whichever of the three pieces is missing, idempotently.
`nix run .#doctor` warns about unoutfitted ones.

### Worktrees accumulate, and squash-merge hides which are dead

`doctor` answers "is every worktree outfitted", never "should this one still
exist". As of 2026-08-27 that gap reads: 71 worktrees workspace-wide, 38 of
them under `android`, 57 GB on disk, and 21 `android` branches with no upstream
at all — 17 of those untouched for two weeks or more.

Do not classify them with `git merge-base --is-ancestor <branch> origin/main`.
Every repo here that merges through a queue **squashes**, so a fully merged
branch is never an ancestor of `main`; the branches that *are* ancestors are
mostly fresh worktrees cut at main-tip whose work is not committed yet. That
test inverts the answer. Ask GitHub instead — verified 2026-08-27:

    gh pr list --head <branch> --state merged --json number,mergedAt

Read an empty result carefully: it means "no merged PR ever had this head",
which covers a live branch and one that was **never pushed** alike — and
never-pushed is the common case here (21 of `android`'s local branches have no
upstream at all). For those, GitHub knows nothing and the local branch is the
only copy of the work.

`--prune` does not close this either: `git worktree prune` drops **dead
registrations** (a directory already deleted), not live worktrees whose work
landed. Removing a live one is a judgement call about unpushed work — an
unpushed branch is the only copy of it — so it stays manual.

### Agent-harness worktree isolation makes a decoy workspace

An agent harness's worktree isolation (Claude Code's `isolation: "worktree"`,
`EnterWorktree`) run at the workspace root makes a worktree **of the
workspace repo** — verified: it lands in `.claude/worktrees/agent-*` with the
tracked files and **none of the org repos**, which are untracked. Its copy of
the tracked root `.envrc` would have pointed every cache and clone at that
decoy; the root `.envrc` now resolves the **main checkout** via
`git rev-parse --git-common-dir` and exports that instead (in the real root
the two are identical). `use flake` stays bare on purpose — a workspace
worktree exists to test its own flake edits.

Even with that guard, harness isolation is the wrong tool for **repo** work:
the repos are not in the worktree. Use `nix run .#worktree -- <repo>
<branch>`.

Ignoring is done two ways, neither of them a tracked `.gitignore` — editing one
in an org repo is not ours to do. `.claude/worktrees/` and `.mcp.json` go in
`.git/info/exclude` (local, never committed) because only `android` ignores the
former upstream, and `.mcp.json` is a file plenty of projects legitimately
track — a global ignore would hide it everywhere. The direnv files do go in
`~/.config/git/ignore` — git's default excludesfile location, so no
`core.excludesfile` setting is needed.

That first mechanism did not actually work until `7388ecb`. `rev-parse -C <p>
--git-common-dir` answers *relative to `<p>`* — plain `.git` — and the result
was being used relative to the caller's cwd, so every pattern landed in the
**workspace** repo's `info/exclude` and none ever reached the repo it was meant
for. `kzstd/.git/info/exclude` held nothing at all. It stayed invisible because
`~/.config/git/ignore` already covered the direnv files; adding `.mcp.json`,
which it does not cover, is what surfaced it. Fixed with
`--path-format=absolute`. A reminder that a documented mechanism is not a
verified one.

---

## `buf generate` needs network

`protobufs` uses the remote plugin `buf.build/bufbuild/es:v2.1.0`.
`protoc-gen-es` is deliberately not pinned locally. `buf lint` works offline.

---

## OTAFIX bootloader — no longer third-party (2026-08-18)

Until 2026-08-18 this section documented `oltaco/Adafruit_nRF52_Bootloader_OTAFIX`
as a third-party artifact fetched via `gh release download`, kept out of the
workspace because no shell provided ARM GCC. That has changed: Meshtastic now
maintains its own org fork,
[`meshtastic/Adafruit_nRF52_Bootloader_OTAFIX`](https://github.com/meshtastic/Adafruit_nRF52_Bootloader_OTAFIX)
(rebranded, MeshCore/Ripple content stripped, org-convention files added),
and it is a workspace entry with a dedicated `.#otafix` shell (`gcc-arm-embedded-13`,
not the nixpkgs default — see the shell's own comment for why). `git submodule
update --init --recursive` is required before the first build.

Meshtastic's separate `Adafruit_nRF52_Bootloader` fork remains a **different
lineage without** the OTAFIX patches — the two are not interchangeable.

No release has been cut on the new fork yet, so there is no prebuilt UF2 to
`gh release download` — build from source via `.#otafix` until one exists.

---

## Verification status

A report, not a promise — these were run on x86_64-linux, 2026-07-29 through
2026-07-31:

| Repo | Verified |
| --- | --- |
| — | `nix flake check --all-systems --no-build` + `nix flake check` (builds the tools, ShellCheck gates them) |
| `meshtastic-sdk` | `./gradlew :core:build` — JVM + Android + iOS klibs, tests, Kover, ABI check |
| `android` | `./gradlew :androidApp:assembleFdroidDebug` — 3 APKs |
| `firmware` | `pio run -e heltec-v3` — flashable factory image, 7m40s |
| `protobufs` | `buf lint` |
| `meshtastic-mcp` | `uv sync --frozen` |

**Not verified:** `.#apple` — needs macOS + Xcode; nothing on Linux can close it.

### Fresh-machine bootstrap

Verified 2026-07-29 on a second x86_64 Ubuntu host with nothing but Nix
installed — empty store, no `~/.gradle`, no Android SDK, no `~/.platformio`:

- `nix flake check --all-systems` — clean (a historical record: that single
  command predates the `checks` output and now fails on purpose — see
  Conventions below for the two-command form that replaced it)
- all seven Linux shells (`kotlin`, `android`, `firmware`, `protobufs`,
  `python` — then named `mcp` — `design`, `nodes`) entered successfully,
  built cold
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

Still open: `.#python` under `mkShellNoCC` is unproven — both test machines have
`/usr/bin/cc`, so `uv sync` never had to build a wheel from source. Settling it
needs a container without `build-essential`. `uv sync --all-extras` (5.1 GB,
torch and scipy included) does **not** settle it: those all ship prebuilt
manylinux wheels, so nothing compiled.

That run did expose the neighbouring problem, which is now fixed. Those same
prebuilt wheels fail to **load** under the Nix interpreter `UV_PYTHON` pins:
they link `libstdc++`/`libz`, Nix's loader cannot see either, and numpy, opencv,
torch and easyocr end up installed but not importable. The failure names neither
library — it reads `Importing the numpy C-extensions failed`, with the real
cause only on the traceback's last line. Hence `LD_LIBRARY_PATH` in the
`.#python` shellHook, and again in the generated `.mcp.json` because the MCP
client launches the server outside that shell. It covers `labeltastic` for
free — Pillow ships manylinux wheels on the same terms.

---

## Conventions for changing this repo

- New file → whitelist it in `.gitignore`, which denies by default.
- Changed `flake.nix` → two checks before committing, because they answer
  different questions:
  `nix flake check --all-systems --no-build` (evaluates every output for all
  three systems) and `nix flake check` (builds this system's `checks` — the
  tool scripts). `--all-systems` without `--no-build` does not work: it tries
  to build the darwin/aarch64 checks on your machine and dies on "platform
  mismatch". Eval only **evaluates** shells; passing does not mean a repo
  builds.
- `writeShellApplication` runs ShellCheck and fails the build on warnings —
  **at build time**. `nix flake check` builds only the `checks` output;
  devShells and apps are merely evaluated (verified by feeding it an app with
  a guaranteed SC2086 failure, which passed). That is why every tool script is
  listed in `checks` — remove one and ShellCheck silently stops gating it.
- The tool scripts are real files in [`scripts/`](./scripts), not flake
  strings — edit them there. The flake assembles each tool (`lib.sh` is
  prepended to `sync` and `worktree`; everything Nix must supply arrives as
  `NIXTASTIC_*` env vars via `runtimeEnv`), so ShellCheck still sees each
  tool whole when `checks` builds. New scripts must be whitelisted in
  `.gitignore` **and** at least `git add`ed, or pure eval cannot see them.
- The git-state logic in `sync`, `worktree` and `doctor` has fixture tests —
  [`scripts/tools-tests.sh`](./scripts/tools-tests.sh), built as
  `checks.<system>.tools-tests` against a fake workspace, one tiny repo per
  entry in the real table, with local
  bare origins (offline by construction, so the build sandbox is a feature).
  Changing drift/pull/adoption behaviour means extending them; `nix flake
  check` runs them.
- Prefer verifying over asserting. Every claim above has a command behind it.
- **A structural change is not finished until the docs are re-audited.** One
  audit day (2026-07-31) found the same failure three times: a claim verified
  once, the code moved, the claim stayed ("hand-made worktrees get the default
  shell", "flake check gates the scripts", "bootstrap-sdk needs
  cmdline-tools"). Before committing a change that moves code, renames a
  mechanism, or alters tool behaviour: grep `CLAUDE.md`, `AGENTS.md`,
  `README.md`, `notes/` and the `flake.nix`/`scripts/` comments for the names
  touched, and re-verify each affected claim **by running its command** — the
  maxim above applies to the docs themselves.
