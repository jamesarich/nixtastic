# What the sibling Kotlin repos lack that `meshtastic-node-kmp` has

Read 2026-09-17 against the live checkouts of `meshtastic-node-kmp` (reference),
`meshtastic-sdk`, `MQTTastic-Client-KMP`, `kzstd`, `TAKPacket-SDK` and
`gradle-flatpak-sources`. A catalogue for James to decide from - **nothing here
is implemented**, and the ranking is the point.

Three things to hold before reading:

- **`node-kmp` is not uniformly ahead.** It is the newest build, so it carries a
  few practices the others predate, but it has no CI at all, and on several
  axes a sibling is the better model. Those are in *Where node-kmp is not the
  model*, and they are not filler.
- **A missing item is not always a gap.** `kzstd`, `TAKPacket-SDK`'s Kotlin
  build and `gradle-flatpak-sources` are single-module, and
  `gradle-flatpak-sources` is a Gradle plugin, not a KMP library. Convention
  plugins, per-module baselines and klib ABI dumps have nothing to be missing
  *from* there. Marked N/A rather than absent.
- **Three items are contradictions, not gaps** - two repos assert opposite
  things about the same tool. Those go in *Measure before adopting*, because
  adopting either side without measuring picks a coin flip.

Related: the `meshtastic-kmp-alignment` memory (agent memory store, not in this
repo) holds the July 2026 alignment history and the decisions already taken -
`jvmToolchain` values (`MQTTastic-Client-KMP` stays at 11, deliberately), the
Codecov regression gate chosen over a local `koverVerify` floor, `CODEOWNERS =
@jamesarich`. None of those is relitigated here.

---

## Adopt: cheap, low-risk, clear win

### 1. `-Xjdk-release`, the JDK **API** ceiling - missing in all five

`node-kmp`'s `meshtastic.kotlin-conventions.gradle.kts` sets three things, not
one:

```kotlin
jvmToolchain(21)
// on each JVM target:
compilerOptions { freeCompilerArgs.add("-Xjdk-release=21") }
tasks.withType<JavaCompile>().configureEach { options.release.set(21) }
```

Every one of the five sets **only** `jvmToolchain(...)`. That pins the bytecode
version and nothing else: built on a JDK 22 or newer toolchain, a call to a
JDK 22+ method compiles cleanly, emits class-file 21, publishes, and fails at
runtime on a consumer's real JDK 21 with `NoSuchMethodError`. Nothing in any
repo's CI would catch it, because CI builds on the same newer JDK.

This is the best value-per-line item in the catalogue.

- **Cost:** three lines per repo - one line in a convention plugin for
  `meshtastic-sdk` and `MQTTastic-Client-KMP`, three in the root script for
  `kzstd`, `TAKPacket-SDK` and `gradle-flatpak-sources`.
- **Risk:** it can only fail a build that was *already* reaching a newer API,
  which is the bug. Note `MQTTastic-Client-KMP` is at toolchain 11 by decision,
  so its number is 11, not 21 - and the exposure there is correspondingly
  larger, since JDK 12-25 APIs are all reachable and all wrong.
- **Verdict: do it everywhere.**

### 2. `gradle/gradle-daemon-jvm.properties` - missing in three

`node-kmp` carries one (`toolchainVersion=21` plus per-OS foojay URLs, written
by `./gradlew updateDaemonJvm`) and applies
`org.gradle.toolchains.foojay-resolver-convention` in `settings.gradle.kts`, so
a contributor without the right JDK gets one downloaded rather than a failure.

- `meshtastic-sdk` has it, stricter (`toolchainVendor=JETBRAINS`).
- `MQTTastic-Client-KMP` has it (21).
- **`kzstd`, `TAKPacket-SDK`, `gradle-flatpak-sources` have none.**
  `TAKPacket-SDK` has no foojay resolver either.
- **Cost:** `./gradlew updateDaemonJvm` writes the file; commit it.
- **Verdict: do it.** It converts the most common first-contact failure into a
  download.

### 3. `.gitattributes` - missing in two

