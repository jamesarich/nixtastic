# CLAUDE.md

Workspace root for multi-repo Meshtastic work. This file is the **router** -
deliberately small, because the per-repo agent docs are far too large to all
be loaded.

- [`README.md`](./README.md) - human workflow
- [`AGENTS.md`](./AGENTS.md) - canonical detail and the reasoning behind every
  constraint. If the two ever disagree, `AGENTS.md` wins.

## Protocol - before editing under any `<repo>/`

1. **`nix run .#brief -- <repo>`** - live branch, drift, correct shell, and
   every agent/governance doc that repo actually has. Run from inside a
   worktree it describes *that* worktree - named on a `checkout` line - not
   the primary checkout. The bare `.#` form only works **from the workspace
   root** (`.#` stops at a git-repo boundary); elsewhere use **`just brief
   <repo>`** (cwd-preserving, so it stays worktree-aware). Every session gets
   the same spellings injected by the plugin's orient hook; `just pins` and
   `just pr <repo> <n>` answer coupling and PR state without `gh`.
2. **Read that repo's own docs first.** Precedence:
   `.specify/memory/constitution.md` → `AGENTS.md` → `CLAUDE.md` →
   `CONTRIBUTING.md`. A repo with no `AGENTS.md` is not undocumented - check
   [`notes/`](./notes/).
3. **Match that repo's conventions, not the workspace's.** Commit style,
   review process and governance differ per repo.
4. **Never mix commits across repos.** Each is independent; this workspace is
   its own repo too.

A precondition, not a suggestion - a bare "read AGENTS.md" pointer has already
been skipped in practice, which is why `.#brief` exists.

## The repos

