# Feature review - multi-transport mesh (2026-09-06)

Adversarial review of the **whole feature**: `meshtastic-node-kmp` (9 modules, ~27k lines), the
`firmware` spike at `spike/ble-mesh-transport`, the `protobufs` spike branch, and the docs in
both repos. 14 reviewers, one per dimension, each told to distrust the commit messages and the
repo prose and read the source. Every finding then went to a separate agent told to **refute it
by default**. 131 findings raised.

## Read this before acting on any of it

- **79 verified and survived, 0 refuted.** A zero refutation rate is not a clean bill of health
  for the review - it is a reason to treat the severities as unaudited. The verifiers did push
  back on content (several highs were corrected down, and one headline claim was shown to be
  vacuous for the shipped app) but threw nothing out entirely.
- **All 131 now have a verdict.** 52 were unverified on the first pass, when those agents hit the
  session limit. They were re-run in two waves on 2026-09-06 and all 52 came back: those waves
  refuted 5 of 39 and moved a good number of severities down, which is the sanity check the first
  pass never got. Treat the original 79 as the softer set.
- Spot-checked by hand, all held: `pumpRetransmits` has exactly one call site;
  `RetransmitQueue.pending` is a bare `LinkedHashMap` with no lock anywhere in `MeshNode`;
  `MeshChannel.hash` XORs the raw name with no modem-preset substitution; the BLE-advertisement
  bearer does supply an RSSI on all three platforms.

## Fixed so far

`meshtastic-node-kmp`, in order. Every one gated, and every new assertion
mutation-checked - reverted the fix, watched the test fail, put it back.

- **`77f0e3b`** Three the review caught, two of them mine from the day before: `AGENTS.md` claimed
  no bearer supplies an RSSI (the advertisement bearer does, on all three platforms; only GATT
  leaves it null); the monitor's freshness clock stopped advancing as soon as anything was logged;
  both platform entry points did `stop()` then `start()`, bypassing the join `restart()` exists for.
- **`d254e27`** Reliable delivery now works on the mesh it exists for. `pumpRetransmits` had one call
  site, in the receive pipeline, so a node hearing nothing never retried and never reported failure.
  There is a timer now, parked on a conflated channel while the queue is empty. `RetransmitQueue`
  claimed single-writer serialisation that does not exist and is mutex-guarded.
- **`960be7d`**, **`58745b3`** The phone API stops being an open write interface. Binds loopback by
  default (the monitor opts into every interface explicitly, and says UNAUTHENTICATED when it does);
  runs under its own SupervisorJob so a bad connection cannot cancel the node's scope; reads with a
  timeout so a silent client cannot wedge the accept loop; and the config dump backpressures instead
  of dropping its own head. Delivery receipts reach the phone as ROUTING_APP packets, so a message
  finally resolves instead of sitting at "Sending...".
- **`2fbfa48`** Wall time and uptime are not the same clock. `Config.epochSeconds` is separate from
  the monotonic `clock`, `rx_time` is 0 rather than a relative number when no wall clock is supplied,
  and a peer's `last_heard` is aged against the node rather than read as an epoch.
- **`110358b`** A region that cannot carry a preset no longer transmits it anyway. `supportsPreset`
  existed and was called by nothing; EU_868 with a turbo preset emitted half its channel outside the
  sub-band.
- **`6ae7f4c`** The relay policy is a ceiling, not a fallback, so a stock phone can no longer defeat
  `RelayPolicy.Island`; and a packet addressed to this node - every local AdminMessage from a stock
  app - is refused rather than sealed with the channel PSK and broadcast to the mesh.
- **`a170ca2`** A blank channel name is not blank on the air: it resolves to the modem preset name,
  as `Channels::getName` does, so a channel imported from a shared URL computes the hash every radio
  computes.

- **`b6bb03d`** A relayed packet gets this node's route, and a dead route is forgotten.
  `forForwarding` left the previous hop's `next_hop` on the wire, so a directed packet died one hop
  past this node; `NextHopTable.forget` existed and was called by nothing, so a neighbour that moved
  out of range was black-holed for the life of the process. Also the Android BLE-advertisement
  `send()`, which passed an empty callback and returned a hard-coded true.
- **`f4dd00a`** A duty cycle you can reset by tapping a chip is not a duty cycle. The rolling-hour
  ledger was per-transport, and the monitor rebuilds transports on every tuning change; it is
  injectable now and the monitor holds one for the life of the process, as the firmware does.
- **`6b1a7cf`** `NodeDirectory`'s key rule is not a pin, and now says so. The scope of "first valid
  key wins" is one process; `Config.peerPublicKey` is the durable mechanism and is consulted ahead
  of the directory.

**All 18 high-severity findings are now addressed** - 17 by code, one (`6b1a7cf`) by correcting a
claim rather than pretending the in-memory rule is a pin. What remains below is medium and low.

## The big ones

Ordered by what would bite a user first, not by dimension.

1. **The phone API is an unauthenticated write interface on every network interface.**
   `PhoneApiTcpServer` uses the one-arg `ServerSocket(port)` ctor, so tcp/4403 binds the
   wildcard address on every desktop node start, with no pairing, no token, no bind-address
   option and no opt-in. Anyone who can reach it gets the config dump, the live packet stream,
   and write access - inject as this node's NodeNum out over LoRa, UDP, BLE and MQTT. A bare TCP
   connect also evicts the legitimate client, repeatedly. The verifier downgraded the PSK
   headline: the monitor's only channel is the hardcoded public LongFast default, so no secret
   leaks *today*, but a consumer configuring a private PSK would leak it.
2. **Reliable delivery does not retry on a quiet mesh.** `pumpRetransmits()` is called from
   exactly one place, inside the receive pipeline. A node that hears nothing never fires attempts
   2..5 and never reports failure - so the feature works precisely when it is least needed.
3. **Neither ACK nor NAK reaches an attached phone.** `PhoneApiSession` subscribes to
   `node.packets` and never to `node.events`, so nothing turns `Delivered` / `DeliveryFailed`
   into a ROUTING_APP `FromRadio`. Every message a stock app sends through the node sits at
   "Sending..." and ends as "Failed to deliver to mesh" - the exact symptom reliable delivery
   was built to fix.
4. **Every timestamp handed to the phone comes from a since-app-start monotonic clock.** `rx_time`
   and peer `last_heard` are stamped from it, so a stock Android app renders messages and peers
   in 1970 and sorts them before everything else.
5. **A stock phone defeats `RelayPolicy.Island`.** `sendPacket` treats the policy as a fallback
   for a zero `hop_limit`, never a ceiling, and the Android app stamps its own default of 3.
6. **LoRa region/preset compatibility is never enforced.** `LoraRegion.supportsPreset` exists,
   is tested, and is called by nothing. EU_868 with a 500 kHz turbo preset emits half its channel
   outside the sub-band. Separately, the rolling-hour duty-cycle ledger is destroyed on every
   dashboard edit, so the duty cycle is unenforceable in practice.
7. **`RetransmitQueue.pending` is a bare `LinkedHashMap`** whose KDoc claims single-writer
   serialisation that does not exist - the phone-API path mutates it from `Dispatchers.IO` while
   the node mutates it from its own scope.
8. **Peer public-key pins do not survive a restart**, so the anti-substitution rule
   `NodeDirectory.mergeKey` documents is re-raced on every launch.


## Firmware spike - now verified (2026-09-06)

The 13 firmware findings were re-verified against `spike/ble-mesh-transport` (head `ca0a39c51`),
read via `git show` only - the branch is checked out in another worktree and `.pio` is shared.
Each verifier was told to refute by default and to say whether a defect is the spike's or
pre-existing on develop.

**11 confirmed, 2 refuted.** The severities moved: four claimed highs came back medium, one low
came back medium, and one high stood. That is a healthier spread than the first pass, which
refuted nothing.

### The one that stayed high, and what it blocks

**The spike is not inert on ESP32 with the feature disabled** (`variants/esp32s3/esp32s3.ini`,
`variants/esp32c3/esp32c3.ini`).

`[ble_mesh_esp32]` in `variants/esp32/esp32-common.ini` documents itself as opt-in, and the commit
that introduced it (`4c5863c09`) is titled "Factor the ESP32 BLE mesh build settings into one
opt-in block". But it is referenced from `[esp32s3_base]` and `[esp32c3_base]` - the sections
every S3 and C3 variant extends - with no condition. Intent was opt-in; the wiring is not.

The runtime gate does not save it. `NimbleBluetooth.cpp` wraps `startAdvertising()` in
`#if BLE_MESH_USE_EXT_ADV`, and that flag is now unconditionally 1 on S3/C3, so the legacy
advertising branch is dead code on **every** S3/C3 build and the phone advertisement runs the
spike's hand-rolled extended-advertising path - including a `Rob<>` explicit-instantiation hack
that reaches a private member of `BLEServer`. The block also rewrites `custom_sdkconfig`, which is
the shared-framework-sdkconfig trap the workspace `CLAUDE.md` warns about.

**Consequence for the pending work:** the handoff's next step 2 is a develop PR carrying the
1M-PHY fix. Anything cut from this branch carries this too unless the reference is made
conditional first. That PR should not go up until it is.

### Confirmed, by verified severity

**[medium] (claimed high) BLE ingress does not sanitise `priority`, letting a radio-range attacker evict genuine packets from the LoRa TX queue**

`src/mesh/BLEMeshHandler.cpp`

BLE-advertisement ingress does not reset `priority`, handing an RF-range attacker a LoRa TX-queue eviction primitive (medium; only when `enabled_protocols` opts into BLE_BROADCAST).

**[medium] (claimed high) `clearCorruptBondStoreOnce()` erases the NimBLE bond database on every ESP32 build, feature enabled or not**

`src/nimble/NimbleBluetooth.cpp`

`clearCorruptBondStoreOnce()` (new in the spike, src/nimble/NimbleBluetooth.cpp:1098) erases the entire NimBLE `nimble_bond` NVS namespace once per device on the first boot of any ESP32 build from this branch. It is called as the first statement of `NimbleBluetooth::setup()` guarded only by `#ifdef ARCH_ESP32` - no enabled_protocols check and no BLE-mesh build flag - so it is not inert when the feature is off. It is one-shot, not per-boot: the `nimbleBondClr` bool in the `meshtastic` Preferences namespace latches it, which means it fires exactly once for every upgrading ESP32 BLE user. The `BLE_MESH_CLEAR_BONDS_ALWAYS` force path is dead code; nothing on the branch defines that macro. The wi

**[medium] (claimed high) NO_PIN pairing mode silently stops offering bonding on every ESP32 build**

`src/nimble/NimbleBluetooth.cpp`

Unguarded security-config change in `NimbleBluetooth::setup()` (src/nimble/NimbleBluetooth.cpp, the NO_PIN `else` branch). develop has `security.setAuthenticationMode(true, false, false)`; the spike changes it to `security.setAuthenticationMode(false, false, false)`. The statement sits in plain `else` with no `#if HAS_BLE_GATT_MESH`, no `BLE_MESH_USE_EXT_ADV`, and no `enabled_protocols` check, in a file every ESP32 build compiles - so it applies whether or not the BLE-mesh feature is enabled.

**[medium] (claimed high) Unbounded, unauthenticated BLE-adv ingress against a drop-oldest receive queue**

`src/mesh/BLEMeshHandler.cpp`

Unbounded, unauthenticated BLE-adv ingress into a shared 4-deep drop-oldest receive queue - real, but the admission control belongs at the shared transport boundary, not in BLEMeshHandler, because develop's UDP bearer has the identical hole.

**[medium] ESP32 phone-API session handle can be stranded on a freed connection when a mesh-peer link drops**

`src/nimble/NimbleBluetooth.cpp`

Corrected mechanism: the phone-API session is NOT keyed on a handle shared with mesh-peer links (each link has its own conn handle, and `nimbleBluetoothConnHandle` is latched only in `onAuthenticationComplete` on an encrypted link, NimbleBluetooth.cpp:719). The real defect is the discriminator: `NimbleBluetoothServerCallback::onDisconnect` (NimbleBluetooth.cpp:797-806) decides "is this the phone's session ending?" from `ESP32BLEGattMesh::onDisconnect()`'s return value, which is `Link::viaMeshAdv` - set only in `ESP32BLEGattMesh::onGapEvent` BLE_GAP_EVENT_CONNECT (ESP32BLEGattMesh.cpp:402), i.e. it means exactly "arrived on advertising instance 2". Neither advertising set is reserved for a ro

**[medium] nRF52 GATT egress can block the main task for seconds inside one runOnce**

`src/mesh/BLEGattMeshHandler.cpp`

nRF52 GATT egress: a stalled-but-connected peer occupies the main task for seconds per packet

**[medium] ESP32 BLE mesh re-enters ble_gap_* from inside a GAP callback, which the spike's own GATT code says crashes**

`src/platform/esp32/ESP32BLEMesh.cpp`

ESP32 BLE mesh restarts scanning from inside the NimBLE GAP callback, and the only path that reaches that branch is a host reset - so it both re-enters ble_gap_* in the window the repo documents as unsafe and fails to actually restore RX.

**[medium] (claimed low) BLEMeshHandler's thread-safety comment asserts the packet pool is safe from other tasks; it is not**

`src/mesh/BLEMeshHandler.h`

The comment is wrong about the packet pool, but not for the reason filed. It does NOT claim "only one task touches the pool" - it explicitly acknowledges the BLE callbacks run on another task, and confines the no-lock argument to the TX ring. The false clause is the parenthetical safety assertion:

**[low] (claimed medium) nRF52: every mesh advertising burst restarts the phone advertisement in fast mode, pinning it there**

`src/platform/nrf52/NRF52BLEMesh.cpp`

In the shared-advertising-set fallback - the only path actually reachable on nRF52, since Bluefruit already owns set 0 and its default configuration (and S140 v6) allows only one set, which the spike's own header comment concedes - NRF52BLEMesh::platformEndAdvertising() hands set 0 back by calling nrf52Bluetooth->resumeAdvertising(). BLEMeshHandler::runOnce() calls platformEndAdvertising() once per burst, and resumeAdvertising() does setInterval(32, 668) + setFastTimeout(30) + start(0), so every burst re-arms a fresh 30 s fast phase at a 20 ms interval. Two failure paths in platformBeginAdvertising() call it as well. Bursts arriving less than 30 s apart therefore keep the phone advertisement

**[low] Raising BLE_GATT_MESH_MAX_LINKS as the header instructs silently gives a third peer that receives nothing**

`src/platform/esp32/ESP32BLEGattMesh.h`

Confirmed, with a sharper mechanism and a corrected threshold.

### Refuted

- **BLE-adv transport is permanently dead after a BLE deinit/re-enable cycle on ESP32** (`src/mesh/BLEMeshHandler.h`, claimed medium) - The cited code facts are real, but the stated failure scenario is unreachable, so the finding as written is refuted and its severity is wrong.
- **nRF52 GATT mesh re-arms fast advertising on every connect and every disconnect, including the phone's** (`src/platform/nrf52/NRF52BLEGattMesh.cpp`, claimed medium) - Read src/platform/nrf52/NRF52BLEGattMesh.cpp on spike/ble-mesh-transport plus the Bluefruit sources it depends on (~/.platformio/packages/framework-arduinoadafruitnrf52/.../BLEAdvertising.cpp, Bluefruit.cpp).


## The remaining 26 - now verified (2026-09-06)

Read against HEAD, each verifier told to refute by default and to say whether the earlier fix
batch had already closed it.

**19 still open, 4 already fixed, 3 refuted.** Severities moved again: several mediums came back
low. With this wave every one of the 131 findings has a verdict.

The 4 it independently confirmed were already fixed: the diagram's freshness clock, both platform
entry points' stop-then-start, the malformed DM address, and MeshNode's unvalidated primary
constructor.

### Refuted

- **An MQTT loop-prevention test that needs no broker is gated behind the broker env var** (claimed low) - Read at HEAD (bc7b7e0); the file is untouched since 6d33342 "Drive the MQTT bridge against a real broker", so nothing was fixed in the batch.
- **NodeDirectory hands out its stored public keys by reference, so the never-replace rule is bypassable** (claimed low) - Read NodeDirectory.kt at HEAD (bc7b7e0). The factual half of the finding is true: `mergeKey` (line ~127) stores `valid` without copying, and `publicKeyOf` (line 72), `get`, `all` and the `peers` State
- **LocalRadio.nodeNum is a public Int, truncating the upper half of the NodeNum space** (claimed low) - Read at HEAD (bc7b7e0). node-phone-api/src/commonMain/kotlin/org/meshtastic/node/phoneapi/LocalRadio.kt:46 still reads `public val nodeNum: Int get() = node.identity.nodeNum.toInt()`, so nothing was c

### Fixed from this wave

- [medium] ReliableNodeTest's UDP self-echo test asserts before the node's collector has run
- [medium] RelayOnAirTest cannot fail: a relay that forwarded nothing reports green
- [medium] PeerRow.lastHeardMs is the time of the peer's last NodeInfo, not the last time it was heard
- [medium] Send test with an empty box crashes when the identity has not loaded or failed to load
- [medium] Unticking the LoRa bearer makes it permanently un-tickable and blames a stick that is plugged in
- [medium] Config.channels/transports are public MutableLists read live, not snapshotted as the KDoc claims
- [low] LoraTransport never overrides MeshTransport.receiveOnly, so a permanently listen-only LoRa bearer is not shown as one
- [low] Three build files say Spotless's ktlint reads .editorconfig; the same build file and AGENTS.md say it does not
- [low] node-core's build file says it has no platform source sets; it has three
- [low] Two files call ok_to_mqtt the bitfield's only defined use; firmware defines and uses a second bit
- [low] A tracked API dump describes a constructor that no longer exists and apiCheck never validates it
- [low] Build-file comment claims withHostTest verifies Android's runtime; it runs on the host JVM

### Still open

None. All 19 were fixed across `1a23f41`, `a105afb` and `7cfe055`, with the last
group being reporting accuracy - the rx counter, the `tx?` sample, diagram label
clipping, the Android permission split, the desktop LoRa gate, two modules missing
from `testAndroidHostTest`, and the config dump running two Configs and four
ModuleConfigs short of the firmware's.

Every one of the 131 findings now has a verdict, and every confirmed high, medium
and low from the two re-run waves is either fixed or explicitly declined with a
reason. What remains untouched is the medium and low tail of the **first** pass -
the one whose verifiers refuted nothing - listed below.

## The cheap re-verification, and why it did not settle the tail (2026-09-06)

The 61 medium/low findings from the first pass were re-run through one cheap
low-effort agent each, on the theory that the first pass's 0-of-79 refutation rate
meant the set was unaudited and a fast adversarial sweep would find the
overstatement. It did not.

**61 answered: 54 still open, 4 already fixed, 3 refuted.** A 5% refutation rate,
against 13% (5 of 39) from the mid-tier waves on the same corpus. So the cheap
pass behaved like the credulous first pass rather than auditing it.

None of the three refutations survives reading:

- **rx_time at 1970** was marked "never a defect" on correct reasoning about
  current code - it reads `config.epochSeconds` now - but that is because it was
  fixed the day before, in `2fbfa48`. Right about HEAD, wrong bucket, and its
  stated reason ("the developer was aware and deliberately avoided it") is a
  guess about history that happens to be false.