`node-kmp`'s is thorough: `* text=auto eol=lf`, `gradlew.bat text eol=crlf`,
binary markers, `**/build/** linguist-generated`, `diff=kotlin`. Present in
`meshtastic-sdk`, `MQTTastic-Client-KMP`, `kzstd`; **absent in
`TAKPacket-SDK` and `gradle-flatpak-sources`**.

This is not cosmetic here. `AGENTS.md` → *Git across repos* records the bug it
prevents: a blob committed with CRLF under an LF rule re-reads as modified in
every fresh clone and every new worktree, with nothing to stage away, and
`.#worktree --remove` then refuses. It was found on `kzstd`'s `gradlew.bat`
(fixed in `87fe98c`, PR #33).

- **Cost:** one file, copied.
- **Verdict: do it.**

### 4. A metaspace ceiling in `org.gradle.jvmargs` - missing in three

`node-kmp` sets `-Xmx4g -XX:MaxMetaspaceSize=1g -XX:+HeapDumpOnOutOfMemoryError`
and its comment names the failure precisely: the daemon does not report an OOM,
it prints *"will expire after the build after running out of JVM Metaspace"*,
takes a test executor with it, and Gradle reports the task **FAILED with zero
test failures recorded** - which reads as a broken test and moves between
modules run to run.

- `meshtastic-sdk` matches it exactly.
- `MQTTastic-Client-KMP` has the heavy profile only in `.github/ci-gradle.properties`,
  copied over the dev file by its `gradle-setup` action - so **local** runs get
  `-Xmx2048M` with no metaspace ceiling.
- **`kzstd` and `TAKPacket-SDK`: `-Xmx2048M`, no ceiling.**
- **Cost:** one line. Sizing is a judgement call per repo; the *ceiling* is the
  point, not the number.
- **Verdict: do it**, at least for `TAKPacket-SDK`, which has the widest target
  matrix of the three.

### 5. Configuration cache - `TAKPacket-SDK` is the only repo without it

`node-kmp`, `meshtastic-sdk`, `MQTTastic-Client-KMP`, `kzstd` and
`gradle-flatpak-sources` all set `org.gradle.configuration-cache=true` plus
`.parallel=true`. `gradle-flatpak-sources` goes further and exercises it in its
own functional tests (`GradleRunner` with `--configuration-cache`, including a
test named *"reused configuration cache entry reads the live captured set, not a
serialized copy"*).

**`TAKPacket-SDK` sets neither property.** Its build is probably close: both of
its custom codegen task classes (`GenerateEmbeddedDictionaries`,
`GenerateInlinedFixtures`) already declare `@InputFiles`/`@OutputDirectory`
properly.

- **Cost:** flip two properties, fix whatever the first run reports. Unknown
  until tried; the `YarnRootExtension` block is the likeliest objector.
- **Verdict: worth a spike.** It is a wall-clock win on a 13-target build.

### 6. Spotless `licenseHeader()` - missing in two, plus one non-Spotless repo

`node-kmp` stamps every `.kt` from `config/spotless/license-header.txt` via
`licenseHeader()`, so a new file is stamped by `spotlessApply` rather than by
someone remembering.

- `meshtastic-sdk` has it (`config/spotless/license-header.txt`).
- `MQTTastic-Client-KMP` has it and is **ahead**: separate
  `config/spotless/copyright.kt` and `copyright.kts` via `licenseHeaderFile`,
  with a delimiter regex for the `.kts` case.
- **`kzstd` and `TAKPacket-SDK`: no header step at all.** SPDX headers exist but
  are hand-written and unenforced.
- `gradle-flatpak-sources` has no Spotless at all (detekt-formatting instead)
  and hand-written headers - adding one is a bigger call, see item 14.
- **Cost:** one file plus one line. Run `spotlessApply` first.
- **Verdict: do it for `kzstd` and `TAKPacket-SDK`.**

### 7. `keepLocallyUnsupportedTargets` - one line, `meshtastic-sdk` only

`node-kmp`'s `meshtastic.library-conventions.gradle.kts`:

```kotlin
kotlin.abiValidation { keepLocallyUnsupportedTargets.set(true) }
```

It keeps the committed declarations for a target the host cannot build, so a
dump taken on Linux does not silently empty the macOS-only entries, and a Linux
gate can check a macOS-only klib instead of excluding it.

`meshtastic-sdk` is already on KGP's built-in `abiValidation` (in
`PublishingConventionPlugin.kt`) but **does not set this flag** - it configures
only `filters.exclude.byNames`. So it has the right plugin without the setting
that is the main reason to be on it.

- **Cost:** one line.
- **Verdict: do it.**

---

## Measure before adopting: three live contradictions

These are not "sibling lacks X". Two repos assert opposite things about the same
tool, and the cheap experiment is worth more than either claim.

### 8. Does Spotless's ktlint step read `.editorconfig`?

`node-kmp` says **no**, in code, and passes an explicit `editorConfigOverride`
map for every setting that must bind:

> *"Spotless's ktlint step does not read the repo `.editorconfig`, so every
> setting that must bind is named here."*

`kzstd`'s `CONTRIBUTING.md` says **yes**:

> *"ktlint reads `.editorconfig`, so that file remains the single source of
> Kotlin style."*

Who is affected if `node-kmp` is right:

| Repo | `.editorconfig` | `editorConfigOverride` | Exposure |
|---|---|---|---|
| `node-kmp` | yes | yes (6 keys) | none |
| `meshtastic-sdk` | yes | yes (1 key) | the other keys, if any bind |
| `MQTTastic-Client-KMP` | **none, deliberately** | no | none - nothing to ignore |
| `kzstd` | yes | no | its `ktlint_standard_*` rules may be inert |
| `TAKPacket-SDK` | **two** (root + `kotlin/`) | no | same, doubled - and the `kotlin/` one carries no `ktlint_*` keys at all, so the root one is the only candidate |
| `gradle-flatpak-sources` | yes | N/A (no Spotless) | none - detekt-formatting does read it |

If `node-kmp` is right, `kzstd` and `TAKPacket-SDK` are running ktlint on bare
defaults and their `.editorconfig` Kotlin rules are decorative. If `kzstd` is
right, `node-kmp`'s map is redundant belt-and-braces and the docs in both repos
should stop disagreeing.

The answer is likely **version-dependent** - Spotless's ktlint step gained
`.editorconfig` discovery at some point - which makes the measurement more
valuable, not less, because both repos are pinning different Spotless versions
(8.10.0 in `meshtastic-sdk` and `TAKPacket-SDK`, 8.10.2 elsewhere).

- **Experiment:** add a deliberately-violating rule to a repo's `.editorconfig`
  (say `ktlint_standard_no-wildcard-imports = disabled`), add a wildcard import,
  run `spotlessCheck`. Ten minutes, settles it for the org.
- **`MQTTastic-Client-KMP` is the cautionary tale either way:** its `.editorconfig`
  was dropped in PR #93 precisely because copying `meshtastic-sdk`'s broke
  previously-clean code. Something reads it.

### 9. Is `meshtastic-sdk`'s detekt actually analysing anything?

The KMP trap is recorded: with no `src/main`/`src/test` layout, the bare
`detekt` task is **NO-SOURCE**, and applying plus configuring detekt is not
proof that it runs. `MQTTastic-Client-KMP` shipped in exactly that state until
PR #110 - no static analysis had been running at all, and an earlier audit
marked it compliant.

How each repo answers it:

- `node-kmp`, `kzstd`, `TAKPacket-SDK`, `gradle-flatpak-sources`:
  `source.setFrom(files("src"))`.
- `MQTTastic-Client-KMP`: a **`detektAll` aggregator** over the per-source-set
  tasks, wired into `check`, excluding the bare `detekt`. Arguably the better
  answer - each source set is analysed with its own classpath.
- **`meshtastic-sdk`: neither.** It is on `dev.detekt` 2.0.0-alpha.6, the
  JetBrains-continued fork, which claims native KMP source-set support - so the
  trap may genuinely not apply. **That is an inference from the plugin's
  lineage, not a measurement.**
- **Check:** run `./gradlew detekt` in `meshtastic-sdk` and look for `NO-SOURCE`
  on the task line, or count findings against a deliberately-introduced
  violation. If it is NO-SOURCE, `meshtastic-sdk` has been green on nothing.

### 10. `gradle-flatpak-sources` declares `configurationCache = false` to the Plugin Portal

`plugin/build.gradle.kts` still carries, for both published plugins:

```kotlin
compatibility { features { configurationCache = false } }
```

It was true when added (commit `34b3b89`, 2026-05-27). 0.1.7 and 0.2.0 fixed the
incompatibility - the `CHANGELOG` documents replacing cross-project
`settings.gradle.extensions` reads with a shared `BuildService` - and the README
now says *"Neither flag concerns the configuration cache, which is supported
from 0.2.1 on."* The Portal-facing metadata was never flipped.

So the repo's own docs and the metadata a consumer reads on the Plugin Portal
disagree. Cheap to fix; the only question is whether the fix is *true*, which is
what the functional tests already assert.

---

## Adopt with real cost: James's call

### 11. kotlinx BCV → KGP's built-in ABI validation

`node-kmp` and `meshtastic-sdk` use KGP's built-in `abiValidation`
(`checkKotlinAbi` / `updateKotlinAbi`). **`MQTTastic-Client-KMP` (0.18.2),
`kzstd` (0.18.2) and `TAKPacket-SDK` (0.18.1) are still on kotlinx
binary-compatibility-validator**, which upstream declared maintenance mode.

The concrete reason to move is item 7: BCV's answer to a target the host cannot
build is *skip and trust the committed dump*, which cannot distinguish "target
absent on this runner" from "target removed from the library".
`keepLocallyUnsupportedTargets` can.

- **Cost per repo:** swap the plugin, regenerate dumps, and absorb a layout
  change - the JVM dump moves from `api/<m>.api` to `api/jvm/<m>.api`. The
  regeneration wants a macOS host with a warm `~/.konan`, and every open PR
  touching the surface will conflict.
- **`TAKPacket-SDK` carries an extra wrinkle:** `ignoredPackages.add("org.meshtastic.proto")`,
  because it re-exports the generated Wire types. The built-in validator's
  equivalent is a `filters.exclude` entry, and getting it wrong dumps the whole
  protobufs surface.
- **Verdict: yes, medium priority, one repo at a time.** It was already the
  recorded direction; this is a reminder of why, not a new proposal.

### 12. Isolated Projects

`node-kmp` sets `org.gradle.unsafe.isolated-projects=true` and is *shaped* for
it: coordinates set by a `meshtastic.coordinates` convention plugin rather than
`allprojects`, Spotless applied per project rather than at the root, and
`isolated.rootProject` instead of the plain accessor.

- **`MQTTastic-Client-KMP` is already IP-ready on its own side** - no
  `allprojects`/`subprojects` anywhere, version assigned via
  `gradle.lifecycle.beforeProject`, Spotless per module - and its
  `gradle.properties` says so, naming the blocker as KGP's
  `WasmNpmResolverPlugin` reaching from `:sample` into the root. **One-line flip
  when upstream fixes it.** Worth watching for; not worth doing anything now.
- **`meshtastic-sdk` is genuinely blocked by its own shape:** `allprojects { group;
  version }` plus two `subprojects {}` blocks (detekt, Kover). Unblocking it
  means a coordinates convention plugin, moving Spotless per project, and
  replacing both `subprojects` blocks. That is `node-kmp`'s structure, arrived
  at deliberately - but it is a real refactor for configuration-time
  parallelism on six modules.
- `kzstd`, `TAKPacket-SDK`, `gradle-flatpak-sources`: **N/A**, single-module.
  All three say so in a comment, which is the right answer.
- **Verdict: skip for now.** Revisit `MQTTastic-Client-KMP` when KGP lands the
  fix; leave `meshtastic-sdk` unless configuration time becomes a complaint.

### 13. An **arming flag** on hardware-gated tests

`node-kmp`'s `LiveTestGate` (in `node-transport-ble` and
`node-transport-ble-gatt`, `macosArm64Test`) does not merely skip when the
hardware is absent - `MESH_LIVE_REQUIRED=1` turns the skip into a **failure**.
Kotlin/Native has no assumption API, so unarmed it passes and prints the reason;
armed, a bench run that tested nothing cannot report success.

