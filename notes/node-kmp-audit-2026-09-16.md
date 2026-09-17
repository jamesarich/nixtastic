# node-kmp audit - state, parity gaps, smells, doc standards

Audited 2026-09-16 against `main` at `314bc20`, clean, 0 drift vs `origin/main`.
Claims below are checked against code or a run, not quoted from the repo's own
docs - the docs are the subject of section 4.

## 1. Where the work stands

~42,000 lines of Kotlin across 11 library modules, two apps and a headless
runner.

`gradle jvmTest` returns BUILD SUCCESSFUL, but the run was **up-to-date, not
executed** (13 tasks executed, 66 up-to-date) - the results on disk are from a
prior run the same day. As they stand:

| Target | Tests | Skipped | Failures |
| --- | --- | --- | --- |
| `jvmTest` | 817 | 0 | 0 |
| `testAndroidHostTest` | 665 | 0 | 0 |
| `macosArm64Test` | 557 | 0 | 0 |
| `iosSimulatorArm64Test` | 548 | 0 | 0 |

The four zeroes in the skipped column are the finding, not the reassurance - see
§3.2.

| Module | Files | Lines | Role |
| --- | --- | --- | --- |
| `node-core` | 65 | 12,101 | packet codec, crypto, dedup, relay, nodeDb |
| `node-transport-lora` | 54 | 7,513 | SX1262 over CH341A / spidev |
| `node-transport-ble-gatt` | 32 | 6,123 | dual-role GATT mesh |
| `node-phone-api` | 25 | 4,931 | client-facing handshake, config dump, admin |
| `monitor` | 16 | 3,609 | bench dashboard (CMP) |
| `node-transport-ble` | 25 | 2,424 | connectionless extended advertisements |
| `node-transport-udp` | 12 | 1,534 | multicast bearer |
| `node-transport-mqtt` | 11 | 1,350 | broker bridge |
| `node-transport-wifi-aware` | 6 | 951 | Android Aware |
| `node-desktop-ble-macos` | 7 | 901 | macOS native BLE bridge |
| `node-headless` | 3 | 509 | bench runner |
| `node-bluez` | 4 | 371 | shared BlueZ D-Bus session |

Ten of those carry a committed ABI (`api/*.klib.api`, plus `api/android/`).
`node-headless`, `monitor` and `monitor-android` are apps and carry none, which
is correct.

**What is architecturally strongest.** The parity classification harness in
`node-phone-api/src/jvmTest` is the best thing in the repo and is unusual in this
org: every reported proto field is labelled `NODE` / `ECHOED` / `ENFORCED` /
`CONSTANT` with a written reason, completeness is reflected off Wire's
`@WireField` so a pin bump fails on an unclassified field by name, and
truthfulness is checked by building two deliberately different nodes and
asserting every `NODE` field actually differs. That catches the repo's one
recurring defect class (a reported field not derived from live state) at the only
layer that can see it, because `config.proto` has no `optional` fields and so
wire-level diffing is structurally blind to it.

Two count claims in `AGENTS.md` check out exactly: **10 reported config
sections** (`ConfigFieldParityTest.sections()`, including the empty `sessionkey`)
and **17 `ModuleConfig` sections**, all `ECHOED`.

**What is blocked.** `maven-publish` is applied in
`build-logic/src/main/kotlin/meshtastic.library-conventions.gradle.kts` with full
POM metadata, but **no repository is declared, on purpose** - the comment there
says `~/.m2` makes the coordinates resolvable to an adapter in another repo, and
adding a remote is the decision to ship. So the library is consumable locally via
`publishToMavenLocal` and by nobody else.

The gate on shipping is PR #1 (`chore/wire-builders-only`, the Wire `buildersOnly`
migration that makes an artifact safe across protobufs pins): a draft **87 commits
behind `main`**, now `mergeStateStatus DIRTY` with conflicts, so no workflows run
on it at all and its green tick means nothing was looked at.

## 2. Parity gaps

### Tier 1 - the wire

