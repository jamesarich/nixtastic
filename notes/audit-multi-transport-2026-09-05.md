# Audit — multi-transport mesh, 2026-09-05

Scope: firmware `spike/ble-mesh-transport` (27 commits, 36 files, +4.4k lines vs
`develop`), `meshtastic-node-kmp` `main` (97 commits since 2026-08-28), the two
workspace notes and both repos' own docs. Three read-only reviews ran in
parallel (firmware core + concurrency; firmware security + wire contract;
node-kmp transports + monitor); every finding below was checked against the
source before it was kept. Severity is the reviewer's, confirmed by me.

## Verdict in one paragraph

The design holds: framing, reassembly bounds, ingress guards and the transport
registry are correct and identically implemented on both sides of the wire,
and the hardware proofs stand. What the audit found is at the edges the bench
never exercised: a phone and a mesh peer on the same nRF52 radio at once
(the nRF52 port assumed one link), a subscriber's MTU never reaching the
peripheral role in node-kmp, two teardown races in code written this morning,
and one release blocker that is not code at all — the protobuf enums the whole
feature depends on exist only in this machine's submodule checkout.

## Blocker

| # | Where | Finding | Status |
| --- | --- | --- | --- |
| B1 | firmware `protobufs` submodule, `8db5d3e` | The four new enum values (`ProtocolFlags.BLE_BROADCAST=2`, `BLE_GATT_PEER=4`, `TransportMechanism.TRANSPORT_BLE_ADV=9`, `TRANSPORT_BLE_GATT=10`) are committed only in the local submodule; on no remote. A clone of the spike gets a dangling pointer. node-kmp still consumes `org.meshtastic:protobufs:2.8.0`, which lacks them (wire-safe: unknown enum values round-trip as unknown fields, but the client cannot name them). | **Resolved 2026-09-05**: pushed to `meshtastic/protobufs` branch `spike/ble-mesh-transport` (`6c246f1`, `8db5d3e`). Publishing the artifact for node-kmp remains. |

## Fixed in this audit