- **want_ack stripped from broadcasts** was refuted as "working as deliberately
  designed, not an unintended bug", which does not engage the claim - that the
  stated rationale misdescribes the protocol and leaves the 3-attempt broadcast
  budget as dead code. Confirmed on hardware the next morning: a channel message
  sent from the stock Android app through the phone API sat at "Sending..." for
  five minutes and then went red. The app's own send-ack timeout stamped
  `Routing.Error.TIMEOUT`, which `getMessageRoutingErrorStringResFrom` renders
  with the same string as `MAX_RETRANSMIT` - so "Failed to deliver to mesh" on
  screen was the app giving up, not a NAK from the node.
- **the phone session bound to a cancelled node** was refuted with the words
  "Without seeing platform..." in the reasoning. Refuting on admittedly
  incomplete evidence is the failure mode this whole exercise is meant to catch.

**What it was good for.** Two findings it kept open were ones I had recorded as
closed and had not fixed: `LoraTransport` still not declaring `receiveOnly`
(yesterday's commit fixed the neighbouring availability bug and I filed the wrong
one as done), and the desktop's `loraStatus` still returning a constant null after
I corrected its KDoc to describe exactly that gap. Both fixed in `27b1f65`.
Cheap agents re-reading a claim against HEAD are a decent check on *my* bookkeeping
even when they are a poor check on the claim.

**So the tail is still unaudited.** The 54 remaining have now been confirmed twice
by graders who confirm nearly everything. Treat them as leads, not as a work list;
anything acted on should be read first, as the ones fixed so far were.

## Confirmed findings

79 findings by area, severity-ordered within each.

### Crypto, keys and secrets

**[high] Phone-API TCP listener binds every interface, is unauthenticated, and hands out the channel PSKs**

`node-phone-api/src/jvmMain/kotlin/org/meshtastic/node/phoneapi/PhoneApiTcpServer.kt:32`

The desktop node opens tcp/4403 on 0.0.0.0 on every start, with no pairing, token or bind-address option, and the first thing it gives any client that sends `want_config_id` is every channel's raw PSK. Anyone who can reach the host's port 4403 obtains full read/write access to the user's mesh channels.

