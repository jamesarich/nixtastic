# Handoff — multi-transport mesh (resume here)

Rewritten 2026-09-04 at the end of the session that put all four bearers in one
Android node, instrumented them per bearer, and found the dead-UDP bug that
instrumentation exists to find. **Start a new session here.** Everything below
is committed; push state is stated per repo.

**Updated the same evening:** the Apple-central bootloop is **fixed** on the spike
(`fcc3c0582`, 1M-only PHY), iPad ↔ firmware GATT carries frames, and the GATT PHY
is a monitor tuning knob (node-kmp `4436227`). Details under "The Apple-central
bootloop is FIXED" below; the bench rules it cost are at the end of this file.

## Read first

1. [`multi-transport-mesh.md`](./multi-transport-mesh.md) — the canonical plan
   (**one protocol, many bearers**; LoRa stays first-class) with the live
   `## Implementation status` and a dated section per bench sitting (the
   2026-09-04 one is last). This handoff is the pointer; that doc is truth.
2. Per the workspace protocol, run `nix run .#brief -- <repo>` before editing
   under any repo, and read that repo's own docs (`meshtastic-node-kmp` →
   `README.md` then `AGENTS.md`, both updated 2026-09-04; `firmware` →
   `AGENTS.md`).
3. Memories worth loading: `ble-mesh-interop-bench` (bench recipe + tooling
   traps), **`node-kmp-monitor-bench-driving`** (how to drive the monitor on
   Pixel and desktop), **`android-17-access-local-network`**,
   **`gradle9-jar-task-type-split`**, `pixel6a-wireless-adb`,
   `ios-ble-kmp-gotchas`, `heltec-v3-serial-dtr-rts`,
   `xcodebuild-device-test-failure-sudo`.

## Where the plan stands

| Phase | State | Where |
| --- | --- | --- |
| 1 — client N-transport node | **done; four bearers (gatt, ble-adv, udp, lora) in one Android node, instrumented per bearer, PROVEN live** | `meshtastic-node-kmp` `main`, **pushed** (`8427db6` + the docs commit) |
| 2 — firmware transport registry | done, green (native 1392/1392) | `firmware` `spike/ble-mesh-transport` (`d8ea49801`, pushed) |
| 3 — firmware BLE-GATT mesh-peer edge | **PROVEN end to end** — the phone decoded a position + text notified by the V3, and the phone's writes/relays are accepted. **Open:** the notify direction is *not delivering in the four-transport monitor* (see In flight) | spike branch tip `ea24b26d5`, **ahead 5 of origin, NOT pushed** |
| LoRa transport (CH341A + SX1262, Meshtadpole) | **PROVEN bidirectional on hardware**, merged to `main`, in the monitor | `meshtastic-node-kmp` `main` |
| 4 — new bearers (Wi-Fi Aware, anti-entropy) | future | — |

**Proven on hardware (2026-09-04), from the Pixel's own log:**

```
tx[gatt,ble-adv,udp]  probe from !6337995d
rx[lora]              opaque from !3061b02e (chan #50)
relay[gatt,ble-adv]   !3061b02e id=1188083055 hops=3
rx[ble-adv] / rx[udp] / rx[lora]  dropped … (DUPLICATE)      ← one frame, three bearers
relay suppressed !d1d90f21 (beaten by 101)                    ← cancel-on-overhear
```

plus a three-node, three-bearer chain: the desktop logged `rx[udp] text chan
from !6337995d` — the Pixel's probe — while the Pixel's own UDP tx was 0, so it
went Pixel →GATT/BLE-adv→ V3 →UDP→ desktop.

## Waiting on the bench — do this FIRST

The GATT rx=0 hunt is **done and reviewed in code, verified nowhere**. Eight
commits sit on node-kmp `main` (unpushed) and two on the spike branch (unpushed,
unflashed). The full story is in the plan doc's last section; the short version is
that the V3 was never a GATT peer of the Pixel at all — its mesh-peer
advertisement was dark because the firmware conflated "wrote the CCCD" with
"arrived on the mesh advertising set", and the iPad held the radio's single mesh
slot. Everything below is what remains.