- `MQTTastic-Client-KMP` gates three JVM integration tests on
  `MQTT_INTEGRATION_TESTS` - **skip-only**.
- `meshtastic-sdk` gates `:transport-ble:connectedAndroidTest` on Android
  `Assume` - **skip-only**.
- `kzstd`, `TAKPacket-SDK`, `gradle-flatpak-sources`: nothing to gate.
- **Cost:** about ten lines per repo.
- **Verdict: yes, small.** The value is entirely in the arming: a skip-only gate
  makes "the broker was unreachable" and "the suite passed" indistinguishable in
  a green run.

### 14. Spotless in `gradle-flatpak-sources`

It is the only repo with no Spotless - formatting rides on `detekt-formatting`
(ktlint rules through detekt), which *does* read `.editorconfig`. That is a
coherent choice, not an oversight, and it sidesteps item 8 entirely. The cost of
switching is a full reformat plus a new baseline.

- **Verdict: skip** unless the org standardises on Spotless for its own sake.
  Its `.editorconfig` does carry one piece of dead copy-paste worth deleting:
  `ktlint_function_naming_ignore_when_annotated_with = Composable`, in a Gradle
  plugin with no `@Composable` anywhere.

---

## Adopt only where it applies

### 15. Reflection-over-proto surface tests