*Failure:* On a cafe/hotel/office LAN, run `meshtastic --host <desktop-ip>` (or point the stock Android app's TCP transport at it). `PhoneApiSession.sendConfig` fires unconditionally on the first ToRadio, `LocalRadio.channels()` emits `ChannelSettings(psk = ch.psk.toByteString())` for each configured channel, and the attacker now holds the AES key for every channel the node runs - able to decrypt all captured traffic and to inject as any node. The same socket also accepts `ToRadio.packet`, and `MeshNode.sendPacket` (MeshNode.kt:377) trusts the caller-supplied `packet.id` verbatim as the AES-CTR nonce input, so the attacker additionally controls nonce selection for traffic sent under this node's NodeNum.

*Verifier correction:* **Phone-API TCP listener is unauthenticated on every interface, starts unconditionally, and offers no bind-address knob** (severity: medium, desktop/JVM only)

**[high] Peer public-key pinning lasts only for the process lifetime, contradicting NodeDirectory's own anti-substitution claim**

`node-core/src/commonMain/kotlin/org/meshtastic/node/NodeDirectory.kt:111`

`mergeKey`'s KDoc states that the first valid 32-byte key wins and "is never replaced" because a later different key "is a substitution attempt". That is true only inside one `NodeDirectory` instance. The directory is constructed fresh in `MeshNode` with no persistence seam and no load/save anywhere in the repo, and the monitor never sets `Config.peerPublicKey`, so every restart discards all pins and the mesh re-races for them. The firmware, which this rule is copied from, persists NodeDB to flash.

*Failure:* Attacker sits within earshot (UDP multicast segment, BLE advertisement range, or a bridged MQTT channel). User restarts the desktop/Android monitor. The node's `announce` goes out; the attacker immediately broadcasts a NodeInfo with `from = <victim peer X's NodeNum>` carrying the attacker's own 32-byte X25519 public key. Because the directory is empty, `mergeKey(existing = null, incoming = attackerKey)` returns the attacker key and pins it. Every subsequent `sendText(to = X, ...)` resolves through `publicKeyFor` -> `directory.publicKeyOf(X)` and encrypts the DM to the attacker's key. The user sees a normal PKI-encrypted direct message; X never receives it and the attacker reads it. Nothing in the UI or the phone API distinguishes this from a correct pin. A second, in-process variant: `BoundedLru` (capacity 120) evicts the oldest keyed entry once 120 keyed peers exist, so flooding 120 keyed NodeInfos clears a specific pin without a restart.

*Verifier correction:* **Peer public-key pins live only as long as the process, so `NodeDirectory`'s documented anti-substitution rule does not survive a restart (and can be evicted before one).**

**[medium] Packet ids are a plain +1 counter, so one observed packet predicts all future ids; the KDoc claims the CSPRNG prevents this**

`node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:969`

`nextId()` is `previous + 1` masked to 32 bits. `config.random` only picks the initial value, so every id after the first observed packet is fully predictable. The `Config.random` KDoc justifies requiring a CSPRNG partly on the grounds that "a predictable id aids traffic correlation" - a property the counter destroys regardless of the RNG. The firmware deliberately does the opposite: it keeps only a 10-bit rolling counter and re-randomises the top 22 bits on every packet.

*Failure:* Attacker hears one packet from this node (trivial on UDP multicast or BLE advertisement - no key needed, the header is plaintext) and reads `id = N`. It then broadcasts a burst of well-formed MeshPackets with `from = <our NodeNum>` and `id = N+1 .. N+200` and arbitrary ciphertext. Every relay in earshot records those `(from, id)` pairs in its `PacketHistory` (PacketHistory.kt:24-29, keyed exactly on `(from, id)`, 5-minute window). For the next 200 packets this node originates, every neighbour drops them as duplicates before decryption. The node reports its own sends as successful; messages simply never arrive, and nothing logs a reason. Firmware nodes are not vulnerable to the same trick because their ids are not enumerable.

*Verifier correction:* Packet ids are a plain +1 counter (`MeshNode.kt:965-973`), seeded once from `config.random` at `MeshNode.kt:215`. One observed packet from this node therefore predicts every subsequent id.

**[medium] iOS stores the node private key in a backed-up directory; Android explicitly avoids exactly this**

`monitor/src/iosMain/kotlin/org/meshtastic/node/monitor/Platform.ios.kt:207`

The iOS identity store writes the X25519 private key plus the address seed to `NSApplicationSupportDirectory` with `NSDataWritingFileProtectionComplete` and no backup exclusion. Application Support is included in iCloud and encrypted-iTunes/device-to-device backups by default; `NSFileProtectionComplete` is an at-rest-on-device property and has no effect on backup inclusion. `NSURLIsExcludedFromBackupKey` is never set - grep for `ExcludedFromBackup` across the repo returns nothing. The Android actual made the opposite choice deliberately and documents the hazard.

*Failure:* User restores an iPhone backup onto a second device, or uses Quick Start device-to-device transfer while keeping the old phone. Both devices now hold the same `NodeIdentityRecord`, so both derive the same NodeNum and hold the same X25519 private key. On the mesh they mutually drop each other's frames (each sees its own NodeNum as sender) and peers that pinned that key cannot tell which device they are talking to; the private key has also been copied into an iCloud backup the user was told was device-only. This is precisely the failure Platform.android.kt:199-203 names, and Android is immune to it while iOS is not.

*Verifier correction:* iOS stores the node private key in a backed-up directory; Android deliberately does not (medium)

**[medium] A secondary channel with an unset PSK is transmitted in cleartext instead of under the primary key**

`node-core/src/commonMain/kotlin/org/meshtastic/node/ChannelCrypto.kt:60`

`resolveKey` maps an empty PSK to "no encryption" unconditionally, and its KDoc claims this follows "the firmware's size semantics exactly". It does not: `Channels::getKey` treats an empty PSK as "no encryption" only for the PRIMARY channel - for a SECONDARY it recurses into the primary slot and uses the primary's key. `MeshChannel` has no role concept at all, so the rule cannot be applied, and the omission is not mentioned anywhere. `LocalRadio.channels()` nonetheless labels index 0 PRIMARY and every other slot SECONDARY, so an attached phone applies the inherit rule while the node does not.

*Failure:* User imports a `https://meshtastic.org/e/#...` channel URL, or hand-configures a second channel, where the secondary's `ChannelSettings.psk` is empty - a configuration every Meshtastic radio treats as "encrypted with the primary key". `ChannelSetUrl.decode` (line 48) builds `MeshChannel(name, psk = ByteArray(0))`. On send, `ProtoPacketCodec.seal` calls `channelCrypto.transform(plaintext, channel.psk, ...)`, `resolveKey` returns null, and `transform` returns the payload unchanged (ChannelCrypto.kt:33), so the encoded `Data` - message text included - goes into `MeshPacket.encrypted` verbatim. Anyone sniffing the UDP multicast group, the BLE advertisement, or the MQTT topic reads the message with no key. The user is given no signal: the app-facing `isCleartext` is never surfaced by the monitor, and the channel hash also diverges (name-only XOR instead of name XOR primary key), so real radios silently ignore the packet rather than complaining.

*Verifier correction:* A secondary channel with an unset PSK is transmitted in cleartext, and is invisible to real radios in both directions.


### The phone API

**[high] Every packet and peer handed to the phone is timestamped from a monotonic since-app-start clock, so the app renders 1970**

`meshtastic-node-kmp/monitor/src/commonMain/kotlin/org/meshtastic/node/monitor/MonitorController.kt:43`

MonitorController.clock is `startMark.elapsedNow().inWholeMilliseconds` (TimeSource.Monotonic, ~0 at app launch) and is handed to MeshNode as `config.clock`. MeshNode stamps `rx_time = (now / 1000).toInt()` on every MeshPacket it forwards to the phone (MeshNode.kt:526) and NodeDirectory peers record `lastHeardMs` from the same clock, which LocalRadio turns into `NodeInfo.last_heard` (LocalRadio.kt:117). Both are therefore seconds-since-launch, not epoch seconds. The same config dump also carries the node's *own* NodeInfo.last_heard from a wall clock (Platform.jvm.kt:76 passes `System.currentTimeMillis()` to LocalRadio, used at LocalRadio.kt:78), so one dump mixes two epochs.

*Failure:* Monitor runs 5 minutes; a stock Android app connects over TCP and a peer sends a text. Android's `MeshPacket.rxTimeOrNull()` (core/model/.../util/Extensions.kt:95) substitutes a real time only when rx_time is exactly 0, so it keeps 300 and the message renders at 1970-01-01 00:05:00, sorted before every other message in the thread. Every peer in the node list shows last-heard in 1970 while 'my node' shows the correct wall-clock time. Reproduces on every JVM monitor run after the first second of uptime.

*Verifier correction:* Real defect, severity high, but the root cause is in the library, not in MonitorController.

**[high] Two bytes on TCP/4403 kill the whole monitor: ToRadio(disconnect) then any frame throws ClosedSendChannelException out of an unguarded scope**

`meshtastic-node-kmp/node-phone-api/src/commonMain/kotlin/org/meshtastic/node/phoneapi/PhoneApiSession.kt:74`

`toRadio` handles `disconnect` by calling `close()`, which calls `outbound.close()`. The TCP read loop in PhoneApiTcpServer keeps reading on the same socket afterwards (`while (isActive) { input.read(buf) ... session.toRadio(payload) }`), so the next frame reaches `emit()` -> `outbound.send(...)` (PhoneApiSession.kt:141) on a closed channel and throws ClosedSendChannelException. `serve` has a `finally` but no `catch` (PhoneApiTcpServer.kt:62-78), and `writer` (`out.write` at :58) is equally unguarded, so the exception propagates: serve job -> accept job -> the `scope` passed to `platformServe`, which on desktop is the Compose `rememberCoroutineScope()` used to build MonitorController (Main.kt:16-18). That scope is a plain `Job(parent)` with no CoroutineExceptionHandler, and `nodeJob` is its child, so cancelling it stops the MeshNode and every transport.

*Failure:* Any LAN host: `connect 4403; write StreamFrame(ToRadio(disconnect=true)); write StreamFrame(ToRadio(heartbeat={}))`. The second frame throws, the controller scope is cancelled, the node stops relaying, all transports close, and every later `scope.launch` in MonitorController (start/stop/tune/sendTest) is dead - with no log line, because `log()` also runs through `_state.update` from that scope. The same crash path is reached non-maliciously by a TCP RST from a phone that leaves Wi-Fi mid-write (`out.write` -> SocketException: Broken pipe) or mid-read (`input.read` -> Connection reset).

*Verifier correction:* **Title:** `PhoneApiTcpServer` has zero exception handling around blocking socket IO and session calls, on a plain non-supervisor Compose scope - one dropped TCP connection cancels the MonitorController scope and stops the node.

**[high] A second phone connection wedges the accept loop forever, because cancelAndJoin cannot interrupt a blocking socket read**

`meshtastic-node-kmp/node-phone-api/src/jvmMain/kotlin/org/meshtastic/node/phoneapi/PhoneApiTcpServer.kt:38`

The accept loop does `current?.cancelAndJoin()` before serving a new socket, but the coroutine being cancelled is parked in `input.read(buf)` (:68), a blocking JDK call inside `withContext(Dispatchers.IO)` that ignores coroutine cancellation. No `soTimeout` is set anywhere in the file, so the read blocks indefinitely. `cancelAndJoin` therefore suspends until the *old* client sends a byte or closes, and the whole accept loop - not just that one session - is stalled meanwhile. The class KDoc's claim that 'a second connection replaces the first' is false whenever the first client is silent.

*Failure:* Phone A connects over TCP and its Wi-Fi drops without a FIN (half-open socket - the common Android case). Phone A sends nothing more. Phone A reconnects on a new IP: accept() returns, `cancelAndJoin()` parks on A's dead read, and the new socket is never served - no config dump, no bytes at all, so the app hits its 18x5s inactivity limit and gives up. Every subsequent connection attempt is queued behind the same stalled accept loop. Only a monitor restart recovers. A LAN attacker gets the same result deliberately: connect once, send nothing, hold the socket open.

*Verifier correction:* A silent phone connection wedges the accept loop, because `cancelAndJoin` cannot interrupt a blocking socket read.

**[high] A local AdminMessage from the phone is broadcast onto every bearer under the channel PSK instead of being handled or rejected**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:373`

`sendPacket` has no destination check for `to == identity.nodeNum` and no portnum filter. A local AdminMessage packet (`to = myNodeNum`, `channel = 0`, `pki_encrypted = false`, portnum ADMIN_APP) takes the ordinary path: `to != BROADCAST` so `direct = true`, `pki` stays null because `packet.pki_encrypted` is false, and the payload is sealed with `config.channels[0].psk` and handed to `originate` -> `broadcast()`, i.e. transmitted on UDP multicast, BLE advertisement, BLE GATT, LoRa and MQTT. Nothing delivers it locally and nothing answers it. The docs describe AdminMessage as simply 'not yet' implemented (notes/handoff-multi-transport.md:131), which understates it: it is partially handled - accepted, encrypted and put on the air.

*Failure:* A stock Android app attached to the desktop monitor opens Radio Configuration. CommandSenderImpl builds an admin packet with `getAdminChannelIndex(myNum) == 0` (CommandSenderImpl.kt:116-122) and `pkiEncrypted = false` (only set when channel == PKC_CHANNEL_INDEX, :516-517). node-kmp encrypts it with the monitor's default LongFast key `byteArrayOf(1)` - the published public key (MonitorController.kt:61) - and multicasts it. Anyone on the LAN segment or in RF range decrypts the AdminMessage, including its session passkey and, for a set_config, the whole config being written. The phone gets no admin response, so every config screen stalls until the app's own timeout.

*Verifier correction:* `MeshNode.sendPacket` (node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:373-392) has no guard for `to == identity.nodeNum`. A packet the phone addresses to its own node - which for a stock app means every local AdminMessage - is treated as an ordinary direct send: `direct = true` (:378), `pki` stays null because `pki_encrypted` is false (:379), and `seal` encrypts the payload under `config.channels[0].psk` (ProtoPacketCodec.kt:302-304) before `originate` -> `broadcast` (:455-472, :944-963) puts it on UDP multicast, BLE advertisement, BLE GATT, LoRa and MQTT. Nothing delivers it 

**[high] Neither the implicit ACK nor the MAX_RETRANSMIT NAK is turned into a ROUTING_APP FromRadio, so phone-sent messages never resolve**

`meshtastic-node-kmp/node-phone-api/src/commonMain/kotlin/org/meshtastic/node/phoneapi/PhoneApiSession.kt:33`

PhoneApiSession's only inbound source is `node.packets`; it never touches `node.events`. The firmware raises both receipts as ROUTING_APP packets delivered locally to the phone: `perhapsGenerateImplicitAckForOwnOverheard` -> `sendAckNak(Routing_Error_NONE, ...)` (ReliableRouter.cpp:74-79) and `sendAckNak(Routing_Error_MAX_RETRANSMIT, ...)` on retry exhaustion (NextHopRouter.cpp:465), both via `router->sendLocal`. In node-kmp the implicit ack is a `MeshEvent.Delivered` produced in `implicitAck()` (MeshNode.kt:491) - a path that returns *before* `toMeshPacket`/`_packets.tryEmit` (MeshNode.kt:526) - and exhaustion is a `MeshEvent.DeliveryFailed` from `pumpRetransmits` (MeshNode.kt:420) that is never a packet at all. An explicit ACK from a stock-radio DM peer *does* reach the phone, because `toMeshPacket` runs before the `when (decoded)` branch, so the gap is specifically these two locally generated receipts. Broadcasts are worse: `sendPacket` passes `wantAck = packet.want_ack && direct` (MeshNode.kt:391), so a broadcast is never even tracked and no receipt of any kind is possible.

*Failure:* Phone sends a broadcast text through the node. Node transmits; a neighbouring radio rebroadcasts it; MeshNode raises `MeshEvent.Delivered` and the monitor logs it - the phone sees only a `queueStatus` and stays ENROUTE until PacketHandlerImpl's grace period stamps it `Routing.Error.TIMEOUT` and it renders as 'Failed to deliver to mesh'. A DM whose retries are exhausted behaves the same: the app never receives MAX_RETRANSMIT and falls back to its own timeout, so a genuine routing failure and a lost ACK are indistinguishable.

*Verifier correction:* Real defect, high severity, confirmed. One mechanism correction to the failure scenario.

**[medium] After any tuning change the phone keeps talking to a session bound to a cancelled node**

`meshtastic-node-kmp/monitor/src/commonMain/kotlin/org/meshtastic/node/monitor/MonitorController.kt:189`

`platformServe(fresh, scope, ::log)` hands the *controller* scope to PhoneApiTcpServer, and PhoneApiSession's `live`, `keepalive` and `telemetry` jobs plus the socket `writer` are all launched in that scope - not in `nodeJob`. `stop()` cancels `nodeJob` and calls `serving?.invoke()` (`server.stop()`), which cancels only the accept job and closes the ServerSocket; the live session's jobs are reached only through `serve`'s `finally`, which cannot run while `serve` is parked in the blocking `input.read`. Nothing in the protocol tells the phone the radio restarted - the firmware sends `FromRadio.rebooted` and drops the link.

*Failure:* User taps any transport chip or region chip in the monitor. `tune` -> `restart` -> `stop` cancels the node while the attached phone's socket stays open and unserved. The stale PhoneApiSession keeps sending a queueStatus every 30 s, so the Android TCP transport's inactivity counter never trips and the app shows Connected indefinitely. Every message the phone sends now hits `node.sendPacket` on a node whose scope is cancelled and comes back as `queueStatus(res = -1)`, i.e. ERROR, with no reconnect. Meanwhile `start()` builds a new server that binds fine, so the two coexist.

*Verifier correction:* **After any tuning change the phone keeps talking to a session bound to a cancelled node (desktop only)**

**[medium] TCP/4403 binds to 0.0.0.0 unconditionally with no authentication, exposing channel PSKs and an unclamped hop_limit**

`meshtastic-node-kmp/node-phone-api/src/jvmMain/kotlin/org/meshtastic/node/phoneapi/PhoneApiTcpServer.kt:32`

`ServerSocket(port)` binds the wildcard address; there is no bind-address parameter and no auth step anywhere in the session state machine. `platformServe` is invoked from `startWith` on every node start (MonitorController.kt:189), so the listener is up whenever the monitor runs - there is no opt-in equivalent to the firmware's WiFi/network config, and none of the firmware's MESHTASTIC_PHONEAPI_ACCESS_CONTROL redaction (PhoneAPI.cpp strips device_id, metadata and channel contents for an unauthorized client). Any nonce dumps everything: MyNodeInfo, DeviceMetadata, all eight Channels *including* `ChannelSettings.psk`, the security config's public key, and the whole node directory. On the send side `hopLimit = if (packet.hop_limit > 0) packet.hop_limit else relayPolicy.hopLimit` (MeshNode.kt:387) with no clamp to RelayPolicy.HOP_MAX, even though inbound frames above HOP_MAX are dropped (MeshNode.kt:495).

*Failure:* Any host on the same LAN (coffee-shop Wi-Fi, a compromised IoT device) connects to port 4403, sends `ToRadio(want_config_id = 1)` and reads back every channel PSK the host configured plus the full node DB - no pairing, no PIN, nothing. It can then originate mesh traffic as this node with an attacker-chosen packet id and hop_limit, and, per the previous findings, kick or permanently wedge the legitimate phone's session just by connecting. Injection into LoRa via a stock UDP-enabled radio is pre-existing (RelayPolicy KDoc says so), but PSK/nodeDB disclosure and hop_limit escalation are new here.

*Verifier correction:* TCP/4403 binds the wildcard address with no bind-address option and no authentication, and lets any LAN client override RelayPolicy.Island

**[medium] The config dump always reports region UNSET, pinning a stock Android app in MUST_SET_REGION with no way out**

`meshtastic-node-kmp/monitor/src/jvmMain/kotlin/org/meshtastic/node/monitor/Platform.jvm.kt:76`

`LocalRadio`'s `region` parameter defaults to `Config.LoRaConfig.RegionCode.UNSET` and the only production construction site omits it, so `configs()` always emits `LoRaConfig(region = UNSET)` (LocalRadio.kt:150). The monitor already knows the answer - `TransportTuning.loraRegion` is a user-selected chip (TransportTuning.kt:48) driving the real SX1262 - and it is never plumbed through. The same dump reports `hop_limit = node.relayPolicy.hopLimit` (LocalRadio.kt:151), which is 0 under the default RelayPolicy.Island.

*Failure:* A stock Android app connects to the desktop node over TCP. `ConnectionsViewModel.regionUnset` maps `lora.region == RegionCode.UNSET` to true, so `connectionStatus` resolves to `ConnectionStatus.MUST_SET_REGION` - 'Connected and active, but LoRa region is UNSET - user action required' - permanently, even when the user has set US on the LoRa stick in the monitor. The user cannot clear it, because the set_config AdminMessage the app would send is broadcast onto the mesh and never answered (see the AdminMessage finding).

*Verifier correction:* The config dump hardcodes the LoRa section, so a stock app is pinned in MUST_SET_REGION with no way out.

**[low] Peer NodeInfo is sent with hw_model = UNSET, which the Android app treats as a placeholder and strips names from**

`meshtastic-node-kmp/node-phone-api/src/commonMain/kotlin/org/meshtastic/node/phoneapi/LocalRadio.kt:114`

`peerNodeInfo` hardcodes `hw_model = HardwareModel.UNSET` for every peer while still supplying real `long_name`/`short_name`. Android's NodeInfoDao keys its placeholder detection on exactly that field, so it discards the names it was just given for the denormalized search columns. The same NodeInfo also carries `snr = 0f` unconditionally, which is a measured-looking value rather than an absent one.

*Failure:* A stock app connected to the node receives ten peers with proper names. NodeInfoDao.getVerifiedNodeForUpsert sets `longName = null; shortName = null` for each because `user.hw_model == HardwareModel.UNSET`, so node search and the name-based filters return nothing for any peer the node reports, and MeshUser.hwModelString is null so no hardware image renders. If an existing entry has a real user, the merge branch at NodeInfoDao.kt:202-215 additionally decides whether to keep or clobber based on that same flag.

*Verifier correction:* Peer NodeInfo discards the peer's real hw_model and re-emits UNSET, which the Android app treats as a placeholder


### The LoRa bearer

**[high] Region/preset compatibility is never enforced, so EU_868 plus a 500 kHz preset emits 250 kHz outside the sub-band**

`meshtastic-node-kmp/node-transport-lora/src/commonMain/kotlin/org/meshtastic/node/transport/lora/LoraChannelPlan.kt:98`

LoraRegion.supportsPreset() exists (LoraRegion.kt:89) and is asserted in tests, but no code path calls it. LoraChannelPlan.resolve() also omits the firmware's band-span check ((freqEnd-freqStart) < freqSlotWidth). The firmware refuses both cases in checkOrClampConfigLora (RadioInterface.cpp): an unsupported preset clamps to the region's default preset, and a bandwidth wider than the region span clamps the bandwidth. The Kotlin transport tunes and transmits the combination as given.

*Failure:* LoraConfig(region = LoraRegion.EU_868, preset = LoraModemPreset.SHORT_TURBO) - reachable straight from the dashboard, since TransportTuning.LORA_REGIONS contains "EU_868" and LORA_PRESETS contains SHORT_TURBO/LONG_TURBO/MEDIUM_TURBO. bw = 500 kHz, spacing = 0, padding = 0, so slotWidthMHz = 0.5 and numSlots = roundToInt((869.65-869.4)/0.5) = roundToInt(0.49999...) = 0. defaultSlot() returns 0 for n <= 0, so frequencyMHz = 869.4 + 500/2000 + 0 + 0 = 869.65 MHz. With 500 kHz occupied bandwidth the emission spans 869.40-869.90 MHz: the upper 250 kHz sits outside the 869.4-869.65 high-duty EU sub-band whose 27 dBm / 10 % limits the transport is applying. txConfigured is true (region is not UNSET, not wideLora), so attemptTx transmits it. EU_N_868 + any 250 kHz preset is the same shape (869.5354 MHz +/-125 kHz, over 869.65).

*Verifier correction:* Region/preset compatibility and the region's band span are never enforced, so EU_868 with a 500 kHz TURBO preset tunes 869.65 MHz and emits 869.40–869.90 MHz - half the channel outside the sub-band, and 125 kHz off where a firmware radio would be.

**[high] The rolling-hour duty-cycle ledger is destroyed and recreated on every dashboard edit**

`meshtastic-node-kmp/node-transport-lora/src/commonMain/kotlin/org/meshtastic/node/transport/lora/LoraTransport.kt:167`

LoraAirtime is a per-LoraTransport field with no persistence, and the monitor rebuilds the whole transport list on every tuning change - including changes that have nothing to do with LoRa. The firmware's airTime is a process-lifetime singleton, so its hourly budget survives a config change. Here the budget resets to zero, which makes the region duty cycle unenforceable in practice on the shipped consumer.

*Failure:* Run the monitor with loraRegion = "EU_868" (10 % duty cycle = 360 s/hour). Transmit until attemptTx starts refusing with "airtime budget". Tap any dashboard chip - hop limit, GATT PHY, UDP port, or toggling an unrelated bearer. MonitorController.tune() sees a changed TransportTuning and calls restart() -> startWith() -> defaultTransports(), which constructs a brand new LoraTransport and therefore `private val airtime = LoraAirtime()` with an empty entry deque. txAllowed() now returns true immediately and the node can transmit a second full hourly budget with no wait. Repeat indefinitely.

*Verifier correction:* CONFIRMED, with the framing corrected.

**[medium] A transmit that times out waiting for TX_DONE is not charged to airtime although the PA radiated**

`meshtastic-node-kmp/node-transport-lora/src/commonMain/kotlin/org/meshtastic/node/transport/lora/LoraTransport.kt:531`

attemptTx issues SetTx (startTransmit) and then polls DIO1 until `clock() + 2*toaMs + 500 ms`. airtime.logTx() is called only inside `if (sent)`. The SX1262 begins radiating the moment SetTx is accepted, so a run that misses TX_DONE has still put the frame on the air - the transmission is simply invisible to the duty-cycle and channel-utilisation ledgers.

*Failure:* On a slow or stalling CH341 USB link (or with txPollIntervalMs coarse relative to toaMs), d.dio1High()/d.irqStatus() do not observe TX_TERMINAL before the deadline. `sent` is false, so txTimeouts is incremented and logTx is skipped, but a full time-on-air of RF was emitted. Under EU_868/EU_866/TH/UA_433 the node keeps believing it has its whole 10 % (or 2.5 %) hourly budget while having already spent part of it. Two such timeouts in a row also leave `consecutiveTimeouts` short of STUCK_TX_COUNT=3, so nothing re-initialises and the pattern can repeat.

*Verifier correction:* CONFIRMED, with a corrected failure story and severity low (not medium).

**[medium] send() gives up after a timeout but the frame stays queued and can still be transmitted much later**

`meshtastic-node-kmp/node-transport-lora/src/commonMain/kotlin/org/meshtastic/node/transport/lora/LoraTransport.kt:224`

send() waits txMaxDeferMs + SEND_GRACE_MS (20 s by default) and returns false on timeout, but the TxRequest is still held by the actor's channel/backlog and is never withdrawn. Worse, a request promoted out of the backlog gets a *fresh* firstAttempt, so the txMaxDeferMs deadline that was supposed to bound its life restarts per item. Nothing counts this in LoraStats, contradicting the type's "Every drop is counted somewhere here" doc.

*Failure:* On a busy channel, queue four frames (TX_QUEUE is 16). Frame 1 is pending and keeps deferring; frames 2-4 sit in `backlog`. Each send() returns false after 20 s and MeshNode.broadcast() records the bearer as not having carried the packet (and the caller may retransmit). Frame 1 is refused at 10 s; loop() line 439 then promotes frame 2 with `Pending(it, next + jitter, next)` - firstAttempt = now - giving it another full 10 s window, then frame 3, then frame 4. Frame 4 can reach the air ~40 s after its own send() already reported failure, duplicating whatever the node retransmitted in the meantime. Neither txRefused nor any other counter records the abandoned wait.

*Verifier correction:* **send() abandons a transmit request it cannot withdraw, so a frame reported as not-sent can still reach the air.**

**[medium] LoraConfig.channelName is never wired to the node's MeshChannel.name, so the LoRa slot and the channel identity disagree**

`meshtastic-node-kmp/monitor/src/jvmAndroidMain/kotlin/org/meshtastic/node/monitor/LoraTuning.kt:16`

The firmware derives the frequency slot from `Channels::getName(primaryIndex)` - the primary channel's own name, falling back to the preset display name only when that name is empty. LoraChannelPlan.channelName() reproduces the formula but reads LoraConfig.channelName, a field entirely separate from MeshNode's MeshChannel. toLoraConfig() never sets it, and MonitorController hard-codes the channel name "LongFast", so the two disagree for every preset except LONG_FAST.

*Failure:* In the monitor, set loraRegion = "US" and loraPreset = "MEDIUM_FAST". LoraConfig.channelName stays "", so LoraChannelPlan hashes the preset display name "MediumFast": djb2 = 1461075348, % 104 = slot 44, 913.125 MHz. The node's own MeshChannel is still MeshChannel("LongFast", psk), so every packet it sends carries the channel byte from hash("LongFast" XOR key). A firmware radio that shares that channel byte must have its primary channel named "LongFast", and such a radio on the MediumFast preset computes hash("LongFast") % 104 = slot 19 = 906.875 MHz. The two are 6.25 MHz apart and mutually deaf. No non-LONG_FAST preset can interoperate from the monitor, and the library gives no warning that the two names must be kept in sync.

*Verifier correction:* CONFIRMED, with the failure scenario re-stated.

**[low] The 2 m ham regions fail the SX1262 frequency range check and produce an endless 3-second re-init loop**

`meshtastic-node-kmp/node-transport-lora/src/commonMain/kotlin/org/meshtastic/node/transport/lora/LoraTransport.kt:284`

runRadio explicitly guards the one band an SX1262 cannot reach upward (wideLora / 2.4 GHz) with a non-retrying LoraState.Error, but nothing guards the bands it cannot reach downward. LoraRegion.ALL contains ITU1_2M / ITU2_2M / ITU3_2M at 144-148 MHz, below Sx1262.MIN_FREQ_MHZ (150.0), so Sx1262.frf() throws from inside begin().

*Failure:* LoraConfig(region = LoraRegion.ITU1_2M). LoraChannelPlan.resolve gives slotWidth 0.02, numSlots 100, overrideSlot 26 -> slot 25, freq = 144.0 + 15.6/2000 + 0.0022 + 25*0.02 = 144.51 MHz (the firmware's own documented default for that row). Sx1262Driver.begin -> modem -> setFrequency -> Sx1262.frf(144.51) hits `require(freqMHz in 150.0..960.0)` and throws IllegalArgumentException. runRadio's generic `catch (e: Throwable)` at :333 publishes LoraState.Error(msg, 3000) and retries forever every three seconds, whereas the equivalent unreachable-band case at :284-288 sets retryInMs = null and awaits cancellation.

*Verifier correction:* Real defect, severity low, with a corrected repro and a wider scope than stated.


### Reliable delivery, beacons and telemetry

**[high] Reliable delivery only ever retransmits when an unrelated inbound frame arrives, so a lone want_ack send is never retried and never reported failed**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:308`

`pumpRetransmits()` has exactly one call site - inside the `transform { }` of `receivePipeline()` (MeshNode.kt:308). Nothing else drives it: no timer, no `delay` loop, no hook on `originate`. Verified by `grep -rn pumpRetransmits` across the whole repo: three hits, all in MeshNode.kt (comment at 306, call at 308, definition at 403). The KDoc at MeshNode.kt:394-401 concedes only that "a retry can be late on a silent mesh"; in fact on a silent mesh no retry ever happens, and `queue.expired()` is never consulted, so `MeshEvent.DeliveryFailed(MAX_RETRANSMIT)` is never emitted either. Even a bearer with loopback does not rescue it: our own frame arrives at t≈0 and `RetransmitQueue.due(now)` compares `nextTxMs = now + 6500 > now` (RetransmitQueue.kt:97,105), so nothing is due; there is no wake-up at t=6500.

*Failure:* Node A (GATT or LoRa or BLE-adv bearer, `reliableDelivery = ReliableDelivery()`, `relayPolicy = Island`) sends `sendText("hi", to = 0xB0B, wantAck = true)`. Peer B is out of range and no other node is transmitting. The packet is sent once. 6.5 s, 30 s, 10 min pass: `due()` is never called because no frame ever enters the receive pipeline, so attempts 2..5 never go out and `expired()` never runs. The caller sees neither `Delivered` nor `DeliveryFailed`, for ever. The only thing that can shake the queue loose is unrelated inbound traffic, so retry cadence is set by how chatty the neighbourhood is rather than by `ReliableDelivery.intervalMs` - on a quiet node the effective cadence degrades to the beacon loopback interval (3 h NodeInfo) at best.

*Verifier correction:* Reliable delivery is driven entirely off the receive path, so on a node that is hearing nothing a `want_ack` send is transmitted once, never retried, and never reported failed.

**[high] DeliveryFailed never reaches an attached phone, so the "Sending…" state reliableDelivery exists to clear is never cleared**

`meshtastic-node-kmp/node-phone-api/src/commonMain/kotlin/org/meshtastic/node/phoneapi/PhoneApiSession.kt:32`

`PhoneApiSession` consumes `node.packets` only (PhoneApiSession.kt:32-38). `grep -rn '\.events' node-phone-api/src/commonMain` returns nothing - the session never subscribes to `MeshNode.events`, which is where `MeshEvent.DeliveryFailed` and the implicit-ack `MeshEvent.Delivered` are raised (MeshNode.kt:409-421, 443). Nothing synthesises a `Routing` ACK/NAK `FromRadio` for the phone. This directly falsifies two KDocs: `MeshEvent.DeliveryFailed` (MeshEvent.kt:178-188) - "the event a phone needs: without it a client sits at [Sending…]" - and `Config.reliableDelivery` (MeshNode.kt:~1030) - "a phone attached through node-phone-api sits at 'Sending...' for ever because nothing ever reports either outcome". The firmware does the opposite: on exhaustion it calls `sendAckNak(meshtastic_Routing_Error_MAX_RETRANSMIT, getFrom(p.packet), p.packet->id, p.packet->channel)` (NextHopRouter.cpp, doRetransmissions), and on an overheard rebroadcast of its own packet it calls `sendAckNak(meshtastic_Routing_Error_NONE, ...)` (ReliableRouter.cpp, perhapsGenerateImplicitAckForOwnOverheard) - both of which land on the phone as a Routing packet.

*Failure:* A stock Meshtastic app connects over the phone API and sends a DM with `want_ack`. `PhoneApiSession.send()` returns `queueStatus(res = 0)` so the app shows "Sending…". The peer is unreachable. Five attempts are spent, `DeliveryFailed(MAX_RETRANSMIT)` is emitted on `node.events`, and nothing forwards it: the app's message stays at "Sending…" indefinitely. Symmetrically, when the packet *is* implicitly acked (a neighbour rebroadcast), `MeshEvent.Delivered` fires on `events` but no Routing ACK reaches the phone, so the tick never appears either - only a real end-to-end Routing ACK from the destination, which arrives as an inbound packet on `node.packets`, works.

*Verifier correction:* **DeliveryFailed/Delivered never reach an attached phone: node-phone-api forwards no Routing ACK/NAK, and two KDocs claim it does**

**[medium] Ack and NAK handling is not gated on the packet being addressed to us, so other nodes' Routing traffic is reported as our own delivery outcome**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:606`

The `DecodedPacket.RoutingError` and `DecodedPacket.Ack` branches (MeshNode.kt:606-625) check neither `header.to == identity.nodeNum` nor whether the request id is one of ours. `retransmits?.acknowledge(decoded.requestId)` returns `Boolean` and the result is discarded, and `MeshEvent.DeliveryFailed` / `MeshEvent.Delivered` are emitted unconditionally. `ProtoPacketCodec.open()` (ProtoPacketCodec.kt:268-288) decrypts *any* packet whose `channel` hash matches one of our channels regardless of `to`, so every Routing ack/NAK on a channel we hold is decoded. The firmware wraps the entire ack/nak block in `if (isToUs(p))` (ReliableRouter.cpp, `sniffReceived`). Two consequent doc falsehoods: `MeshEvent.Delivered` says "A peer acknowledged a message we sent" (MeshEvent.kt:90-96) and `MeshEvent.DeliveryFailed` says "Only raised where Config.reliableDelivery is set" (MeshEvent.kt:186-187) - but the RoutingError branch emits it even when `retransmits` is null, since only the `acknowledge` call is null-safe, not the emission. The same branch hardcodes `attempts = 0` (MeshNode.kt:613) while the KDoc promises "how many transmissions were actually made".

*Failure:* Two firmware radios B and C are on our LongFast channel and DM each other with `want_ack`. Our node holds the channel key, is not addressed, and has `reliableDelivery = null`. Every ACK B sends to C decodes here and emits `MeshEvent.Delivered(from = B, requestId = <C's packet id>)`; every NAK emits `MeshEvent.DeliveryFailed(reason = REJECTED, attempts = 0)`. A host UI or the monitor bound to `events` shows delivery confirmations and failures for messages this node never sent, and shows them on a node where the feature is switched off. In the (rare) case a foreign request_id collides with one of ours, `retransmits.acknowledge` silently retires a genuinely outstanding packet.

*Verifier correction:* Confirmed as written, with four sharpenings:

**[medium] Implicit ack accepts an MQTT-carried rebroadcast, which the firmware explicitly refuses**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:438`

`implicitAck` (MeshNode.kt:438-443) discriminates loopback from relay purely on `(header.hopsAway ?: 0) > 0`, i.e. `hop_start - hop_limit`. It never reads `transport_mechanism` or `via_mqtt`; `grep -rn 'transport_mechanism|TransportMechanism' node-core/src/commonMain node-phone-api/src/commonMain` returns nothing, even though `MqttFraming.toCanonical` stamps `transport_mechanism = TRANSPORT_MQTT` on every downlink (MqttFraming.kt:97). The firmware gates the same decision on the bearer twice over: `perhapsGenerateImplicitAckForOwnOverheard` only calls `stopRetransmission` when `p->transport_mechanism == TRANSPORT_LORA` (ReliableRouter.cpp:80-82), and `sniffReceived` excludes `isFromUs(p) && p->transport_mechanism == TRANSPORT_MQTT` from the ack/nak stop. The KDoc at MeshNode.kt:428-437 presents `hopsAway` as a complete discriminator; it is not, because an MQTT downlink can carry a non-zero hop count.

*Failure:* Our node has a UDP/LoRa bearer plus an MQTT bridge, and sends a `want_ack` DM with `hop_limit = hop_start = 3`. A firmware node hears it over LoRa and rebroadcasts at `hop_limit = 2`. A *different* gateway node hears that rebroadcast and uplinks it to the broker. Our MQTT transport is subscribed to the channel wildcard, so the envelope comes back: `gateway_id` is not ours so `MqttFraming.toCanonical` admits it (MqttFraming.kt:82), `from == identity.nodeNum`, `hopsAway = 3 - 2 = 1 > 0`. `implicitAck` retires the pending packet and raises `MeshEvent.Delivered` off a broker round-trip whose latency and duplication are exactly why the firmware refuses to count it. Retransmission stops on evidence the reference implementation rejects.

*Verifier correction:* **Implicit ack retires a pending packet on an MQTT-carried rebroadcast, where the firmware deliberately keeps retransmitting**

**[medium] positionLoop loses its "never sent" state after the first wake, so a node whose GPS has no fix at startup reports nothing for a full interval**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:851`

`sinceSentMs` starts null and `due` is computed as `elapsed == null || elapsed >= beacon.interval` (MeshNode.kt:830) - null encodes "never sent", which forces an immediate broadcast. But the accumulator at the bottom of the loop runs unconditionally: `sinceSentMs = (sinceSentMs ?: 0) + wake.inWholeMilliseconds` (MeshNode.kt:851). So one wake after startup `sinceSentMs` is non-null for ever, whether or not anything was sent, and `lastSent` stays null so `moved` (MeshNode.kt:831-833) can never fire either. The "never sent" state is unrecoverable.

*Failure:* `PositionBeacon()` defaults: `interval = 1.hours`, `smartMinimumInterval = 5.minutes`, so `wake = 5.minutes`. At t=0 the host's `PositionSource.current()` returns null - the normal case, a GPS cold start. `sinceSentMs` becomes 300_000. At t=5 min a fix arrives: `due` is `300_000 >= 3_600_000` → false; `moved` requires `lastSent != null` → false. Nothing is sent. The node stays positionless until t=60 min, i.e. up to `interval - smartMinimumInterval` (55 minutes) after it first knew where it was. `PositionBeaconTest`'s "no fix means nothing is sent" test uses a source that returns null for ever, so it never exercises the late-fix path.

*Verifier correction:* CONFIRMED, with the cited line numbers corrected (they drift 1-3 lines from the file on disk) and the scope tightened.

**[medium] PositionBeacon(precisionBits = 1) is accepted at construction and then throws out of the position coroutine on every broadcast**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/PositionSource.kt:58`

`BeaconPolicy`'s `PositionBeacon` init only requires `precisionBits in 0..32` (BeaconPolicy.kt:122-124), so 1 is a valid configuration. `NodePosition.truncatedTo(1)` computes `mask = 0x80000000`, `halfCell = 1 shl (32 - 1 - 1) = 2^30 = 1_073_741_824`, then `copy(latitudeI = (latitudeI and mask) + halfCell)` (PositionSource.kt:56-58). `copy` re-runs the data class `init`, which requires `abs(latitudeI) <= 900_000_000` (PositionSource.kt:25). For any positive latitude the masked value is 0 and the result is 1_073_741_824; for any negative latitude it is -2_147_483_648 + 1_073_741_824 = -1_073_741_824. Both exceed the guard, so the `require` throws for every possible input.

*Failure:* A host sets `BeaconPolicy(position = PositionBeacon(precisionBits = 1))` - accepted. At the first due broadcast `codec.encodePosition` calls `position.truncatedTo(1)` (ProtoPacketCodec.kt:139) and an `IllegalArgumentException("latitudeI out of range: 1073741824")` propagates out of `encodePosition`, out of `positionLoop`, out of the `scope.launch` in `MeshNode.init` (MeshNode.kt:97-101). There is no try/catch on that path. If the host's scope carries an ordinary `Job` rather than a `SupervisorJob`, the failure cancels the whole node scope and takes the receive pipeline, the NodeInfo beacon and every transport collection down with it - the node goes silent with one stack trace naming only a latitude.

*Verifier correction:* `NodePosition.truncatedTo` (PositionSource.kt:52-59) rounds through `copy()`, which re-runs the validating `init` at PositionSource.kt:24-27 - so the function asserts on its own output. Any `(bits, coordinate)` pair where `(coord and mask) + halfCell` lands outside the constructor's `±900_000_000` / `±1_800_000_000` range throws `IllegalArgumentException` out of `encodePosition` (ProtoPacketCodec.kt:139), out of `positionLoop` (MeshNode.kt:836-843) and out of the bare `scope.launch` at MeshNode.kt:100-103, which has no try/catch, no `SupervisorJob` and no `CoroutineExceptionHandler` anywhere i

**[medium] want_ack is stripped from every broadcast on a rationale that misdescribes the protocol, making the 3-attempt broadcast budget dead and dropping a stock app's channel-message delivery tick**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:352`

`sendText` passes `wantAck = wantAck && direct` (MeshNode.kt:364) and `sendPacket` passes `packet.want_ack && direct` (MeshNode.kt:389,391); those are the only two `originate` call sites that set `wantAck` at all (verified by grepping every `originate(` call site). So `RetransmitQueue.track`'s broadcast branch - `if (to == MeshNode.BROADCAST) policy.broadcastAttempts` (RetransmitQueue.kt:94) - is unreachable, and `ReliableDelivery.BROADCAST_ATTEMPTS` is dead configuration despite `notes/multi-transport-mesh.md:1193` claiming "Firmware budgets, 5 unicast and 3 broadcast total attempts" as implemented. The stated reason is also wrong: MeshNode.kt:352 says "Asking every hearer of a broadcast to reply is how you flood a shared channel", conflating `want_ack` with `want_response`. No node replies to a broadcast `want_ack`: firmware's explicit-ack block is inside `if (isToUs(p))` and `isToUs` is false for a broadcast; firmware relies on the *implicit* ack instead, which is why `ReliableRouter::send` does `isBroadcast(p->to) ? NUM_RELIABLE_RETX : NUM_RELIABLE_UNICAST_ATTEMPTS`. node-kmp's own `acknowledge()` is likewise gated on `header.to == identity.nodeNum` (MeshNode.kt:533), so it could not flood either.

*Failure:* A stock Meshtastic app attached over the phone API sends a channel message with `want_ack = true` (the app sets it for channel sends so it can render a delivery tick from the implicit ack). `MeshNode.sendPacket` sees `direct == false`, clears `want_ack` before `codec.encodeData` (MeshNode.kt:389) and skips `retransmits.track`. The packet goes out once with `want_ack = false`; no neighbour's rebroadcast can be recognised as an implicit ack for it, no retry is scheduled, and the app never gets its tick. On real firmware the same message would be sent up to 3 times and ticked on the first overheard rebroadcast. `RetransmitQueueTest.a broadcast gets fewer` passes because it calls `RetransmitQueue.track` directly, bypassing the MeshNode path that can never reach it.

*Verifier correction:* CONFIRMED, with two scope corrections.

**[low] A Routing carrying route_request/route_reply is classified as an acknowledgement**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/ProtoPacketCodec.kt:372`

`interpret`'s ROUTING_APP branch decides purely on `error_reason` (ProtoPacketCodec.kt:372-377): `if (reason == null || reason == Routing.Error.NONE) DecodedPacket.Ack(requestId)`. `Routing` is a oneof of `route_request` / `route_reply` / `error_reason`, so a Routing whose oneof is `route_reply` has `error_reason == null` and falls into the Ack arm. The comment two lines above says "a Routing carrying neither is a route update we do not model" (ProtoPacketCodec.kt:363-364), but nothing checks `route_request`/`route_reply` - the only other gate is `data.request_id != 0` (ProtoPacketCodec.kt:366), which a route reply satisfies. `RoutingOutcomeTest` (RetransmitQueueTest.kt:112-172) covers empty Routing, explicit NONE, a non-NONE error and `request_id == 0`, but never a route_request/route_reply payload.

*Failure:* A peer (or older/other-stack firmware) sends a `Routing{route_reply = ...}` on ROUTING_APP with `request_id` set to one of our outstanding packet ids. `interpret` returns `DecodedPacket.Ack`, `MeshNode` calls `retransmits.acknowledge(requestId)` and emits `MeshEvent.Delivered` - a route-discovery message read as a delivery receipt. Combined with the missing `isToUs` gate above, this needs no cooperation from the destination at all.

*Verifier correction:* A `Routing` whose oneof variant is `route_request`/`route_reply` is classified as an acknowledgement (severity: low, latent).

**[low] BeaconPolicy.firstAnnounceRequestsReplies documents cross-launch suppression the library has no way to implement**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/BeaconPolicy.kt:60`

The KDoc states "a client node that may be launched and killed often is a poorer citizen if it asks every launch, which is why this is one request per node lifetime and not per start" (BeaconPolicy.kt:57-61). The implementation is a local `var wantReplies = beacon.firstAnnounceRequestsReplies` inside the `init`-block coroutine (MeshNode.kt:88-95), re-initialised to `true` on every `MeshNode` construction. There is no persistence anywhere in the library, so "per node lifetime" cannot be distinguished from "per start" - the behaviour is exactly the per-launch one the KDoc says it avoids. `BeaconTest.only the first announcement asks for replies` (BeaconTest.kt:118) tests one node instance and so cannot catch this.

*Failure:* An Android host constructs a `MeshNode` in a service that the OS restarts, or a desktop app crash-loops. Each start broadcasts, 2 s later (the default `initialDelay`, vs the firmware's 30 s + 15 s/module), a NodeInfo with `want_response = true`, asking every node in earshot to answer. Peers' own 12 h suppression bounds the reply storm, so this is not a flood - but the documented guarantee is simply absent, and a reader budgeting airtime from this KDoc is misinformed.

*Verifier correction:* Real, but it is a documentation defect, not a behavioural bug - the finding's own framing ("the documented guarantee is simply absent") is the accurate one and should be the headline. Restate as: BeaconPolicy.firstAnnounceRequestsReplies' KDoc (BeaconPolicy.kt:53-62) claims one reply request per node lifetime rather than per start, justified by hosts that are "launched and killed often". The implementation is a per-instance local (MeshNode.kt:90-95) with no persistence anywhere in the library, so the behaviour is exactly the per-launch one the KDoc disclaims. The monitor (MonitorController.kt:

**[low] MqttFraming justifies admitting our own echoed uplink with an implicit ack that can never fire**

`meshtastic-node-kmp/node-transport-mqtt/src/commonMain/kotlin/org/meshtastic/node/transport/mqtt/MqttFraming.kt:78`

`toCanonical` drops an envelope bearing our own `gateway_id` unless the packet is also from us, and the comment gives the reason: "A packet we originated is deliberately *not* dropped - hearing ourselves is what raises MeshNode's implicit ack" (MqttFraming.kt:78-82). Our own publish echoed back under our own gateway id is byte-identical to what we sent, so `hop_limit == hop_start` and `PacketHeaderView.hopsAway == 0` (PacketCodec.kt:144). `MeshNode.implicitAck` requires `hopsAway > 0` (MeshNode.kt:440) and therefore returns null. The case the exception exists for cannot produce the receipt it names; the only packets that do are the ones arriving under a *foreign* gateway id, which the guard already lets through unconditionally.

*Failure:* A node bridging to a broker with a private/self-hosted setup where its own publishes are echoed back: every uplinked packet of ours re-enters `process()`, is peeked and routed to `implicitAck`, and is discarded with no ack, no rx count and no event. Behaviourally harmless, but the comment is the stated justification for a hole in the MQTT loop guard, and it is false - anyone tightening that guard would remove it believing they were breaking implicit acks.

*Verifier correction:* MqttFraming's own-gateway exception is justified by a comment that names an unreachable mechanism (MqttFraming.kt:78-82, mirrored in MqttDownlinkTest.kt:75-78).

**[low] LocalRadio reports a fixed node_info_broadcast_secs of 3600 regardless of the node's actual beacon policy**

`meshtastic-node-kmp/node-phone-api/src/commonMain/kotlin/org/meshtastic/node/phoneapi/LocalRadio.kt:142`

`configs()` hardcodes `Config.DeviceConfig(role = CLIENT, node_info_broadcast_secs = 3600)` (LocalRadio.kt:142) and never consults the node's `BeaconPolicy`. The default `BeaconPolicy.nodeInfoInterval` is `3.hours` (BeaconPolicy.kt:25), and when `Config.beacon` is null the node never announces at all (MeshNode.kt:82-83). This sits directly against the rest of the file's stated principle - "Every field this node cannot honestly measure is left unset rather than zeroed" (LocalRadio.kt:84-86).

*Failure:* A stock app connects, reads the device config and shows "Node info broadcast: 1 hour". The node is actually announcing every 3 hours, or - with `Config.beacon = null`, which is the library default - never. A user who then tries to change the value over the phone API gets no effect either, since `toRadio` handles only `want_config_id`, `packet`, `heartbeat` and `disconnect` (PhoneApiSession.kt:65-77).

*Verifier correction:* LocalRadio reports a hardcoded `node_info_broadcast_secs = 3600` that matches neither the node's beacon policy nor the firmware default.

**[low] The beacon coroutine launched from init touches properties declared later in the class**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:81`

The `init` block at MeshNode.kt:81-103 does `scope.launch { delay(beacon.initialDelay); announce(...) }`. `announce()` reads `codec` (declared MeshNode.kt:204), `nextPacketId` (215), `deferredEvents` (145) and `_transportStats` (170) - all initialised *after* this `init` block in declaration order. The construction is safe only because `delay(initialDelay)` suspends before any of them is touched. `kotlinx.coroutines.delay` returns without suspending when the duration is <= 0, and `BeaconPolicy`'s init permits `Duration.ZERO` (it requires only `!initialDelay.isNegative()`, BeaconPolicy.kt:77).

*Failure:* A host builds the node on `Dispatchers.Main.immediate` (e.g. a `viewModelScope` on Android's main thread) with `BeaconPolicy(initialDelay = Duration.ZERO)`. `launch` needs no dispatch, the body runs inline inside the constructor, `delay(0)` returns immediately, and `announce()` dereferences `nextPacketId`/`codec` while they are still null - `NullPointerException` from the `MeshNode` constructor, with a stack that names `announce`, not the ordering.

*Verifier correction:* CONFIRMED, with tightened line numbers and a narrowed (but still real) trigger.


### Wire-format parity with the firmware

**[high] Channel hash is computed from the raw name, so a stock default channel imported from a URL never matches the mesh**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/ChannelSetUrl.kt:48`

`ChannelSetUrl.decode` builds `MeshChannel(name = it.name, ...)` verbatim, and `MeshChannel.hash` (MeshChannel.kt:12-18) XORs those raw name bytes. The firmware's `Channels::getName` substitutes the modem-preset display name ("LongFast", …) whenever the stored name is empty, and `Channels::initDefaultChannel` stores exactly that: `strncpy(channelSettings.name, "", …)` with `psk = {1}`. So the node and every radio hash different strings for the stock primary channel.

*Failure:* User imports a shared URL from a stock radio (`https://meshtastic.org/e/#…`, ChannelSettings{name:"", psk:0x01}). Node computes hash = xorHash("") ^ xorHash(defaultKey) = 0x00 ^ K; every radio computes xorHash("LongFast") ^ xorHash(defaultKey) = 0x0A ^ K. The two differ by 0x0A. Outbound: `seal()` stamps `channel` with the node's hash, `Router::perhapsDecode` finds no channel whose `decryptForHash` matches, and drops every packet as bad psk. Inbound: `open()` does `keys.channels.indexOfFirst { it.hash == pkt.channel }` → -1 → returns null → every mesh packet is `Unreadable`. The node is completely invisible on the most common channel in Meshtastic.

*Verifier correction:* REAL DEFECT, high - with two corrections to the evidence.

**[high] forForwarding never recomputes next_hop, so a relayed next-hop-directed packet dies at the hop after this node**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/ProtoPacketCodec.kt:198`

`forForwarding` copies the received packet changing only `hop_limit` and `relay_node`, leaving `next_hop` exactly as the previous hop stamped it. The firmware recomputes it on every relay: `NextHopRouter::sendWithNextHop` does `p->next_hop = getNextHop(p->to, p->relay_node).value_or(NO_NEXT_HOP_PREFERENCE)`, and `perhapsRebroadcast` routes a next-hop-directed relay through `NextHopRouter::send` specifically so that happens.

*Failure:* Radio S sends a DM to D with `next_hop` = this node's last byte. `routedThroughUs` matches, the node relays. The re-broadcast still carries `next_hop` = this node's own last byte. Every downstream radio evaluates `p->next_hop == NO_NEXT_HOP_PREFERENCE || p->next_hop == getLastByteOfNodeNum(getNodeNum())` (NextHopRouter.cpp:261) - neither holds for them - so nobody relays it further and the DM stops one hop past the node. A firmware relay in the same position would either substitute its own learned next hop or fall back to NO_NEXT_HOP_PREFERENCE (flood), and the packet would reach D.

*Verifier correction:* `forForwarding` never recomputes `next_hop`, so a relayed next-hop-directed packet dies one hop past this node whenever the destination is not the node's direct neighbour.

**[medium] An ACK or NAK addressed to another node retires this node's retransmits and is reported as delivery**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:619`

`process()` acts on `DecodedPacket.Ack` and `DecodedPacket.RoutingError` with no check that `header.to == identity.nodeNum`. Firmware's `ReliableRouter::sniffReceived` wraps the entire ack/nak handling in `if (isToUs(p))` with the explicit comment "ignore ack/nak/want_ack packets that are not address to us".

*Failure:* Any ROUTING_APP packet decodable on one of our channels - including one addressed A→B that we merely overhear, or one forged by anyone holding the channel PSK - whose `Data.request_id` equals a pending id calls `retransmits?.acknowledge(requestId)` and emits `MeshEvent.Delivered(header.from, requestId, via)` / `MeshEvent.DeliveryFailed(...)`. The message stops being retried and the host is told it arrived (or was rejected) by a node that never saw it. Combined with the sequential packet ids below, an attacker can compute a future id and pre-forge the ack.

*Verifier correction:* **An ack or nak addressed to another node is reported as our own delivery, and can retire our retransmits**

**[medium] Packet ids are a plain +1 counter, not the firmware's 22-random / 10-counter split, making every future id predictable**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:965`

`nextId()` seeds once from a CSPRNG (MeshNode.kt:215) and thereafter returns `current + 1`. The firmware re-randomises the top 22 bits on every call: `rollingPacketId &= ID_COUNTER_MASK; id = rollingPacketId | random(UINT32_MAX & 0x7fffffff) << 10;` - only the low 10 bits are sequential. The Config KDoc at MeshNode.kt:1010-1018 claims "a predictable id aids traffic correlation" and picks a CSPRNG for exactly that reason, which the increment then defeats.

*Failure:* A passive listener that sees one packet from the node knows every id it will ever send. Because both the node's and the firmware's `PacketHistory` are keyed on `(from, id)` alone, an attacker can broadcast packets carrying `from = victimNodeNum, id = victimNextId…` so every relay records them; the victim's real packets are then dropped as duplicates at every hop (`FloodingRouter::shouldFilterReceived` → "Ignore dupe incoming msg"). Against a firmware node the same attack needs 2^22 guesses per packet. It also makes the ungated-ack finding above trivially exploitable.

*Verifier correction:* `nextId()` (MeshNode.kt:965-974) is a plain 32-bit +1 counter seeded once from the CSPRNG at :215. The firmware re-randomises the top 22 bits on every call (Router.cpp:347-349, `ID_COUNTER_MASK = UINT32_MAX >> 22` at MeshTypes.h:20), so only its low 10 bits are sequential. The divergence is real and worth closing - adopt the 22/10 split in `nextId()`, it is a two-line change - and the Config KDoc at :1009-1018, which names traffic correlation as a reason for the CSPRNG default, is defeated for ids by the increment (it still holds for `extraNonce`, which is drawn per packet).

**[medium] Originated packets carry relay_node = 0, and the last-byte computation omits the firmware's 0 → 0xFF mapping**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/ProtoPacketCodec.kt:310`

`seal()` builds the MeshPacket without setting `relay_node` at all, so every origination goes out with 0. The firmware sets it unconditionally on send - `Router::send`:521, `FloodingRouter::send`:22, `NextHopRouter::sendWithNextHop`:104 - and derives it through `getLastByteOfNodeNum(num) { return (num & 0xFF) ? (num & 0xFF) : 0xFF; }` so the value is never 0. The node uses a raw `and 0xFF` in both places it produces the byte (ProtoPacketCodec.kt:203, MeshNode.kt:192).

*Failure:* (a) Every packet the node originates has relay_node = 0. `NextHopRouter::sniffReceived` gates route learning on `nodeDB->resolveUniqueLastByte(p->relay_node, …)`, which returns early for 0 ("getLastByteOfNodeNum() never yields 0, so nothing can legitimately match"), so no radio ever learns a route to the node and DMs to it always flood. (b) `MeshIdentity.derive` can produce a nodeNum whose low byte is 0x00 (1 in 256 of installs). That node computes `ourLastByte = 0`, while a radio addressing `next_hop` at it writes 0xFF - `routedThroughUs` (MeshNode.kt:706-707) compares 0xFF against 0 and NO_NEXT_HOP(0), both false, so the node silently refuses to relay every packet the mesh explicitly routed through it; and its own relays stamp relay_node = 0, which firmware reads as "no relayer".

*Verifier correction:* Confirmed, with two corrections.

**[medium] A relay drops an originator's reliable retransmission that the firmware deliberately re-relays**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:500`

`process()` treats every `(from, id)` already in history as a hard drop, sending at most an ack when the packet is directly addressed to us. The firmware explicitly does not: `FloodingRouter::shouldFilterReceived` detects `bool isRepeated = p->hop_start > 0 && p->hop_start == p->hop_limit` and, if the packet is not still queued, calls `reprocessPacket(p)` then `perhapsRebroadcast(p)`. It likewise re-relays a duplicate that arrives with a *higher* hop_limit (`perhapsHandleUpgradedPacket`).

*Failure:* Node is configured `RelayPolicy.Meshed` and is the only path between S and D. S sends a want_ack packet; D's ack is lost. S retransmits the identical `(from, id)` with `hop_start == hop_limit`. The node returns `MeshEvent.Dropped(DUPLICATE)` and does not relay, so every retry after the first never reaches D. S burns its whole retransmit budget and reports delivery failure for a destination that is reachable. A firmware relay in the same position forwards each retry.

*Verifier correction:* CONFIRMED (medium). A relay drops an originator's reliable retransmission that the firmware deliberately re-relays.

**[medium] open() tries only the first channel whose hash matches, and interpret() accepts UNKNOWN_APP as a valid decrypt**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/ProtoPacketCodec.kt:282`

`open()` picks `keys.channels.indexOfFirst { it.hash == pkt.channel }` and commits to that key with no verification and no fallthrough. The firmware loops over *every* channel (`for (chIndex = 0; chIndex < channels.getNumChannels(); chIndex++) if (channels.decryptForHash(chIndex, p->channel))`), decrypts each candidate, and only accepts one whose plaintext parses as a `Data` *and* whose `portnum != UNKNOWN_APP`; anything else is logged "bad psk" and the loop continues. `interpret()` has no UNKNOWN_APP guard - portnum 0 falls into `else -> DecodedPacket.Other(data.portnum.value)`.

*Failure:* Two configured channels whose 8-bit hashes collide (roughly 1 in 256 per pair; ~11% somewhere in a full 8-channel set) - the node always decrypts with the lower-indexed one. Every packet on the higher-indexed channel is decrypted with the wrong key and surfaces as `Unreadable`, or, when the garbage happens to parse, as `DecodedPacket.Other(0)`, permanently. Firmware on the same channel set reads both.

*Verifier correction:* `ProtoPacketCodec.open()` (node-core/src/commonMain/kotlin/org/meshtastic/node/ProtoPacketCodec.kt:282-288) selects a channel key with `keys.channels.indexOfFirst { it.hash == pkt.channel }` and commits to it: no plaintext verification, no retry against other channels that share the same 8-bit hash. Firmware's `Router::perhapsDecode` loops every channel whose hash matches, decrypts each candidate, and accepts one only if the plaintext parses as a `Data` *and* `portnum != UNKNOWN_APP`; both failures log "bad psk" and continue to the next candidate. `interpret()` (:338-456) has no UNKNOWN_APP br

**[medium] rx_time is filled from the node's monotonic clock and always marked present, so a stock app timestamps every message at 1970**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:526`

`_packets` emits `pkt.copy(rx_rssi = …, rx_time = (now / 1000).toInt())` where `now = config.clock()`, documented at MeshNode.kt:999 as "Monotonic milliseconds" (uptime, not epoch). `MeshPacket.rx_time` is `Int?` - explicit presence - so this always sets the field. The firmware never does this: `computeRxTimeStamp()` returns `{haveTime ? getValidTime(RTCQualityFromNet) : Time::getUptimeSecs(), haveTime}` and `stampRxTime` stores the validity flag, so a clockless radio sends the field *absent*.

*Failure:* A node with the documented real monotonic clock and one hour of uptime hands the phone API `rx_time = 3600`. `PhoneApiSession` forwards `received.packet` unmodified, and the Android app does `time = (packet.rxTimeOrNull() ?: 0) * 1000L` where `rxTimeOrNull()` only folds an exact 0 - so every message from the node is stored and displayed at 1970-01-01 01:00 and sorts before the entire message history. The correct behaviour is to omit the field (null), which is what a radio with no RTC does.

*Verifier correction:* CONFIRMED, with the trigger threshold and the root cause sharpened.

**[medium] hopsAway is null for a hop_start == 0 sender, breaking duplicate re-acking and route learning for the library's own default policy**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/PacketCodec.kt:144`

`PacketHeaderView.hopsAway` returns null whenever `hopStart == 0`. The firmware resolves that case rather than giving up: `getHopsAway` returns `hop_start - hop_limit` (i.e. 0) as soon as the packet is decoded and `decoded.has_bitfield` is set, which every 2.5.0+ sender - including this library, which always emits `bitfield` - guarantees.

*Failure:* `RelayPolicy.Island` is the node's default and stamps `hop_limit = hop_start = 0`. Peer A (another instance of this library at default config) sends a want_ack DM; our ack is lost; A retransmits. MeshNode.kt:511 evaluates `header.wantAck && header.to == us && header.hopsAway == 0`, and `null == 0` is false, so the duplicate is dropped with no second ack. A exhausts its retransmit budget and raises `DeliveryFailed` for a message we in fact received - the exact failure the duplicate-ack branch was written to prevent. The same null makes `NextHopTable.learnFrom` return false at line 38 (`header.hopsAway != 0`), so no route is ever learned for any Island-policy peer.

*Verifier correction:* `PacketHeaderView.hopsAway` (PacketCodec.kt:144) returns null whenever `hopStart == 0`, and `RelayPolicy.Island` - the library default (MeshNode.kt:982) - stamps `hop_start = hop_limit = 0` (ProtoPacketCodec.kt:322). So every consumer that tests `hopsAway == 0` silently excludes Island-policy senders, which includes every other node running this library at its defaults.

**[medium] NodePosition.truncatedTo can throw out of its own copy(), killing the position beacon coroutine**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/PositionSource.kt:58`

`truncatedTo` masks the low bits and adds half a cell, then returns `copy(...)`, which re-runs the `init` block's `require(abs(latitudeI) <= 900_000_000)` / `require(abs(longitudeI) <= 1_800_000_000)`. The half-cell addition can push a legal coordinate past those limits, so a valid input produces an IllegalArgumentException. The firmware's `truncateCoordinate` performs the identical arithmetic and has no range check at all, so this is a guard the node added that the wire semantics do not have.

*Failure:* Any longitude within 2^(31-bits)/1e7 degrees of ±180 - 0.026° at 13 bits, 0.0066° at 15 bits (the firmware's MAX_POSITION_PRECISION_PUBLIC_KEY), 0.21° at 10 - or any latitude within the same window of ±90, throws. Verified numerically: trunc(1_800_000_000, 13) = 1_800_142_848 > 1_800_000_000. The throw escapes `encodePosition` and propagates out of `positionLoop`, which is launched at MeshNode.kt:99-104 with no try/catch; the position beacon stops for the life of the process, and if the caller's scope uses a plain Job rather than a SupervisorJob the failure cancels the receive pipeline and the announce loop with it.

*Verifier correction:* CONFIRMED, with two corrections and a severity downgrade to low-medium.

**[low] A channel-encrypted TEXT_MESSAGE addressed to this node is accepted and acked; firmware rejects it as a legacy DM**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/ProtoPacketCodec.kt:342`

`interpret()` maps any TEXT_MESSAGE_APP payload to `DecodedPacket.Text(text, direct)` with `direct = false` for a channel decrypt, whatever the destination. Firmware refuses that combination outright inside the channel-decrypt loop: `else if (!owner.is_licensed && isToUs(p) && decodedtmp.portnum == TEXT_MESSAGE_APP) { LOG_WARN("Rejecting legacy DM"); return DecodeState::DECODE_FAILURE; }`.

*Failure:* Anyone holding the channel PSK sends TEXT_MESSAGE_APP with `to` = the node's nodeNum, channel-encrypted. The node surfaces `MeshEvent.TextMessage(from, to = us, direct = false)` and, per MeshNode.kt:533-537, sends an ack for it. A 2.8 radio in the same position drops it and delivers nothing - the check exists specifically to stop a PSK holder downgrading a DM out of PKI.

*Verifier correction:* A channel-encrypted TEXT_MESSAGE addressed to this node is accepted, acked, and forwarded to a connected phone as a DM; firmware rejects it outright as a legacy DM.

**[low] Traceroute reply omits the unknown-hop and unknown-SNR padding the firmware inserts, so route and snr_towards fall out of alignment**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:886`

`answerTraceroute` passes `route = decoded.route` unchanged and `snrTowards = decoded.snrTowards + TRACEROUTE_SNR_UNKNOWN`. The firmware calls `insertUnknownHops(p, r, !incoming.request_id)` *before* `appendMyIDandSNR`: it pads `route` with `NODENUM_BROADCAST` entries until `route_count == getHopsAway(p)`, then pads `snr_towards` with INT8_MIN until it matches `route_count`.

*Failure:* A traceroute request reaches the node at 2 hops but only one upstream relay appended itself - which is exactly what this node's own opaque relaying produces, per its own KDoc at MeshNode.kt:872-875. Firmware would reply with route = [R1, 0xFFFFFFFF] and snr_towards = [s1, INT8_MIN, INT8_MIN]; the node replies with route = [R1] and snr_towards = [s1, -128]. The reply's hop count no longer matches the distance travelled and the per-hop SNR list no longer indexes the route list, so a client rendering hop i against snr_towards[i] shows the wrong reading against the wrong hop.

*Verifier correction:* Traceroute reply omits both of the firmware's pre-append pads, so hops that no node named disappear from the route (and, when the incoming SNR list is short, the destination's own SNR entry is lost).

**[low] PacketHistory's 5-minute expiry is documented as matching the firmware, which has no time-based expiry at all**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/PacketHistory.kt:37`

The KDoc says "The firmware forgets a packet after ~5 minutes; match it so relay behaviour agrees", and `expireBefore(nowMs - 5min)` implements that. The firmware's `PacketHistory` has no age-based eviction: `insert()` takes a free slot, then a matching slot, then the *oldest* slot only when the fixed-size array is full. `RECENT_WARN_AGE` (10 min) is a logging threshold only, and `wasSeenRecently` never consults any age.

*Failure:* With a real monotonic clock, a captured packet replayed six minutes later has been expired from the node's history: it is re-delivered to the host and, under RelayPolicy.Meshed, re-relayed onto every bearer. A firmware node whose PACKETHISTORY table has not yet wrapped still has the `(sender, id)` record and suppresses it. The two disagree exactly where the comment claims they agree.

*Verifier correction:* PacketHistory.kt:37 documents a firmware behaviour that was removed from firmware in June 2025; the constant is fine, the stated rationale is false.


### Relay, routing and loop safety

**[high] A stock phone app defeats RelayPolicy.Island: sendPacket honours the phone's hop_limit and never clamps it**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:387`

`MeshNode.sendPacket` computes `val hopLimit = if (packet.hop_limit > 0) packet.hop_limit else relayPolicy.hopLimit`, so any packet arriving over the phone API with a non-zero hop_limit bypasses the relay policy entirely. RelayPolicy's KDoc calls itself "the safety lever" and Island promises "never be relayed", but that promise only holds for `sendText`/`announce`/`positionLoop`, which pass `relayPolicy.hopLimit` directly. The same line also applies no HOP_MAX bound: `RelayPolicy.Meshed` enforces `require(hopLimit in 1..HOP_MAX)` and `process()` line 495 drops ingress with `hopLimit > RelayPolicy.HOP_MAX`, but egress through sendPacket has neither check, and `ProtoPacketCodec.seal` stamps `hop_limit = hopStart = hopLimit` verbatim.

*Failure:* Node built with the default `RelayPolicy.Island` and `node-phone-api`. `LocalRadio.configs()` (LocalRadio.kt:151) reports `lora.hop_limit = node.relayPolicy.hopLimit` = 0. Meshtastic-Android's `CommandSenderImpl.computeHopLimit()` is `(localConfig.lora?.hop_limit ?: 0).takeIf { it > 0 } ?: DEFAULT_HOP_LIMIT` (CommandSenderImpl.kt:106) with `DEFAULT_HOP_LIMIT = 3` (line 570), and `buildMeshPacket` stamps it on every outgoing packet (line 509). So the app sends hop_limit=3, `PhoneApiSession.send` calls `node.sendPacket(packet)` (PhoneApiSession.kt:108), and every message the user types is flooded three hops into the LoRa mesh from a node whose configured policy is "talk only to nodes in direct range". Separately, a phone (or a hostile local app on the phone-API socket) handing `hop_limit = 200` produces a frame with `hop_start = hop_limit = 200` on the air.

*Verifier correction:* A stock phone app defeats RelayPolicy.Island: MeshNode.sendPacket honours the phone's hop_limit and never clamps it.

**[high] A learned next_hop is never invalidated, so a neighbour moving out of direct range permanently black-holes DMs to it**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/NextHopTable.kt:28`

`nextHopFor` is a bare `routes.get(nodeNum)` with no freshness, liveness or failure check, and `NextHopTable.forget` - whose KDoc says "Called when it stops working; flooding is the correct thing to fall back to" - is never called anywhere in the library (grep for `routes.forget` / `.forget(` over all non-test sources returns only NextHopTable.kt:51 itself and the unrelated GATT arbiter). `MeshNode` has three places that learn the route is dead (`DeliveryFailure.MAX_RETRANSMIT`, `DeliveryFailure.REJECTED`, `DeliveryFailure.NO_INTERFACE`) and none of them touch `routes`. The firmware it is modelled on guards the same byte at *read* time twice over: `isRouteStale` clears the stored hop on age/failure (NextHopRouter.cpp:315-321) and `resolveLastByte(node->next_hop, requireDirectNeighbor=true)` refuses to emit a hint for a neighbour that has gone away (NextHopRouter.cpp:329). node-kmp has neither, and its only guard - uniqueness among `directory.all()` - is applied at write time only.

*Failure:* Peer P is heard directly (hopsAway == 0, last byte unique), so `learnFrom` stores `routes[P] = P & 0xFF`. P then moves one hop away, behind relay R. `sendText(to = P)` / `sendPacket` set `nextHop = routes.nextHopFor(P)` = P's last byte (MeshNode.kt:355, 386). R evaluates `p->next_hop != NO_NEXT_HOP_PREFERENCE && p->next_hop != R's last byte` (NextHopRouter.cpp:261, mirrored by node-kmp's own `routedThroughUs`, MeshNode.kt:706) and refuses to relay. Nothing else will either. Every DM to P is dropped at hop one, `reliableDelivery` burns its attempts and reports MAX_RETRANSMIT, and the route is still there for the next message - forever, since only LRU pressure from 120 other learned routes can remove it. Broadcasts are unaffected (`nextHop` is forced to NO_NEXT_HOP for them), so the mesh looks healthy while direct messages to that one peer are silently unreachable.

*Verifier correction:* A learned next_hop is never invalidated, so a neighbour that moves out of direct range black-holes DMs to it for the life of the process.

**[medium] forForwarding relays a unicast without rewriting next_hop, so the relayed copy still names this node and dies at the next hop**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/ProtoPacketCodec.kt:198`

`forForwarding` copies the packet changing only `hop_limit` and `relay_node`; `next_hop` is left exactly as received. `scheduleRelay` accepts a packet when `routedThroughUs(header)` - i.e. when `next_hop` is NO_NEXT_HOP *or equals our own last byte* (MeshNode.kt:706) - so in the second case the frame we put back on the air still says "only the node whose last byte is X may relay this", where X is us. The firmware never does this: every rebroadcast of a next-hop-routed packet goes through `NextHopRouter::send` -> `sendWithNextHop`, which recomputes `p->next_hop = getNextHop(p->to, p->relay_node)` before transmitting (NextHopRouter.cpp:107, reached from perhapsRebroadcast at NextHopRouter.cpp:282).

*Failure:* Radio A has learned that this node is the next hop toward D and sends a DM with `next_hop = <our last byte>`, `hop_limit = 3`. We accept it (routedThroughUs true), relay it with `hop_limit = 2` and `next_hop` unchanged. D is two hops away behind radio R. R evaluates `p->next_hop != NO_NEXT_HOP_PREFERENCE && p->next_hop != R's last byte` and declines to rebroadcast; so does every other node except the ~1/256 that happen to share our last byte. The DM is lost, and A's next-hop route through us keeps being reinforced because our relay stamped `relay_node = us`. The same pattern exists in the firmware's opaque relay path (`NextHopRouter::relayOpaquePacket` decrements hop_limit and sets relay_node but calls `Router::send`, which never touches next_hop - NextHopRouter.cpp:52-65, called from Router.cpp:1707), but that file is not part of the spike diff, so it is an upstream issue rather than one this feature introduced.

*Verifier correction:* CONFIRMED as written, with three additions and one softening.

**[medium] The duplicate-re-ack path is dead for any sender using the library's default RelayPolicy.Island**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:511`

The re-ack guard is `if (header.wantAck && header.to == identity.nodeNum && header.hopsAway == 0)`. `hopsAway` is `Int?` and is `null` whenever `hopStart == 0` (`PacketCodec.kt:144`: `if (hopStart > 0) hopStart - hopLimit else null`). `RelayPolicy.Island` has `hopLimit = 0` and `seal()` stamps `hop_start = hopLimit`, so every packet a default-configured node originates carries `hop_start = 0` and reads back as `hopsAway == null`. `null == 0` is false, so the branch never runs. The comment directly above it states the purpose - "Our ack was lost, so the sender is trying again... dropping silently leaves it retrying until its budget runs out and then reporting a failure for a message we in fact received" - and that is exactly what happens. Note the non-duplicate ack at line 533 has no hopsAway condition at all, so the first copy *is* acked; only the retry is not.

*Failure:* Two node-kmp nodes on the default `RelayPolicy.Island`, sender configured with `reliableDelivery` (which `Config.validated()` forces to carry a real clock). A sends a DM with want_ack. B receives it, acks, the ack is lost on the medium. A retransmits the identical bytes. B's `history.wasSeenRecently` returns true, control reaches line 511, `header.hopsAway` is null because A stamped hop_start = 0, no ack is sent. A exhausts `reliableDelivery` attempts and raises `MeshEvent.DeliveryFailed(MAX_RETRANSMIT)` for a message B received and displayed. A firmware sender is unaffected because firmware always stamps hop_start = hop_limit >= 1.

*Verifier correction:* Real defect, confirmed, with two corrections to the finding's framing.

**[medium] BoundedLru.put can evict the entry it just inserted when it is the only one matching preferEvict**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/BoundedLru.kt:62`

`val victim = next.entries.firstOrNull { preferEvict(it.value) } ?: next.keys.iterator().next()` searches the whole map *including the key appended on the line above*. The comment on line 61 asserts the opposite: "Iteration is oldest-first and the key just appended is last, so it is never a victim." That reasoning holds for the plain-LRU fallback, but not for the preferEvict scan: when the newly inserted value is the only one satisfying the predicate, `firstOrNull` returns it and `next.remove(victim)` discards the write.

*Failure:* `NodeDirectory` passes `preferEvict = { it.publicKey == null }` (NodeDirectory.kt:51). Fill the directory to its 120-entry capacity with peers that all carry a public key - the steady state on any firmware-2.5+ mesh, since every node broadcasts an X25519 key in its NodeInfo. Now hear a packet from a new node: `heard()` -> `upsert` builds `Peer(nodeNum)` with `publicKey = null` and calls `lru.put`. `next` has 121 entries; the predicate matches only the last one; the new peer is removed and the map returns to the same 120 keyed peers. `heard()` still returns the Peer and `_peers.value = lru.values()` re-emits a list that does not contain it, so `directory.get(newNode)` is null, `publicKeyOf` is null, the node never appears in the peers StateFlow, and `routes.learnFrom` is handed a knownNodes list that omits the very sender it is learning about (MeshNode.kt:518-519). Every subsequent packet from that node repeats the full 120-entry LinkedHashMap copy and discards it. The node is only ever admitted once its NodeInfo arrives carrying a 32-byte key (up to an hour on a radio's default broadcast interval), because `learn()` then produces a non-matching value and the fallback evicts the oldest entry correctly.

*Verifier correction:* **Real defect, medium severity, and the trigger condition is the attractor state rather than a corner case.**

**[medium] The spike's two BLE ingress paths clear via_mqtt, re-arming the MQTT republish loop and defeating lora.ignore_mqtt**

`firmware/src/mesh/BLEMeshHandler.cpp:151`

`BLEMeshHandler::deliverToRouter` and `BLEGattMeshHandler::deliverToRouter` both set `mp.via_mqtt = false` on every received frame, each commented as mirroring `UdpMulticastHandler`. `UdpMulticastHandler::onReceive` does not do this - it clears `pki_encrypted`, `public_key`, `rx_snr`/`rx_rssi` and stamps `transport_mechanism`, but leaves `via_mqtt` alone (UdpMulticastHandler.h:95-108). Nor does LoRa: the flag is carried on the air in the packet header (`PACKET_FLAGS_VIA_MQTT_MASK`, RadioInterface.cpp:1516) and restored on receive (RadioLibInterface.cpp:681). So the two new bearers are the only ingress paths in the firmware that destroy the flag, and the comment's stated rationale ("a sender must not suppress our MQTT uplink") describes a different concern from the flag's actual job, which is `MQTT::onSend`'s first line: `if (mp_encrypted.via_mqtt) return; // Don't send messages that came from MQTT back into MQTT` (MQTT.cpp:701-702).

*Failure:* A node-kmp node bridges MQTT and BLE-adv. It downlinks packet P from the broker - `MqttFraming.toCanonical` stamps `via_mqtt = true` (MqttFraming.kt:93) - and relays it onto BLE-adv with the flag intact (`forForwarding` preserves it). Firmware radio R hears the advertisement; `deliverToRouter` clears via_mqtt at line 151. R decodes P (it holds the channel key), and `Router::handleReceived`'s receive-side uplink fires on `decodedState == DECODE_SUCCESS && moduleConfig.mqtt.enabled && !isFromUs(p) && mqtt` (Router.cpp:1612-1636) - the loop guard in `MQTT::onSend` sees `via_mqtt == false` and R republishes to the broker a packet that came off the broker. Every BLE-mesh-reachable gateway does the same once. Bounded by each gateway's PacketHistory, so it is amplification rather than an unterminated loop, but it is exactly the republish the flag exists to stop. Second, independent consequence: `Router.cpp:1678` implements the user-facing `config.lora.ignore_mqtt` as `if (config.lora.ignore_mqtt && p->via_mqtt) drop` - a user who has switched that on still receives MQTT-sourced traffic whenever it reaches them over BLE-adv or BLE-GATT.

*Verifier correction:* The finding stands as written; the two file:line citations should be tightened to BLEMeshHandler.cpp:151 and BLEGattMeshHandler.cpp:367 (the latter was given as a 364-373 range), and UdpMulticastHandler.h lives at src/mesh/udp/UdpMulticastHandler.h. Two additions and one framing note:

**[low] node-kmp never stamps relay_node on its own originations, so every packet it sends carries the firmware's "no relayer" sentinel**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/ProtoPacketCodec.kt:313`

`seal()` builds the outgoing `MeshPacket` without setting `relay_node`, so it is 0 on every text, NodeInfo, position, ack and traceroute reply this library originates. Only `forForwarding` sets it (line 203). The firmware sets it unconditionally on every transmission, originations included: `p->relay_node = nodeDB->getLastByteOfNodeNum(getNodeNum())` in `Router::send` (Router.cpp:521) and again in `NextHopRouter::sendWithNextHop` (NextHopRouter.cpp:104). Zero is not a neutral value there - `PacketHistory::wasRelayer` treats `relayer == 0` as "no" (PacketHistory.cpp:463-468) and empty `relayed_by[]` slots are 0.

*Failure:* Two concrete effects. (a) A radio whose NodeNum's low byte is 0x00 evaluates `if (p->relay_node == ourRelayID)` as true for every node-kmp origination it merely hears, and records `weWillRelay = true`, `setOurTxHopLimit(r, p->hop_limit)` and `r.relayed_by[0] = 0` for a packet it never relayed (PacketHistory.cpp:86-92), which then feeds `wasRelayer(ourRelayID, found)` - the `PacketRecord&` overload at PacketHistory.cpp:493 has no zero guard, unlike the `(relayer, id, sender)` one - and so feeds `NextHopRouter::sniffReceived`'s next-hop learning with a relayer it invented. (b) No firmware node can ever learn a next hop toward a node-kmp node from an ACK or reply, because that learning reads `p->relay_node` and `resolveUniqueLastByte(0)` resolves nothing (NextHopRouter.cpp:189-198), so DMs to this node always flood.

*Verifier correction:* node-kmp never stamps `relay_node` on its own originations, so firmware neighbours cannot learn a next hop toward it

**[low] process() range-checks hop_limit on ingress but not hop_start, unlike every other ingress path in the system**

`meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:495`

`if (header.hopLimit > RelayPolicy.HOP_MAX) return Dropped(BAD_HOP_COUNT)` bounds hop_limit but says nothing about hop_start, so `hopsAway = hopStart - hopLimit` (PacketCodec.kt:144) is attacker-controlled and unbounded for anything arriving over UDP, BLE-adv, BLE-GATT or LoRa. Every comparable ingress point checks both: `MqttFraming.toCanonical` does `if (packet.hop_limit > RelayPolicy.HOP_MAX || packet.hop_start > RelayPolicy.HOP_MAX) return null` (MqttFraming.kt:84), and so do all three firmware transports (UdpMulticastHandler.h:91, BLEMeshHandler.cpp:143, BLEGattMeshHandler.cpp:359).

*Failure:* A peer sends a frame with `hop_start = 4000000000, hop_limit = 3`. It passes line 495, `hopsAway` evaluates to a huge positive number, and it is used as a boolean-ish predicate in three places - `implicitAck` (`(hopsAway ?: 0) > 0`, line 440), `answerTraceroute`'s broadcast guard (line 882), and `NextHopTable.learnFrom`'s `hopsAway != 0` (NextHopTable.kt:38). Consequences are mild because all three only compare against 0, but the frame is also handed to `_packets` and reaches a connected phone through node-phone-api with the bogus value intact, and the inconsistency means the MQTT bearer rejects a frame that the UDP bearer accepts.

*Verifier correction:* process() range-checks hop_limit on ingress but not hop_start, unlike every other ingress path in the system


### Concurrency and lifetime

**[high] RetransmitQueue's plain LinkedHashMap is mutated from two dispatchers at once**

`/Users/james/nixtastic/meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/RetransmitQueue.kt:81`

RetransmitQueue.kt:63-66 asserts "Single-writer, like PacketHistory: MeshNode.process and the send path are the only callers and they are serialised by the node's own scope, so the read-modify-write sequences here are safe without locking." That serialisation does not exist. `pending` is a bare LinkedHashMap and MeshNode holds no Mutex anywhere (no `kotlinx.coroutines.sync` import in MeshNode.kt). The send path is `MeshNode.sendText`/`sendPacket` - public suspend functions with no documented threading contract - which reach `originate()` (MeshNode.kt:454) and `retransmits?.track(...)` (MeshNode.kt:466) on whatever coroutine the caller is on, while `pumpRetransmits()` (MeshNode.kt:403) runs `queue.due(now)` and `queue.expired(now)` on the receive collector, and `process()` runs `retransmits?.acknowledge(...)`.

*Failure:* On the shipping desktop path: MonitorController builds the node on `nodeScope`, derived from Compose's `rememberCoroutineScope()` (Main.kt:18) - the Swing EDT - and unconditionally starts the phone-API TCP server (Platform.jvm.kt:75-82). PhoneApiTcpServer.kt:63-71 reads the socket inside `withContext(Dispatchers.IO)` and calls `session.toRadio(payload)` there; PhoneApiSession.kt:107-111 calls `node.sendPacket(packet)`. A phone sending a direct message with want_ack (which the stock Android app does) therefore executes `pending[id] = Pending(...)` on an IO thread while the EDT is inside `pending.values.filter { ... }` in `due()` (line 105) or `pending.remove(entry.id)` in `expired()` (line 123). Result: ConcurrentModificationException or a corrupted/rehashing LinkedHashMap. The CME is swallowed by MeshNode.kt:272-279 ("A retransmission that throws must not tear down the receive pipeline"), so the visible symptom is not a crash but retransmission silently ceasing while `MeshEvent.DeliveryFailed` is never raised - the phone sits at "Sending..." forever, which is the exact failure `reliableDelivery` was added to fix.

*Verifier correction:* **RetransmitQueue's plain LinkedHashMap is mutated from two dispatchers at once (desktop phone-API path)** - high, confirmed.

**[high] The phone-API config dump silently drops its oldest frames once the node knows ~32 peers**

`/Users/james/nixtastic/meshtastic-node-kmp/node-phone-api/src/commonMain/kotlin/org/meshtastic/node/phoneapi/PhoneApiSession.kt:29`

`outbound` is `Channel<ByteArray>(capacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)` and `emit()` (line 140-142) uses `outbound.send(...)`, which under DROP_OLDEST never suspends and never fails - it evicts the head instead. `sendConfig()` (lines 91-105) pushes a fixed 33 frames (my_info + own node_info + metadata + 8 channels + 8 Configs + 13 ModuleConfigs + config_complete_id) plus one `node_info` per entry of `radio.otherNodes()`, which is `node.directory.all()` minus self (LocalRadio.kt:121-123) - up to 119, since NodeDirectory's default capacity is 120 (NodeDirectory.kt:126). The producer runs at memory speed on Dispatchers.IO while the only consumer is a separate coroutine doing blocking `out.write` + `out.flush` per frame (PhoneApiTcpServer.kt:55-61).

*Failure:* A node that has heard 32 or more other peers - ordinary on any real mesh, and the directory holds 120 - overflows the 64-slot channel during the dump. DROP_OLDEST discards the *head*, i.e. `my_info`, the node's own `node_info`, `metadata`, the channel list and the Configs - precisely the frames the client needs to know the node number and the channel keys - while the tail (peer node_infos and `config_complete_id`) survives, so the app believes configuration completed. Nothing counts or reports the loss: `queueStatus()` (lines 131-138) hardcodes `free = OUTBOUND_CAPACITY, maxlen = OUTBOUND_CAPACITY` regardless of actual occupancy.

*Verifier correction:* Title: the phone-API config dump is pushed through a lossy DROP_OLDEST channel and loses frames mid-dump on a node with many peers, while still reporting config_complete

**[medium] MQTT inbound frames are dropped with the trySend result discarded and no counter**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-mqtt/src/commonMain/kotlin/org/meshtastic/node/transport/mqtt/MqttBridgeTransport.kt:113`

`clientScope.launch { client.messages.collect { trySend(InboundFrame(it.payload.toByteArray())) } }` discards the `ChannelResult`. The enclosing `channelFlow` has the default BUFFERED capacity (64) and there is no `.buffer(...)` and no drop counter on this transport, unlike every other bearer in the library: UDP counts into `dropped`/`droppedFrameCount` (UdpMulticastTransport.kt:73-102), the GATT link counts into `droppedChunks`/`droppedChunkCount` (GattLinkBase.kt:103-113, 179-185), and LoRa counts `rxDropped` (LoraTransport.kt receive()).

*Failure:* Subscribed to a busy public broker (`framing.subscriptions()` fans out over the configured channels), a burst of retained/backlogged envelopes exceeding 64 while the node's receive pipeline is busy silently discards the excess. `MeshNode.transportStats` shows the `mqtt` row with a plausible rx count and `failures = 0`, `availability` reads Active, and there is no counter anywhere that says frames reached the process and were thrown away - the exact "a slow consumer looks like a quiet network" failure the other three transports each added a counter to rule out.

*Verifier correction:* MQTT inbound frames can be dropped silently: the `trySend` result at MqttBridgeTransport.kt:113 is discarded and this transport publishes no drop counter (severity: low-medium).

**[medium] All three BLE-advertisement radios drop scan results uncounted**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-ble/src/androidMain/kotlin/org/meshtastic/node/transport/ble/BleMeshRadio.android.kt:86`

`trySend(BleAdvertisement(body, result.rssi))` in the Android `ScanCallback.onScanResult` discards its result, inside a bare `callbackFlow` (line 81) with no explicit capacity - the default BUFFERED (64). The same pattern with the same discarded result appears at BleMeshRadio.apple.kt:89 and BluezBleMeshRadio.kt:82. `BleMeshTransport` (BleMeshTransport.kt:39-44) adds no counter either, so the `ble-adv` bearer has no drop diagnostic at all.

*Failure:* `onBatchScanResults` (line 90-92) re-enters `onScanResult` for a whole batch in one callback, so a batched scan delivery larger than the free buffer space drops the tail with no trace. In a dense mesh - the case the advertisement transport exists for - `ble-adv` reports a healthy rx count while frames that reached the phone's Bluetooth stack never reach the node, and there is no counter to distinguish that from a quiet radio.

*Verifier correction:* All three BLE-advertisement radios discard the `trySend` result, so ble-adv has no drop diagnostic (low)

**[medium] GattLinkBase.peerLocks grows with every connection ever made and is never cleared**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-ble-gatt/src/commonMain/kotlin/org/meshtastic/node/transport/ble/gatt/GattLinkBase.kt:93`

`peerLocks: MutableMap<String, Mutex>` is only ever inserted into (`lockFor`, line 96-98) and never removed from. `inbound()`'s teardown (lines 200-204) closes the control channel, calls `stop()` and `peers.clear()` - which also clears the arbiter (GattPeerTable.kt:354-357) - but does not touch `peerLocks`, so the map also survives a full collect/cancel/re-collect cycle of the same link object. The KDoc at lines 89-91 acknowledges "Entries are not reaped" and justifies it with "[MAX_LINKS] bounds the latter", but MAX_LINKS (=3) bounds *concurrently held* peers, not the cumulative set of tokens.

*Failure:* On Apple the peer id is a per-connection token in both roles: `CBCentral.identifier.UUIDString` for a subscriber (GattLink.apple.kt:258) and `CBPeripheral.identifier.UUIDString` for a writable peer, and the disconnect handler's own comment (GattLink.apple.kt ~line 425) states "after a disconnect the peer re-advertises under a rotated random address / new identifier". A long-running iOS node in a churning crowd therefore accumulates one `Mutex` plus its String key per connection event, permanently, for the life of the `AppleGattLink` instance - which in the monitor is rebuilt only when a tuning knob changes. Because `MeshNode.events` uses `SharingStarted.WhileSubscribed` with a 0 stop timeout, every subscriber gap also re-collects `inbound()` without resetting the map.

*Verifier correction:* **GattLinkBase.peerLocks is never reaped, so it grows for the life of the link instance** (severity: low)

**[medium] MonitorController's peer mirror is unbounded and survives every node rebuild**

`/Users/james/nixtastic/meshtastic-node-kmp/monitor/src/commonMain/kotlin/org/meshtastic/node/monitor/MonitorController.kt:66`

`private val peers = LinkedHashMap<Long, PeerRow>()` is written on every `MeshEvent.PeerUpdated` (lines 361-373) and is never evicted from, never capped, and never cleared - `stop()` (287-300) and `restart()` (311-318) leave it intact, so it also accumulates across node rebuilds under a changed identity. The library's own directory that feeds it is explicitly bounded: `NodeDirectory` uses `BoundedLru<Long, Peer>(capacity)` with `DEFAULT_CAPACITY = 120` (NodeDirectory.kt:51, 126). The monitor's mirror silently removes that bound.

*Failure:* Every distinct `from` that ever produces a decodable NodeInfo adds a permanent entry, and the growth is driven by traffic a stranger controls - anyone holding the LongFast PSK can mint NodeInfos under arbitrary node numbers. Worse, `onEvent` copies the whole map into the rendered state on *every* received frame (`peers = peers.values.toList()`, line 384), so the per-frame cost grows linearly with the number of node numbers ever seen while the node itself has long since evicted them - the dashboard's peer list and the node's directory drift apart and the copy gets steadily more expensive.

*Verifier correction:* **MonitorController hand-folds a peer map the library added `MeshNode.peers` to prevent, and that map is unbounded and never cleared**

**[medium] MqttBridgeTransport teardown blocks uncancellably behind the client's connection mutex**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-mqtt/src/commonMain/kotlin/org/meshtastic/node/transport/mqtt/MqttBridgeTransport.kt:125`

The flow's `finally` runs `withContext(NonCancellable) { runCatching { client.close() } }` with no timeout. `MqttClient.close()` (MQTTastic-Client-KMP core MqttClient.kt:663-685) sets `closed = true` and then *must acquire* `connectionMutex` before it can cancel `reconnectJob`. The auto-reconnect loop that `autoReconnect = true` (line 99) enables holds that same mutex across `connectInternal(endpoint)` and `resubscribe()` (MqttClient.kt:929-933), and `connect()` holds it across the whole TCP connect plus CONNECT/CONNACK exchange (MqttClient.kt:386ff).

*Failure:* Cancel the transport (a `tune()`/`toggleTransport` in the monitor, or the last `events` subscriber leaving) while the reconnect loop is inside `connectInternal` against an unreachable broker. `close()` blocks on `connectionMutex` inside `NonCancellable`, so the cancellation cannot proceed and the collector never completes. `MonitorController.restart()` (line 315) does `previous?.join()` before starting the new node, so the whole dashboard stalls mid-rebuild with no error - the transport rows freeze and nothing says why. The stall lasts as long as the in-flight connect attempt; I did not verify MQTTastic's TCP connect timeout, so the duration is unknown but is at minimum an OS SYN timeout. The in-repo precedent for bounding exactly this is LoraTransport.kt's `TEARDOWN_TIMEOUT_MS = 500` wrapped around `d.sleepWarm()` in its own NonCancellable teardown.

*Verifier correction:* MqttBridgeTransport teardown can block for minutes behind the MQTT client's connection mutex (unbounded NonCancellable close)

**[medium] Apple notify() prunes a subscriber that subscribed a moment earlier, and nothing re-adds it**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-ble-gatt/src/appleMain/kotlin/org/meshtastic/node/transport/ble/gatt/GattLink.apple.kt:499`

`notify()` snapshots `characteristic.subscribedCentrals` (line 499) from the send coroutine, then calls `peers.retainSubscribers(liveIds)` (line 501), which drops from the table every subscriber not in that snapshot (GattPeerTable.kt:325-329). `peripheralManager(_, central, didSubscribeToCharacteristic:)` runs on the CoreBluetooth dispatch queue and is the *only* caller of `peers.subscribed(...)` on this platform - there is no `didUnsubscribe` wiring and iOS does not repeat the subscribe callback.

*Failure:* A central whose subscribe callback lands between the `subscribedCentrals` read and the `retainSubscribers` call is added to the table and immediately pruned out of it for the life of that connection. It still physically receives every notification, because `manager.updateValue(data, characteristic, null)` with a nil central reaches all subscribed centrals regardless of the table - but the link no longer knows about it: it is never returned in the delivered set, so `broadcastPacket` never attributes delivery to it, it never appears in `GattLinkStatus.subscribers` (so the dashboard under-reports the link), and it stays permanently in `ungreetedSubscribers`… no - it is gone from the table entirely, so `greet()` never offers it a HELLO again and the arbitration election for that pair can never settle, leaving both directions carrying traffic for a pair that should have shed one. If it was the *only* subscriber, `broadcastPacket` line 299 sees `subs.isEmpty()` and skips notify altogether, so it is silenced outright.

*Verifier correction:* Apple notify() can prune a subscriber that subscribed microseconds earlier, and nothing ever re-adds it (GattLink.apple.kt:499-501)

**[low] GattLinkBase drops control chunks uncounted two lines above the counted drop**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-ble-gatt/src/commonMain/kotlin/org/meshtastic/node/transport/ble/gatt/GattLinkBase.kt:178`

`control.trySend(chunk)` discards its result. The control channel has capacity `CONTROL_BUFFER = 32` (line 28). The very next branch (lines 179-185) counts its drops into `droppedChunks` with the comment "every one is counted so it is no longer silent" - the control path has no equivalent counter and is not covered by `droppedChunkCount`.

*Failure:* A burst of control chunks - or a stalled `for (chunk in control) settle(chunk)` consumer (line 187-189), which is starved whenever the same callbackFlow scope is busy - overflows 32 and discards a HELLO. The far side has already marked us greeted the moment its local stack accepted the write (GattLinkBase.kt:214 `if (lockFor(peer.id).withLock { write(peer, hello) }) peers.greeted(peer.id)`), so it never re-sends. The KDoc at lines 237-241 claims the 2 s sweep covers exactly this ("a chunk lost to a full inbound buffer would otherwise stall the election"), but `resolve()` only re-runs over `arbiter.knownPeers()` - a peer whose HELLO was lost was never identified, so it is not in that set and the sweep cannot recover it. The pair keeps both GATT directions open until one side reconnects, with no counter recording that it happened.

*Verifier correction:* GattLinkBase.kt:178 - control-chunk drops are uncounted, breaking `droppedChunkCount`'s documented contract, and nothing recovers a lost HELLO.

**[low] MeshNode.lastAnnounceMs is a plain var written from at least three coroutines**

`/Users/james/nixtastic/meshtastic-node-kmp/node-core/src/commonMain/kotlin/org/meshtastic/node/MeshNode.kt:112`

`private var lastAnnounceMs: Long? = null` is a non-volatile, non-atomic field. It is written at line 799 from `announce()` - which the beacon loop launched in `init` (lines 53-63) drives, and which is also public API callable from any coroutine - and written at line 929 and read at line 910 from `replyWithNodeInfo()`, which runs on the receive collector. Every other piece of cross-coroutine state in this class is deliberately atomic or copy-on-write: `nextPacketId` is an `AtomicLong`, `answeredNodeInfo` a `BoundedLru`, `PendingRelay.claimed` an `AtomicBoolean`, and the KDoc at lines 82-90 explains that reasoning for `pendingRelays`.

*Failure:* On a multi-threaded scope (`CoroutineScope(Dispatchers.Default)`, which nothing in the library forbids), the receive collector reading `lastAnnounceMs` at line 910 can miss a write made by the beacon coroutine at line 799 with no happens-before edge, so `BeaconPolicy.minimumSpacing` is not enforced and the node answers a NodeInfo request it should have throttled - the firmware throttle this reproduces exists to stop two nodes turning a shared channel into a conversation. It is also a torn read of a boxed `Long?` reference in principle.

*Verifier correction:* MeshNode.lastAnnounceMs is a plain `var` raced between the beacon coroutine and the receive collector

**[low] JavaNetSocket.receive() busy-spins on a repeating non-close exception**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-udp/src/jvmAndroidMain/kotlin/org/meshtastic/node/transport/udp/UdpMulticastSocket.jvmAndroid.kt:89`

`receive()` loops `while (!socket.isClosed)` and swallows every exception with `catch (_: Exception) { if (socket.isClosed) return null }`. There is no delay and no failure budget on the path where `socket.receive(datagram)` throws while the socket remains open.

*Failure:* Any repeating open-socket failure - a SecurityException from a SecurityManager/policy, or a persistent IOException from the interface (Android's Wi-Fi dropping while the socket stays open, a route disappearing) - spins the loop at full speed on a `Dispatchers.IO` thread with no yield, burning a core and never reporting anything. The transport looks perfectly idle from above: no exception escapes to `MeshNode`'s `.catch` at MeshNode.kt:246, so `failures` stays 0 and no `MeshEvent.TransportFailed` is raised, which is precisely the "a dead bearer reads exactly like an idle one" case the surrounding code was written to eliminate.

*Verifier correction:* `JavaNetSocket.receive()` (node-transport-udp/src/jvmAndroidMain/.../UdpMulticastSocket.jvmAndroid.kt:89-100) retries a catch-all `Exception` with no delay, no counter and no failure budget; the loop's only exits are a successful receive or `socket.isClosed`. Because the JVM body has no suspension point, a repeating open-socket failure spins a `Dispatchers.IO` thread at full speed and is not cancellable from inside - it unwinds only when `awaitClose { socket.close() }` (UdpMulticastTransport.kt:107) fires on collector cancellation, so it burns a core for as long as anything is collecting.


### Transport seams and availability honesty

**[high] Android BLE-advertisement send() returns true without ever reading the advertising callback's status**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-ble/src/androidMain/kotlin/org/meshtastic/node/transport/ble/BleMeshRadio.android.kt:165`

`AndroidBleMeshRadio.advertise()` builds `val callback = object : AdvertisingSetCallback() {}` (line 165), calls `advertiser.startAdvertisingSet(parameters, data, null, null, null, callback)` (167), sleeps `durationMs` and returns a hard-coded `true` (171). `startAdvertisingSet` is asynchronous and reports every failure through `AdvertisingSetCallback.onAdvertisingSetStarted(set, txPower, status)` with `ADVERTISE_FAILED_DATA_TOO_LARGE`, `ADVERTISE_FAILED_TOO_MANY_ADVERTISERS`, `ADVERTISE_FAILED_INTERNAL_ERROR`, etc. That override is not implemented, so no failure status is ever observed and `true` here means only "we called an async API" - weaker even than "the local stack accepted it".

*Failure:* Pixel with Bluetooth on and every permission granted, but the controller's advertising instances already taken (the GATT transport in this same library registers its own discoverability advertisement, and any other app can too). `startAdvertisingSet` fails asynchronously with ADVERTISE_FAILED_TOO_MANY_ADVERTISERS. `send()` returns true anyway. In MeshNode.broadcast (node-core/.../MeshNode.kt:958-959) `carried += "ble-adv"` and the bearer's `tx` counter is incremented; in scheduleRelay (:686-690) every name in `carried` also gets `relayed + 1` and a `MeshEvent.Relayed` is emitted; in originate (:462-470) a non-empty `carried` makes `sendText`/`sendPacket` return true and starts `retransmits.track(...)` reliable delivery. The monitor's ble-adv row shows a rising tx and relayed count, the log shows "sent over ble-adv", and not one byte reached the air.

*Verifier correction:* Android BLE-advertisement `send()` returns a hard-coded `true` without ever reading the advertising callback's status.

**[medium] Android BLE availability checks API-31-only permission names on a minSdk-26 module, so BLE reports NeedsPermission forever on API 26-30**

`/Users/james/nixtastic/meshtastic-node-kmp/node-core/src/androidMain/kotlin/org/meshtastic/node/transport/BluetoothAvailability.android.kt:44`

`bluetoothAvailability` resolves the first permission in `permissions` whose `checkSelfPermission` is not GRANTED and reports `NeedsPermission(it)`. Both BLE callers pass only the API-31 runtime names: `BleMeshRadio.android.kt:66` passes BLUETOOTH_SCAN + BLUETOOTH_ADVERTISE, `GattLink.android.kt:81-88` passes those plus BLUETOOTH_CONNECT. Every Android module here sets `minSdk = 26`. On API 26-30 those permission names are not defined by the platform, so they are dropped at install time and `checkSelfPermission` returns PERMISSION_DENIED regardless of the manifest. The repo itself knows this: `Platform.android.kt:142-152` gates `AndroidBlePermissions.required` on `SDK_INT >= S` and asks only for ACCESS_FINE_LOCATION below it. The availability helper has no such gate.

*Failure:* Android 8-11 phone (API 26-30, within the declared minSdk) running the monitor. BLE works there - extended advertising is API 26+, and the manifest's legacy BLUETOOTH/BLUETOOTH_ADMIN/ACCESS_FINE_LOCATION grants are in place. Both `gatt` and `ble-adv` report `NeedsPermission(BLUETOOTH_SCAN)`. MonitorApp.kt:266-267 sets `enabled = usable` and `selected = enabled && usable`, so both chips are greyed out and cannot be ticked, and the row shows "needs permission: BLUETOOTH_SCAN" in place of counters. Pressing the permission button cannot fix it: `AndroidBlePermissions.required` on that API level requests only ACCESS_FINE_LOCATION. The bearer is reported unavailable while it works - the inverse of the lie the seam exists to end.

*Verifier correction:* Android BLE availability checks API-31-only permission names with no SDK_INT gate on minSdk-26 modules, so both BLE transports report NeedsPermission(BLUETOOTH_SCAN) forever on API 26-30 while working normally.

**[medium] A BLE-advertisement bearer opened while Bluetooth is off dies permanently and silently, then reports Ready again**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-ble/src/androidMain/kotlin/org/meshtastic/node/transport/ble/BleMeshRadio.android.kt:79`

`advertisements()` starts with `val scanner = adapter?.bluetoothLeScanner ?: return emptyFlow()`. `BluetoothAdapter.getBluetoothLeScanner()` returns null whenever the adapter is not enabled, so with Bluetooth off at collection time the receive path is an already-completed flow, not an error. MeshNode collects each transport's `incoming()` exactly once through `merge` (MeshNode.kt:261-262) and never re-collects a flow that completed, so the bearer can never receive again for the life of the node. Nothing records it: `.catch` at :281-282 only counts an *exception*, so `failures` stays 0; `TransportActivity.tracking` decrements the collector count on completion, so availability falls back to the platform's answer, which the BroadcastReceiver in `bluetoothAvailability` flips to `Ready` the moment the user switches Bluetooth on. `canTransmit` also becomes true (the advertiser is re-fetched per call at line 146), so transmit recovers while receive stays dead. The same shape exists at BluezBleMeshRadio.kt:75-77 (`poweredAdapter() ?: return emptyFlow()`).

*Failure:* Start the monitor node on Android with Bluetooth switched off (permissions already granted from a previous run, so the auth-flip restart in MonitorActivity.kt:56-63 never fires). ble-adv's incoming flow completes instantly. The user then turns Bluetooth on in Settings. The dashboard row goes from "needs permission: Bluetooth to be switched on" back to a normal enabled row; tx starts counting because `advertise()` re-fetches the advertiser; rx stays at 0 forever and `failed` stays at 0. The row is indistinguishable from a bearer that is transmitting into an empty mesh, which is exactly the state TransportAvailability was written to make distinguishable.

*Verifier correction:* Confirmed as written, with two precisions.

**[medium] The desktop discards the LoRa transport's only error channel while claiming the desktop has no LoRa**

`/Users/james/nixtastic/meshtastic-node-kmp/monitor/src/jvmMain/kotlin/org/meshtastic/node/monitor/Platform.jvm.kt:51`

`actual fun loraStatus(transports) = flowOf(null)` with the comment "No LoRa on the desktop yet, so the dashboard hides its controls". That is false: `node-transport-lora/src/jvmMain/.../LoraDevice.jvm.kt:17-20` resolves a real `Ch341PollingDevices(LibUsbCh341Backend(...))` when libusb is present, and `Platform.jvm.kt:38-43` does build a `LoraTransport`. The consequence is not cosmetic: `LoraTransport.availability` (LoraTransport.kt:141-155) deliberately maps `LoraState.Error` to the `else -> Ready` branch ("a bearer that greys itself out on a transient USB error and never comes back is worse"), so the *only* place a `LoraState.Error.message` ever reaches a human is the `loraStatus` line - which the desktop throws away. The class KDoc at Platform.jvm.kt:31-37 compounds it by asserting the GATT, BLE and LoRa jvmMain seams are "no-op stubs", contradicted by BluezGattLink.kt, BluezBleMeshRadio.kt and LibUsbCh341Backend.kt.

*Failure:* Desktop Linux with libusb installed and a CH341/SX1262 stick plugged in that fails initialisation repeatedly (bad wiring, a chip that will not answer `getStatus`). LoraTransport cycles Initialising -> Error -> retry forever, publishing the driver's message on `state`. The dashboard's LoRa row shows availability `ready`, counters `rx 0 tx 0 relayed 0 failed 0`, no status line and no error text - byte-identical to an idle, working bearer. The same stick on Android prints "error: <message> 0/0" in the LoRa line, because Platform.android.kt:66-89 implements loraStatus for real.

*Verifier correction:* The desktop's `loraStatus` seam and its KDoc predate the desktop LoRa backend and now assert the opposite of the truth

**[medium] LoraTransport never declares receiveOnly although its transmit ban is fixed for the transport's life**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-lora/src/commonMain/kotlin/org/meshtastic/node/transport/lora/LoraTransport.kt:171`

`private val txConfigured: Boolean = !config.region.isUnset && !config.region.wideLora && !config.receiveOnly` is a `val` computed once from an immutable config, and `canTransmit` (line 185-190) is gated on it. That is exactly `MeshTransport.receiveOnly`'s definition - "Whether this medium can never transmit here, whatever its state - a fact about the platform, fixed for the life of the transport" (MeshTransport.kt:98-112). `LoraTransport` does not override `receiveOnly`, so it inherits the interface default `false`, and the monitor's only consumer of the constant axis (`MonitorController.kt:199`, `available.filter { it.receiveOnly }`) never lists it.

*Failure:* Android or desktop with a CH341 stick attached and the dashboard's "rx only" toggle ticked (TransportTuning.kt:56, wired through LoraTuning.kt:23), or with the default `UNSET` region left in place - the default in TransportTuning.kt:48, and the one a user is most likely to be sitting on. The LoRa transport listens and refuses every transmit for its entire lifetime. The monitor's lora row prints `0` in the tx column instead of "rx only" (MonitorApp.kt:259, :285-290), which is precisely the confusion MonitorState.kt:60-72 says the receiveOnly axis exists to end - "a tx that can never leave zero looked like a bearer nobody had sent on yet".

*Verifier correction:* Real defect, confirmed; severity low-medium (a reporting/contract mismatch, not a functional break - sends do refuse correctly).

**[medium] MqttFraming will not uplink a PKI direct message heard on LoRa, because LoraFraming cannot carry pki_encrypted and neither side reconstructs it**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-mqtt/src/commonMain/kotlin/org/meshtastic/node/transport/mqtt/MqttFraming.kt:140`

`uplinkChannelId` routes to the PKI topic solely on `packet.pki_encrypted` (line 140), otherwise matching `packet.channel and 0xFF` against configured channel hashes. `LoraFraming.toCanonical` (LoraFraming.kt:38-57) builds its MeshPacket from the 16-byte on-air header, which has no `pki_encrypted` bit, and never sets one - so every packet bridged in from LoRa arrives with `pki_encrypted = false`. A PKI DM has `channel = 0` by construction (ProtoPacketCodec.kt:319 - "A PKI packet MUST carry channel 0"), and channel hash 0 matches no configured MqttChannel, so `matches.singleOrNull()` returns null and `fromCanonical` returns null. The firmware does the opposite at exactly this point: Router.cpp:1597-1601 sets `p_encrypted->pki_encrypted = true` for an opaque, non-broadcast, not-to-us packet with `channel == 0x00` *specifically so it publishes to the PKI topic*.

*Failure:* A node running LoRa + MQTT as a gateway (the pairing MqttBridgeTransport's KDoc names: "a node holding this and a LoRa link bridges them by construction"). Another radio on the LoRa mesh sends a PKI direct message to a third node. This gateway hears it, `LoraFraming.toCanonical` produces a canonical packet with channel 0 and pki_encrypted false, `MqttFraming.fromCanonical` returns null, and the packet is silently skipped by MeshNode.broadcast (:952 `?: continue`). A firmware gateway in the same position publishes it to `msh/<region>/2/e/PKI/!nodeid`. The bridge simply loses every PKI DM that arrives over LoRa, with no counter and no event - `fromCanonical` returning null is indistinguishable from "this bearer chose not to carry it".

*Verifier correction:* CONFIRMED, with two scope corrections.

**[low] The MQTT bearer is invisible on every platform - built by no defaultTransports() and named by no absentTransports()**

`/Users/james/nixtastic/meshtastic-node-kmp/monitor/src/commonMain/kotlin/org/meshtastic/node/monitor/TransportTuning.kt:73`

`ALL_TRANSPORTS = setOf("gatt", "ble-adv", "udp", "lora")` and is documented as "The `MeshTransport.name` of every bearer this library ships", but `MqttBridgeTransport.name` is "mqtt". No `defaultTransports()` actual constructs it (grep for MqttBridgeTransport over monitor/ and monitor-android/ returns nothing, and monitor/build.gradle.kts has no node-transport-mqtt dependency), and no `absentTransports()` actual names it either - Android and JVM both return `emptyMap()`, iOS returns only "lora". This is precisely the case Seams.kt:26-34 says absentTransports exists for: "a medium the platform never builds has nobody to speak for it and simply vanishes from the dashboard... which makes 'iOS cannot do this' and 'nobody has written it yet' look identical, when they are the two facts a reader most needs told apart." That the omission is unintended is visible in MeshDiagram.kt:44, which already assigns "mqtt" a colour for the bearer legend.

*Failure:* A user opens the monitor on any of the three platforms and sees four transport rows. A whole shipped module - node-transport-mqtt, with MqttFraming, MqttTopic and a driven-against-a-real-broker bearer - is absent from the dashboard with no row, no reason and no log line, while `MeshDiagram` is already prepared to colour its edges. There is no way to tell "this platform cannot do MQTT" from "the monitor never wires it up", which is the exact distinction the seam was added to preserve.

*Verifier correction:* CONFIRMED (low, maintainer-facing). Corrected statement:

**[low] The dashboard's "tx?" metric is sampled once at node start and never updated when Bluetooth comes on**

`/Users/james/nixtastic/meshtastic-node-kmp/monitor/src/commonMain/kotlin/org/meshtastic/node/monitor/MonitorController.kt:206`

`canTransmit = chosen.any { t -> t.canTransmit }` is evaluated once inside `startWith` and written into `MonitorState`; nothing else in the controller ever writes that field (grep for `canTransmit` over monitor/src/commonMain returns only :197 comment, :206, and MonitorApp.kt:216 which renders it). `canTransmit` is explicitly a live sample - MeshTransport.kt:100-103 says so, and GattLink.android.kt:90 returns `adapter?.isEnabled == true`, BleMeshRadio.android.kt:74-76 returns `isLeExtendedAdvertisingSupported && bluetoothLeAdvertiser != null`, both of which change when the user toggles Bluetooth. The node is rebuilt only on a `tune()` edit (MonitorController.kt:122-127) or when BLE *authorization* first flips to granted (MonitorActivity.kt:56-63, MainViewController.kt:45-52) - never on an adapter state change. So the field is a snapshot presented as a live metric, three lines below a comment warning against exactly this ('sampling canTransmit is what marked the iPad's gatt row receive-only for good').

*Failure:* Android, Bluetooth switched off, permissions already granted from a previous run. The user unticks udp and lora (each retick rebuilds the node) leaving only gatt and ble-adv, then presses start: both sample `canTransmit` false, so the status strip reads `tx? no`. The user switches Bluetooth on in Settings. `bluetoothAvailability`'s BroadcastReceiver re-emits Ready and both transport rows come back to life, but `tx?` stays `no` for the rest of the session because no rebuild is triggered by an adapter change. Two fields of the same state object now disagree about the same bearers.

*Verifier correction:* Real defect, low severity, with four refinements to the finding as written:

**[low] Apple bluetoothAvailability() is a single-value flow frozen at transport construction, so an authorization change never reaches the dashboard**

`/Users/james/nixtastic/meshtastic-node-kmp/node-core/src/appleMain/kotlin/org/meshtastic/node/transport/BluetoothAvailability.apple.kt:27`

`bluetoothAvailability(): Flow<TransportAvailability> = flowOf(when (CBPeripheralManager.authorization) { ... })` evaluates the `when` eagerly, as an argument to `flowOf`, at the moment the function is called - which is property-initialisation time in `AppleBleMeshRadio` (BleMeshRadio.apple.kt:55) and `AppleGattLink` (GattLink.apple.kt:125), both `val`s. The returned flow emits that one snapshot and completes. Every consumer treats availability as live: MonitorController.kt:238-249 collects it indefinitely expecting changes, and the Android sibling genuinely is live (a BroadcastReceiver re-emitting on ACTION_STATE_CHANGED). Because the flow completes immediately, `TransportActivity.tracking` also gives no protection - `combine` holds the last base value, so a `Ready` snapshot plus a live collector reports `Active` forever.

*Failure:* iOS, first run. `MainViewController`'s LaunchedEffect raises the CoreBluetooth consent prompt at first composition. The user taps Start while the prompt is still up: transports are constructed with `CBManager.authorization == notDetermined`, which BluetoothAvailability.apple.kt:32 maps to `Ready`. The user then taps 'Don't Allow'. `IosBlePermissions.authorized` stays false, so the granted-flip restart at MainViewController.kt:45-52 never fires, no transport is rebuilt, and both the `gatt` and `ble-adv` rows report `active` for the rest of the session with `rx 0 tx 0` - offered as live, enabled toggles for a stack that is denied. The `NeedsPermission("Bluetooth (denied in Settings)")` branch this file writes for exactly that case (line 34) is unreachable once a transport exists.

*Verifier correction:* **Apple `bluetoothAvailability()` is a one-shot snapshot taken at transport construction, so an authorization change never reaches any consumer.**

**[low] UDP multicast reports a constant Ready on the JVM and Android, so a node with no network reports Active and counts sends it never made**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-udp/src/jvmAndroidMain/kotlin/org/meshtastic/node/transport/udp/UdpMulticastSocket.jvmAndroid.kt:30`

`JavaNetSockets.availability = flowOf(TransportAvailability.Ready)` - "Always available where java.net is". Wrapped in `TransportActivity`, that reads `Active` for anyone collecting. But `MulticastSocket(port)` plus `joinGroup` succeed on a host with no usable network (the loopback join is accepted), and `send` (line 76-86) opens a short-lived socket, writes, and returns `true` on any non-throwing `socket.send` - which a datagram write to loopback is. `UdpMulticastTransport.canTransmit` is the constant `true` (UdpMulticastTransport.kt:71). The one condition Android genuinely needs and can be checked - a held `WifiManager.MulticastLock`, without which the transport's own KDoc says the socket "silently receives nothing" - is never consulted, and neither is Wi-Fi state. The same file's BLE sibling does report `NeedsPermission("Bluetooth to be switched on")` for the analogous condition.

*Failure:* Android phone with Wi-Fi off (or on a network whose AP blocks multicast, or a desktop on a VPN-only route). The udp row reads `active`, `tx?` reads `yes`. `sendText` calls broadcast, `JavaNetSockets.send` returns true, `carried` gets "udp", the tx counter climbs, `originate` returns true and arms the reliable-delivery retransmit queue, and `MeshEvent.Sent` reports the message as carried on udp. Every one of those is false; rx stays 0 and `failed` stays 0. The transport's own KDoc says of the missing MulticastLock case 'expect a timeout rather than an error: nothing throws' - which is precisely the case the availability seam was added to make visible, and it is the one bearer that does not implement it.

*Verifier correction:* On Android, UDP multicast is the one bearer whose availability seam is unimplemented, so the failure its own KDoc calls silent stays silent.


### The MQTT bridge

**[medium] MQTT downlink accepts packets attributed to ourselves from any gateway; the implicit-ack rationale for it is unreachable, and it admits a forged delivery receipt the firmware blocks**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-mqtt/src/commonMain/kotlin/org/meshtastic/node/transport/mqtt/MqttFraming.kt:82`

`toCanonical` drops a downlink only when `envelope.gateway_id == gatewayId && from != nodeNum`. The firmware's `onReceiveProto` drops *every* packet where `isFromUs(e.packet)` holds, regardless of which gateway published it (MQTT.cpp:122-137: the our-gateway branch returns in both arms, and the next statement is a second unconditional `if (isFromUs(e.packet)) return;`). The code comment justifies the exception with "hearing ourselves is what raises MeshNode's implicit ack, which is the same receipt the firmware synthesises here" - but that path can never fire. `MeshNode.implicitAck` (MeshNode.kt:438-443) requires `(header.hopsAway ?: 0) > 0`, and `hopsAway` is `if (hopStart > 0) hopStart - hopLimit else null` (PacketCodec.kt:144). A broker republishes bytes verbatim, so our own uplinked envelope comes back with `hop_start == hop_limit` → hopsAway 0 under `RelayPolicy.Meshed`, and null under `Island` (hop_start 0). So the relaxation yields no legitimate behaviour at all, while opening a receipt-forgery surface: the firmware synthesises its ack with an explicit `routingModule->allocAckNak(...)` that does not depend on hop counts, which is a different mechanism entirely.

*Failure:* Node N (nodeNum 0x000a11ce) runs `RelayPolicy.Meshed(3)` with an MQTT bridge (any broker, public or private) and `want_ack` traffic. N sends a direct message id 0x1234, which goes into `RetransmitQueue` and is uplinked as `msh/2/e/LongFast/!000a11ce` with hop_start=3, hop_limit=3. Any other subscriber on that broker - on mqtt.meshtastic.org that is anyone - captures the envelope, rewrites `gateway_id` to `!0000beef` and `packet.hop_limit` to 2, and republishes to `msh/2/e/LongFast/!0000beef`. N's `toCanonical` accepts it (gateway_id != ours, so the guard does not fire), `MeshNode.process` line 491 routes it to `implicitAck`, `hopsAway` is now 3-2 = 1 > 0, `RetransmitQueue.acknowledge(0x1234)` removes the pending entry and returns true, and N emits `MeshEvent.Delivered` and stops retransmitting a message that was never delivered to anyone. The firmware, given the identical envelope, logs "Ignore downlink msg we sent" and drops it. Symmetrically, N's own genuine echo off the broker produces no ack at all, so the documented parity with the firmware's implicit ack does not exist in either direction.

*Verifier correction:* MQTT downlink accepts packets attributed to ourselves from any gateway, diverging from the firmware in both arms of the rule it cites; the specific exception the code comment justifies is unreachable, and the wider acceptance admits a forged delivery receipt the firmware blocks.

**[low] The range-test / detection-sensor public-broker exclusion in mayUplink is unreachable, so this node uplinks range-test traffic to a public broker where the firmware refuses**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-mqtt/src/commonMain/kotlin/org/meshtastic/node/transport/mqtt/MqttFraming.kt:128`

`mayUplink` reads `packet.decoded` to decide, but nothing in this library ever produces a canonical `MeshPacket` with the `decoded` oneof arm set. `ProtoPacketCodec.seal` always encodes `encrypted = ciphertext.toByteString()` and never `decoded`, every origination and every `forForwarding` copy goes through it, and `MqttFraming.toCanonical` itself refuses `packet.encrypted == null` (line 89). So `decoded` is always null, `mayUplink` returns at line 123 (`return fromUs || privateBroker`), and the check at line 128 that excludes `RANGE_TEST_APP` / `DETECTION_SENSOR_APP` from a non-private broker is dead code. The firmware applies that exclusion to its own traffic too - `isConfiguredForDefaultServer && (portnum == RANGE_TEST_APP || portnum == DETECTION_SENSOR_APP)` in `onSend` sits *outside* the `isFromUs` guard - so the node is strictly more permissive than the firmware for exactly the two portnums the project singled out as broker flood.

*Failure:* A host (or a stock Meshtastic app attached through node-phone-api) calls `MeshNode.sendPacket` with a `MeshPacket` whose `decoded.portnum` is `RANGE_TEST_APP`, on a node whose MQTT bridge points at a public broker with `privateBroker = false` and an uplink-enabled channel. `sendPacket` seals the payload (encrypted set, decoded null), `broadcast` calls `MqttFraming.fromCanonical`, `mayUplink` sees `decoded == null` and returns `fromUs = true` at line 123 without ever reaching the `PUBLIC_BROKER_EXCLUDED` test, and the range-test packet is published to `<root>/2/e/<channel>/<gatewayId>`. Firmware in the same position logs "MQTT onSend - Ignore range test/detection sensor msg on public mqtt" and drops it. The same applies to `DETECTION_SENSOR_APP`.

*Verifier correction:* CONFIRMED, with two corrections to scope.

**[low] A failed SUBSCRIBE kills the MQTT bearer permanently, contradicting the documented "an unreachable broker does not kill the bearer"**

`/Users/james/nixtastic/meshtastic-node-kmp/node-transport-mqtt/src/commonMain/kotlin/org/meshtastic/node/transport/mqtt/MqttBridgeTransport.kt:116`

Only the initial CONNECT is retried. `connectWithRetry` wraps `client.connect(endpoint)` in `runCatching` and loops on `reconnectDelayMs`, but the very next line - `framing.subscriptions().forEach { client.subscribe(it, SUBSCRIBE_QOS) }` - is unguarded. `MqttClient.subscribe` calls `requireConnection()`, which throws when the session is not established, and can also throw `MqttException` on a refused SUBACK (`NOT_AUTHORIZED` on a broker with topic ACLs is the ordinary case). That throw escapes the `channelFlow`, and `MeshNode.receivePipeline`'s per-transport `.catch` *completes that transport's flow normally* - by design, so the other bearers survive - which means the MQTT bearer is dead for the remaining life of the node with no reconnect path. MQTTastic's `autoReconnect`, which the class comment relies on for outage survival, only ever gets a chance to run if this line succeeds first.

*Failure:* A node connects to a broker with per-topic ACLs (or simply loses the TCP session in the window between CONNACK and SUBSCRIBE - a keepalive-timed-out session, a broker restart, a NAT rebind). `client.subscribe("msh/2/e/LongFast/+", AT_LEAST_ONCE)` throws; the exception leaves `incoming()`; `receivePipeline` increments `failures`, emits one `MeshEvent.TransportFailed("mqtt", ...)`, and completes the flow. `live.value` is left null by the `finally`, so `send()` returns false for every subsequent packet, `availability` is reset to `TransportAvailability.Ready` at line 127 (so the monitor shows the bearer as healthy), and nothing ever retries. The class KDoc at lines 53-56 states "An unreachable broker does not kill the bearer. [incoming] retries on [MqttBridgeConfig.reconnectDelayMs] and [availability] reports [TransportAvailability.Unavailable] meanwhile, so a node whose network comes back reconnects without being rebuilt" - none of which holds past the connect call.

*Verifier correction:* A failed SUBSCRIBE kills the MQTT bearer permanently; only the initial CONNECT is retried.


### Test-suite honesty

**[medium] Env-guarded JVM tests return as passes, not skips, and three modules cannot even print the skip line**

`meshtastic-node-kmp/node-transport-udp/src/jvmTest/kotlin/org/meshtastic/node/transport/udp/FirmwareInteropTest.kt:102`

Every environment guard in the JVM test trees is a bare `return`, never `@Ignore` or an `assumeTrue`, so Gradle counts the test as passed rather than skipped. Worse, only `node-transport-ble`, `node-transport-ble-gatt` and `node-transport-lora` set `testLogging { showStandardStreams = true }` in their build.gradle.kts; `node-core`, `node-transport-udp`, `node-transport-mqtt` and `node-phone-api` do not, so the `println("... skipped ...")` lines are swallowed. `ChannelSetUrlDeviceTest.kt:18` and both `MqttBrokerInteropTest` guards print nothing at all. AGENTS.md states the hardware tests 'are env-guarded (MESH_GATT_LIVE, MESH_INTEROP_CHANNEL_URL) and pass as skips' - on the JVM side that is prose, not behaviour. The repo already knows the right pattern: every androidDeviceTest uses `org.junit.Assume.assumeTrue`.

*Failure:* Run the documented gate (`gradle allTests`) with no env set. `:node-transport-udp:jvmTest` reports FirmwareInteropTest's three tests as passed with no output; `:node-core:jvmTest` reports ChannelSetUrlDeviceTest passed with no output; `:node-transport-mqtt:jvmTest` reports MqttBrokerInteropTest's two tests passed with no output; `UdpMulticastTransportTest`'s three real-socket tests return at `testInterface() ?: return@runBlocking` on any host with no non-loopback multicast NIC and also report passed. Nine JVM tests read as green ticks having executed zero assertions, and nothing in the gate output distinguishes that from a run that actually exercised a radio, a broker and a socket.

*Verifier correction:* Env-guarded tests return as passes, not skips - and the modules that do set `showStandardStreams` still swallow their native skip lines

**[medium] The LoRa-egress interop test asserts only a value the fixture itself passed in**

`meshtastic-node-kmp/node-transport-udp/src/jvmTest/kotlin/org/meshtastic/node/transport/udp/FirmwareInteropTest.kt:229`

`a packet this node sends is relayed onto LoRa` is declared as `withRadio(RelayPolicy.Meshed(2)) { f -> ... }` and its single assertion is `f.node.relayPolicy.hopLimit shouldBe 2` - reading back the value the test's own fixture argument set two lines above. Everything after it (20 announces at 3s intervals) has no assertion at all; the test ends with `println("interop: sent as !... - check a second radio for 'Lora RX ... fr='")`. The KDoc calls this the proof that the node's packets reach the LoRa mesh through a bridging radio and says it is 'Verified by observation on a second physical radio', which is honest about the method but the file is still filed as a test.

*Failure:* Two ways this passes wrongly. Unarmed (the normal case): `MESH_INTEROP_LORA_EGRESS` unset returns at line 223 before any of it, reported as passed. Armed with a radio: break outbound relaying entirely - make `announce()` return false, or make the transport drop every send - and the test still passes, because `relayPolicy.hopLimit` is a property of the fixture, not of anything that went on the air.

*Verifier correction:* The LoRa-egress interop test cannot fail on its armed path. `FirmwareInteropTest.kt:221` declares `a packet this node sends is relayed onto LoRa` as `withRadio(RelayPolicy.Meshed(2)) { f -> ... }`, and past the `MESH_INTEROP_LORA_EGRESS` gate its only assertion is `f.node.relayPolicy.hopLimit shouldBe 2` (:229) - a read-back of the policy the test's own fixture argument set, since `withRadio` (:100) passes it to `Fixture` (:83) which passes it to `MeshNode { relayPolicy = policy }` (:92), surfaced unchanged by `MeshNode.kt:69`. The 20 `announce()` calls at :233-236 assert nothing and discard t