**The GATT question is answered.** Android ↔ the firmware's mesh-peer service is
**proven both ways** on the bench (`rx[gatt]` and `gatt 15 rx` on the phone;
`Received text msg from=0x6337995d` on the radio for six consecutive sends). The
plan doc's last section has the exact readings, the three wrong turns it took to
get there, and the bench state.

**The Apple-central bootloop is FIXED on the spike (2026-09-04, `fcc3c0582`).** The
V3's BLE **controller** asserted ~200 ms after an Apple central connected — before
discovery or the CCCD write — and rebooted, 0 of ~170 connects surviving. Decoded
from 22 panics, 11 sharing a remote-PHY-update signature
(`r_llc_rem_phy_upd_proc_continue_eco` → `ll_phy_update_ind_handler_hack`),
matching `BLE assert lld_con.c 3397`. It is Espressif's open esp-idf#15311 (same
assert, same PC), reproduced on **stock develop and the nightly** with the stock
iOS app, so it was never the spike. Ruled out on the bench: serial (one held-open
port and a closed port both crash), the mesh-peer service (phone-API set crashes),
`LL_CFG_FEAT_LE_2M_PHY` (host-only, never reaches the S3 controller), the
controller's `BT_CTRL_BLE_LLCP_*` flags (1/27), a newer controller blob (none
exists through IDF v6.1). A Pixel requesting 2M PHY never crashes it — the
trigger is what the A16 does inside the procedure, not the procedure itself.
**Fix:** Apple's own accessory guidance — indicate 1M-only PHY preferences —
sent as raw HCI `LE Set Default PHY` after `ble_hs_synced()` in
`NimbleBluetooth::setup()` (the NimBLE wrapper is compiled out). 9/9 iPad
connects survive, subscribe and carry frames (`GATT mesh RX from=0x9ebca8df`).
Owed: a develop PR, a nudge on esp-idf#15311. Bench trap learnt on the way: an
iOS app whose connect never completes leaves bluetoothd retrying for ~10 min
after the app is killed *and* uninstalled; Settings > Bluetooth off (not the
Control Center toggle) clears it.

**Also settled, so nobody re-attempts it:** the **desktop monitor cannot do GATT**
— `GattLink.jvm.kt` is `UnsupportedGattLink` (the JVM has no BLE), so its `gatt`
row can never move. macOS has a real CoreBluetooth path via
`appleMain`/`macosArm64` (`GattLiveTest`), which the JVM desktop app does not
reach. Desktop's testable bearer is UDP, and that needs the V3's WiFi **on**,
which turns BLE **off** — the two cannot be tested in one sitting.

**Still unverified on-device:** the `failed` column lighting up at all (no way was
found to make a bearer *throw* on this device — see the traps),
`transport[udp] FAILED: …`, and the Apple MTU re-read (compile-verified only,
because that radio cannot hold an Apple connection long enough to exercise it).

## Next steps, in order

1. **Push three repos:** firmware spike `fcc3c0582` (the 1M-PHY fix, flashed on
   the V3), node-kmp `4436227` (GATT PHY knob), and this workspace.
2. **Develop PR from `fcc3c0582` — ON HOLD, James's call when.** It fixes stock
   firmware too (develop and the nightly bootloop on this iPad with the stock iOS
   app); the trade to state when it goes up: iOS phone-API links run at 1M on
   ESP32-S3/C3. Until then the fix lives only on the spike branch.
3. **Upstream:** nudge esp-idf#15311 (same assert, same PC 0x40006fcb) with the
   peer-initiated variant, the stock-Meshtastic repro and the 1M workaround; a
   `meshtastic/firmware` issue so A16-iPad users have somewhere to land.
4. **V3 bench restore:** the web-flasher erase (17:47) took `config.proto` and
   `nodes.proto` and reset the primary channel to `LongFast`. Region US and
   `enabled_protocols=7` are restored over serial; the **`olm3sh` channel and the
   WiFi credentials are James's to re-enter from the app** (never written by the
   agent). `bluetooth.mode` is back at its default. WiFi is **off** (BLE on).
