# Handoff - multi-transport mesh (resume here)

**Start a new session here.** This file is the pointer: where the work stands,
what is settled, what to do next, and the bench and traps that cost hours. The
evidence lives in [`multi-transport-mesh.md`](./multi-transport-mesh.md), which
is the canonical plan plus a dated section per bench sitting.

Rewritten 2026-09-05 at the end of the day the tier-1 parity plan was
implemented end to end, and updated through 2026-09-06. Everything below is
committed and pushed.

**What 2026-09-06 changed**, in one paragraph, because it moved two things the
plan had listed as open. The review's confirmed findings were fixed and proven
against the stock Android app, ending with two receipt bugs the app made visible:
a broadcast carried no `want_ack`, so a channel message resolved only when the
app's own five-minute timeout gave up on it, and an unreadable `want_ack` packet
got silence where the firmware sends `PKI_UNKNOWN_PUBKEY` - the NAK that makes a
peer send the NodeInfo that fixes it. And **desktop BLE stopped being a plan**:
Linux's GATT roles reached firmware for the first time, after three fixes, and
macOS got a bearer at all, through our own CoreBluetooth in a Kotlin/Native dylib
called in-process over JNI. Windows is now the whole of the desktop BLE gap.

## Read first

1. [`multi-transport-mesh.md`](./multi-transport-mesh.md) - the plan (**one
   protocol, many bearers**; LoRa stays first-class), its live
   `## Implementation status`, and the dated sittings. That doc is truth; this
   one is the index.
2. [`audit-multi-transport-2026-09-05.md`](./audit-multi-transport-2026-09-05.md)
   - the whole-feature audit, and the only place **O1-O12** are written down.
   Most are still open and most are firmware-side; O11 is next step 8 below. Of
   the node-kmp ones, **O4, O10 and O12 were fixed 2026-09-05** and O6 is
   corrected in the docs but not implemented - see
   [`review-multi-transport-2026-09-06.md`](./review-multi-transport-2026-09-06.md),
   which supersedes the audit for node-kmp and adds 131 findings of its own.
3. Per the workspace protocol, run `just brief <repo>` before editing under any
   repo, and read that repo's own docs (`meshtastic-node-kmp` → `README.md` then
   `AGENTS.md`; `firmware` → `AGENTS.md`).
4. Memories worth loading: `ble-mesh-interop-bench` (bench recipe and tooling
   traps), **`node-kmp-monitor-bench-driving`** (driving the monitor on Pixel and
   desktop), **`nrf52-ble-mesh-pocket-bench`**, `bench-serial-recipes` (DTR/RTS
   holders), `esp32-firmware-gotchas` (the PHY-update assert, the shared
   pioarduino libs trap), `android-ble-transport` (the 5-minute scan downgrade),
   `ios-restoration-held-ble-connection`, `v3-serial-holder-capture`,
   `android-17-access-local-network`, `ios-ble-kmp-gotchas`,
   `gradle-agp-upgrades`, `xcodebuild-device-test-failure-sudo`.

## Where the plan stands

| Phase | State | Where |
| --- | --- | --- |
| 1 - client N-transport node | **done**; four bearers (gatt, ble-adv, udp, lora) in one node, instrumented per bearer, proven live. Desktop BLE proven on Linux **and** macOS 2026-09-06; Windows is the one platform left | `meshtastic-node-kmp` `main`, pushed |
| 2 - firmware transport registry | done, green (native 1392/1392) | `firmware` `spike/ble-mesh-transport` (through `46b4fdc79`, pushed) |
| 3 - firmware BLE-GATT mesh-peer edge | **proven both ways** on ESP32-S3 (Android; iOS after the 1M-PHY fix) and nRF52 (Android and iOS, two phones at once) | `ESP32BLEGattMesh`, `NRF52BLEGattMesh`; `BLEGattMeshHandler` shared |
| Tier-1 node parity | **done end to end** 2026-09-05 | `meshtastic-node-kmp` `main`, pushed |
| 4 - new bearers (Wi-Fi Aware, anti-entropy) | future | - |

