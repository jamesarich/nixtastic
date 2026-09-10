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
- **`meshtastic-node-kmp`** - `checkKotlinAbi` will move. That diff is the
  public ABI change and should be reviewed once, now, rather than after
  strangers depend on it.
- **`meshtastic-sdk`** - has an external downstream consumer outside this
  workspace, so if proto types appear in its public surface this is a
  **source-breaking change for them**. Do not `apiDump` blindly; read the
  diff and treat the version bump as a governance decision.
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