`node-kmp`'s strongest testing idea, and it has no analogue anywhere else.
`ConfigFieldParityTest` reflects over Wire's `@WireField` on every reported
section and holds two properties at once: *completeness* - a field the proto
grows that the `FIELDS` map does not name **fails, naming the field** - and
*truthfulness* - it builds two nodes that differ in seven ways and asserts every
field marked `NODE` reads differently between them and every `CONSTANT`/`ECHOED`
field reads the same, so a hardcoded value cannot hide behind a `NODE` label.
`AdminVerbSurfaceTest` does the same for admin verbs and additionally drives
every `DECLINED` verb for real, proving it inert.

The transferable shape is: **a schema that grows fails a test that names the
addition**, rather than waiting for the seventh instance of the bug.

- `TAKPacket-SDK` is the nearest relative and solves a different half: 47 golden
  fixtures cross-decoded by five bindings catch a **wire** change but not
  surface *growth* - a new `TAKPacketV2` field no binding maps is invisible to
  them.
- `meshtastic-sdk` is where this would actually pay, if and where it mirrors
  config sections.
- **Cost:** real, per repo, and only meaningful against a proto surface being
  mirrored.
- **Verdict: `meshtastic-sdk` only, low priority, high value if it applies.**

---

## Where `node-kmp` is **not** the model

