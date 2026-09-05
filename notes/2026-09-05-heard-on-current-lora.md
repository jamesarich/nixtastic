# Heard-on-current-LoRa node bit — cross-repo umbrella

Status: planned
Started: 2026-09-05

## Goal

After a LoRa preset, region or frequency-slot change, every client keeps
showing the nodes it knew before the change. Nothing marks them, so the node
list looks populated while every send into it fails — silently for channel
broadcasts, which have no ack. New users read the stale list as "the mesh is
here, the app is broken".

Origin: <https://redd.it/1w7y2st> (DragonCon event firmware, Atlanta on
MediumFast vs LongFast), raised by Jonathan.

Fix: firmware carries one bit per node — "heard since the current LoRa
config took effect" — cleared for every node when the config changes, set
whenever the node is heard. Clients grey out the unset ones and offer a
one-tap clear. The bit lives in firmware, not in a client, because MUI has
no phone at all, and because a phone-side heuristic misfires whenever the
preset is changed from the device UI or CLI while the phone is disconnected.

## Repos touched

| repo | change | branch / worktree | verification | landed (SHA or PR) |
| --- | --- | --- | --- | --- |
| protobufs | `NodeInfo.heard_on_current_lora` bool tag 15; `NodeInfoLite.bitfield` doc note | — | `buf lint` | |
| firmware | bitfield bit 11; set on hear, clear on slot change; mirror in `TypeConversions`; submodule bump | — | `bin/run-tests.sh` (native), bench flash | |
| device-ui | grey stale rows in the node list; zip pin bumped into firmware | — | on-device (TFT + OLED views) | |
| android | `Capabilities` gate, node-list marking, stale banner + one-tap clear | — | `nixtastic:android-baseline` | |
| apple | parity | — | repo's own gate | |
| design | cross-platform render rule; docs gap tracked as sub-issues | — | issue only | |

`meshtastic-sdk` and `meshtastic-python` are deliberately out of scope
(both are behind at protobufs v2.7.26; they pick the field up on their next
bump with no code change required).

## Contract changes

`NodeInfo` gains field 15, `bool heard_on_current_lora`. New field number,
nothing reused or deleted — satisfies the proto rule in
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

The obvious alternative — a device-level `lora_config_changed_at`, with
stale defined as `last_heard < changed_at` — is wrong on this firmware.
`NodeDB` treats `last_heard` as "a real epoch or 0" and routes nodes heard
while the clock is untrusted into a RAM sidecar
(`recordHeardWhileClockUntrusted`, backfilled by `backfillHeardAt()`). A
radio that changes preset before it has a time source writes a watermark of
0, and every pre-change node with a real timestamp then compares as fresh. A
bit is clock-independent and is correct on exactly the paths where the
timestamp scheme fails.

## Release order

1. `protobufs` — merge and tag. Firmware and apple bump submodules; android
   waits for the published `org.meshtastic:protobufs` artifact.
2. `firmware` — implement, release. `device-ui` lands first and is bumped in
   as a zip pin, so MUI is a two-step landing.
3. `android`, `apple` — bump the pin, implement the UI behind the capability
   gate.

`design` runs in parallel; it gates nothing.

## Open questions / unproven

- **Persistence.** `AdminModule::saveChanges` calls
  `MeshService::reloadConfig(saveWhat)` → `nodeDB->saveToDisk(saveWhat)`, and
  a LoRa config write passes `SEGMENT_CONFIG` (1), not `SEGMENT_NODEDATABASE`
  (16). The clear happens in RAM and the path then reboots, so as written the
  cleared bits are lost. The change must OR in `SEGMENT_NODEDATABASE` on the
  slot-affecting paths. Not yet verified on hardware.
- **Trigger coverage.** `AdminModule.cpp:1162` keys on `modem_preset` alone.
  The clear needs the full slot-affecting set: `region`, `use_preset` (or
  bandwidth/spread_factor/coding_rate when custom), `override_frequency`,
  `channel_num` — and a primary-channel rename in `handleSetChannel`
  (`AdminModule.cpp:1457`), because the slot is the channel name's hash.
- **Warm tier.** `WarmNodeStore` steals the low 7 bits of `last_heard` for
  role/protected/xeddsa-signed and explicitly restores the XEdDSA bit on
  re-admission, because it is "learned from verified traffic, not from
  NodeInfo" — the same class of fact as this bit. Bit 7 of that stolen field
  is free (`WARM_META_BITS` 7 → 8 coarsens LRU recency from 128 s to 256 s).
  Cheaper alternative: carry nothing, let re-admission default the bit to 0
  and let the normal set-site set it if the re-admission was an actual RF
  hear. Needs checking that re-admission is always hear-driven.
- **Field sense.** `not_heard_on_current_lora` would make proto3's false
  default safe against old firmware with no capability gate, at the cost of a
  negative-sense bool and an inversion between the firmware bit and the wire.
  Recommended: keep positive sense, gate on `Capabilities`.
- **Upgrade wave.** Nodes predating the firmware upgrade have bit=0 and read
  stale until heard again. Either set the bit for all nodes in the NodeDB
  version migration, or accept a one-time wave.

## Out of scope, worth recording

Two claims from the Reddit thread that are wrong, checked against the code:

- "Mesh Discovery recommends by SNR" — no. `DiscoverySummaryGenerator.kt:36`
  ranks by `uniqueNodes` descending, then channel utilization ascending.
- "Sending fails silently" — half right. DMs surface `MAX_RETRANSMIT`
  (`Message.kt:90`). Channel broadcasts have no ack, so those are silent.

Discovery being slow and buried is a separate usability item.
