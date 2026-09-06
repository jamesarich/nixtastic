# Heard-on-current-LoRa node bit - cross-repo umbrella

Status: in progress - protobufs merged (9a78479); android PR #7055 ready for merge; apple shipped an interim
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
| firmware | bitfield bit 11; set on hear, clear on slot change; mirror in `TypeConversions`; submodule bump | - | `bin/run-tests.sh` (native), bench flash | issue #11745 |
| device-ui | grey stale rows in the node list; zip pin bumped into firmware | - | native CMake/ctest, on-device TFT | issue #387 |
| android | `Capabilities` gate, marker, banner + removal offer, hide-unheard filter | `feat/unheard-on-current-lora` | full baseline green; CI 17/17 at 96742ad | **PR #7055** ready, 4 CodeRabbit rounds addressed |
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

Four CodeRabbit rounds, 14 findings, 13 fixed and 1 declined. The ones worth
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
- Declined: moving the 57->58 migration test to `androidHostTest`. Every
  existing (n-1)->n test lives in `jvmTest`; `.coderabbit.yaml:156` is stale.

Follow-up: Meshtastic-Android#7059, a regression test for the delayed-session
normalization race.

Ships on the `2.8.0.16-g9a78479-SNAPSHOT` pin; James confirmed snapshots are
fine to ship on.