5. **nRF52 gate: PASSED on the WisMesh Pocket (RAK4631), 2026-09-04 21:00.** Spike
   `361ac318d` links (RAM 39.8%, flash 91.4%; the fix was one undefined
   `nrf52BluetoothReady`). Flashed by UF2 (`meshtastic --enter-dfu`, copy to
   `/Volumes/RAK4631`), `enabled_protocols=2`. **BLE-adv RX proven:** the Pixel's
   Send test landed as `BLE mesh RX from=0x6337995d rssi=-36` the same second.
   **BLE-adv TX NOT observed:** two Pocket-originated texts reached the Pixel over
   LoRa only (`ble-adv` rx counter flat). Boot says why to look:
   `BLE mesh: no spare adv set (0x4), sharing the phone's` — S140 has one
   advertising set, Bluefruit owns it, and the mesh borrows it per send
   (`NRF52BLEMesh.cpp:107-125`) with no error logged and no frame received. Next
   work item: make the shared-set path actually radiate (or time-share the one
   set for both phone API and mesh), then GATT mesh-peer on nRF52. Pocket console:
   USB CDC prints only with **DTR asserted** (the opposite of the V3's UART rule),
   and a config write or `--reboot` re-enumerates USB under an open handle.
6. **Gate the ESP32-C3:** ESP32-C3 (single-core, tight RAM — likely-fail
   candidate) and nRF52 (`Bluefruit.begin(2,0)` + linker RAM); neither on the
   bench, both unbuilt. Firmware native tests need Docker on macOS.
7. **Tuning backlog** (all in the plan doc): iOS-*central* discovery flakiness
   (`didDiscoverPeripheral` unreliable; inbound link is solid); DUAL-role
   connection arbitration + a low connection cap; per-peer send-queue concurrency;
   the send-dedup asymmetry (repeated `Send test` shared a packet id on the Pixel).
8. **Bigger pieces:** desktop BLE (BlueZ D-Bus on Linux / a CoreBluetooth binding
   on macOS) and LoRa (libusb `UsbBulkPipe`) JVM backends — today the desktop
   lists four bearers and only UDP moves bytes; iOS UDP (multicast entitlement +
   a native socket the app supplies); **iOS LoRa-over-USB is blocked by iOS**.
9. **Dogfood API gaps still open:** `GattMeshTransport` clock default; a
   `MeshNode` peer `Flow`. Done since last time: a `MeshTransport` display label
   (`name`); and the note that Compose chips ignore synthetic taps was **wrong**
   — `android_tap` registers fine.
10. **Monitor polish:** the tuning panel squeezes the log to nothing on a phone
   (a sheet, or collapse peers too); the LoRa stale claim after the device tests
   (`SX1262 command 0x80 failed, status 0xf7` retrying) and the post-TX bulk-IN
   retry.

## The bench

- **Heltec v3** (ESP32-S3) — USB serial on `/dev/cu.usbserial-0001`, **WiFi off,
  BLE on**, running spike `fcc3c0582` (1M-only PHY). Config after the flasher
  erase: `region=US`, `enabled_protocols=7`, default `bluetooth.mode`, primary
  channel `LongFast` until James re-shares `olm3sh`, empty node DB. Console via
  the one-open pyserial holder (below); every open resets the board.
- **Pixel 6a** (Android 17, SDK 37) — wifi-adb serial
  `adb-24201JEGR04964-pey7fQ._adb-tls-connect._tcp` (the **full** mDNS serial).
  `mcp__meshtastic__android_ui_dump` / `android_tap` **must pass `serial=`**; taps
  register on the monitor's Compose chips and buttons (Send test is at
  `(897,2211)`). The Meshtadpole hangs off its OTG port. Node `!6337995d`.
- **Desktop monitor** — `java -jar monitor/build/compose/jars/MeshMonitor-macos-arm64-0.1.0.jar`
  with the Temurin 21 JDK after `gradle-queue -- :monitor:packageUberJarForCurrentOS`.
  Window opens at (111,87) 720×900; Send test is `cliclick c:757,938`; capture it
  with `screencapture -x -R111,87,720,900 out.png` after making it frontmost via
  System Events (`capture_screen` MCP has no backend on this Mac). **Never
  `gradlew :monitor:run` for the bench** (never exits, pins a shared queue slot);
  **one instance at a time** (same `user@host` identity — two drop each other's
  frames as "heard myself"). Node `!a6e88506`.
