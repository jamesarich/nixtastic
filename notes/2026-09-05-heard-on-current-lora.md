# Heard-on-current-LoRa node bit - cross-repo umbrella

Status: in progress - protobufs merged (9a78479); android PR #7055 MERGED 2026-09-07; apple shipped an interim.
firmware#11811 is open and **changed the mechanism from a sweep to a derived per-node slot fingerprint**
(see the 2026-09-11 section). Follow-ups are up as drafts: android **#7138** (MQTT-only nodes,
string, docs) and protobufs **#1079** (the field's own doc comment). Thomas still needs telling
that the proto text is fixed separately, while #11811 is open.
Started: 2026-09-05

## Goal

After a LoRa preset, region or frequency-slot change, every client keeps
showing the nodes it knew before the change. Nothing marks them, so the node
list looks populated while every send into it fails - silently for channel
broadcasts, which have no ack. New users read the stale list as "the mesh is
here, the app is broken".

Origin: <https://redd.it/1w7y2st> (DragonCon event firmware, Atlanta on
MediumFast vs LongFast), raised by Jonathan.

Fix: firmware carries one bit per node - "heard since the current LoRa
config took effect" - cleared for every node when the config changes, set
whenever the node is heard. Clients grey out the unset ones and offer a
one-tap clear. The bit lives in firmware, not in a client, because MUI has
no phone at all, and because a phone-side heuristic misfires whenever the
preset is changed from the device UI or CLI while the phone is disconnected.

## Repos touched

| repo | change | branch / worktree | verification | landed (SHA or PR) |
| --- | --- | --- | --- | --- |
| protobufs | `NodeInfo.heard_on_current_lora` bool tag 15; `NodeInfoLite.bitfield` doc note | - | `buf lint` | |
| protobufs | doc comments rewritten for the derived scheme (2026-09-11) | `docs/heard-on-lora-derived` | `buf lint` + `buf breaking` clean | **PR #1079** draft |
| firmware | bitfield bit 11; set on hear, clear on slot change; mirror in `TypeConversions`; submodule bump | - | `bin/run-tests.sh` (native), bench flash | issue #11745 |
| device-ui | grey stale rows in the node list; zip pin bumped into firmware | - | native CMake/ctest, on-device TFT | issue #387 |
| android | `Capabilities` gate, marker, banner + removal offer, hide-unheard filter | `feat/unheard-on-current-lora` | full baseline green; CI 17/17 at be0a8d7; CodeRabbit 0 actionable | **PR #7055 MERGED** 2026-09-07 |
| android | `Node.isUnheardOnCurrentLora` excludes MQTT-only nodes; string + docs (2026-09-11) | `fix/heard-on-lora-derived-followups` | full baseline green, 19m59s, 4 new tests | **PR #7138** draft |
| apple | parity | - | Garth's own | **PR #2429 MERGED** (interim app-side, not the proto field) |
| design | cross-platform feature spec; docs as a sub-issue | - | issue only | **#146 (parent)**, docs meshtastic#2649 |

`meshtastic-sdk` and `meshtastic-python` are deliberately out of scope
(both are behind at protobufs v2.7.26; they pick the field up on their next
bump with no code change required).

## Contract changes

`NodeInfo` gains field 15, `bool heard_on_current_lora`. New field number,
nothing reused or deleted - satisfies the proto rule in
`notes/cross-repo-contracts.md` → Changing a proto. No nanopb annotation, so
no firmware buffer sizing changes.

The device-side twin is a bit in the existing `NodeInfoLite.bitfield`
(uint32, bits 0..10 used, 21 spare) at shift 11, mirrored on the wire the
same way `is_key_manually_verified` and `has_xeddsa_signed` already are
(`TypeConversions.cpp:19-24`). Zero added bytes in the NodeDB, which matters:
`NodeInfoLite` has been deliberately shrunk (positions/telemetry moved to
satellite arrays, SNR packed to Q4, bools packed into the bitfield) and
`MAX_NUM_NODES` is 120 on nRF52840/ESP32.