| Repo | Role | Stack | Shell | Branch | Commits | Agent docs |
| --- | --- | --- | --- | --- | --- | --- |
| `firmware` | device firmware | C++ / PlatformIO | `.#firmware` | `develop` | sentence-style, ad-hoc prefixes | `AGENTS.md` |
| `device-ui` | MUI: LVGL on-device UI lib (vendored into `firmware` builds as a zip pin) | C++ / LVGL | `.#firmware` | `master` | sentence-style | → [`notes/device-ui.md`](./notes/device-ui.md) |
| `android` | Android + desktop app | Kotlin / Compose | `.#android` | `main` | Conventional | `AGENTS.md`, Spec Kit, skills, subagents |
| `apple` | Apple platform clients | Swift / Xcode | `.#apple` | `main` | Conventional | Spec Kit → [`notes/apple.md`](./notes/apple.md) |
| `meshtastic-sdk` | KMP client SDK | Kotlin MP | `.#kotlin` | `main` | Conventional | `AGENTS.md`, `GOVERNANCE.md`, `CODEOWNERS`, Spec Kit |
| `MQTTastic-Client-KMP` | MQTT 5 client lib | Kotlin MP | `.#kotlin` | `main` | Conventional | `AGENTS.md` |
| `kzstd` | zstd codec lib | Kotlin MP | `.#kotlin` | `main` | Conventional | `AGENTS.md` |
| `meshtastic-node-kmp` | client-side mesh **node** (own keys + crypto) - **private**, CI off | Kotlin MP | `.#kotlin` | `main` | sentence-style | `AGENTS.md`, `README.md` |
| `TAKPacket-SDK` | CoT ↔ TAKPacketV2, 5 languages | Kotlin MP (+ swift/py/ts/c#) | `.#kotlin` | `main` | imperative, detailed body | `CLAUDE.md` (24 KB) |
| `gradle-flatpak-sources` | Flathub manifest plugin | Kotlin / Gradle | `.#kotlin` | `main` | Conventional | → [`notes/gradle-flatpak-sources.md`](./notes/gradle-flatpak-sources.md) |
| `meshtastic-mcp` | MCP server + agent skills | Python / uv | `.#python` | `master` | Conventional | `AGENTS.md`, `CONVENTIONS.md`, `llms.txt`, cursor + windsurf rules |
| `labeltastic` | contact-QR nametag kiosk (Niimbot printer) | Python / uv | `.#python` | `main` | Conventional | `AGENTS.md`, `CONTRIBUTING.md`, `llms.txt` |
| `meshtastic-python` | Python CLI + API (`meshtastic` on PyPI) | Python / **Poetry** | `.#python` | `master` | sentence-style, merged via PR | → [`notes/meshtastic-python.md`](./notes/meshtastic-python.md) |
| `protobufs` | shared `.proto` definitions | buf · deno · gradle · cargo | `.#protobufs` | `master` | mixed | → [`notes/protobufs.md`](./notes/protobufs.md) |
| `design` | design standards, tokens, assets | node · inkscape | `.#design` | `master` | Conventional | → [`notes/design.md`](./notes/design.md) |
| `api` | backend API for meshtastic.org | TypeScript / Node / pnpm / Prisma | `.#api` | `master` | mixed | none yet |
| `meshtastic` | project website + docs (meshtastic.org) | Docusaurus 3 / TypeScript / MDX / pnpm | `.#docs` | `master` | Conventional, merged via PR | Spec Kit |
| `Adafruit_nRF52_Bootloader_OTAFIX` | nRF52 OTAFIX bootloader (org fork of oltaco's) | C / Make | `.#otafix` | `master` | Conventional (since the fork) | `AGENTS.md` (PR #8) |
| `web-flasher` | web-based device flasher (flasher.meshtastic.org) | Nuxt 3 / Vue / TypeScript / pnpm | `.#webflasher` | `main` | Conventional | `.github/copilot-instructions.md` |

The table is orientation; `nix run .#brief -- <repo>` is truth - it reads the
live branch, drift, and doc inventory (with sizes) every time.

Not in the workspace: `meshtastic-sniffer` (not the org), `meshtastic-backend`
(Gradle 7.3.1, predates JDK 21), `pluginmeshtastic` (non-redistributable ATAK
SDK).

## Cross-repo coupling

- `protobufs` is vendored as a submodule at `firmware/protobufs` **and** at
  `meshtastic-python/protobufs`. Edit in `protobufs`, bump the pointer in
  each. Wire compatibility affects firmware, both apps and the SDK
  **simultaneously**. `android` is not a submodule consumer - it takes the
  published `org.meshtastic:protobufs` artifact pinned in
  `gradle/libs.versions.toml`, so a bump there is a version bump.
- `meshtastic-sdk` is consumed by **neither `android` nor `apple`** (checked
  2026-09-05: no `org.meshtastic.sdk` import in either; both talk to radios
  through their own phone-API transports) - but it **does** have a downstream
  consumer outside this workspace (Jonathan's TAK-related work), so an ABI change
  still breaks someone without touching a repo here. The node library
  (`meshtastic-node-kmp`) is designed to sit *below* the SDK, never depend on it.
- `MQTTastic-Client-KMP` is consumed by `meshtastic-node-kmp` (2026-09-05):
  `node-transport-mqtt` takes `org.meshtastic:mqtt-client-core` and
  `mqtt-client-transport-tcp` from Maven Central, which is the reason that library
  exists. So an ABI change there now breaks the node's MQTT bearer. It publishes
  no `iosX64` artifact, which is the one target that module omits.
- `gradle-flatpak-sources` packages `android`'s `:desktopApp` for Flathub.
- `meshtastic-python` is what `labeltastic` and `meshtastic-mcp` both import to
  reach a radio, so it sits under every Python-side device test in this
  workspace. `labeltastic` pins `meshtastic>=2.6` - the release that shipped
  the shared-contact URL (`meshtastic.org/v/#…`) it prints as a QR.
- `design` defines standards that `android`, `apple` and `web` implement;
  tracked on <https://github.com/orgs/meshtastic/projects/16>, not in the repo.
- `design` is also vendored as a submodule inside `meshtastic` at
  `static/design`, the same pattern as the `protobufs` submodules above.
- `api` backs meshtastic.org and serves the small JSON resources the clients
  share: `data/deviceLinks.json`, `data/eventFirmware.json`, and since
  2026-08-20/21 `data/bootloaderOtaQuirks.json` (`resource/bootloaderOtaQuirks`)
  and `data/maintenanceUf2.json` (`resource/maintenanceUf2`, api #125).
  `android` consumes both (#6803): `BootloaderOtaQuirksRepositoryImpl` and
  `MaintenanceUf2RepositoryImpl` fetch the endpoint, seeded from a bundled
  asset so they are never empty offline, and the maintenance manifest's
  SHA-256 is verified before any UF2 write - so the trust-model question is
  settled as "digest-pinned manifest, not compile-time constants". A
  scheduled Action (#6813) refreshes the bundled seeds from the API. `apple`'s
  OTAFIX flow (#2338/#2339) still hand-mirrors its board map and
  `web-flasher`'s drag-and-drop UF2 flow has no nudge - neither consumes
  either endpoint yet.
- `web-flasher` already calls `api.meshtastic.org` for
  `resource/deviceHardware` and `resource/eventFirmware` (mirroring its own
  cached copy of the hardware list, refreshed by a scheduled GitHub Action -
  the same "committed sync copy" shape as `api`'s own `deviceLinks.ts`).
- The nRF52 factory-erase images the maintenance manifest points at are
  hosted via commit-pinned `raw.githubusercontent.com` URLs into
  **`web-flasher`'s own `public/uf2/`**, and the OTAFIX images at an
  `Adafruit_nRF52_Bootloader_OTAFIX` release tag - so a new OTAFIX release
  is now an `api` data change (plus `apple`'s hand copy), no longer an
  `android` code change.

The wire-level contracts these couplings rest on - the phone↔device handshake,
proto change rules, MQTT topics and the release order - are in
[`notes/cross-repo-contracts.md`](./notes/cross-repo-contracts.md). The org's
repo-shape conventions - community-health files, branch naming, coordinates,
and the invariants a KMP library here must hold - are in
[`AGENTS.md`](./AGENTS.md) → Org conventions.

## Spec Kit

`android`, `apple`, `meshtastic-sdk` and `meshtastic` carry it. Their
`.specify/memory/constitution.md` (8–12 KB) **outranks** other agent docs -
read it. The specify→plan→tasks lifecycle is not used in practice (measured
2026-09, `notes/agent-surface.md`); do not create its files.

`apple/CLAUDE.md` is Spec Kit-managed and **dynamic** - regenerated to point at
the active `specs/<feature>/plan.md`. Read it to find the live plan; never
hand-edit it.

## Worktrees

`nix run .#worktree -- <repo> <branch>` creates one under
`<repo>/.claude/worktrees/` with the repo's shell wired up and a `.mcp.json`
so the `meshtastic-mcp` tools follow you in - except where upstream tracks
its own `.mcp.json` (`android`, `firmware`): theirs wins, and the
**user-scope launcher registration** (`doctor` checks it, `sync` prints the
command) is what carries the meshtastic tools there instead. A worktree made any
other way (hand-rolled `git worktree`, agent skills) silently lacks these
files - for `firmware`, including the sidecar that keeps it off upstream's
broken PlatformIO; `nix run .#sync` adopts such strays and writes what's
missing.

**Never use the harness's own worktree isolation (`isolation: "worktree"`,
`EnterWorktree`) for repo work.** At the workspace root it creates a worktree
of the *workspace* repo, which contains none of the org repos - they are
untracked. Use `nix run .#worktree` instead.

## Changing the workspace itself

The tool scripts are real files in `scripts/` - edit them there, not in
`flake.nix`, and follow the Conventions section of `AGENTS.md`. The gate is
two commands (`just check` runs both): `nix flake check --all-systems
--no-build`, then `nix flake check` - the second builds the tools (ShellCheck)
and runs their fixture tests.

## Fails silently - check these first

`nix run .#doctor` checks most of this list and prints the fix for what it
finds - run it before diagnosing by hand.

- **`MESHTASTIC_WORKSPACE` unset** → JDK pinning inert, Gradle auto-provisions
  its own JDKs. `direnv` sets it. In a per-repo `.envrc` it must be exported
  **before** `use flake`, or the shellHook runs too early to see it.
- **Never hand-write a repo `.envrc`** - `nix run .#sync` generates them,
  and since 2026-08-21 also repairs a generated one whose shell `flake.nix`
  has renamed (a stale `#mcp` survived every sync and nix-direnv silently
  fell back to an unpinned environment); `doctor` reports it as `envrc
  shells`. Hand-written files are warned about, never touched.
  `firmware` is special: it tracks its own (`use nix`, pointing at upstream's
  flake), so it gets an untracked `.envrc-workspace` sidecar instead. Never
  edit a tracked `.envrc`.
- **`.mcp.json` is generated too** - `.#sync` at the root, `.#worktree` per
  worktree, and both name the stable `bin/meshtastic-mcp-launch`, which holds
  the store paths and which `sync` rewrites (`nix flake update` breaks the
  server until you do). A bare `claude mcp add` (local scope, store paths in
  `~/.claude.json`) is the trap; the sanctioned form is **user scope pointed
  at that same launcher** - it reaches `android/`, `firmware/` and every
  worktree, and one endpoint in both scopes means no `/mcp` conflict.
- **Per-repo subagents only exist at the root because `.#sync` copies them
  there.** Claude Code scans `.claude/agents/` from the cwd up to the
  enclosing repo root, and the org repos are not ancestors of the workspace -
  so `android`'s `gradle-runner` is unusable from a root session until sync
  aggregates it into `.claude/agents/<repo>--<agent>.md`. The copies keep
  upstream's frontmatter `name:` (that, not the filename, is what the Agent
  tool resolves), so `android/CLAUDE.md`'s "dispatch the `gradle-runner`
  subagent" works verbatim from here. `doctor` reports missing or stale
  copies; two repos sharing a name resolve by filesystem order, so `sync`
  warns rather than picking silently.
- **Per-repo *skills* reach every session as forwarders.** A skill directory's
  name is its identity, so repo skills cannot be copied like subagents. The
  `nixtastic` plugin that `.#sync` renders into `.cache/agent-marketplace/`
  and installs ships one forwarder per repo skill, `nixtastic:<repo>-<skill>`,
  whose body points at the real `SKILL.md`; it also carries the three bundled
  meshtastic-mcp skills, `meshtastic-cross-repo`, the worktree and Gradle
  guards, the memory hooks and the GitHub MCP. `bin/claude-ws <repo>` (`--add-dir`,
  loads that repo's `CLAUDE.md` too) remains for skills that must run in place.
- **The direnv hook fires only in interactive shells** - scripts and agent
  subshells get no repo environment, so Gradle silently runs unpinned. From
  non-interactive contexts use `direnv exec <repo-or-worktree> <cmd>`.
- **`.#python` needs `LD_LIBRARY_PATH`** - `UV_PYTHON` pins the venv to the Nix
  interpreter, whose loader cannot see the system `libstdc++`/`libz` that
  manylinux wheels link. numpy, opencv and torch install fine and then fail to
  import, blaming neither library.
- **Any active Nix shell breaks `apple`'s real Xcode builds** - not just
  `.#apple`; nixpkgs' Darwin stdenv exports `DEVELOPER_DIR`/`SDKROOT` pointing
  at a bare Nix `apple-sdk` stub, and `CC=clang`/`CXX=clang++` resolve through
  the polluted `PATH` to Nix's own `clang` and an ancient `xcbuild`-package
  `xcrun` - none of which is `/Applications/Xcode.app`. None of the resulting
  errors name Nix: a linker rejecting `-objc_abi_version`, `xcrun`/`simctl`
  reporting `unable to find sdk: 'macosx'` (the *versioned* SDK still resolves,
  only the bare alias breaks), and `clang` rejecting `-index-store-path` as
  `unknown argument` all look like Xcode or project bugs. `xcode-select -p`
  itself is unaffected - only the env vars and `PATH` lookup are. Fix per
  invocation, don't touch the persistent selection:
  `env -u DEVELOPER_DIR -u SDKROOT -u CC -u CXX -u LD -u AR -u NM -u RANLIB
  -u STRIP -u NIX_CC PATH="/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild …`
  (same for bare `xcrun`/`simctl` calls). Verified 2026-08-20 against Xcode
  26.6 - a full `build-for-testing` + test run only succeeded once every one
  of these was stripped.
- **The Nix JDK SIGSEGVs linking Kotlin/Native test binaries** - `./gradlew
  build` or `allTests` in any KMP repo here kills the daemon during
  `linkDebugTest*`, blaming nothing. Not memory: `21.0.12+8-nixos` crashes where
  Temurin 21 passes on the same host. Pass
  `-Dorg.gradle.java.home=$HOME/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`.
  `AGENTS.md` → Gradle and JDKs.
- **`:desktopApp:hotRun` dies headless because of the *daemon*, not your
  terminal** - the app is forked by the Gradle daemon and inherits its
  environment, and Gradle reuses any compatible daemon regardless of env. One
  daemon started from an agent tool call or `ssh` makes every later run fail
  with `HeadlessException` from a desktop terminal too. Use `--no-daemon` with
  `DISPLAY`/`XAUTHORITY` exported (AWT reaches Wayland via XWayland).
  `AGENTS.md` → Gradle and JDKs.
- **The bench is shared, and so is `firmware/.pio`** - every session's MCP
  tools export `MESHTASTIC_FIRMWARE_ROOT` pointing at the one primary
  `firmware/` checkout, whatever worktree you are standing in. Another
  session's build cleans your artifacts, and a leaked `pio run -t upload` with
  an invalid port auto-detects onto whichever board it finds. `/dev/ttyACM*`
  numbers are assignment order, not identity - resolve by USB serial through
  `/dev/serial/by-id/`. [`notes/bench-fleet.md`](./notes/bench-fleet.md).
- **Six JDKs required**, satisfying three separate Gradle mechanisms. Removing
  any one breaks a specific repo.
- **Toolchain config belongs in `gradle.properties`, never `GRADLE_OPTS`** -
  the daemon never sees the launcher's environment.
- **Develocity is per-repo, not org-wide** - every Gradle repo carries its own
  `gradle/develocity.settings.gradle` (android's lives in
  `build-logic/settings-plugin`) and its own `DEVELOCITY_ACCESS_KEY` secret,
  whose value **must** start `community.develocity.cloud=` or the key is
  silently ignored. A repo missing the secret still builds - it just publishes
  no scan and never writes the cache. Access keys are scoped to the *server*,
  so the one in `$GRADLE_USER_HOME/develocity/keys.properties` (workspace-local
  here) already covers every repo; `projectId` is metadata the build declares,
  not a permission. Cache **writes** are gated on `GITHUB_EVENT_NAME` being
  `push` or `merge_group`: same-repository PRs *do* receive secrets, so an
  access-key check alone would let unmerged code poison the shared cache. The
  old `GRADLE_CACHE_URL` / `_USERNAME` / `_PASSWORD` secrets are unused but
  deliberately retained as the rollback path - don't confuse them with
  `GRADLE_CACHE_READ_ONLY`, which is still live and governs the Actions-side
  Gradle home cache, not this one. `protobufs` is the last repo not yet
  onboarded (PR #1027).
- **`meshtastic/.github` provides no community-health defaults** - it holds
  only `LICENSE`, `README.md` and `profile/`, so a repo with no
  `SECURITY.md`/`CODE_OF_CONDUCT.md`/`CONTRIBUTING.md` inherits nothing and
  simply has none. `AGENTS.md` → Org conventions.
- **Default branches are not all `main`** - see the table.
- **`.gitignore` here denies by default** - a new file is untracked until
  whitelisted.
- **An ESP32 build rewrites a *shared* framework sdkconfig** - `custom_sdkconfig`
  in a variant `.ini` is applied by editing
  `~/.platformio/packages/framework-arduinoespressif32-libs/<mcu>/sdkconfig`
  in place, not a per-env copy. So reading that file tells you what the **last
  env built** asked for, not what your env asks for, and two envs for the same
  MCU silently fight over it. Reading it mid-session produced flatly
  contradictory answers about whether `CONFIG_BT_NIMBLE_EXT_ADV` was set.
  Trust the built ELF (`readelf`/`strings`), not the sdkconfig file.
  Worse: the rebuilt **libs** stay installed, so a later build of *another* env
  whose sdkconfig hash pioarduino considers current links against them silently
  (develop got the spike's `EXT_ADV=y` NimBLE, every legacy advertising call
  failed `rc=8`, the bench test was void). Renaming the package dir inside
  `~/.platformio/packages/` hides nothing - PlatformIO resolves packages by the
  manifest `name` inside - so `mv` it out of `packages/`, `pio pkg install -e
  <env>`, then build. "SUCCESS" with an unchanged Flash size and an old ELF mtime
  is the tell that nothing was rebuilt.
- **`MYNEWT_VAL(...)` does not reflect `custom_sdkconfig`** - NimBLE feature
  macros resolve from the *prebuilt* `esp_nimble_cfg.h` in the framework's
  include tree, so `#if MYNEWT_VAL(BLE_EXT_ADV)` reads 0 even in a build whose
  rebuilt NimBLE library has extended advertising. Gate firmware code on a flag
  the repo sets in `build_flags`; a `MYNEWT_VAL` guard compiles your feature out
  and leaves no trace in the log.
- **`firmware`'s native test suite needs Docker on macOS** -
  `bin/run-tests.sh` is Linux-only and `bin/test-native-docker.sh` is the macOS
  path. Running `pio test` directly cannot substitute: `-e coverage` passes the
  GCC-only `-fprofile-abs-path`, and `-e native`'s LovyanGFX fonts do not
  compile under Apple clang. Run it from a git worktree and it prints two
  `fatal: not a git repository` lines - cosmetic, version stamping only.
- **`pio device monitor` cannot run with stdout redirected** - pyserial's
  miniterm calls `termios.tcgetattr` on stdin and dies on a non-tty, so it
  produces nothing from a script or agent tool call. The `meshtastic-mcp`
  serial tools hand the child a pty and work; for a one-off, read the port with
  pyserial directly (`~/.platformio/penv/bin/python`).
- **`nix flake check` only evaluates shells** - passing eval does not mean a
  repo builds.
- **Memory is per-slug and the slug is your absolute cwd** - so `android/`,
  every worktree, and the other machine each start with an empty
  `~/.claude/projects/<slug>/memory` and never see what the root session
  learned. `.#sync` links every slug it owns into one private store
  (`~/.nixtastic-agent`, repo `jamesarich/nixtastic-agent`) - including the
  Desktop app's worktrees of this repo - `.#worktree` links at creation, a
  brand-new worktree is linked by the memory hook at its first session, and
  the plugin's hooks pull at `SessionStart` and push at `Stop`. `doctor`
  reports an unlinked slug, an unpushed store, and memories not touched in 90 days. A memory true on one machine only (the bench,
  `/dev/serial`, Xcode) gets `machine: james-pc` or `machine: darwin` under
  its `metadata:`; `sync` renders that into the index line, where selection
  happens. Design: [`notes/agent-memory-sync.md`](./notes/agent-memory-sync.md).
