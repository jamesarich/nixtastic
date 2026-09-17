# node-kmp naming and packaging - the open calls

Written 2026-09-17 from an audit of `meshtastic-node-kmp`'s terminology,
nomenclature and packaging, on branch `docs/positioning-and-terminology`.

The **in-repo** half of that audit is committed there: `docs/positioning.md`
(the case, per audience), `docs/glossary.md` (the vocabulary rule), a README
that leads with capability rather than with the `meshtastic-sdk` contrast, and
one identifier spelling fix. This file is the other half: calls that are James's
and cost something to get wrong, so they are recorded rather than made.

None of these is blocking. All of them get cheaper the earlier they are taken,
because the repo publishes nothing to a remote yet.

## What the audit found that was already right

- **Artifact coordinates already match the org shape.** `~/.m2` shows
  `sdk-core` / `sdk-transport-ble` / `sdk-bom`, `mqtt-client-core` /
  `mqtt-client-transport-tcp` / `mqtt-client-bom`, and `node-core` /
  `node-transport-ble` / `node-transport-lora`. The `<product>-core`,
  `<product>-transport-<x>`, `<product>-bom` convention holds across three repos
  without anyone having written it down.
- **The transport / bearer / medium split is real, not drift.** The code keeps
  them apart consistently: `MeshTransport` is the type, `bearer` is the running
  instance with counters and a name, `medium` is what `InboundFrame.rssi` and
  `TransportAirtime` describe. It was simply never stated. `docs/glossary.md`
  now states it. No renames needed.
- **The neighbour/neighbor split is a rule, not a mistake.** Identifiers follow
  the schema (`NeighborInfo`, `neighbors`, `NeighborGraph`); prose, comments and
  test names are British. Exactly one main-source identifier violated it and is
  fixed.
- **Repo hygiene is clean.** Every stray in the primary checkout
  (`java_pid2884.hprof`, `idb-*/`, `local.properties`, `build/`) is ignored and
  none is tracked.

## The calls

### 1. The repo name

`meshtastic-node-kmp` carries two costs.

`-kmp` is an implementation detail in the name. No sibling carries one:
`meshtastic-sdk`, `kzstd`, `protobufs`. `MQTTastic-Client-KMP` does, and it is
the outlier. If this ever grows a non-Kotlin consumer story the suffix ages
badly, and it says nothing a consumer needs at the point they read it.

`node` alone is the most overloaded noun in the project: a radio is a node, an
entry in the NodeDB is a node, `NodeNum` is a node's address, and now a library
is too. In a sentence like "the node's node DB" it is already straining.

Options, roughly in order of cost: keep it (it is private, nobody depends on the
name yet); drop the suffix to `meshtastic-node`; or pick a product word that is
not `node`. A rename costs a redirect and nothing else today, and costs a
migration once anything depends on the coordinates.

### 2. `node-*` sits as a peer of `sdk-*` in one group

`org.meshtastic:node-core` beside `org.meshtastic:sdk-core` reads as two peer
products. The layering is the opposite: this sits *below* the SDK, and the
stated direction is that the SDK could one day depend on it. A consumer
scanning the group learns nothing about which to reach for.

This is the same decision as #1 and should be taken with it, not separately.

### 3. No BOM, while both siblings ship one

`sdk-bom` and `mqtt-client-bom` exist; `:node-bom` is commented out in
`settings.gradle.kts`. Eleven publishable modules is already past the point a
BOM earns itself, but the real argument is specific to this repo: Wire's
generated types are binary compatible only at an **exact** `protobufs` version
match, Gradle resolves two pins to the higher one, and that is precisely the
broken combination. A BOM is the mechanism that stops a consumer assembling
that failure by hand. It should land with publication, not after.

### 4. `curve25519` under `org.meshtastic`

`node-bluez` is **not** an open question: James stated on 2026-09-16 that the
BLE work is meant to be upstreamed into Kable, which has no JVM/Linux backend,
and `:node-bluez` is already built for that donation (it speaks `BluezProbe`,
imports nothing else here). Its coordinate is a way station, so leave it.

`curve25519` is the open one. It carries no Meshtastic type and no dependencies
at all, and yet `org.meshtastic:curve25519` claims a very generic name inside
the org's group - either a squat or a promise, depending on how it is read.
Three ways out: keep it there and accept that the group is not only about
Meshtastic; publish it under a different group; or upstream it and depend on the
result. Worth deciding before it has an external consumer, because that is the
moment the coordinate stops being free to move.

### 5. Cosmetic: a stale artifact in `~/.m2`

`org.meshtastic:node-desktop-ble` is in the local repository from before the
module was renamed to `:node-desktop-ble-macos`. Harmless, but it is the kind of
thing that makes a local resolution look like it worked when it resolved to the
old jar. Worth a `rm -rf ~/.m2/repository/org/meshtastic/node-desktop-ble*`
before trusting a local composite build.

## One correction to memory

`node-kmp-app-adapter-seams` (2026-09-08) says the repo "applies **no
`maven-publish` plugin at all**". That is now stale: `meshtastic.library-conventions`
applies `com.vanniktech.maven.publish`, `meshtastic.coordinates` sets the group
and version, and the root build names an eleven-module `libraryModules` set.
What remains true is the blocker: `publishToMavenCentral()` is deliberately not
called and no remote repository is declared, so nothing outside this repo can
depend on it and merge. The memory has been updated.