Not filler. Each of these is a place to copy *from* a sibling.

- **Wrapper `distributionSha256Sum`: `node-kmp` is the only repo that lacks it.**
  All five siblings pin it. Adopt in the other direction.
- **Develocity: `node-kmp` has none** (no CI by design). All five siblings wire
  the OSS Community instance with the same careful push gate - remote-cache
  writes only on `push`/`merge_group` with a key present, explicitly excluding
  `pull_request`, because a same-repository PR *does* receive secrets.
- **`node-kmp` has no workflows at all** - no CI, release, docs, CodeQL or
  Scorecard. Every release-hardening idea in the org lives in a sibling: Maven
  Central idempotency probes, build-provenance attestation, dual-format SBOMs
  (`MQTTastic-Client-KMP`), a five-language docs site (`TAKPacket-SDK`), a
  "require green CI on the released commit" Checks-API poll (`meshtastic-sdk`,
  `kzstd`).
- **detekt aggregation:** `MQTTastic-Client-KMP`'s `detektAll` is a better
  answer than `node-kmp`'s `source.setFrom(files("src"))`, which analyses the
  whole tree with one classpath.
- **Custom Gradle tasks: the siblings have more, not fewer.** `node-kmp` has two
  (`stageMacBleBridge`, a `Copy`; `nodeJar`). `meshtastic-sdk` and
  `MQTTastic-Client-KMP` each have a `verifyModuleBoundary` guard that fails
  configuration if a module gains a forbidden project dependency;
  `TAKPacket-SDK` has two real codegen task classes; `gradle-flatpak-sources`
  has a `functionalTest` source set wired into `check`.