- **iPad** — devicectl UDID `EF386CA9-5DC4-551F-9D9E-ABDE7F5CF166`; **hardware**
  UDID `00008120-001C1D820A61A01E` (what `idevicesyslog` wants). Bundle
  `org.meshtastic.node.monitor`, wrapper in `meshtastic-node-kmp/tools/monitor-ios/`.
  iOS = `:monitor:linkDebugFrameworkIosArm64` **with the Temurin JDK**, then
  `xcodebuild -project tools/monitor-ios/MeshMonitor.xcodeproj`, then `devicectl
  device install app` + `process launch`. Read its trace via `xcrun devicectl
  device process launch --console --terminate-existing --device <UDID>
  org.meshtastic.node.monitor` (background it, sleep, kill).
- **Monitor defaults:** the node starts as an **island (no relay)** with LoRa
  **UNSET (rx-only)** — flip `relay` and pick a region in the tuning panel to make
  it bridge and speak on the air. `relayed` sitting at 0 next to
  `relay suppressed … (beaten by N)` is correct cancel-on-overhear, not a bug.

## Traps that cost hours (don't re-pay them)

- **Local-network protection is gated on a compat change, not on targetSdk 37.**
  `adb shell dumpsys platform_compat | grep RESTRICT_LOCAL_NETWORK` reads
  `disabled` on this Pixel (Android 17), and UDP works with
  `ACCESS_LOCAL_NETWORK` revoked. Hold the permission anyway, but **do not
  diagnose with it** — I recorded it as the cause of a dead `udp` bearer on
  2026-09-04 and the revoke test disproved it. What fixed that bearer is still
  unknown.
- **On Android a dead bearer is a callback, not a throw.** With Bluetooth off, the
  BLE transports do not throw (`onScanFailed` instead), so the `failed` column
  stays 0 and a dead row is identical to an idle one. `failures == 0` is not
  health; the `GATT:` line's `fault:` is what actually reports it.
- **On ESP32, WiFi on means BLE off.** `main-esp32.cpp` brings up NimBLE only when
  `bluetooth.enabled && !network.wifi_enabled`, so a V3 configured as a UDP peer
  has **no BLE at all** — both BLE transports sit at "waiting for Bluetooth ready"
  for ever. This cost a whole afternoon: `gatt rx=0` was blamed on a firmware
  slot-conflation bug when the real cause was a bench config change of my own.
  Check `get_config network` before diagnosing anything BLE.
- **Decode every backtrace, and count the signatures, before naming a cause.** An
  ESP32 panic dumps both cores, so an interrupt-WDT crash yields several unrelated
  stacks. Decoding *one* of 22 produced a confident, entirely wrong root cause
  (`TransmitHistory` doing flash I/O). `addr2line` against the flashed ELF -
  `~/.platformio/packages/toolchain-xtensa-esp-elf/bin/xtensa-esp-elf-addr2line
  -pfC -e .pio/build/heltec-v3/firmware-*.elf 0xADDR` - settled in minutes what
  three rounds of hypothesising could not. Every per-commit ELF is kept in
  `.pio/build/heltec-v3/`, so an old panic can still be decoded.
- **A serial capture contains binary bytes, so `grep` silently finds nothing in
  it** (it treats the file as binary and suppresses matches, and `grep -c` prints
  an empty string rather than 0). Filter these logs with `python3`, or `grep -a`.
- **A constant identity seed makes every device the same node**; same-id nodes
  drop each other's frames as "heard myself", silently. Per-install identity
  (`platformNodeSeed()`) — and one desktop instance at a time.
