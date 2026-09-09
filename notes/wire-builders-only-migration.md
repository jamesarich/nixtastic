# Wire `buildersOnly`: making the generated protos binary-stable

A migration plan for `protobufs`, `android`, `meshtastic-sdk`,
`meshtastic-node-kmp` and `TAKPacket-SDK`.

**This is on the critical path to shipping `meshtastic-node-kmp` as a product**
(confirmed 2026-09-09). It is not a someday cleanup. The reasoning is in *Why
this is blocking* below, and the short version is that a released node-kmp
without it cannot be consumed by `android` at all, and every release shipped
before it makes the eventual migration strictly more expensive.

The cheap workaround described below (`-PprotobufsVersion`) covers local
development in the meantime. It does not survive contact with a published
artifact, which is the whole point.

Everything here was measured against the repos as they stood on 2026-09-09,
Wire 6.4.7, `protobufs` at `ca2cb1a`. Where a claim came from generating code
rather than from documentation, it says so - the Wire docs do not mention the
single most important consequence.

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
Four properties make this a bad failure:

- **`buf breaking use:[FILE]` cannot catch it.** Nothing about it is a wire
  break. The encoded bytes stay compatible in both directions; only the JVM
  signature moved.
- **Both POMs claim agreement.** The metadata is not wrong, it is irrelevant -
  the mismatch is between bytecode and bytecode.
- **Gradle actively selects the broken pair.** Two pins on one classpath
  resolve to the higher, which is exactly the combination that fails.
- **It surfaces far from its cause.** In the diagnosed case it was thrown
  inside a coroutine, swallowed by an exception handler, and visible only as a
  phone-API handshake that stopped dead after `my_info`.

A version range cannot express "recompile me", so the consumer needs the
dependency *rebuilt*, not re-resolved.

### Where it bites, and where it does not

It bites only where **two independently compiled artifacts share generated
types**. Inside one build it cannot happen, because everything compiles against
one copy.

Today that is exactly one situation: `meshtastic-node-kmp` published as an
artifact and consumed by `android` or `meshtastic-sdk`, which is what the
adapter spikes do. It did not bite while those spikes used composite builds,
because a composite *recompiles* node-kmp against the consumer's protos. Moving
to a published artifact is what surfaced it - the composite build was hiding a
real constraint.

### The cheap workaround, already in place

`meshtastic-node-kmp` (2026-09-09, commit `0c1aa70`) takes
`-PprotobufsVersion=<v>`, which overrides the version catalog and publishes a
second track at `0.1.0-pb<v>-SNAPSHOT` beside the default. `AGENTS.md` →
*Consuming this from another repo* has the detail. Cost: one republish when the
consumer's pin moves.

**It only works because the consumer rebuilds the dependency**, which is
exactly what a consumer of a published library does not do. So it covers
side-by-side development and expires the moment node-kmp ships - it is a
bridge to the migration, not a substitute for it.

## What `buildersOnly` actually does

`wire { kotlin { buildersOnly = true } }`, added in Wire 4.4.1, documented only
as *"True to turn visibility of all generated types' constructors to
non-public."*

Generated against our own schema (the flag flipped in
`packages/kmp/build.gradle.kts`, generated, inspected, reverted):

```kotlin
public class NodeInfo private constructor(   // NOT a data class
  @field:WireField(tag = 1, ...) public val num: Int = 0,
  ...
) : Message<NodeInfo, NodeInfo.Builder>() {

  override fun newBuilder(): Builder { ... }   // every field copied across
  override fun equals(other: Any?): Boolean { ... }
  override fun hashCode(): Int { ... }
  override fun toString(): String { ... }

  public class Builder : Message.Builder<NodeInfo, Builder>() {
    @JvmField public var num: Int = 0
    @JvmField public var user: User? = null
    ...
    override fun build(): NodeInfo = NodeInfo(...)
  }
}
```

Four findings, three of which the documentation does not state:

1. **The constructor is `private`.** As documented.
2. **There is no `copy()` at all** - the class is no longer a `data class`.
   This is the consequential one and it appears nowhere in the docs or the
   changelog. It is not a Kotlin `@ConsistentCopyVisibility` interaction; the
   `data` modifier is simply not emitted.
3. **`newBuilder()` is the replacement for `copy()`**, and it carries
   `unknownFields` across, which a hand-rolled rebuild would drop.
4. **`equals`/`hashCode`/`toString` are generated explicitly**, so value
   semantics survive. Only `componentN()` destructuring is lost.

Why this fixes the problem: a `Builder` is one property per field. Adding a
proto field adds a property and leaves every existing signature untouched, so
an artifact compiled against an older copy keeps linking. **Permanently
binary-compatible for additive proto changes**, which is the only kind
`buf breaking use:[FILE]` allows anyway.

It does not change encoded bytes. `ADAPTER.encode`/`decode` are unaffected, so
**all read paths and all serialization are untouched** - only construction and
modification change shape. `boxOneOfsMinSize` and `makeImmutableCopies` are
independent and keep their current values.