| # | Sev | Where | Finding | Fix |
| --- | --- | --- | --- | --- |
| F1 | high | node-kmp `GattLink.android.kt` | Peripheral never learned a subscriber's MTU: `onMtuChanged` fed `subscriberChunk()`, which ignores an address not yet subscribed; the MTU exchange precedes the CCCD write, so every subscriber sat at 20 and `maxChunkSize` (min over both roles) pinned the whole link to 20-byte fragments. | Chunk remembered per address from `onMtuChanged`, handed to `subscribed()`, cleared on disconnect. `8bf28a2` |
| F2 | high | firmware `NRF52Bluetooth.cpp` | The phone was "whichever link connected last": `connectionHandle` set on every connect, `fromNum.notify32()` on Bluefruit's default handle (= last connect). A mesh peer connecting second stole the phone's data notifications, and its later drop made `PhoneAPI::checkConnectionTimeout` close the real phone session. | Phone identified by phone-API use (`toRadio` write, `fromRadio` read, `fromNum`/`logRadio` CCCD); notifies and log go to that handle explicitly; only that link's drop ends the session. `ca0a39c51`; built and native-tested, **not yet exercised with a stock app beside a mesh peer** (needs the Pixel's stock app paired to the Pocket while the iPad monitor is subscribed). |
| F3 | high | firmware `NRF52Bluetooth.cpp` | A link dropping before it subscribed fell through to `bluetoothPhoneAPI->close()` and the DISCONNECTED status while the real phone was connected. | Same fix as F2: teardown keyed on the phone's handle, not on "had subscribed". |
| F4 | med | firmware `NRF52BLEGattMesh.cpp` | Bluefruit stops the connectable advert on connect and restarts only when no peripheral link remains, so the second slot was reachable only if the peer connected first (the bench worked by accident: the BLE-adv burst's `resumeAdvertising` re-armed it). | The mesh layer re-arms the advert on every connect **and disconnect** while a slot is free (the disconnect half turned out to be the one that mattered: after the iPad dropped, the Pixel's live link kept the advert off and the iPad could not return). Bench-verified with BLE broadcast off so nothing else could re-arm it: iPad killed, relaunched, connected and subscribed in 3 s. `ca0a39c51` |
| F5 | med | firmware both platforms' `pushRx` | The zero-length disconnect marker was dropped when the 6-slot RX ring was full (exactly when a peer floods then leaves), so the pump kept that handle's half-built packets for the next peer the stack gave the handle to. | The marker overwrites the newest chunk (a dead link's) instead of being dropped. `ca0a39c51`, native suites green. |
| F6 | med | firmware `NRF52BLEGattMesh.cpp` | Bluefruit's `notify()` blocks up to 100 ms per call; the pump retries a refusal 50 times, so a departed peer whose supervision timeout had not fired cost seconds of main-loop stall per queued packet. | Refuse immediately when the link is gone. `ca0a39c51`. The blocking cost for a live-but-slow peer remains (O5). |
| F7 | low | firmware both BLE ingress paths | `via_mqtt` and `tx_after` arrived attacker-set: a BLE sender could suppress our MQTT uplink or schedule our transmit. | Cleared on ingress alongside the PKI metadata. `ca0a39c51`. `next_hop`/`relay_node`/`priority` left as LoRa also carries them (O7). |
| F8 | med | node-kmp `GattLink.android.kt`, `BleMeshRadio.android.kt` | This morning's 3-minute scan refresh could outlive teardown: `removeCallbacks` cannot stop a `run()` in flight and `run()` re-posts itself; the flow variant's stop+start has no suspension point, so a close between them leaves a scan on a closed channel. | Cleared flag checked in `run()`; lock plus `closed` flag around the restart. `8bf28a2` |
| F9 | med | node-kmp `GattLink.android.kt` | A `startScan` that throws (permission not yet granted, adapter mid-transition) skipped returning teardown, leaking the GATT server and advertiser; the next rebuild opened a second server. | Wrapped, reported as a fault, teardown always returned. `8bf28a2` |
| F10 | low | node-kmp | `connectGatt` on `TRANSPORT_AUTO` against dual-mode phones (the classic status-133 source); log auto-scroll keyed on `log.size`, dead once the log hit its 500 cap; duplicate import; the claim that `onPhyUpdate` reports a 1M answer as a refusal (a 1M answer is `GATT_SUCCESS` with `txPhy=1`); a comment still calling the Apple write-size re-read unverified. | All fixed. `8bf28a2` |

## Open — recorded, not fixed here

| # | Sev | Where | Finding | Why deferred |
| --- | --- | --- | --- | --- |
| O1 | med | firmware `NimbleBluetooth.cpp` (ESP32) | Mirror of F2/F3 on the S3: a stock phone whose `CONNECT_IND` lands on the mesh-peer set (both sets share the public address) is flagged `viaMeshAdv` and its disconnect skips `resetBleSessionState()`; the next central inherits session state. Session confusion in NO_PIN, no auth bypass in PIN mode. | Same phone-by-use fix as F2 belongs here; the V3 is unplugged so it cannot be verified today. |
| O2 | med | firmware `BLEMeshHandler::deliverToRouter` | No rate limit on BLE-adv ingress and `Router::enqueueReceivedMessage` drops the *oldest* packet when the queue is full, so a phone flooding unique frames every 30 ms evicts genuine LoRa receptions. Encrypted-tag garbage passes every guard; no PSK needed. | Needs a per-peer token bucket or a separate BLE ingress queue; a design decision, not a patch. |
| O3 | med | firmware `NRF52BLEMesh.cpp` | Every BLE-adv burst stops and restarts the phone advertisement via `resumeAdvertising()` = `start(0)` = fast mode for 30 s, resetting the timer each time, and re-arms it while a phone is connected. Steady mesh traffic pins the advert in fast mode forever. The "dedicated set" branch is dead: Bluefruit never raises the set count above 1. | Pre-existing spike behaviour; needs a Bluefruit-aware restore (slow interval, respect connected state). |
| O4 | med | node-kmp `MonitorController.restart()` | Joins the collector, not the sharing coroutine that owns the transports, so the "old LoRa transport never races the new one for the USB claim" premise (also in AGENTS.md) is not guaranteed; each rebuild leaks the old node's sharing coroutine and a relay in its contention window still fires on the old transports. Same on the permission-grant path (`stop(); start()`). | Fix shape is a child `Job` per node, cancel-and-join; touches the node lifecycle contract. |
| O5 | med | firmware `BLEGattMeshHandler::pumpTx` + Bluefruit | Bluefruit's notify blocks up to 100 ms; the pump pushes every fragment of every peer in one `runOnce`, so a slow live peer stalls the main task (~400 ms for a 15-fragment packet). NimBLE's notify is non-blocking, which the retry model assumed. | Needs a per-tick budget or async notify on nRF52. |
| O6 | low | node-kmp both GATT links | `LinkChunk.rssi` is never populated, so GATT frames get the UDP-style mid-window contention slot; AGENTS.md says BLE RSSI is mapped. | `readRemoteRssi` / `readRSSI` plumbing. |
| O7 | low | firmware BLE ingress | `next_hop`, `relay_node`, `priority`, `want_ack`, `delayed` arrive sender-set on BLE (LoRa carries some in its header, so LoRa RX sets them too). | Decide which a non-LoRa ingress should normalise. |
| O8 | low | firmware `ESP32BLEMesh.cpp` | `advInstanceConfigured` / `readyHandled` never clear, so the ESP32 mesh handler cannot survive a NimBLE host reset; `startScanning()` from the DISC_COMPLETE callback re-enters the host during its reset. ESP32 has no BLE re-enable path without reboot, so this only bites on a controller error. | Rare path; needs a reset hook. |
| O9 | low | firmware `Router.cpp` | `callTransports()` runs before the `MAX_RADIO_PAYLOAD_LEN` drop, so an oversize frame is relayed to GATT/UDP peers but never LoRa. | Behavioural; decide whether transports should share LoRa's size cap. |
| O10 | low | node-kmp | Monitor shows PHY chips on iOS where the value is ignored (a tap costs a rebuild for nothing); stats keyed by `MeshTransport.name` collapse two same-named transports; `Config` says "snapshotted" but keeps live lists; UDP `trySend` drops uncounted. | Small, separate. |
| O11 | design | firmware nRF52 | With the GATT-peer bit on, the mesh UUID displaces TX power in the scan response and the advertised name shortens to "Meshtastic_" for every stock app in range. | Product decision: an extended advertising set (S140 supports it) or service discovery on connect instead of advertising it. |
| O12 | low | node-kmp reassembly asymmetry | Firmware reassembles strictly in order, 2 in flight per peer; node-kmp any order, 4 per peer. A node-kmp sender interleaving 3+ packets' fragments to one radio gets the third refused. `GattMeshTransport` splits per send, so this needs sends serialised per link — confirm. | Behavioural; verify the sender never interleaves. |

## Wire contract (firmware ↔ node-kmp) — verified identical

Company ID 0xFFFF, protocol version 1, adv budget 251/8/243, adv layout, fragment
header `[ver][id lo][id hi][idx][total]` (id little-endian), `total==0 ||
index>=total` rejected, service/characteristic UUIDs (LE byte order checked on
both platforms), chunk = MTU−3. The only divergence is the enum publication (B1).

## Docs sweep

Rot found and fixed: the handoff's "do this FIRST" section about unpushed work
(all pushed), a phase table pointing at a superseded spike commit and omitting
nRF52/iOS, "Apple MTU re-read unverified" (verified at chunk 512 and 244),
"C3 and nRF52 unbuilt" (nRF52 done; C3 links: RAM 34.2% / flash 87.2%), the
bench section listing the V3 (unplugged) and not the Pocket, the Pixel's adb
serial, six memories missing from the read-first list; the design note's status
block ("spike ahead 5, not pushed"); node-kmp's README claim that iOS links
stop after the first moments (they now last minutes on both radios) and its
firmware-GATT proof row naming only the V3. Code comments: one dated bench
metric and one paragraph of decision history removed, one "untested" claim
corrected. The spike carries no docs of its own; that is fine for a spike and a
gap for anything beyond one.

## Gates run

node-kmp: full AGENTS.md gate (four JVM test suites, Android assemble, JVM and
iOS-simulator compiles) green on `8bf28a2`; installed on the Pixel. Firmware
`ca0a39c51`: `rak4631_blemesh` (RAM 41.1%, flash 92.1%) and `heltec-v3` (RAM
39.8%, flash 68.2%) build; native `test_ble_mesh`, `test_ble_gatt_mesh` and
`test_transport_registry` pass under Docker; flashed on the WisMesh Pocket,
where the Pixel and the iPad both subscribe and the kill-and-relaunch test
passes. ESP32-C3 `heltec-ht62-esp32c3-sx1262` links (RAM 34.2%, flash 87.2%).
The V3 is unplugged, so the S3 build is compile-verified only today.