- **There is no `kmpSmokeCompile`-style task in `node-kmp`.** That task is an
  `android` thing. No repo in this set has an all-targets-compile-without-tests
  aggregator, and if one is wanted it has to be written, not copied.
- **Reproducible archives:** `kzstd` and `TAKPacket-SDK` set
  `isReproducibleFileOrder` / `isPreserveFileTimestamps = false` so published
  artifacts are byte-deterministic. `node-kmp` does not.
- **Konsist:** `MQTTastic-Client-KMP` runs an architecture test suite enforcing
  a public-API allowlist as a second layer beyond BCV and `explicitApi()`.

### One correction to the record

The memory note says `node-kmp` does ABI validation *"inline in the root
`subprojects` block"*, with `meshtastic-sdk` ahead for having it in a convention
plugin. **That is stale.** As of this reading it is in
`build-logic/src/main/kotlin/meshtastic.library-conventions.gradle.kts`,
alongside `explicitApi()`. The two repos are now the same shape here, and
`node-kmp` has the flag `meshtastic-sdk` is missing (item 7).

---

## Changelog strategy

Covered separately - `node-kmp` is the only repo of the six with the JetBrains
`org.jetbrains.changelog` plugin wired, and adopting it is in flight (see the
`changelog-plugin` branches). Two findings from that work belong here because
they are properties of the tool, not of one repo:

- **`getChangelog` does not fail when the declared version has no section.** It
  silently returns the most recent released one. A release workflow that feeds
  it into the release body will therefore publish the *previous* release's notes
  for a version whose entry was forgotten, with everything green. Any adoption
  needs an explicit `grep -qE "^## \[$VERSION\]"` gate; the plugin will not
  provide one.
- **`patchChangelog` reflows the introduction.** A hard-wrapped paragraph comes
  back with a blank line inserted mid-sentence. Keep both the file's intro and
  the plugin's `introduction` value as single unwrapped lines per paragraph, and
  identical to each other.

And one state finding: three of the five changelogs had already stopped being
maintained - `TAKPacket-SDK` shipped 0.9.0 and 0.9.1 with no entry (its file was
under `kotlin/`, last touched at 0.8.1), and `gradle-flatpak-sources` has
`v0.2.1` tagged with `[0.2.0]` still the newest section. **A hand-maintained
changelog with no build hook rots the first time a release path bypasses the
person maintaining it** - in `TAKPacket-SDK`'s case, its own `bump-version.yml`,
which fans the version to five files and never touched the changelog.

---

## Summary table

`·` = N/A for that repo's shape.

| Item | sdk | mqtt | kzstd | tak | flatpak |
|---|---|---|---|---|---|
| 1. `-Xjdk-release` | — | — | — | — | — |
| 2. `gradle-daemon-jvm.properties` | ✓ | ✓ | — | — | — |
| 3. `.gitattributes` | ✓ | ✓ | ✓ | — | — |
| 4. metaspace ceiling | ✓ | CI only | — | — | ✓ |
| 5. configuration cache | ✓ | ✓ | ✓ | — | ✓ |
| 6. Spotless `licenseHeader()` | ✓ | ✓ (ahead) | — | — | · |
| 7. `keepLocallyUnsupportedTargets` | — | · | · | · | · |
| 8. `editorConfigOverride` | partial | · | — | — | · |
| 11. KGP built-in ABI validation | ✓ | — | — | — | · |
| 12. Isolated Projects | — | blocked | · | · | · |
| 13. test arming flag | — | — | · | · | · |
| 15. proto surface tests | — | · | · | partial | · |
| wrapper SHA (node-kmp lacks) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Develocity (node-kmp lacks) | ✓ | ✓ | ✓ | ✓ | ✓ |

---

## If only three things get done

1. **`-Xjdk-release` in all five.** Three lines each, catches a class of
   runtime failure CI structurally cannot see.
2. **Measure item 8** - whether Spotless's ktlint reads `.editorconfig`. Ten
   minutes, and it decides whether two repos' formatting rules are real.
3. **Run `./gradlew detekt` in `meshtastic-sdk` and look for `NO-SOURCE`**
   (item 9). The same check was overstated for `MQTTastic-Client-KMP` for
   months.