`buildersOnly` takes precedence over `javaInterop`, so `javaInterop` does not
need setting; the Builder is emitted either way. Confirmed by generating with
`javaInterop` unset, as it is today.

## What it costs

Call sites needing rewriting, measured 2026-09-09. "Production" is everything
outside a test source set.

| Repo | Production | Test | Total |
| --- | ---: | ---: | ---: |
| `android` | 523 | 1400 | 1923 |
| `meshtastic-sdk` | 169 | 589 | 758 |
| `meshtastic-node-kmp` | 120 | 113 | 233 |
| `TAKPacket-SDK` | 0 | 0 | 0 |
| **Total** | **812** | **2102** | **2914** |

Of those, the `.copy(field_name = …)` sites - the read-modify-write ones, which
are the fiddly half - are 209 in `android`, 18 in `meshtastic-sdk`, 16 in
`meshtastic-node-kmp`.

Reproduce the counts with:

```sh
P='\b(MeshPacket|FromRadio|ToRadio|AdminMessage|NodeInfo|User|Position|Telemetry|ChannelSettings|DeviceMetrics|Data|Config|ModuleConfig|Channel)\(|\.copy\(\s*[a-z]+_[a-z_]+\s*='
grep -rn --include='*.kt' -E "$P" <repo> --exclude-dir=build --exclude-dir=.git
```

Two things make this less alarming than the total:

- **72% of it is test code**, which is mechanical and fails loudly. The risk
  concentrates in the 812 production sites.
- **`TAKPacket-SDK` is not affected at all.** It constructs no Meshtastic proto
  types directly.

The hotspots are heavily concentrated - `android`'s top six files are all
tests, led by `RadioConfigViewModelTest.kt` (184 sites); `meshtastic-sdk`'s
worst production file is `internal/AdminApiImpl.kt` (63); `node-kmp`'s are
`LocalRadio.kt` (40) and `AdminService.kt` (35).

## Why this is blocking

`meshtastic-node-kmp` is intended to ship as a product. Three consequences
follow, and the first one is the decisive one.

**1. A released node-kmp is unusable by `android` as things stand.** `android`
normally tracks an unreleased `protobufs` snapshot - it is where proto changes
originate, so it is routinely ahead of the last release (on 2026-09-09, 31
commits ahead). node-kmp pins releases on purpose, because the pin bump is its
parity review checkpoint. Those two positions are both correct and they are
irreconcilable across a published artifact: whichever pin the release carries,
the other consumer gets `NoSuchMethodError`. `-PprotobufsVersion` resolves it
by rebuilding locally, which a consumer of a *published* library does not do.
So without `buildersOnly`, the flagship consumer cannot adopt the flagship
artifact.

**2. Every release shipped before the migration raises its cost.** Once
external consumers exist, the constructor shape is public API. Changing it then
means a major version, a deprecation window, and a migration those consumers
must perform on our schedule rather than their own. Doing it before the first
public release costs nothing but our own call sites - and it is the *same* work
either way.

**3. Pin-matching becomes a support burden rather than a chore.** Today the
failure lands on the person who caused it, with the repos in front of them.
After release it lands on a stranger, at runtime, with a `NoSuchMethodError`
naming a constructor and nothing pointing at the version skew.

**Sequencing: this should land before node-kmp's first published release.**
That release is already gated on adding a publish repository (see
`meshtastic-node-kmp/AGENTS.md` → *Before this can go public*); this belongs in
the same gate. Phases 1 and 2 below - `protobufs` publishing both shapes, and
node-kmp migrating - are the blocking pair. Phases 3 and 4 (`meshtastic-sdk`,
`android`) can follow at their own pace *provided* Phase 1 has shipped, because
the parallel artifact is what decouples them.

Secondary triggers, if the release slips:

- A second independently-published Kotlin library starts exposing proto types
  (an `apple` KMP shim, a third-party consumer).
- The `NoSuchMethodError` class of bug is hit by anyone other than us.

## Migration strategy: parallel artifact, not a flag day

Flipping the flag in `protobufs` changes every Kotlin consumer in one release.
With 2914 call sites across three repos that cannot land atomically, and a
half-migrated consumer does not compile.

**Publish both shapes for one release cycle instead.** `protobufs` takes its
publishing coordinates from `packages/kmp/gradle.properties`
(`GROUP=org.meshtastic`, `POM_ARTIFACT_ID=protobufs`) via
`com.vanniktech.maven.publish`. A second Gradle module reading the same proto
sources with `buildersOnly = true` and `POM_ARTIFACT_ID=protobufs-builders`
publishes a parallel artifact with identical package names.

That lets each consumer migrate on its own schedule by changing one catalog
line, verify, and merge independently. When the last consumer is across, the
builders module becomes the only one and the old artifact is deprecated.

The package names collide, so **no consumer may depend on both at once**. That
is a feature: the clash is a compile error, not a runtime surprise.

### Phases