**What landed 2026-09-05:** identity and keypair persistence, keyless-first
eviction, `pki_encrypted` derived rather than trusted, telemetry/traceroute/
waypoint/neighbour decoding, reliable delivery, the NodeInfo and Position
beacons, self-telemetry over the phone API, NAK decoding, traceroute answering,
desktop LoRa over libusb, DUAL-role GATT arbitration, the MQTT bridge, desktop
BLE over BlueZ, iOS UDP, and the availability seam. Three gate holes were closed
first, each of which had already let a real defect through. Slices, SHAs, the
hardware proofs and what stayed blocked: the plan doc's **"Tier-1 parity
implemented end to end (2026-09-05)"**.

Proven on hardware that day: the beacon end to end between two nodes; desktop
LoRa rx *and* tx with acks back over the air; a PKI DM round-trip to the WisMesh
Pocket that real firmware decrypted and acknowledged; three DUAL nodes electing
exactly one GATT role per pair; the MQTT bridge against a real mosquitto; and the
availability seam flipping live as Bluetooth went off and back.

## Settled (do not re-investigate)

**The GATT question is answered.** Android ↔ the firmware's mesh-peer service is
proven both ways on the bench (`rx[gatt]` and `gatt 15 rx` on the phone;
`Received text msg from=0x6337995d` on the radio for six consecutive sends). The
plan doc has the exact readings and the three wrong turns it took to get there.

**The Apple-central bootloop is fixed on the spike** (`fcc3c0582`). The V3's BLE
**controller** asserted ~200 ms after an Apple central connected, before discovery
or the CCCD write, and rebooted; 0 of ~170 connects survived. Decoded from 22
panics, 11 sharing a remote-PHY-update signature
(`r_llc_rem_phy_upd_proc_continue_eco` → `ll_phy_update_ind_handler_hack`),
matching `BLE assert lld_con.c 3397`. It is Espressif's open esp-idf#15311, same
assert and same PC, reproduced on **stock develop and the nightly with the stock
iOS app**, so it was never the spike. Ruled out on the bench: serial, the
mesh-peer service, `LL_CFG_FEAT_LE_2M_PHY` (host-only, never reaches the S3
controller), the controller's `BT_CTRL_BLE_LLCP_*` flags (1/27), and a newer
controller blob (none exists through IDF v6.1). A Pixel requesting 2M PHY never
crashes it, so the trigger is what the A16 does inside the procedure, not the
procedure itself. **Fix:** Apple's own accessory guidance, indicate 1M-only PHY
preferences, sent as raw HCI `LE Set Default PHY` after `ble_hs_synced()` in
`NimbleBluetooth::setup()`. 9/9 iPad connects survive, subscribe and carry frames.

**Desktop GATT is three facts, not one.** On **Linux**, `GattLink.jvm.kt` picks
`BluezGattLink` and both roles exist (built, not yet exercised on Linux
hardware). On **macOS and Windows JVMs** it is still `UnsupportedGattLink`,
because BlueZ is Linux-only and there is no other JVM BLE stack. The **macOS
native** binary has a real CoreBluetooth path and meshes over GATT for real,
which is how the third node in the arbitration proof was run. Bridging that into
the JVM desktop app is [`desktop-ble-plan.md`](./desktop-ble-plan.md), and the
TCC spike for it passed.

**Apple cannot advertise arbitrary BLE payload, and no macOS API changes that.**
CoreBluetooth's macOS and iOS headers are byte-identical here; IOBluetooth is
classic BR/EDR with no raw HCI. This was investigated to a conclusion. The
cross-cutting consequence, recorded in node-kmp's `AGENTS.md`: moving the on-air
format to *service data* would leave Apple unable to transmit **and** make
Windows receive-only, because Windows treats service data as system-reserved on
the publisher.

**The Linux side is proven (2026-09-06):** desktop LoRa rx, the phone API with
the Python CLI, and the BlueZ GATT central against firmware and Android - connect,
subscribe, write and, after a third fix, receive. Three BlueZ bugs found on the
day: a wrong `InterfacesAdded` field, no retry-on-sight, and inbound
notifications arriving as `ArrayList<Byte>` and being dropped as "not bytes" (the
central looked healthy and received nothing). Plan doc → "The Linux bench sitting
(2026-09-06)".

**Still unverified on-device:** the `failed` column lighting up at all (no way was
found to make a bearer *throw* on this device, see the traps) and
`transport[udp] FAILED: …`.

**Bench-proven 2026-09-06** (Meshtadpole + WisMesh Pocket on the Mac, region US,
10 dBm):