- **Gradle 9: `tasks.withType<org.gradle.api.tasks.bundling.Jar>` silently misses
  `org.gradle.jvm.tasks.Jar` tasks** (Compose's uber jar, `jvmJar`) — config never
  applies, build stays green. Type it `org.gradle.jvm.tasks.Jar`. And an uber jar
  must strip BouncyCastle's `META-INF/*.SF|DSA` or the JVM refuses it.
- **`createDistributable`/jpackage fails under the Nix shell** — use the uber jar.
- Raw `./gradlew` is **blocked** — `direnv exec <repo> ~/.claude/bin/gradle-queue
  -- <tasks>`; exit 75 = queue timeout, re-run. Kotlin/Native (iOS) needs
  `-Dorg.gradle.java.home=$HOME/.gradle/jdks/eclipse_adoptium-21-aarch64-os_x.2/jdk-21.0.10+7/Contents/Home`.
  **Never run two node-kmp builds at once** in one checkout (an agent's build
  compiles another agent's half-written edits).
- **A stale CH341 claim** after the LoRa device tests shows in the monitor as
  `SX1262 command 0x80 failed, status 0xf7` retrying forever; a reinstall or
  replug clears it.
- **K/N `NSLog` is unusable for a Kotlin String** (`%s` silent, `%@` crashes) —
  `println` + `--console`. `idevicesyslog` cannot see third-party app logs.
- Xcode/devicectl need the nix env stripped, **inline**: `env -u DEVELOPER_DIR -u
  SDKROOT -u CC -u CXX -u LD -u AR -u NM -u RANLIB -u STRIP -u NIX_CC
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" …`.
- A failing on-device XCUITest triggers `devicectl diagnose` → a **sudo popup**
  (benign). Use `process launch`, not a test, to run the app.
- `@ObjCSignatureOverride` when two delegate overrides share a Kotlin signature.
- bleak on macOS is a **false negative** for GATT notifications; the real Android
  client is the oracle.

## Constraints — carry these verbatim

- **Never commit** the live channel PSK/URL, the radio private key, or the WiFi
  PSK to **any** file — env vars only. Only toggle the v3 `network.wifi_enabled`
  at runtime; never write the stored PSK.
- `meshtastic-node-kmp` is **private, CI off**, takes direct commits to `main`.
  The `nixtastic` workspace takes **direct pushes to main**. The Meshtastic org
  **blocks tag deletion** and has **immutable releases** — verify a version
  before any tag push. Never flash the v3 without the user's OK.
- Report status honestly: state what is **proven** vs **not**, verify on-device
  before claiming a fix, and never declare a feature working while it isn't —
  today's "Android runs all four transports" was wrong until the counters said so.

## Bench rules learnt 2026-09-04 evening (each cost an hour)

- **Serial: open the port once per sitting.** Each open power-on-resets the V3
  even with DTR/RTS low, so a background holder appends to a file and everyone
  `grep -a`s it (a panic dump puts binary bytes in the file and plain `grep -c`
  then prints an empty string). NVS `Device reboots: N` is the serial-free reboot
  witness; the RTC boot count is zeroed by that reset.
- **An iPad that connected to a radio that died mid-connect keeps connecting
  forever with no app process** — bluetoothd re-issues the pending connect; kill
  and even uninstall do not clear it (it decays after ~10 min). **Settings >
  Bluetooth off** clears it at once; the Control Center toggle is *not* off. A
  completed link tears down cleanly on kill.
- **Reinstalling the iOS monitor** means re-trusting the developer profile
  (Settings > General > VPN & Device Management) and re-granting Bluetooth on
  first launch; until both, the app runs with no BLE and the V3 sees nothing.
- **pioarduino keeps one IDF libs package for every checkout.** A build after
  another env rebuilt it links against *that* config (develop got EXT_ADV libs,
  BLE failed rc=8, the test was void). Renaming the dir inside
  `~/.platformio/packages/` hides nothing (manifest lookup); `mv` it out, then
  `pio pkg install -e <env>`. "SUCCESS" with an old ELF mtime is the tell.
- **Android never triggers the controller assert because it never starts a PHY
  update**; asked to (`setPreferredPhy(2M)`) it negotiates 2M cleanly. iOS asks
  at the controller level and apps cannot stop it. The fix is peripheral-side.
