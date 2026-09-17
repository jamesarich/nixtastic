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

So the first move is not code, it is the pin - a new protobufs release, or
consuming a `-SNAPSHOT` as [[protobufs-tags-lockstep-with-firmware]] describes.
That is a cross-repo decision: `firmware` and `meshtastic-python` vendor the
submodule, `android` and `TAKPacket-SDK` take the published artifact.

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