Proto3 bool defaults to false, so a new client against old firmware would
read every node as "not heard" and mark the whole list stale. Clients gate
the UI on a firmware-version `Capabilities` check, not on the field alone.

## Why a bit and not a timestamp

The obvious alternative - a device-level `lora_config_changed_at`, with
stale defined as `last_heard < changed_at` - is wrong on this firmware.
`NodeDB` treats `last_heard` as "a real epoch or 0" and routes nodes heard
while the clock is untrusted into a RAM sidecar
(`recordHeardWhileClockUntrusted`, backfilled by `backfillHeardAt()`). A
radio that changes preset before it has a time source writes a watermark of
0, and every pre-change node with a real timestamp then compares as fresh. A
bit is clock-independent and is correct on exactly the paths where the
timestamp scheme fails.

## Release order

1. `protobufs` - merge and tag. Firmware and apple bump submodules; android
   waits for the published `org.meshtastic:protobufs` artifact.
2. `firmware` - implement, release. `device-ui` lands first and is bumped in
   as a zip pin, so MUI is a two-step landing.
3. `android`, `apple` - bump the pin, implement the UI behind the capability
   gate.

`design` runs in parallel; it gates nothing.

## Decisions taken since scoping

All four scoping questions are now settled in design#146 and the firmware
sub-issue:

- **Clear at the choke point, not in `AdminModule`.** `MenuHandler.cpp` calls
  `service->reloadConfig(SEGMENT_CONFIG)` from ~15 sites - the device's own
  screen menu never touches `AdminModule`, and that is the MUI path this whole
  change exists for. Hook `MeshService::reloadConfig`, comparing a slot-tuple
  snapshot. That also picks up `set_channel_url`/`set_config_url` (scanned QR),
  licensed-mode region changes, `resetRadioConfig` and factory reset.
- **Persistence confirmed as a real gap.** `reloadConfig` ends in
  `saveToDisk(saveWhat)` and a LoRa write passes `SEGMENT_CONFIG`, not
  `SEGMENT_NODEDATABASE`, so the clear would be lost across the reboot. The
  fix belongs at the same choke point, which also covers the edit-transaction
  deferral.
- **Warm tier: carry nothing.** `getOrCreateMeshNode` is reached from
  favourite-add, ignore, `add_contact` and NodeInfo ingestion - none are hears
  - so a cleared bit on re-admission is the correct outcome, not a limitation.
  Bit 7 of the stolen `last_heard` field stays free.
- **Upgrade wave: one-time watermark.** A spare bitfield bit needs no schema
  change, so no migration hook fires. Do not bump `DEVICESTATE_CUR_VER` (it
  also drives the legacy-decode gate; 26 is reserved). Use the
  `POSITION_TELEMETRY_OPTIN_VER` pattern instead.
- **Field sense: positive**, gated on a client capability check. Clients must
  gate persistence as well as display, or a false read from old firmware
  outlives the firmware upgrade.

## Still unproven

- Nothing has been built or flashed. Every claim above is read from source.
- `device-ui#387` could not be attached as a native GitHub sub-issue of #146
  (the endpoint 404s for that repo); it is linked by reference in #146's
  checklist only.

## Out of scope, worth recording

Two claims from the Reddit thread that are wrong, checked against the code:

- "Mesh Discovery recommends by SNR" - no. `DiscoverySummaryGenerator.kt:36`
  ranks by `uniqueNodes` descending, then channel utilization ascending.
- "Sending fails silently" - half right. DMs surface `MAX_RETRANSMIT`
  (`Message.kt:90`). Channel broadcasts have no ack, so those are silent.

Discovery being slow and buried is a separate usability item.

## Android review log (PR #7055)

Six CodeRabbit rounds, 18 findings, 17 fixed and 1 declined. The ones worth
remembering because they were real bugs, not polish:

- Removal could delete the user's own node: `ourNode` and the node list come
  from independent flows, so the list held the local node while `ourNode` was
  still null. Now offers nothing until the local number is known.
- Normalizing only `nodeState` never reached the UI, which renders from the
  repository flows. Moved to the database (`markAllHeardOnCurrentLora`), bound
  to the originating session lease like `insertMetadata`.