- **AEAD channels are unimplemented and node-kmp cannot detect one.** Firmware
  `d05fbec64` (#9749, merged 2026-09-14) adds `use_aead` to `ChannelSettings` and
  differentiates the channel hash with `h ^= 0xAE`. `MeshChannel.hash`
  (`node-core/.../MeshChannel.kt:41`) is the pre-AEAD XOR with no `0xAE` term, so
  against an AEAD channel every packet is unmatched *before* decryption is
  attempted - it reads as an unknown channel, not as a crypto failure. Worse than
  read-only: the proto comment says AES-CTR packets are *rejected* on such a
  channel, so a node-kmp node is mute and deaf at once.

  Blocked, not deferred: `use_aead` landed in protobufs on 2026-09-10 and no tag
  carries it; the pin is `2.8.0`. The primitive is already here - `PkiCrypto`
  runs AES-256-CCM through `MeshCrypto` - so this is hash + flag + wiring, not new
  crypto. Buildable today against `-PprotobufsVersion=2.8.0.55-g072c607-SNAPSHOT`.
  See [`upstream-drift-aead-and-opaque-relay.md`](./upstream-drift-aead-and-opaque-relay.md).

- **XEdDSA plaintext signing is absent.** `MeshNode.licensed` is consulted only by
  the legacy-DM reject; firmware's licensed mode also signs plaintext, which is
  not implemented. So the flag is not ham-mode interop, and the KDoc says so -
  honest, but it is a gap.

- **Closed since the last note:** opaque relay under `CORE_PORTNUMS_ONLY`.
  `opaqueRelayAllowedBy` (`MeshNode.kt:1529`) now returns true for
  `CORE_PORTNUMS_ONLY` and restores the PKI-shaped `KNOWN_ONLY`/`LOCAL_ONLY` rule,
  matching `ee7611783`. Commits `044ea19` and `2bd873b`.

- **One deliberate divergence, written down:** node-core dedups `id == 0` while
  firmware treats id 0 as non-floodable and never dedups it, so a LoRa peer
  emitting id-0 frames is dropped after the first.

### Tier 2 - the phone API

- **`security.packet_signature_policy` is `ECHOED` and nothing in the repo reads
  it.** A grep for `signaturePolicy` / `packet_signature_policy` outside the
  classification test returns nothing. A client that sets Strict on a node-kmp
  node gets the setting stored and reported back with no enforcement. Correctly
  classified, so it is not an instance of the recurring bug - but it is a real
  Tier-2 gap against a 2.8 behaviour, and it sits next to the first-wins key
  trust model.

- **All seventeen `ModuleConfig` sections are `ECHOED` in full.** Verified:
  `ModuleConfigFieldParityTest` bulk-assigns `Origin.ECHOED` at line 263 and its
  `NODE` set is asserted empty. This is the largest surface where a client can
  believe a setting took effect and be wrong. MQTT is the near miss - the bearer
  exists but is configured through `MqttBridgeConfig`, not `moduleConfig.mqtt`.

- **`position_broadcast_secs` is unrepresentable when the node broadcasts no
  position** - the wire has no "never", so it reports 0, which reads as "use the
  default". A schema limit, not a bug.

- **The `Origin` enum has four members; `AGENTS.md` names three.**
  `FieldParity.kt:38` added `ENFORCED` (stored, reported, *and obeyed* - used by
  `security.admin_key` and `security.is_managed`). The Parity section still tells
  a reader to classify a new field as "one of `NODE`, `ECHOED` or `CONSTANT`".
  Doc drift in the one paragraph a new contributor acts on.

### Tier 3

Correctly declined. 48 inbound admin verbs are enumerated and classified, the
declined ones are fed to `AdminService` for real and must produce no reply and
change no owner, and `MUST_BE_DRIVEN` pins the dangerous ones
(`factory_reset_device`, `nodedb_reset`, `enter_dfu_mode_request`, both reboots)
so coverage cannot quietly shrink. No gap.

### Coverage the platform matrix still lacks

- **Windows has no BLE backend in any source set.** WinRT gives a Win32 app the
  peripheral role, but it is a COM ABI with no Java projection, so it needs native
  code in a language not yet chosen.
- **iOS central connect is unreliable**, and iOS background is untouched.
- **UDP on iOS** needs `com.apple.developer.networking.multicast`, granted by
  application; the project does not hold it.
- **An Apple node cannot be tested against firmware's mesh-peer service at all** -
  the radio's BLE controller asserts ~200 ms after any Apple central connects.
  Firmware-side; nothing here changes it.

## 3. Issues and smells

Ranked by what would actually bite.

1. **There is no CI. `.github/workflows/` does not exist** - only `FUNDING.yml`,
   a PR template and issue templates. Every gate the repo relies on
   (`ConfigFieldParityTest`, `AdminVerbSurfaceTest`, `checkKotlinAbi`,
   `spotlessCheck`, `detekt`) runs only when a human remembers to run it locally.
   A repo whose entire safety argument is "a test fails when you add an
   unclassified field" has nothing that runs that test. This is the highest-value
   single change available, and it does not depend on the repo going public -
   Actions runs on private repos.

2. **All 17 test methods in the eight hardware-facing test classes pass without
   asserting anything when their env var is unset.** Each was opened and every
   `@Test` in all eight is gated on the first line; the gate is a bare `return`,
   which the runner records as PASSED, not SKIPPED. That is why every target's
   skipped column above reads 0.

   | File | Target | @Test | Gate |
   | --- | --- | --- | --- |
   | `BluezAdvertiseLiveTest` | jvm | 4 | `MESH_BLUEZ_ADVERTISE` |
   | `FirmwareInteropTest` | jvm | 3 | `MESH_INTEROP_CHANNEL_URL` |
   | `MqttBrokerInteropTest` | jvm | 2 | `MESH_MQTT_BROKER` |
   | `ChannelSetUrlDeviceTest` | jvm | 1 | `MESH_INTEROP_CHANNEL_URL` |
   | `GattLiveTest` | macosArm64 | 3 | `MESH_GATT_LIVE` / `MESH_GATT_SEND` |
   | `BleMeshLiveTest` | macosArm64 | 2 | `MESH_INTEROP_CHANNEL_URL` |
   | `GattFragmentDiagnosticTest` | macosArm64 | 1 | `MESH_GATT_DIAGNOSE` |
   | `HopLimitSurveyTest` | macosArm64 | 1 | `MESH_HOP_SURVEY` |

   Ten under `jvmTest`, seven under `macosArm64Test`. Several print "skipped" to
   stdout, which makes it look handled and is the reason it is most likely to be
   trusted. The Android device tests do this correctly with JUnit `assumeTrue`,
   which reports a real skip - the mechanism exists in the repo and is not used on
   the JVM or native side. Fix: `assumeTrue` on JVM, and on Kotlin/Native either an
   `@Ignore`-by-default marker or a `kotlin.test` assumption shim, so a green run
   states how many bearer proofs did not execute.

3. **Three raw `println` calls survive the MeshLog migration.** Commit `11d0612`
   moved logging onto the platform's own log; `BluezPairingAgent.kt:142,146` and
   `BluezBleMeshRadio.kt:160` still write to stdout. A library writing to a host's
   stdout is what that migration was for.

4. **Three worktrees are live, one of them the stale PR.**
   `chore/wire-builders-only` (PR #1, 87 behind), `demo/node-kmp-hw-model`,
   `feat/ble-bearer-flags`. `just brief` reported 5; the lister found 3.

**What is clean, and worth saying so.** Zero `TODO`/`FIXME`/`HACK`/`XXX` in the
whole tree. Five `!!` total. No `GlobalScope`. `runBlocking` only in `main()` and
in the macOS native bridge's synchronous C seam, both correct. Seventeen
`@Suppress` annotations, each narrow and named. Wire-enum mappings are exhaustive
`when` with no `else`, on purpose. This is a tidier codebase than any other Kotlin
repo in the workspace.

One thing that looks like a smell and is not: `MeshNode.Config.clock` defaults to
a frozen `{ 0L }`, which would degrade replay suppression to capacity-only. It is
deliberate and partly enforced - `validated()` holds
`require(reliableDelivery == null || clock !== FROZEN_CLOCK)`, comparing by
instance identity against a named `FROZEN_CLOCK` because a real monotonic clock
may legitimately return 0 twice and a behavioural probe could not tell them apart.
The residue is that the guard is tied to `reliableDelivery` only: a node with the
frozen clock and no reliable delivery still ages nothing out of `PacketHistory`,
which the KDoc states and calls "for pure-relay uses and tests". Worth knowing,
not worth changing.

## 4. Docs and comments against the standard

The standard applied here has two sources. Design standards §11 governs the
documentation site and the client docs written in `android` and `apple`, so it is
not binding on this repo's agent docs - it is applied because it is the org's
written statement of the rule asked for, and because §11.2 ("don't date the page
from inside it: *currently*, *now*, *as of this writing* describe the moment of
writing rather than the system - the page outlives that moment") and §11.5 ("give
each fact one home and link to it; content repeated across pages drifts") say it
precisely. The binding rule is the repo's own, set by commits `969dd64` "Comments
state facts, not how the code got here" and `ec09da9` "Cut the comments back to
the invariant".

### Code comments: the rule held

Scanning `main` only - the three worktrees still carry the pre-cleanup style and
will reintroduce it on merge, so check their diffs - the cleanup stuck. Genuine
residue, four places:

| File:line | What |
| --- | --- |
| `node-transport-ble-gatt/.../BluezGattApplication.kt:68` | "that was the hypothesis this was written for, and the bench refuted it" - pure history |
| `node-transport-ble-gatt/.../BluezGattLink.kt:343` | "Measured on the bench 2026-09-16" |
| `node-transport-ble-gatt/.../BluezGattData.kt:145` | "Measured on the bench 2026-09-16: `BREDR.Bonded: yes`..." |
| `node-headless/.../BearerNamesTest.kt:15` | "a name nothing answers to used to..." |

The two date stamps each state a real invariant and then date it; keep the
invariant, drop the date, point at the note holding the measurement.
`MeshNode.Config.licensed` and `.clock` are the model to copy - each states what
it does, what it does not do, and stops.

### `AGENTS.md` (64 KB, 1,019 lines): the story, not the contract

16 embedded date stamps, and narrative framing throughout. Four sections carry
it, ordered by cost:

- **"Before this can go public" (120 lines)** is a lab notebook. "The no-pair
  agent does not do what it was written to do. **Settled 2026-09-09**" spends a
  full screen relitigating a hypothesis before reaching the durable fact - the
  agent scopes service authorisation to the mesh UUID, `BluezRetryBackoff` is
  what keeps the connect storm down, do not cite it as the passkey fix. The
  two-host BlueZ capability table measures two specific adapters. Both belong in
  `notes/`; the invariant that stays is that `canTransmit` tests `MaxAdvLen`, not
  a version number.
- **"Build and test" (353 lines - a third of the file)** carries the ABI-gate
  history inline: "Verified clean on a Mac at `0c1aa70` (2026-09-09)", "it cost
  something real on 2026-09-05: four backticked test names containing commas",
  "four commits on 2026-09-05, none of which ran the ABI check", "the baseline
  the day it landed was 73.6% line". Each has a rule inside it (run `allTests`
  not `jvmTest`; Kotlin/Native rejects commas in backticked names; regenerate
  `api/` dumps with the change that moved them). Keep the rules, move the
  incidents.
- **"Safety" (102 lines)** opens a subsection with "**Reversed 2026-09-09.** This
  section used to say the opposite" and then states the current rule. The reversal
  is the changelog; the rule is the doc.
- **"Seams a host has to know about" (44 lines)** opens "Added or changed by the
  2026-09-06 review and 2026-09-07 bench fixes" - a changelog framing on a
  reference section whose bullets are otherwise exemplary (each names the seam,
  what it replaced, and the failure that made it necessary, with no dates).
  Delete the preamble; the section is otherwise the best-written in the file.

**"Design decisions" (129 lines) should largely stay.** It opens "Recorded so a
later reader (or reviewer) does not 'correct' them back", which is a legitimate
purpose - rationale for a deliberate non-obvious choice is not history. It is the
model for what the four above should look like after the cut.
"Where a setting comes from" (82 lines) is nearly clean: one "used to be written
back to a..." line.

Two factual errors to fix while there. "The native suites need no hardware; the
ones that want a radio are env-guarded... and **pass as skips**" - they pass, and
they are not skips (§3.2). The same claim appears in `.gitignore`: "the hardware
tests read `MESH_INTEROP_CHANNEL_URL` and skip without it". And the `Origin`
three-vs-four list in §2.

### `README.md` (31 KB, 375 lines): consumer doc carrying a bench log

- **"What is proven" (82 lines)** is a per-run bench matrix with dated evidence,
  RSSI figures, packet ids and the host that ran it. It is impressive and it is
  the wrong document - a README answers "what does this library do and can I use
  it", and this answers "what did James measure, and when".
  `notes/bearer-delivery-matrix.md` already exists and is the home; §11.5's "give
  each fact one home and link to it" is the rule. What should survive is a short
  capability table - bearer × platform × in/out × proven-on-hardware - with a
  link.
- The false "skipped unless `MESH_INTEROP_CHANNEL_URL`" claim leads that section.
- **"Not yet here" (76 lines)** mixes durable limits (Apple cannot transmit an
  advertisement - `CBPeripheralManager.startAdvertising` takes a local name and
  service UUIDs and nothing else; Windows needs C++/WinRT) with bench narrative
  ("on the bench two of three connects dropped after two seconds"). Keep the
  first kind; cut the second to a line and a link.

`CONTRIBUTING.md` (112 lines) is clean - zero date stamps, zero narrative
markers. `CLAUDE.md` and `GEMINI.md` are byte-identical modulo the assistant
name, so their "kept in sync" claim holds. `AGENTS.md` has two "see the section
below" references, which §11.5 rules out for a linearized reader; trivial.

### Size, as the symptom

A 64 KB `AGENTS.md` is loaded in full by every agent session on this repo. The
workspace router exists precisely because per-repo agent docs are too large to
all be loaded. Across the five sections classified above, roughly 250 lines of
`AGENTS.md` and ~90 of `README.md` are measurement or incident history with an
existing home in `notes/` - a ~25% cut with no rule lost.

## 5. What I would do next, in order

**Worked 2026-09-17.** Items 2, 5 and 6 were closed on `main` before this pass
(`e291219` real skips, the docs cut, `b7fe930` signature-policy enforcement, plus
XEdDSA signing). This pass closed 1 and 4 and settled 3:

| | | |
| --- | --- | --- |
| 1 | CI | `ci/add-workflows`, PR #4. **Actions is disabled at the repository level** (`actions/permissions` → `enabled: false`) - the workflow cannot run until that is turned on, which is one toggle in Settings → Actions and not a code change. |
| 3 | PR #1 | Measured, not rebased - see [`wire-builders-only-migration.md`](./wire-builders-only-migration.md). Reset-and-reapply, once `protobufs` tags `buildersOnly`; rebasing now buys half the sites and goes DIRTY again before the tag. |
| 4 | AEAD | `feat/aead-channels`, PR #5, full gate green. Everything but the `use_aead` proto field, which is ~4 lines and lands with the pin bump. |


1. Add a CI workflow. `spotlessCheck`, `detekt`, `checkKotlinAbi`, `allTests`,
   `testAndroidHostTest` - the gate `AGENTS.md` already specifies, which nothing
   currently runs.
2. Convert the 17 env-gated tests to real skips, so a green run reports how many
   bearer proofs did not execute. Cheap, and it makes (1) honest.
3. Rebase PR #1 - it is conflicted, so nothing runs on it and the drift only
   grows. Declaring a remote repository is the decision that follows it.
4. Write AEAD against the snapshot pin (hash `^= 0xAE`, `use_aead`, AES-CCM
   channel path); land it when protobufs cuts a tag carrying the field.
5. Cut `AGENTS.md` and `README.md` per §4 - move measurement to `notes/`, keep
   rules and rationale. Fix the "pass as skips" claim in both plus `.gitignore`,
   and the three-vs-four `Origin` list.
6. Decide `security.packet_signature_policy`: enforce it, or document in the dump
   that it is stored and not obeyed.
