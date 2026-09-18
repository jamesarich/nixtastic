# node-kmp: filling the gaps, in order

Written 2026-09-17 after a parity and transport survey of `main` at `97e534f`,
with the "proven on hardware" claims re-checked against session transcripts and
live hardware. Supersedes the *What I would do next* list in
[`node-kmp-audit-2026-09-16.md`](./node-kmp-audit-2026-09-16.md), whose six items
are now closed or carried below.

**Worked the same day.** Merged: 1 (#16), 2 (#17), 4 (#19), 5 (#18), 7 (#20), plus
the forgery fix (#14). Item 3 - parity coverage for the messages the harness does
not reflect over - is the remaining tier-1 piece. Tier 4 and tier 5 stand.

Ordering principle: **one structural fix outranks four point fixes**, because the
point fixes keep coming back. Most of tier 0 and tier 2 are symptoms of the same
missing test.

## Tier 0 - the bug that is live now

**1. `set_channel` drops `use_aead` (#15).** Mine, from #12. A client that turns
AEAD on gets an ack and reads back `false`; a backup of an AEAD channel does not
survive a restore; the URL path and the admin path now disagree. Fix is two arms
of `AdminService.resolveChannels` plus `withAeadResolved()`.

First because it is small, it is a real defect in shipped behaviour, and its test
is the seed of tier 1.

## Tier 1 - the structural fix, which is the actual answer

**2. Extend the parity harness to the *written* node.** Both parity tests build
two fresh `LocalRadio`s and never write to them. `LocalRadio.configs()` substitutes
only 8 fields back from live state, so after a `set_config`:

- the other 12 `lora` NODE fields - `tx_power`, `modem_preset`, `bandwidth`,
  `spread_factor`, `coding_rate`, `use_preset`, `tx_enabled`, `channel_num`,
  `override_frequency`, `override_duty_cycle`, `frequency_offset`,
  `sx126x_rx_boosted_gain` - read back **as the phone wrote them**, wearing a
  `NODE` label, while the bearer is untouched;
- `security.public_key` reads back whatever the phone wrote, so an app can be
  shown a key that is not the node's;
- every `CONSTANT` in device/power/display/bluetooth/device_ui becomes an echo.

The harness's whole value is failing on a claim the code does not honour.
Certifying only the unwritten node is the blind spot that let #15 through and
leaves 12 mislabelled LoRa fields standing. **This is what stops the list
regrowing.** Expect it to fail loudly on first run; that is the point.

**3. Extend it to the messages it does not reflect over at all.** It covers
`Config` and `ModuleConfig`. Uncovered and reported to every client:
`ChannelSettings` (the #15 class), `MyNodeInfo`, `DeviceMetadata`, `NodeInfo`,
`User`, `LocalStats`, `QueueStatus`, `DeviceConnectionStatus`.

Land 2 and 3 together if they fit; 2 first if not.

## Tier 2 - honesty fixes, small and high value

**4. `security.packet_signature_policy` is `ECHOED` wearing `ENFORCED`.**
`AdminService.applyConfig` reads `security` only for authorisation and never
pushes the policy; the host sets it on `MeshNode`'s builder. A client that writes
`STRICT` reads `STRICT` back while the node keeps the host's policy, and with the
section unwritten it cannot read the truth either. **Decide**: wire `applyConfig`
to push it, or relabel and say in the dump that the host owns it. Mislabelling a
security field is worse than the gap, and `ENFORCED` is the one label with no
mechanical check behind it.

**5. The README is wrong about iOS BLE in three places.**
`ExtendedAdvertising.ios.kt` sets `receivesExtendedAdvertisements = false`,
measured twice (219 legacy advertisements against 0 extended). The bearer table
lists Apple under advertisement *In*, the module table says "receive everywhere",
and the monitor row claims iOS BLE-adv. *Not yet here* covers Apple **transmit**
and never says iOS cannot receive. Also: a JVM off Linux gets
`UnsupportedBleMeshRadio` - `emptyFlow()` - so desktop macOS and Windows hear
nothing either, and the bearer table contradicts the module table on GATT against
firmware.

**6. Grade the hardware claims by their evidence.** Verified against transcripts:
udp, lora, gatt and ble-adv on Linux are backed by tool output on `james-pc`.
Three rest on earlier prose with no bench output behind them - `Linux↔firmware`
GATT *against a WisMesh Pocket* specifically, `Pixel ↔ Heltec V3`, and BLE-adv
transmit from Android. The capabilities survive (GATT against a RAK4631 is
proven); those sentences should be marked unre-run.

## Tier 3 - real parity gaps, each needing a decision first

**7. Licensed mode is half-built.** Signing honours `licensed`, but firmware
reaches plaintext by *stripping the keys*: `Channels::ensureLicensedOperation`
clears every PSK and disables the admin channel, and `ensurePkiKeys` refuses to
generate PKI keys. We have no equivalent, so a host setting `Config.licensed =
true` gets a node that signs **and still encrypts** - the opposite of the
regulatory point of ham mode. Via the phone API it is deliberately declined and
documented, so the blast radius is a host setting it in code. **Decide**:
implement `ensureLicensedOperation`, or refuse `licensed = true` at construction
until it exists.

**8. `Routing.ack_proof` - do not emit yet; the receive side is already safe.**
Keep `unknownErrorReason`'s tag scan as it is. Emitting needs a pairwise key
channel traffic does not have, the HMAC is over the encoded `Routing` *without*
field 4, and nanopb **halts** on a bytes overflow rather than truncating, so 9
bytes destroys the whole decode and the ack vanishes.

**9. `NodeInfo.heard_on_current_lora` - settle the semantics first.** Its clear-set
is pure Tier 1 state (region, preset or custom BW/SF/CR, `override_frequency`,
`channel_num`, primary channel name). But it excludes MQTT-heard nodes as "not
over our own radio", and this library's bearers are BLE, GATT, UDP, MQTT and
Wi-Fi Aware, with LoRa often absent. What it means for a radio-less node is a
contract question, not a pin-bump guess.

## Tier 4 - test coverage that does not exist

**10. Bearer/platform pairs with no live test of any kind:** LoRa on JVM (any OS),
UDP on Android, every iOS pair (`node-transport-ble-gatt` has no Apple test source
set), the macOS desktop bridge (`node-desktop-ble-macos` has only a wire unit
test), MQTT off JVM.

**11. Kotlin/Native has no assumption API**, so an unarmed native hardware test
prints `skipped:` and passes. A green macOS-native run proves nothing unless
`MESH_LIVE_REQUIRED=1` is set - worth setting in whatever drives the bench.

## Tier 5 - James's calls, unchanged

**12. The on-air advertisement format**, the real blocker on going public:
manufacturer data under company ID `0xFFFF` is the only format Android, BlueZ and
Windows can all transmit; service data would cost transmit on two platforms and
buy nothing - iOS hears no extended advertisement whatever the AD type (corrected
2026-09-18; the earlier "buys iOS background receive" was false). The open call
is the identifier replacing the test value `0xFFFF`, which has to change in the
firmware's `BLEMeshHandler.h` and here together. Changing it later breaks every
deployed node.

**13. CI stays off while the repo is private** - PR #4 is written and waiting.
**14. Publishing**: declare a remote, and take the naming calls - the `-kmp`
suffix, `node-*` as a peer of `sdk-*`, `curve25519` under `org.meshtastic`, and
the missing BOM, which matters here because Gradle resolving two protobufs pins to
the higher one is exactly the broken combination.
**15. Restore the protobufs pin to a tag** the day one is cut, and make the
snapshot repository conditional again in the same change.

## What I would actually do next

1 → 2 → 5 → 4. One live bug, then the test that would have caught it, then the
doc that misleads an outside reader, then the security label. Tier 3 waits on a
decision rather than on effort.
