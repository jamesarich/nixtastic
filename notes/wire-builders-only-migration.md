# Wire `buildersOnly`: making the generated protos binary-stable

A migration for `protobufs`, `TAKPacket-SDK`, `meshtastic-node-kmp`,
`meshtastic-sdk` and `android`. Executed as one coordinated change on
2026-09-09, not as phases.

**On the critical path to shipping `meshtastic-node-kmp` as a product.** A
released node-kmp without it cannot be consumed by `android` at all, because
the two repos deliberately sit on different `protobufs` pins and Wire's
generated Kotlin is binary compatible only at an exact version match.

Measured against the repos as they stood on 2026-09-09, Wire 6.4.7,
`protobufs` at `8db5d3e`. Everything below was compiled and run, not just
generated and read - which is how the two blockers in *What it actually costs*
were found.

## The problem

**Wire's generated Kotlin types are binary compatible only at an exact version
match**, in either direction. This is not the wire-format rule and nothing in
the toolchain says it.

A Wire message compiles to one all-args synthetic constructor. Any added field
changes that signature, so a consumer compiled against a different copy of
`org.meshtastic:protobufs` fails at runtime:

    java.lang.NoSuchMethodError: 'void org.meshtastic.proto.NodeInfo.<init>(
        int, User, Position, float, int, DeviceMetrics, int, boolean,
        Integer, boolean, boolean, boolean, boolean, boolean,
        okio.ByteString, int, kotlin.jvm.internal.DefaultConstructorMarker)'