- **The retransmit budget, end to end.** With the Pocket's `lora.tx_enabled` set
  false so it hears a DM but cannot ack, a `want_ack` DM went out five times on
  the same packet id at ~7 s spacing and ended
  `undelivered ... (MAX_RETRANSMIT after 5 attempts)`. The firmware's unicast
  budget, on a real radio. `tx_enabled` restored afterwards.
- **The PKI DM round-trip still works** after the `next_hop` recomputation and the
  hop-limit ceiling: `rx[lora] delivered: !7263cc65 ack req=...`, so the Pocket
  decrypted and acknowledged it.
- **The desktop LoRa status line**, which returned a constant null until that
  morning: `LoRa: 906.875 MHz 10 dBm 15/8 -52 dBm 5.75 dB`.
- **`LoraTransport.receiveOnly` both ways**: the bearer row read `rx only` with the
  region UNSET and lost it the moment US was armed.
- **The phone API's own warning line**, `listening on 0.0.0.0:4403 -
  UNAUTHENTICATED, reachable from this network`, which is the monitor opting in
  explicitly now that the library binds loopback.
- **`restart()`**: arming the region produced exactly one `node stopped` per
  `node started`, and the attached phone session was dropped with it.

**Proven against the stock app 2026-09-06** (Pixel 6a on wifi adb, TCP to
192.168.1.138:4403):

- **Routing receipts for a broadcast, which is what the phone actually sends.**
  A channel message from the app resolved in ~20 s with
  `[ackNak] req=188409998 routeErr=5 isAck=false` - a real MAX_RETRANSMIT NAK
  from the node after its three broadcast attempts. Before `5cc41af` both senders
  stripped `want_ack` from every broadcast, so nothing was tracked, no receipt of
  any kind was possible, and the app's own five-minute send-ack timeout stamped
  the message `Routing.Error.TIMEOUT` instead. Both render as "Failed to deliver
  to mesh" (`getMessageRoutingErrorStringResFrom` folds TIMEOUT, GOT_NAK and
  MAX_RETRANSMIT into one string), so the screen looks identical either way - the
  logcat `routeErr` is the only way to tell a receipt from a give-up.
  MAX_RETRANSMIT is the honest verdict here: the node was on `Island`, so nothing
  could rebroadcast it and no implicit ack was reachable.
- **The refusal of a phone's local AdminMessage** is visible on connect as five
  `queueStatus res=-1` in a row - the app pushing its own owner/config at the
  radio, addressed to the radio itself.
- **The `Delivered` half, on the same message path.** With US armed, `relay` on and
  `hopLimit` 1, a channel message from the app went out once and was retired 1.9 s
  later by a real neighbour's rebroadcast:

  ```
  7:29.370  lora: tx ok len=41 toa=559ms
  7:29.372  tx[udp,lora] data id=2123155540 to=!ffffffff
  7:31.231  rx[lora] delivered: !a6e88506 ack req=2123155540
  ```

  `[ackNak] req=2123155540 routeErr=0 isAck=true` on the phone, green tick,
  "Delivered to mesh". The receipt carries our own node id, as the firmware's
  locally generated implicit ack does. No retransmission at all - the whole point
  of the implicit ack is that it stops the budget early.
  `loraRelayOnAir` stayed false, so relaying here means LoRa in, UDP out; the node
  put no extra traffic on the air.
- **The PKI-unknown-key recovery loop**, whole, off a real solar node on the mesh:

  ```
  1:33.296  rx[lora] opaque from !f2775c7e (chan #0)
  1:33.296  tx[udp,lora] nak id=2022782888 to=!f2775c7e
  1:35.471  rx[lora] peer !f2775c7e (key)
  1:50.664  rx[lora] text DM from !f2775c7e: Test
  1:50.664  tx[udp,lora] ack id=2022782889 to=!f2775c7e
  ```

  Before `13e9158` the first line was the whole story: an unreadable `want_ack`
  packet got silence, the sender spent its five unicast attempts and settled on
  "Relayed, not confirmed by recipient" - an implicit ack off a neighbour's
  rebroadcast being the only receipt it ever saw. The NAK is what makes a firmware
  sender push its NodeInfo, which is the key we were missing, 2.2 s later.

**Cleared 2026-09-06**, all three by the stock app simply working against the
desktop node for a day: the config dump completes its handshake at the firmware's
ConfigType and ModuleConfigType maxima (10 and 17, up from 8 and 13); messages
carry real times (`8:42 AM`, not 1970); and the Pixel reached
`192.168.1.138:4403` from another device, which is the `ANY_ADDRESS` opt-in
working now that the library binds loopback by default.

**What the next bench sitting owes.**

1. **Two CoreBluetooth peers that never resolved.** Across an eight-hour macOS run
   two of three centrals sat at `opening,notify=pending,chunk=20` the whole time.
   That is the shape of the bug `803b594` fixed on BlueZ - a peer reserved and then
   never retried - and nobody has looked at whether the Apple side ever gives up.
2. **A LoRa stick that detached and stayed detached.** The Meshtadpole dropped off
   USB mid-run and the bearer read `detached` for the remaining hours. The JVM path
   is documented as hot-plug polled, so either the poll does not re-attach or it
   never ran; replug one and watch.
3. **The airtime ledger across a tuning change.** Still unrun. The monitor surfaces
   no airtime figure, so it needs a log line or a test hook first.

The LoRa preset clamp is **deliberately not bench-tested**: verifying it means
configuring EU_868 on a radio sitting in the US, which is the out-of-band
emission the fix exists to prevent. It is unit-tested and mutation-checked, and
that is the right place for it. Whether the shared airtime ledger survives a
tuning change is still unrun - the monitor surfaces no airtime figure, so it
needs either a log line or a test hook first.

**A monitor restart silences LoRa.** `TransportTuning.loraRegion` defaults to
`UNSET` and the tuning is not persisted, so a relaunched dashboard comes back
`LoRa: 906.875 MHz rx-only` however the previous session was armed. Nothing warns
about it; the bearer row and the header line are the only tell, and a send then
goes out over UDP alone. Arming is a transmit decision, so a remembered region
would have to be an explicit opt-in rather than a silent restore.

## Next steps, in order

1. **`protobufs` to `master`.** The submodule commits (`6c246f1` BLE-adv enums,
   `8db5d3e` GATT mesh-peer enums) are on `meshtastic/protobufs`
   `spike/ble-mesh-transport`, so a clone of the firmware spike resolves. Landing
   them on `master` and publishing the `org.meshtastic:protobufs` artifact is what
   lets node-kmp name the values, and is a prerequisite for anything shipping.
2. **Develop PR from `fcc3c0582` - ON HOLD, James's call when.** It fixes stock
   firmware too. The trade to state when it goes up: iOS phone-API links run at 1M
   on ESP32-S3/C3. Until then the fix lives only on the spike branch.

   **Precondition, found 2026-09-06 and landed the same day as `46b4fdc79`:**
   the spike was **not inert on ESP32**. Kept here as the record of why.
   `[ble_mesh_esp32]` calls itself opt-in and is referenced unconditionally from
   `[esp32s3_base]` and `[esp32c3_base]`, so `BLE_MESH_USE_EXT_ADV` is 1 on every
   S3/C3 build and `NimbleBluetooth::startAdvertising()` runs the spike's
   hand-rolled extended-advertising path instead of the legacy one - on devices
   whose owners never enabled anything. Make that reference conditional before
   cutting any PR from this branch. See
   [`review-multi-transport-2026-09-06.md`](./review-multi-transport-2026-09-06.md)
   → "Firmware spike - now verified".
3. **Upstream:** nudge esp-idf#15311 (same assert, same PC 0x40006fcb) with the
   peer-initiated variant, the stock-Meshtastic repro and the 1M workaround; open
   a `meshtastic/firmware` issue so A16-iPad users have somewhere to land.
4. **Commonize the transports** (James, 2026-09-05). **Mostly done 2026-09-06.**
   The state and fault half was the availability seam; per-peer send queues landed
   as `GattLink.broadcastPacket` (`2c87654`), and the stats shape as the
   distinct-transport-name rule (`54e4a77`). Scan and advertise scheduling was
   **deliberately not lifted**: the premise that Android's 5-minute downgrade
   workaround is not Android-specific turned out to be unevidenced - neither
   `BleMeshRadio.apple.kt` nor `BluezBleMeshRadio` restarts its scan, and
   CoreBluetooth's throttling is background-only. What is genuinely left is the
   cross-peer fan-out inside a single send, which needs three connected peers to
   settle whether Android's one-outstanding-operation bound is per connection or
   per app. The GATT chunk and
   reassembly state machine is already common (`GattLinkBase`), which is what let
   the HELLO arbitration land without touching a platform file. Target: a new
   backend is an I/O adapter of a few hundred lines, not a fourth copy of the
   transport.
5. **Step 0's remaining app-side adapters.** The phone-API server landed
   (`aadec77`): `node-phone-api` plus a desktop TCP listener on 4403, and the
   stock Android app connects to the desktop node over TCP, completes both
   handshake stages, holds the link, and a message it sends leaves as a multicast
   frame. Still owed: the Android `IRadioInterface` adapter, the Apple
   `Transport`/`Connection` pair, the SDK `RadioTransport` module, and
   `AdminMessage` handling. Two facts the stock app taught: its TCP transport
   drops a radio silent for 90 s (18 read timeouts, reset only by received bytes),
   so the session answers heartbeats and sends a `queueStatus` every 30 s; and
   without Routing ACK/NAK its sent messages sit at "Sending..." and end as
   "Failed to deliver to mesh" - **fixed 2026-09-06** (`960be7d`): the session
   forwards `Delivered` and `DeliveryFailed` as local ROUTING_APP packets.
6. **Monitor: Material 3 and a live mesh diagram - DONE 2026-09-06** (`bc01e59`).
   Four destinations under `NavigationSuiteScaffold`, which picks the navigation
   shape from the window size class: verified by resizing the desktop window, a
   bottom bar at 460dp and a rail at 720dp and above. The mesh view is the
   supporting-pane layout, diagram alone on a compact window and diagram beside
   the log on an expanded one. The diagram is this node at the centre, peers on a
   ring, edges coloured by the bearer each was last heard on and fading with
   silence. Deliberately not a graph of the whole mesh: this node knows what it
   heard, not the topology beyond it. `SupportingPaneScaffold` itself does **not**
   work here - its supporting pane never expanded at any width - so the split is
   driven off `currentWindowAdaptiveInfo().windowSizeClass` instead. Still open
   from the original wish list: per-bearer rates over time rather than totals, and
   queue depth.
7. **Desktop BLE for macOS and Windows.** [`desktop-ble-plan.md`](./desktop-ble-plan.md).
   The macOS helper-process bridge is proven viable by the TCC spike; unsettled is
   whether a bundled `.app` gets its own TCC grant (the spike ran from a
   terminal-launched JVM, so TCC attributed to the terminal). Windows needs WinRT.
8. **nRF52's advertised-name decision.** With the GATT-peer bit on, the S140's
   single advertising set carries the mesh UUID in the scan response in place of
   TX power, and the name shortens to "Meshtastic_" for every stock app in range.
   Fine on a bench, not in a release. Options: an extended advertising set on
   nRF52, or discovering the service on connect instead of advertising it.
9. **V3 bench restore** (unplugged since 2026-09-05 morning). The web-flasher
   erase took `config.proto` and `nodes.proto` and reset the primary channel to
   `LongFast`. Region US and `enabled_protocols=7` were restored over serial; the
   **`olm3sh` channel and the WiFi credentials are James's to re-enter from the
   app** and were never written by the agent.
10. **The Apple app's restoration handler** (`BLETransport.swift`
    `handleWillRestoreState`) re-issues `connect()` on the first restored
    peripheral with no check that it is the preferred device, and never cancels.
    Harmless with a healthy radio, an infinite hammer against one that dies
    mid-connect. A small PR against `apple`, independent of the controller bug.
11. **ESP32-C3 on-device.** `heltec-ht62-esp32c3-sx1262` links with the mesh
    section (RAM 34.2%, flash 87.2%). No C3 on the bench, so this stays open until
    someone has one.
12. **Tuning backlog:** iOS-*central* discovery flakiness
    (`didDiscoverPeripheral` unreliable; the inbound link is solid, and two of
    three iOS connects to the Pocket dropped after 2 s before one stuck); the
    send-dedup asymmetry (repeated `Send test` shared a packet id on the Pixel).
13. **Dogfood API gaps - DONE 2026-09-06** (`dba67eb`). `GattMeshTransport.clock`
    defaults to the monotonic epoch `GattArbitration` already keeps, and
    `MeshNode.peers` is a `StateFlow` over the directory.
14. **Monitor polish.** The tuning panel squeezing the log to nothing on a phone is
    gone by construction - tuning and the log are separate destinations now. Still
    open: the LoRa stale-claim message after the device tests
    (`SX1262 command 0x80 failed, status 0xf7` retrying) and the post-TX bulk-IN
    retry.

## The bench

Shared hardware; the USB radios are global mutable state across sessions - see
[`bench-fleet.md`](./bench-fleet.md).

- **WisMesh Pocket** (RAK4631, nRF52840) - node `!7263cc65` "956a", running spike
  `ca0a39c51` env `rak4631_blemesh`, `enabled_protocols=6` (BLE broadcast + GATT
  peer), stock config otherwise, default channel. Not USB-attached as of
  2026-09-05 evening; it was on the air for the LoRa and DM proofs. Console: USB
  CDC prints **only with DTR asserted** (`cdc-holder.py`), a `--set`/`--reboot`
  re-enumerates USB under an open handle, and **any CLI session silences the
  console until the next reboot** (the phone API takes the port; the API still
  answers). Flash by `meshtastic --enter-dfu` then `cp *.uf2 /Volumes/RAK4631/`.
- **Heltec v3** (ESP32-S3) - **unplugged since 2026-09-05 morning**, and erased
  before that. Last state: spike `fcc3c0582` (1M-only PHY), WiFi off, BLE on,
  `region=US`, `enabled_protocols=7`, primary channel `LongFast` until James
  re-shares `olm3sh`, empty node DB. When plugged: `/dev/cu.usbserial-0001`,
  console via the one-open pyserial holder with **DTR/RTS low** (every open resets
  the board).
- **Meshtadpole** (CH341A + SX1262 USB stick) - on the **Mac** since 2026-09-05,
  which is what desktop LoRa was proven with. It was on the Pixel's OTG port
  before that; this laptop has two USB ports, so it and the Pocket trade places.
- **Pixel 6a** (Android 17, SDK 37) - node `!6337995d`. USB adb as
  `24201JEGR04964`; over wifi-adb it is the **full** mDNS serial
  `adb-24201JEGR04964-pey7fQ._adb-tls-connect._tcp`. Runs the monitor with the
  3-minute scan refresh. `mcp__meshtastic__android_ui_dump` / `android_tap`
  **must pass `serial=`**; taps register on the monitor's Compose chips and
  buttons (Send test is at `(897,2211)`).
- **Desktop monitor** (this Mac) - node `!a6e88506`.
  `java -jar monitor/build/compose/jars/MeshMonitor-macos-arm64-0.1.0.jar` with
  the Temurin 21 JDK after `gradle-queue -- :monitor:packageUberJarForCurrentOS`.
  Window opens at (111,87) 720×900; Send test is `cliclick c:757,938`; capture it
  with `screencapture -x -R111,87,720,900 out.png` after making it frontmost via
  System Events (`capture_screen` MCP has no backend here). **Never
  `gradlew :monitor:run` for the bench** (never exits, pins a shared queue slot);
  **one instance at a time**, since two share a `user@host` identity and drop each
  other's frames as "heard myself".
- **`james-pc`** (192.168.1.168) - the **Linux box**, and the only host where the
  BlueZ backends can run at all. BlueZ 5.85, kernel 7.0.0-30-generic, controller
  `E8:48:B8:C8:20:00` (manufacturer 0x005d, version 0x0a). BLE **scanning is
  proven** there; **advertising is refused by that controller** with
  `Invalid Parameters (0x0d)` at every payload size and with `SecondaryChannel`
  removed, and `bluetoothctl` fails identically, so it is the adapter or its
  driver rather than this code. **The BlueZ GATT central is proven there
  (2026-09-06), both directions after an inbound-notification fix** against the
  Pocket's firmware and the Pixel; the peripheral role
  cannot be, since it cannot advertise. The Mac is unreachable from it: BlueZ
  picks the classic bearer (`br-connection-key-missing`). It is also the machine
  whose USB the bench radios normally hang off, and the sitting's recipe is in the
  plan doc's "The Linux bench sitting (2026-09-06)".
- **iPad** - devicectl UDID `EF386CA9-5DC4-551F-9D9E-ABDE7F5CF166`; **hardware**
  UDID `00008120-001C1D820A61A01E` (what `idevicesyslog` wants). Bundle
  `org.meshtastic.node.monitor`, wrapper in
  `meshtastic-node-kmp/tools/monitor-ios/`; installed and trusted as of
  2026-09-05, Bluetooth granted. Build: `:monitor:linkDebugFrameworkIosArm64`
  **with the Temurin JDK**, then `xcodebuild -project
  tools/monitor-ios/MeshMonitor.xcodeproj`, then `devicectl device install app` +
  `process launch`. Read its trace via `xcrun devicectl device process launch
  --console --terminate-existing --device <UDID> org.meshtastic.node.monitor`
  (background it, sleep, kill). **iOS 26 has no working screenshot path**
  (`idb`'s screenshotr returns `0xe8000022`, `devicectl` has no equivalent), so
  anything read off its screen is eyeball-only and needs a human.
- **MQTT broker** - `meshtastic-node-kmp/tools/mqtt-broker`, a mosquitto in
  compose bound to `127.0.0.1:1883`. Test against it, never
  `mqtt.meshtastic.org`, which feeds the public project map.
- **Monitor defaults:** the node starts as an **island (no relay)** with LoRa
  **UNSET (rx-only)**. Flip `relay` and pick a region in the tuning panel to make
  it bridge and speak on the air. `relayed` sitting at 0 next to
  `relay suppressed … (beaten by N)` is correct cancel-on-overhear, not a bug.

## Traps that cost hours (don't re-pay them)

**Diagnosis**

- **On ESP32, WiFi on means BLE off.** `main-esp32.cpp` brings up NimBLE only when
  `bluetooth.enabled && !network.wifi_enabled`, so a V3 configured as a UDP peer
  has **no BLE at all** and both BLE transports sit at "waiting for Bluetooth
  ready" for ever. This cost an afternoon: `gatt rx=0` was blamed on a firmware
  slot-conflation bug when the cause was a bench config change of my own. Check
  `get_config network` before diagnosing anything BLE.
- **Local-network protection is gated on a compat change, not on targetSdk 37.**
  `adb shell dumpsys platform_compat | grep RESTRICT_LOCAL_NETWORK` reads
  `disabled` on this Pixel, and UDP works with `ACCESS_LOCAL_NETWORK` revoked.
  Hold the permission anyway, but **do not diagnose with it**: it was recorded as
  the cause of a dead `udp` bearer and the revoke test disproved it.
- **On Android a dead bearer is a callback, not a throw.** With Bluetooth off the
  BLE transports do not throw (`onScanFailed` instead), so the `failed` column
  stays 0 and a dead row is identical to an idle one. `failures == 0` is not
  health; that is what the availability seam exists for.
- **Decode every backtrace, and count the signatures, before naming a cause.** An
  ESP32 panic dumps both cores, so one crash yields several unrelated stacks.
  Decoding *one* of 22 produced a confident and entirely wrong root cause.
  `addr2line` against the flashed ELF settled in minutes what three rounds of
  hypothesising could not:
  `~/.platformio/packages/toolchain-xtensa-esp-elf/bin/xtensa-esp-elf-addr2line
  -pfC -e .pio/build/heltec-v3/firmware-*.elf 0xADDR`. Every per-commit ELF is
  kept in `.pio/build/heltec-v3/`, so an old panic can still be decoded.
- **A serial capture contains binary bytes, so `grep` silently finds nothing in
  it** - it treats the file as binary and suppresses matches, and `grep -c` prints
  an empty string rather than 0. Use `grep -a`, or filter with `python3`.
- **A constant identity seed makes every device the same node**, and same-id nodes
  drop each other's frames as "heard myself", silently. Per-install identity
  (`platformNodeSeed()`), and one desktop instance at a time.
- **UDP multicast is asymmetric on this network** (wired-to-wireless AP
  behaviour). It worked on 2026-09-04 and not on 2026-09-05. Do not diagnose a
  dead UDP bearer from it.
- **bleak on macOS is a false negative** for GATT notifications; the real Android
  client is the oracle.

**Bench mechanics**

- **Serial: open the port once per sitting.** Each open power-on-resets the V3
  even with DTR/RTS low, so a background holder appends to a file and everyone
  reads that. NVS `Device reboots: N` is the serial-free reboot witness; the RTC
  boot count is zeroed by that reset.
- **An iPad that connected to a radio which died mid-connect keeps connecting
  forever with no app process.** bluetoothd re-issues the pending connect; killing
  and even uninstalling the app does not clear it, and it decays after ~10 min.
  **Settings > Bluetooth off** clears it at once; the Control Center toggle is
  *not* off. A completed link tears down cleanly on kill.
- **Reinstalling the iOS monitor** means re-trusting the developer profile
  (Settings > General > VPN & Device Management) and re-granting Bluetooth on
  first launch. Until both, the app runs with no BLE and the radio sees nothing.
- **pioarduino keeps one IDF libs package for every checkout.** A build after
  another env rebuilt it links against *that* config (develop once got EXT_ADV
  libs, BLE failed `rc=8`, and the test was void). Renaming the directory inside
  `~/.platformio/packages/` hides nothing, because lookup is by manifest name;
  `mv` it out, then `pio pkg install -e <env>`. "SUCCESS" with an unchanged Flash
  size and an old ELF mtime is the tell that nothing was rebuilt.
- **A stale CH341 claim** after the LoRa device tests shows in the monitor as
  `SX1262 command 0x80 failed, status 0xf7` retrying forever; a reinstall or
  replug clears it.
- **Android never triggers the controller assert because it never starts a PHY
  update.** Asked to (`setPreferredPhy(2M)`) it negotiates 2M cleanly. iOS asks at
  the controller level and apps cannot stop it, so the fix is peripheral-side.

**Build**

- Raw `./gradlew` is **blocked**. Use `direnv exec <repo> ~/.claude/bin/gradle-queue
  -- <tasks>`; exit 75 is a queue timeout, re-run. Kotlin/Native needs
  `-Dorg.gradle.java.home=$HOME/.gradle/jdks/eclipse_adoptium-21-aarch64-os_x.2/jdk-21.0.10+7/Contents/Home`.
  **Never run two node-kmp builds at once** in one checkout, or one agent's build
  compiles another's half-written edits.
- **The gate is `spotlessCheck detekt apiCheck allTests testAndroidHostTest`.**
  Compiling the native targets without *running* them hid four comma-bearing test
  names that Kotlin/Native rejects, and `gradle build` was broken on `main` for
  four commits while everything read green.
- **Kotlin/Native rejects a comma or parentheses in a backticked test name**, and
  only at the iOS/macOS compile, minutes into the gate.
- **Spotless does not read `.editorconfig`.** Anything that must bind goes in an
  explicit `editorConfigOverride` map.
- **Gradle 9: `tasks.withType<org.gradle.api.tasks.bundling.Jar>` silently misses
  `org.gradle.jvm.tasks.Jar` tasks** (Compose's uber jar, `jvmJar`), so the config
  never applies and the build stays green. Type it `org.gradle.jvm.tasks.Jar`. An
  uber jar must also strip BouncyCastle's `META-INF/*.SF|DSA` or the JVM refuses
  it.
- **`createDistributable`/jpackage fails under the Nix shell** - use the uber jar.
- **K/N `NSLog` is unusable for a Kotlin String** (`%s` silent, `%@` crashes) -
  `println` plus `--console`. `idevicesyslog` cannot see third-party app logs.
- Xcode and devicectl need the nix env stripped, **inline**: `env -u DEVELOPER_DIR
  -u SDKROOT -u CC -u CXX -u LD -u AR -u NM -u RANLIB -u STRIP -u NIX_CC
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" …`.
- A failing on-device XCUITest triggers `devicectl diagnose` and a **sudo popup**
  (benign). Use `process launch`, not a test, to run the app.
- **`@ObjCSignatureOverride`** when two delegate overrides share a Kotlin
  signature.

## Constraints - carry these verbatim

- **Never commit** the live channel PSK or URL, the radio private key, or the WiFi
  PSK to **any** file - env vars only. Only toggle the v3 `network.wifi_enabled`
  at runtime; never write the stored PSK. A broker URL carrying credentials **is a
  key**: it arrives through `MqttBridgeConfig`, which is deliberately not a data
  class so `toString` cannot leak it.
- Test MQTT against the local broker, **never `mqtt.meshtastic.org`**, which feeds
  the public project map.
- `meshtastic-node-kmp` is **private, CI off**, and takes direct commits to
  `main`. The `nixtastic` workspace takes **direct pushes to main**. The Meshtastic
  org **blocks tag deletion** and has **immutable releases**, so verify a version
  before any tag push. **Never flash the v3 without the user's OK.**
- Report status honestly: state what is **proven** and what is not, verify
  on-device before claiming a fix, and never declare a feature working while it
  isn't. "Android runs all four transports" was wrong until the counters said so.