- `Capabilities.forceEnableAll = isDebug` defeated the gate in debug builds:
  the absent proto3 field decoded false and was persisted. This capability now
  sits outside the override.
- `reportsHeardOnCurrentLora` is a StateFlow on `NodeManager` (the
  `firmwareEdition` shape): atomic reads across coroutines, and the node list
  presents every node as heard while it is false, so no consumer can act on a
  stale flag before the async DB normalization lands. The filter additionally
  waits for `isNodeDbReady`.
- Declined: moving the 57->58 migration test to `androidHostTest`. Every
  existing (n-1)->n test lives in `jvmTest`; `.coderabbit.yaml:156` is stale.

Follow-up: Meshtastic-Android#7059, a regression test for the delayed-session
normalization race.

Ships on the `2.8.0.16-g9a78479-SNAPSHOT` pin; James confirmed snapshots are
fine to ship on.

## Tooling found wanting on the way

- `pr <repo> <n>` (and `wait --until reviewed`) cannot see a 0-actionable
  CodeRabbit outcome: it lands as an in-place edit of the pinned summary
  comment ("No actionable comments were generated in the recent review"),
  not as a review body. Round six sat "unreviewed" for 30 minutes after it
  had finished. Also: CodeRabbit auto-pauses *automatic* reviews after N
  reviewed commits ("Reviews paused"); an explicit `full review` still runs.
- `just pr <repo> <n> resolve <id> --reply "..."` splits the reply on spaces
  and argparse rejects the rest; `nix run .#pr -- ...` is fine.
- The Flatpak aarch64 workflow's "Reclaim the isolated Gradle home" step
  `rm -rf`s a dir a daemon is still writing and, when it loses, skips the
  whole offline build. x86_64 unaffected. Separate fix.

## Firmware changed the mechanism: derived, not swept (2026-09-11)

firmware#11811 (caveman99, open, branch `fix/nodedb-heard-on-current-lora`)
implements the firmware half, and it does **not** implement the sweep this
note scoped. The first push did; James asked on the PR whether it handled
`discovery` rolling through presets, Garth having flagged it the day before,
and Thomas rewrote it.

Why the sweep was wrong: Discovery is client-driven, so every preset hop
goes through `MeshService::reloadConfig()`. The sweep cleared every mark on
the way out and cleared them again on the way home, and anything heard while
parked on a foreign preset kept its mark once the radio came back. A scan
therefore ended with the whole node DB reading unreachable.

What replaced it:

- Bit 11 is now `NODEINFO_BITFIELD_HAS_RF_HEAR` - "heard over our own radio
  at least once". Sticky, never cleared.
- **Bits 12..23 are a 12-bit FNV-1a fingerprint of the slot it was heard
  on.** Reserved bits now start at 24, not 11.
- `NodeDB::committedSlot` holds the fingerprint of the slot the radio is
  committed to. `refreshCommittedLoraSlot()` re-reads it and touches no node.
- `NodeInfo.heard_on_current_lora` is **derived at
  `TypeConversions::ConvertToNodeInfo` time**: `hasRfHear && heardSlot ==
  committedSlot`. Nothing is persisted per node at config-change time.

So hopping presets writes nothing, and returning to a slot restores its marks
by itself. The discovery problem is fixed entirely on the firmware side.

The fingerprint covers region, `use_preset`, then `modem_preset` **or**
bandwidth/spread_factor/coding_rate (only the pair actually in force, so
editing a dormant field is not a slot change), `override_frequency`,
`channel_num`, and `Channels::getName(primaryIndex)` - which substitutes the
preset name for an empty channel name.

A beacon TX parks the radio on someone else's preset, so
`setLoraSlotTransient(true)` pins the committed slot across that window.

### What this means for android

PR #7055 merged 2026-09-07 against the *sweep* design. The mechanism change
does not break it - android reads the wire bool and never modelled the sweep
- but four things now read wrong. 1 and 2 change behaviour or user-facing
text; 3 and 4 are comments.

Checked, and not a live break:

- `DiscoveryHomeRestorer` restores the captured `homeLoraConfig` **and**
  `homePrimaryChannel` (`applyHomeConfiguration`, restorer:384), so the home
  fingerprint reproduces. This is now load-bearing in a way it was not
  before: the fingerprint is an equality test, so a restore that dropped the
  primary channel would leave every node reading unheard after every scan.
  Worth a regression test, since nothing in discovery's tests asserts it.
- A mid-scan UI gate is defence, not a fix for a live break. A LoRa write
  sets `requiresReboot = false` ("All LoRa radio changes apply live via
  configChanged observer", `AdminModule.cpp:1123`) and `handleSetChannel`
  calls `saveChanges(..., false)`. Neither reboots, so the normal scan path
  holds one session throughout and never re-reads NodeInfo. But android can
  re-dump on its own: `FromRadioPacketHandlerImpl:145` re-handshakes on the
  firmware `rebooted` flag, `RadioConfigViewModel:1265` on an
  `UnexpectedAckSender`, and `LockdownCoordinatorImpl:183` on lockdown
  status. Any of those firing while the radio is parked on a foreign preset
  re-dumps the whole DB reading unheard, and `NodeListScreen:153` then offers
  all of it for removal. Not new - the sweep design had the same hazard and
  was worse, because a swept false persisted while a derived one repairs
  itself the moment home is restored.

Real, ranked:

1. **MQTT-only nodes are presented as unheard forever.** The mark is set
   only on `transport_mechanism == TRANSPORT_LORA && !via_mqtt`, so a node
   that only ever arrives through an uplink reports false for the life of
   the entry. It wore the unreachable badge, was hidden by the unheard
   filter, and was offered for bulk removal by `NodeListScreen:153`
   (`!heardOnCurrentLora && !isFavorite && num != ourNum`), where deleting
   it achieves nothing - the next uplinked packet brings it straight back.
   The bit itself is right (see *Warm tier: carry nothing* above); what was
   never decided is what the *offer* does with it. Fixed in android by a
   derived `Node.isUnheardOnCurrentLora` that excludes `viaMqtt`, so the
   badge, the filter and the offer cannot drift apart.

   **Shared contacts need no guard, contrary to the first read of this.**
   `addFromContact` marks a contact favourite to keep it off the eviction
   list, and the offer already exempts favourites. The two fallbacks that
   skip the favourite (role `CLIENT_BASE`, and the protected-cap refusal)
   call `stampContactHeardNow` instead, which sets `last_heard` but not the
   RF-hear bit - so a contact on a CLIENT_BASE can still be offered. Narrow
   enough to leave alone.
2. **The string is now wrong.** `node_not_heard_on_current_lora` =
   "Not heard since you changed settings". New semantics are "not heard on
   the LoRa settings you are on now" - which is not the same claim. Under
   the derived scheme you can change settings and have nodes stay marked
   (you came back to a slot), or change nothing and have a restored backup
   read unheard.
3. **Doc comments describe the sweep.** `Capabilities.kt:101`,
   `NodeEntity.kt:163`, `NodeInfoDao.kt:416`, `NodeItem.kt:464`.
4. **The proto comment is wrong in the contract itself.**
   `protobufs/meshtastic/mesh.proto:2085-2094` still says "Cleared for every
   node whenever the region ... changes" and "LSB 11 of the bitfield". Bit 11
   is now HAS_RF_HEAR and nothing is cleared. Comment-only, so not a wire
   break, but this is what every other client reads.

`Capabilities.supportsHeardOnCurrentLora` stays gated at `UNRELEASED` and
still needs the firmware release that carries #11811.

`meshtastic-node-kmp` needs nothing: its `AGENTS.md` mentions the field only
as the Wire all-args-constructor ABI example, not as tracked behaviour.

### Verified against source, not recalled

- `heard_on_current_lora` reaches the phone **only** in the want_config
  NodeInfo dump (`PhoneAPI.cpp:618` own node, `:1208` the rest). There is no
  live push, so android's Room column is a connect-time snapshot in both the
  old design and the new one.
- firmware `develop` (cccefa09a) populates the field nowhere. #11811 is the
  first implementation, so no shipped firmware has ever set it.