The cause on the day was `NodeInfo` gaining a single `heard_on_current_lora`
bool ([protobufs #1061](https://github.com/meshtastic/protobufs/pull/1061)).
Four properties make it a bad failure:

- **`buf breaking use:[FILE]` cannot catch it.** Nothing about it is a wire
  break. The encoded bytes stay compatible both ways; only the JVM signature
  moved.
- **Both POMs claim agreement.** The metadata is not wrong, it is irrelevant.
  The mismatch is between bytecode and bytecode.
- **Gradle actively selects the broken pair.** Two pins on one classpath
  resolve to the higher, which is exactly the combination that fails.
- **It surfaces far from its cause.** In the diagnosed case it was thrown
  inside a coroutine, swallowed by an exception handler, and visible only as a
  phone-API handshake that stopped dead after `my_info`.

A version range cannot express "recompile me", so the consumer needs the
dependency *rebuilt*, not re-resolved.

It bites only where **two independently compiled artifacts share generated
types**. Inside one build it cannot happen. It did not bite while the adapter
spikes used composite builds, because a composite recompiles node-kmp against
the consumer's protos; moving to a published artifact is what surfaced it.

## What `buildersOnly` does

`wire { kotlin { buildersOnly = true } }`, added in Wire 4.4.1, documented only
as *"True to turn visibility of all generated types' constructors to
non-public."*

Measured by generating our own schema both ways and diffing all 163 files:

| | before | after |
| --- | ---: | ---: |
| `public fun copy(` | 142 | 0 |
| `private constructor` | 0 | 129 |
| real `newBuilder(): Builder` | 0 | 142 |
| `equals`/`hashCode`/`toString` | 142 | 142 |
| `data class` | 0 | 0 |
| `componentN()` | 0 | 0 |

Three things the documentation does not say, and one thing the previous version
of this note got wrong:

1. **`copy()` disappears entirely.** This is the consequential one. `newBuilder()`
   replaces it and carries `unknownFields` across, which a hand-rolled rebuild
   would drop.
2. **The types were never `data class`es.** Wire already emitted a plain class
   with an explicit `copy()`. So nothing about `data` semantics changes, and
   **destructuring was never available** - `componentN()` is absent on both
   sides. Any migration plan with a "rewrite destructuring" work item is
   describing a problem that does not exist.
3. **Value semantics survive.** `equals`/`hashCode`/`toString` are still
   generated explicitly.
4. `buildersOnly` takes precedence over `javaInterop`, so `javaInterop` needs no
   setting.

Why it fixes the problem: a `Builder` is one property per field. Adding a proto
field adds a property and leaves every existing signature untouched, so an
artifact compiled against an older copy keeps linking. **Permanently binary
compatible for additive proto changes**, which is the only kind
`buf breaking use:[FILE]` allows anyway.

### The encoded bytes do not change, proven twice

Statically, across all 163 generated types: all **2532**
`encodeWithTag`/`encodedSizeWithTag` (adapter, tag) pairs and all **1143**
decode tag-to-adapter mappings are identical. Only the decode *sink* moves,
from a local variable to a builder setter.

At runtime: `TAKPacket-SDK` regenerates 47 golden `.bin` wire frames plus its
`.pb` corpus from 47 CoT XML fixtures. After the rewrite all **103** files are
byte-identical, and `compression-report.md` differs only in its `Generated:`
date, so every compression ratio and byte count matches too. `atak.proto` is
substantively unchanged between `v2.7.26` and master (the 29/29 diff is the
emdash cleanup), so the schema bump cannot account for that.

## What it actually costs

Two blockers that only a compile finds. A plan built on generating and reading
the output will miss both.

### 1. `makeImmutableCopies` must go back on

`buildersOnly = true` with `makeImmutableCopies = false` **does not compile**.
For a repeated field Wire emits the bare field name as the initialiser, which
was a valid constructor parameter in the old shape but is a self-reference once
the constructor takes a `Builder`:

```kotlin
public val chunks: List<Int> = chunks   // Variable 'chunks' must be initialized
```

32 such initialisers across 20 types. Setting `makeImmutableCopies = true`
fixes all of them (`immutableCopyOf("chunks", builder.chunks)`). Worth an
upstream Wire bug.

This costs nothing here, which the old comment in `packages/kmp/build.gradle.kts`
obscured. Copies were disabled "to reduce allocations on high-frequency decode
paths (mesh packets)" - but **no hot-path type has a repeated field at all**.
`MeshPacket`, `Data`, `Position`, `NodeInfo`, `Telemetry`, `DeviceMetrics`,
`FromRadio`, `ToRadio` and `User` are scalar/message only. The 20 affected
types are config and bulk: `ChannelSet`, `Config`, `ModuleConfig`,
`DeviceState`, `NodeDatabase`, `RouteDiscovery`, `NeighborInfo` and the TAK
types.

### 2. `.apply { }` silently corrupts data - use `.also { wb -> }`

The obvious rewrite is wrong:

```kotlin
// WRONG. Inside apply, the Builder's own `model` property shadows the outer
// `model`, so this reads the builder's empty default and always writes "".
X.Builder().apply { this.model = model ?: "" }.build()

// RIGHT. also takes the builder as a parameter, so nothing shadows.
X.Builder().also { wb -> wb.model = model ?: "" }.build()
```

Caught in `TAKPacket-SDK` only because `-Werror` turned "elvis always returns
the left operand" into an error. Without that warning it compiles clean and
produces wrong data. `wb` is unused across all four consumer repos.

The full rule set, and the only forms that should appear in a diff:

```kotlin
X(a = 1, b = c)  ->  X.Builder().also { wb -> wb.a = 1; wb.b = c }.build()
X()              ->  X.Builder().build()
x.copy(a = 1)    ->  x.newBuilder().also { wb -> wb.a = 1 }.build()
copy(a = 1)      ->  this.newBuilder().also { wb -> wb.a = 1 }.build()
```

Always `newBuilder()` for read-modify-write, never a rebuild from fields: it
carries `unknownFields`, and a rebuild silently drops forward-compatible data
from newer firmware. No `buildX { }` helpers - they were considered and
rejected, because a helper per hot type is a second migration later.

## Who is affected

| Repo | Files | Sites | How it consumes protobufs |
| --- | ---: | ---: | --- |
| `protobufs` | 1 | 1 | producer. **No `.kt` sources of its own**, so the change is the flag line |
| `TAKPacket-SDK` | 1 | 19 | `commonMain implementation`, and re-exports proto types |
| `meshtastic-node-kmp` | 36 | 319 | pinned release |
| `meshtastic-sdk` | 62 | 1078 | pinned release |
| `android` | 265 | 2698 | pinned **snapshot** on `main` |

Sites are what the codemod rewrote; a small judgement residue follows in each
repo. Not affected, checked rather than assumed:

- **`MQTTastic-Client-KMP`** does depend on `org.meshtastic:protobufs`, but only
  in its unpublished `sample` module and only to **decode**
  (`ServiceEnvelope.ADAPTER.decode`) plus the `PortNum` enum. Enums have no
  builders and `ADAPTER` is untouched, so it needs no change. Its two apparent
  construction sites are kotlinx.coroutines `Channel(` in a test fake.
- **`kzstd`** has no protobufs dependency.
- **`firmware`, `apple`, `meshtastic-python`** consume the `.proto` submodule,
  not the Kotlin artifact.

**`TAKPacket-SDK` is a serial prerequisite for `android`**, not a parallel lane.
`android` consumes the *published* `org.meshtastic:takpacket-sdk-jvm`, which is
compiled against constructor-shaped protos and re-exports them, so a
buildersOnly `android` on the old TAK artifact hits exactly the
`NoSuchMethodError` this migration exists to kill. TAK must be rebuilt and
republished first.

### Counting sites: do not use a bare grep

The previous version of this note put `android` at 1923 sites from a 14-name
regex. That number is wrong in both directions. The regex omitted every TAK
message (`TAKPacket`, `TAKPacketV2`, `Contact`, `GeoChat`, `Group`), which is
why it scored `TAKPacket-SDK` at 0 when the answer is 19. And it matched far
too much: `Channel(` alone hits kotlinx.coroutines' `Channel(` and android's
hand-written `org.meshtastic.core.model.Channel`.

Seven generated **message** names collide with hand-written classes in these
repos: `Channel`, `Config`, `Data`, `Position`, `Route`, `User`, `Waypoint`.
node-kmp's `PacketCodec` declares its own `NodeInfo`, `Position`, `Waypoint`,
`Neighbor` and `NeighborInfo`; `MeshNode` has its own `Config`. A name match is
not a proto. Resolve by **import**: it is the proto only if the file has
`import org.meshtastic.proto.<Name>` or writes it fully qualified. The
authoritative list is the jar, not the `.proto` files - 181 types have a
`Builder` (142 top level, 39 nested), out of 175 messages and 76 enums.

## How it was done

A deterministic codemod plus the compiler as the oracle, not a hand sweep and
not per-file agents. `scripts` for it live outside the repos; the shape is:

1. Take the Builder-bearing type list from the published jar.
2. Rewrite construction with a Kotlin-aware scanner (strings, char literals,
   nesting block comments), import-scoped per file, iterated to a fixpoint so
   sites exposed by an outer rewrite are caught. Skip anything positional or
   unimported and report it.
3. **Leave `.copy(` alone.** Only the compiler knows whether a receiver is a
   proto. Convert exactly the sites it flags.
4. Compile, convert the flagged copies, repeat. Kotlin stops at the first
   failing module, so each round reveals the next one.
5. `spotlessApply` owns the formatting. Do not hand-indent the output.

The two error shapes to parse. Construction:

```
No parameter with name 'X' found.
No value passed for parameter 'builder'.
```

A lost `copy()`, which K2 reports either as a misresolution onto the stdlib
`Map.Entry.copy()` extension or as a bare receiver mismatch, both with
`Cannot infer type for type parameter 'K'/'V'` and an `ExperimentalStdlibApi`
opt-in error as cascade noise:

```
Candidate 'fun <K, V> Map.Entry<K, V>.copy(): Map.Entry<K, V>' is inapplicable
    because of a receiver type mismatch.
Unresolved reference. None of the following candidates is applicable because of
    a receiver type mismatch:
```

That took ~4100 sites down to single-digit or low-tens residue per repo.

**Compile every source set, not just the JVM target.** `jvmTestClasses` was the
oracle for the bulk, and it is a trap: it never compiles `androidMain`,
`androidHostTest`, the `google`/`fdroid` flavor test source sets, or the Apple
targets. `android` looked finished and still had 22 sites hiding there, found
only by `assembleDebug kmpSmokeCompile test allTests`. Run each repo's real
gate before believing a number.

Four shapes that need a human, all found this way:

- **Import aliases.** `import org.meshtastic.proto.Position as ProtoPosition`
  puts the proto in scope under another name, so a name-based type check misses
  `ProtoPosition(...)` entirely. 46 alias imports across `android` and
  `meshtastic-sdk`.
- **Nullable receivers.** `x?.copy(a = 1)` must become
  `x?.newBuilder()?.also { … }?.build()`. Convert only the first call and the
  safe call stops covering the chain, leaving `.also` on a `Builder?`.
- **Compound expressions.** `node.copy(user = node.user.copy(…))` where the
  outer receiver is a hand-written `core.model.Node` and only the inner one is
  a proto. The compiler reports one line; only one of the two copies may move.
- **A build-then-rebuild round trip.** `X.Builder().build().newBuilder()`
  allocates two messages to produce one. It appears when a pass converts the
  constructor and leaves the trailing `.copy()` for the next pass.

`Message.Builder` has **no public `unknownFields` property** either - only
`addUnknownFields(ByteString)` - so `X(unknownFields = b)` becomes
`X.Builder().addUnknownFields(b).build()`.

### It cost android 27 detekt violations

All in production code, and the cause is uniform rather than 27 separate
problems:

- **15 `CyclomaticComplexMethod`**, concentrated in
  `feature/settings/**/*Config{ItemList,Screen}.kt`. Each setting row's
  `formState.value.copy(field = x)` becomes an `also { }` lambda, and detekt
  counts the lambda, so a screen with twenty rows gains twenty points of
  "complexity" without gaining a branch. `MQTTConfigScreen` reaches 33 against
  a limit of 15.
- **7 `MagicNumber`.** `ignoreNamedArgument` defaults to true, so `X(hop_limit
  = 3)` was exempt and `wb.hop_limit = 3` is not. The rule already excludes
  test source sets.
- **4 `LongMethod` and 1 `LargeClass`**, from the extra lines.

None of it is a real complexity regression. Measured both ways to be sure:
detekt is clean on `origin/main` (34 tasks executed, 0 violations) and reports
27 on the branch, so the migration causes all of them.

**Resolved by raising the three thresholds** (2026-09-09): `allowedComplexity`
15 -> 35, `LongMethod` 60 -> 70, `LargeClass` 600 -> 1100, each with a comment
naming the cause. The alternative was restructuring twenty config screens to
satisfy a metric that is counting lambdas rather than branches.

`MagicNumber` was **not** loosened, because it has no threshold and its seven
reports had a cleaner fix. All seven were numbers that had been exempt as
named arguments (`ignoreNamedArgument` defaults true) until the rewrite made
them assignments. Two in `CommandSenderImpl` now use the `MILLIS_PER_SECOND`
constant that file already declared; the other five are Compose preview sample
data, so the rule gains the same `ignoreAnnotated: ['Preview',
'PreviewLightDark', 'PreviewScreenSizes']` list `LongMethod` already carried,
plus one in-place suppression on a preview helper that is not itself annotated.

## Landing it

No parallel artifact, no phases. **`protobufs-builders` solves a problem that
version numbers already solve**: Maven Central releases are immutable and every
Kotlin consumer pins an exact version, so a buildersOnly `protobufs` breaks
nobody until each consumer chooses to bump. Publishing two shapes of the same
package would only add a name to four version catalogs and a collision that
must never be resolved wrongly.

Decisions taken 2026-09-09:

- **No version bump.** buildersOnly rides with the next `protobufs` tag,
  whatever it is.
- **`publishToMavenLocal` for verification**, not a branch snapshot and not
  merging `protobufs` first. Consumer branches pin
  `2.8.1-buildersonly-SNAPSHOT` (and `takpacket-sdk` `0.9.2-buildersonly-SNAPSHOT`)
  which exist only in `~/.m2`. **Accepted consequence: every consumer PR is red
  in CI until landing day**, and those pin lines are placeholders to be swapped
  for the real tag.
- `mavenLocal()` is injected with `gradle -I <init script>` and never committed.
  Inject it at **settings** level only for `android`, `meshtastic-sdk` and
  `meshtastic-node-kmp`: adding project-level repositories makes Gradle ignore
  the settings repositories entirely and mavenCentral vanishes. `TAKPacket-SDK`
  is the opposite case, declaring repositories per project.

Order on the day: `protobufs` merges and gets tagged, `TAKPacket-SDK` releases
against that tag, then `android` bumps both pins; `meshtastic-node-kmp` and
`meshtastic-sdk` need only the `protobufs` tag and are independent of TAK.

### Per repo

- **`protobufs`** - two settings in `packages/kmp/build.gradle.kts`. Nothing
  else, because the repo has no Kotlin sources.
- **`TAKPacket-SDK`** - repo convention is *do not auto-commit*, so the change
  is left staged. Its goldens are the runtime proof above. `apiCheck` passes
  (its bcv config already ignores `org.meshtastic.proto`).
- **`meshtastic-node-kmp`** - `checkKotlinAbi` passes unchanged, which was not
  what I expected: the proto types appear in its ABI dump as external
  references, and none of its own signatures moved. So there is no ABI review
  to hold here after all.
- **`meshtastic-sdk`** - `checkKotlinAbi` also passes unchanged, so its
  external downstream consumer keeps a compatible binary surface. Note the pin
  here moved 2.7.26 -> 2.8.x, which is a **schema** bump carrying its own
  semantics: `rx_rssi` became `optional int32`, and that, not `buildersOnly`,
  is what broke `RadioMetrics`. Worth splitting from the migration.
- **`android`** - largest but latest. Needs the TAK republish before it can be
  trusted green, since the old TAK artifact would fail at runtime, not at
  compile time.

### Verification per repo

- Each repo's own full gate, no exclusions. `android`'s is the baseline in its
  `CLAUDE.md`, not just a compile.
- `apiCheck` / `checkKotlinAbi` read, never blindly regenerated.
- The end-to-end proof this whole migration exists to make true, and it should
  be asserted explicitly rather than inferred from green builds: **node-kmp
  published from its own default pin, consumed by an `android` build on a
  different pin, with the phone-API handshake test passing.**

## Wire 7.0.0 (released 2026-09-10) does not change any of this

Checked by generating our own schema with 7.0.0 and diffing against the 6.4.7
buildersOnly output, not by reading the changelog.

**`buildersOnly` is byte-for-byte the same feature.** 163 files either way, and
the shape is identical: 129 private constructors, 142 real `newBuilder()`, 0
`copy()`, 0 data classes. All 2532 `encodeWithTag`/`encodedSizeWithTag`
(adapter, tag) pairs are unchanged, so **the bump alters no encoded bytes**.
Nothing in the 7.x changelog touches the all-args constructor, `copy()`, or
binary compatibility. The migration stands exactly as written.

**Neither of our two Wire annoyances is fixed.** Both are about repeated
fields, and both reproduce on 7.0.0:

- `buildersOnly = true` with `makeImmutableCopies = false` still emits the same
  32 self-referential initialisers. The coupling above stays.
- The generated code still trips `UNNECESSARY_NOT_NULL_ASSERTION` 9 times, on
  `MutableList<Int>`/`MutableList<Float>` receivers. RC01's "warning-free under
  Kotlin 2.1" does not cover this, so `packages/kmp`'s `freeCompilerArgs`
  suppression stays. Verified by removing it and building with
  `allWarningsAsErrors`.

One report upstream covers both, and 7.0.0 being the latest release makes it
land better.

### What is worth taking, in a separate PR

Do not fold this into the buildersOnly change. A decode-semantics change does
not belong in a 4100-site refactor.

- **Security, and this is the real reason to bump.** 6.4.7 carries fixed
  advisories: `GHSA-7xpr-hc2w-34m9` (negative lengths when skipping groups,
  unchecked runtime exceptions instead of `ProtocolException`) and
  `GHSA-9rm7-3qhh-h2mc` (oversized lengths and fixed-width values past the
  reader limit). Every Meshtastic client decodes frames that arrived over the
  air from a sender it cannot vouch for, and `android` already fuzzes that path
  in `ReplayFuzzTest`.
- **`oneofMode` (new in 7.0.0-alpha01) replaces our magic number.** We set
  `boxOneOfsMinSize = 5000` purely to force flat nullable oneof properties, and
  the comment there says so. `oneofMode = "flat"` is now the documented,
  explicit spelling of that intent and still honours `boxOneOfsMinSize`.
- **Oneofs decode in constant size per field** (#3691), which is the
  `MeshPacket` hot path.

### The one thing to validate before bumping

⚠ **Decode semantics change on the packet path.** 42 generated types now route
singular message fields through `decodeMessageOrMerge`. Concretely, in
`MeshPacket`:

```kotlin
// 6.4.7:  4 -> builder.decoded(Data.ADAPTER.decode(reader))
// 7.0.0:  4 -> builder.decoded(decodeMessageOrMerge(Data.ADAPTER, reader, builder.decoded))
```

`decoded` is a member of the `payload_variant` oneof. Where a field appeared
twice on the wire, 6.4.7 kept the last occurrence and 7.0.0 merges them. That
direction is the protobuf specification's rule for embedded messages, so this
is Wire fixing a compliance gap rather than inventing behaviour - but it is
still a behaviour change on frames that arrive from the air, and our schema has
19 oneofs across 8 files. **Check it against the firmware's nanopb decode
before bumping** (`firmware-is-the-sentinel-for-node-kmp`): if nanopb merges,
the bump moves the Kotlin clients *toward* parity, and that is worth saying in
the PR.

Not applicable to us, checked rather than assumed: our schema has no
`FieldMask`, no `redacted` fields, and no message named `Builder`, and the
CamelCase-sealed-class break only affects `oneofMode = sealed_class`, which we
do not use. The Gradle 8.2+ floor is satisfied (we are on 9.7.1), the plugin no
longer applying the Kotlin plugin transitively is fine because
`packages/kmp` applies it itself, and the provider-backed `set(...)` migration
does not reach the three scalar options we set - verified by generating with
7.0.0 and the DSL unchanged.

## Alternatives considered and rejected

- **A parallel `protobufs-builders` artifact for one release cycle.** Redundant,
  as above.
- **Version ranges / `resolutionStrategy` force.** Cannot work: the requirement
  is recompilation, not re-resolution, and forcing produces exactly the
  mismatched pair.
- **Shading protobufs into `node-kmp`.** Correct in principle for its bytes-only
  seams, but Shadow is JVM-only - there is no KMP relocation - and
  `nodeDefaults`, `AdminService` and `BackupPreferences` are proto-shaped in the
  public API regardless.
- **Keeping every repo on one pin by policy.** Fails on the first day someone
  needs an unreleased proto field, which is `android`'s normal working mode.
- **`@Deprecated(level = HIDDEN)` retention of old constructors.** Wire
  generates the constructor; we do not, so there is nowhere to put it.
- **Per-file LLM agents for the sweep.** Used only for the judgement residue.
  The bulk is a deterministic transform, and a script does it more cheaply and
  more reliably than 4100 model calls.

## Related

- `meshtastic-node-kmp/AGENTS.md` -> *Consuming this from another repo* - the
  `-PprotobufsVersion` track, which covers side-by-side development and expires
  the moment node-kmp ships, because a consumer of a published library does not
  rebuild its dependencies.
- [`cross-repo-contracts.md`](./cross-repo-contracts.md) - the wire-level rules
  this sits underneath. The "additive changes are safe" rule stated there is a
  *wire* rule; it is not a binary-compatibility rule for Wire's Kotlin output,
  which is the whole subject of this document.
- `2026-09-05-heard-on-current-lora.md` - the field that triggered the
  diagnosis.