**Phase 0 - decide, in `protobufs`.** Confirm the parallel-artifact approach
and that `protobufs-builders` is the name we want to live with. Nothing else
starts until this is settled, because the artifact id ends up in four version
catalogs.

**Phase 1 - `protobufs` publishes both.** One new module, one
`POM_ARTIFACT_ID`, `buildersOnly = true`, everything else identical. Verify by
decoding a fixture with each artifact and asserting byte-identical output, so
"the bytes did not change" is proven rather than assumed. Ship it in a normal
release.

**Phase 2 - `meshtastic-node-kmp` migrates. Blocking for its first release.**
It is the smallest (233 sites), it is private, its CI is off, and it is the
repo whose publication forces the issue. It also proves the migration shape on
a real codebase before either app commits. Its `checkKotlinAbi` dump will move
- that is expected and is the point at which the public ABI change gets
reviewed, which is exactly the review that should happen once rather than after
strangers depend on it.

Phases 1 and 2 are the pair that must land before node-kmp publishes to a
remote. The two below are not blocking, because the parallel artifact from
Phase 1 lets each consumer move independently.

**Phase 3 - `meshtastic-sdk` (758 sites).** Do `internal/AdminApiImpl.kt` (63)
first as the pilot. The SDK has an external downstream consumer outside this
workspace, so this phase is a **breaking API change for them** if proto types
appear in its public surface - check that before starting, and treat it as a
major-version bump if so.

**Phase 4 - `android` (1923 sites).** Largest, but latest and lowest-risk once
the pattern is established twice. Split by module, one PR per `core:*` /
`feature:*` module, production before tests within each. Do not let one PR span
modules - the merge queue ejects on semantic conflicts and a 500-file PR will
never land.

`android` is the consumer that most needs this finished, since it is the one
whose snapshot pin the current scheme cannot serve - so while Phase 4 is not
blocking for node-kmp's release, it *is* blocking for android actually
consuming it.

**Phase 5 - retire.** `protobufs` drops the non-builders module,
`POM_ARTIFACT_ID` returns to `protobufs`, consumers change one catalog line
back. Deprecate rather than delete for one release.

### Mechanical rules for the rewrite

Construction, named arguments:

```kotlin
// before
NodeInfo(num = 42, user = user, hops_away = 3)
// after
NodeInfo.Builder().apply { num = 42; this.user = user; hops_away = 3 }.build()
```

Read-modify-write - **always `newBuilder()`**, never a hand-rolled rebuild,
because `newBuilder()` carries `unknownFields` and a rebuild silently drops
forward-compatible data from newer firmware:

```kotlin
// before
admin.copy(get_config_response = config)
// after
admin.newBuilder().apply { get_config_response = config }.build()
```

Consider adding a small `buildX { }` helper per hot type in each repo's test
support rather than 1400 `.apply { }.build()` chains; the tests are where the
verbosity actually hurts. Decide that in Phase 2 and apply it consistently.

Destructuring (`val (a, b) = proto`) breaks and has no builder equivalent -
rewrite to property reads. Rare, but grep for it per repo before starting.

### Verification per phase

- Byte-identical encode/decode against a fixture corpus, at the `protobufs`
  boundary (Phase 1) and per consumer.
- Each repo's own full gate, no exclusions.
- `meshtastic-node-kmp`: `checkKotlinAbi` diff reviewed rather than blindly
  updated.
- The end-to-end proof that motivated all of this: `node-kmp` published from
  its own default pin, consumed by an `android` build on a *different* pin,
  with the phone-API handshake test passing. That is the assertion this whole
  migration exists to make true, and it should be an explicit acceptance check
  at the end - not inferred from green builds.

## Alternatives considered and rejected

- **Version ranges / `resolutionStrategy` force.** Cannot work: the requirement
  is recompilation, not re-resolution, and forcing produces exactly the
  mismatched pair.
- **Shading protobufs into `node-kmp`.** Correct in principle for its
  bytes-only seams (`PhoneApiSession` exposes only `ByteArray`), but Shadow is
  JVM-only - there is no KMP relocation - and `nodeDefaults`, `AdminService`
  and `BackupPreferences` are proto-shaped in the public API regardless.
- **Keeping every repo on one pin by policy.** Fails on the first day someone
  needs an unreleased proto field, which is `android`'s normal working mode.
- **`@Deprecated(level = HIDDEN)` retention of old constructors.** Wire
  generates the constructor; we do not, so there is nowhere to put it.

## Related

- `meshtastic-node-kmp/AGENTS.md` → *Consuming this from another repo* - the
  `-PprotobufsVersion` track and why it overrides the catalog rather than the
  resolution.
- [`cross-repo-contracts.md`](./cross-repo-contracts.md) - the wire-level rules
  this sits underneath. Note that the "additive changes are safe" rule stated
  there is a *wire* rule; it is not a binary-compatibility rule for Wire's
  Kotlin output, which is the whole subject of this document.
- `2026-09-05-heard-on-current-lora.md` - the field that triggered the
  diagnosis.
