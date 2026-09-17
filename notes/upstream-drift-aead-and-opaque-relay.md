# Two upstream changes node-kmp must answer

Checked 2026-09-16 against `origin/develop` at `67e8aafef`, which the BLE spike is
**108 commits behind**. Both land squarely on contracts node-kmp implements.

## 1. AEAD channels - node-kmp cannot see them at all

`d05fbec64` "Add AEAD (AES-CCM) authenticated encryption for PSK channels"
(#9749, merged 2026-09-14) adds an opt-in `use_aead` flag to `ChannelSettings`
(bool, tag 8). On such a channel a 12-byte auth tag is appended and, per the
commit, forgery, bit-flipping and injection by anyone without the PSK are
prevented.

**The channel hash changes:**

```cpp
// Differentiate AEAD channels in routing so AEAD and non-AEAD
// channels with the same PSK have different hashes
if (ch.has_settings && ch.settings.use_aead)
    h ^= 0xAE;
```

node-kmp's `MeshChannel.hash` is the pre-AEAD `Channels::getHash` - XOR of the
name bytes and key bytes, `and 0xFF`, with no `^= 0xAE`. So against an AEAD
channel it computes a hash 0xAE away from firmware's, `matching(hash)` returns
null, and **every packet on that channel is unmatched before decryption is even
attempted**. It would read as an unknown channel, not as a crypto failure.

Three things are missing, in the order they bite:

1. **the hash differentiation** - one XOR, and without it nothing else matters;
2. **AES-CCM encrypt/decrypt** - node-kmp does AES-CTR only, so it cannot open an
   AEAD packet or verify its tag;
3. **the `use_aead` field** - node-kmp pins `org.meshtastic:protobufs` 2.8.0, which
   predates the flag, so a channel imported from a URL or `AdminService` loses it
   silently.

### It is worse than "cannot read", and it is blocked on a release

The proto's own comment raises the stakes:

```proto
/* ... this enabled - unauthenticated (AES-CTR) packets are rejected.
 * Experimental. Default: false (standard AES-CTR encryption). */
bool use_aead = 8;
```

So on an AEAD channel a node-kmp node would not merely fail to read: **its own
AES-CTR transmissions are rejected by every firmware node on that channel.** It
would be mute and deaf at once, and the hash mismatch means it would not even
report a crypto failure.

**Nothing can be fixed yet.** `use_aead` landed in `protobufs` on 2026-09-10
(`826908b`, "Settle the open schema questions") and **no tag contains it** - the
newest release is `v2.8.0`, ten days older. node-kmp pins the published
`org.meshtastic:protobufs` 2.8.0, and the field is simply not in that artifact:
`ChannelSettings` there carries name, channel_num, uplink/downlink,
module_settings and psk.

### The snapshot path is proven, and the default pin should not move

`2.8.0.55-g072c607-SNAPSHOT` is built from `072c607`, the exact protobufs commit
firmware's develop pins, and it carries the field. Verified 2026-09-16:

```
+--- org.meshtastic:protobufs:2.8.0.55-g072c607-SNAPSHOT
protobufs-jvm-2.8.0.55-g072c607-SNAPSHOT.jar -> ChannelSettings: use_aead, getUse_aead
```

`:node-core:compileKotlinJvm` builds against it. So the work is unblocked the
moment it is wanted:

    gradle -PprotobufsVersion=2.8.0.55-g072c607-SNAPSHOT <task>

**The catalog default should stay 2.8.0**, and `AGENTS.md` says why: the snapshot
repository is added only for such a build "so the default track cannot drift onto
an unreleased proto", and *"the pin bump is where parity is reviewed… an escape
hatch for an app that runs ahead of a release, not a second supported line."*
Moving the default would also bypass `meshtastic.coordinates`, which publishes a
snapshot-proto build at `0.1.0-pb<version>-SNAPSHOT` precisely so two
non-interchangeable tracks cannot share a coordinate.

So AEAD support can be written and tested against the snapshot today; it lands on
the default track when protobufs cuts a release carrying `use_aead`, which no tag
does yet.

Tempering it: the field is marked **Experimental** and defaults to false, so this
is a contract still moving, not one node-kmp is behind on.

## 2. CORE_PORTNUMS_ONLY must now relay opaque frames

`ee7611783` "relay opaque packets in CORE_PORTNUMS_ONLY" (#11844) reverses what
node-kmp encodes, and node-kmp's comment asserts the old behaviour as parity:

```kotlin
// [RebroadcastMode.CORE_PORTNUMS_ONLY]: only decodable [CORE_PORTNUMS] traffic; an opaque
// frame carries no portnum and is not relayed, as firmware relays opaque only under ALL.
RebroadcastMode.CORE_PORTNUMS_ONLY -> relayPortnum != null && relayPortnum in CORE_PORTNUMS
```

Upstream's reasoning: a PKI unicast between two other nodes - remote admin, a DM,
key verification - is opaque to a relay, so a ROUTER (whose default is
`CORE_PORTNUMS_ONLY`) had stopped carrying any of it. Their new test says it
plainly: `"CORE_PORTNUMS_ONLY must relay an opaque frame"`. `KNOWN_ONLY` and
`LOCAL_ONLY` also regain the 2024 rule relaying a PKI-shaped unicast with one
known party.

This one is live: a node-kmp node in `CORE_PORTNUMS_ONLY` silently drops PKI
unicast a firmware router would carry. Small fix, and the comment claiming parity
has to go with it.

## What this means for the implicit-ack spoof guard

See [`gatt-implicit-ack-vs-spoof-guard.md`](./gatt-implicit-ack-vs-spoof-guard.md).
Upstream has since made the position there sharper, not looser:

- `Router.cpp` already refuses forged senders on exactly this path -
  *"isFromUs stays REJECT to keep forged senders off the ACK path"* - so option 3
  (admit the echo to the ack path only) is the very case upstream rejects.
- The blast radius is concrete: `Router.cpp:598` gates the **MQTT uplink** on
  `isFromUs(p)`, so a packet forged with our node number that reached the Router
  decoded would be published to the broker under our identity.

On an AEAD channel a forgery cannot decrypt, so the guard could in principle be
narrowed there. AEAD is off by default, so that buys nothing yet.

**Recommendation: leave the guard alone** - option 1, not option 3. The cost is a
retransmit a LoRa-adjacent node would have retired; the alternative is the attack
upstream is explicitly defending.

## 3. The rest of the `v2.8.0` → master delta, swept 2026-09-17

Re-swept against `protobufs` master `a5ecf64` and `firmware` develop `a4e8b9444`.
Two findings frame everything below.

**Firmware behaviour has not moved.** Five commits since the audit checkpoint
`67e8aafef`, one of them in scope, and it is a flash-reclamation pass for rak4631
- an nRF52 AES implementation swap, two `unordered_map` → `map` changes, and
deleted log sites. `Channels.cpp` has a zero diff. Packet framing, dedup, hop and
relay fields, ack semantics, the contention window and the phone-API handshake are
all untouched. **AEAD remains the whole of the behavioural delta.** The `id == 0`
divergence is exactly where it was: firmware still never dedups id 0 and still
refuses to relay it, and node-kmp still dedups it.

**No tag carries any of this.** `v2.8.0` is still the newest, so every item here
means a `develop-SNAPSHOT`, not a version bump. The pin has nowhere to move.

Additions that need an answer, worst first:

- **`Routing.ack_proof = 4`** (`072c607`, 2026-09-16) - an HMAC-SHA256 truncated
  to 8 bytes over `"ack" ‖ LE32(from) ‖ LE32(to) ‖ LE32(request_id) ‖ routing`,
  where `routing` is the encoded message *without* field 4. It exists because
  channel traffic is AES-CTR with no integrity check, so any PSK holder can forge
  an ack and a bit-flip can turn a success into a failure - the same reasoning
  behind AEAD, applied to acks. **The receive path is already safe**:
  `unknownErrorReason` scans `unknownFields` for the `error_reason` tag rather
  than testing for emptiness, precisely so an ack that grew an unrelated field is
  not misread as a NAK. Do not regress that into an emptiness test. Two traps if
  we ever emit one: encode the message *without* the field rather than zeroing it,
  and truncate to 8 bytes - nanopb halts on a bytes overflow rather than
  truncating, so 9 bytes destroys the whole `Routing` decode and the ack vanishes.
- **`NodeInfo.heard_on_current_lora = 15`** (`9a78479`, 2026-09-05, bit 11 of
  `NodeInfoLite.bitfield`) - presence-vs-sentinel-zero. A library that never sets
  it reports `false` for every node, and an app filtering on it hides everything
  we source. The clear-set is pure Tier 1 state: region, modem preset (or custom
  BW/SF/CR when `use_preset` is false), `override_frequency`, `channel_num`, and
  the **primary channel name**, because the frequency slot derives from it.
  Open question rather than an answer: what "heard on current LoRa" means for a
  node whose bearers are BLE, MQTT and UDP and which may have no radio at all.
  The field excludes MQTT-heard nodes for a reason that generalises awkwardly.
- **`PortNum.PAGING_APP = 38`** (`2fd5a0a`, 2026-09-02) - not a decode gap but a
  *guard* bug, and the guard is ours. Filed as node-kmp #8.
- **`StoreAndForward.original_id = 6`** - Tier 2, no S&F implementation here.
- Tier 3, noted only so a pin bump does not re-derive them: `SoilWaterMetrics`
  (new message, `Telemetry.variant = 11`), `lorawan_bridge.proto` (which
  *replaces* the hand-rolled payload format of the existing `LORAWAN_BRIDGE = 75`
  portnum - a silent reinterpretation, not an addition), `field_metadata.proto`
  (build-time options, stripped by every runtime, no wire surface), two
  `HardwareModel`s, two `Language`s, two `Audio_Baud`s, and
  `HostMetrics.user_string`'s nanopb cap shrinking 200 → 161.

**Five existing messages grew a field** - `ChannelSettings`, `Routing`,
`NodeInfo`, `StoreAndForward`, `Telemetry.variant`. Each moves Wire's all-args
constructor signature, which is the `NoSuchMethodError` trap in
[`wire-builders-only-migration.md`](./wire-builders-only-migration.md). It does
not bite node-kmp today, but it constrains when the pin can move.

One thing to correct if it is repeated: the AEAD channel hash **does** change.
Firmware `Channels::generateHash` XORs in `0xAE` for a `use_aead` channel, so an
AEAD peer and a CTR node on the same name and PSK compute *different* hashes -
the failure is an unmatched channel, not a matched one that decrypts to garbage.
Reading the proto alone suggests otherwise, because `use_aead` is not part of
channel identity in the schema.
