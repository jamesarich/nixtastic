# Handoff — multi-transport mesh (resume here)

Written 2026-09-03 at the end of the session that proved cross-platform BLE-GATT
mesh interop. **Start a new session here.** Everything below is committed and
pushed unless marked otherwise.

## Read first

1. [`multi-transport-mesh.md`](./multi-transport-mesh.md) — the canonical plan
   (**one protocol, many bearers**; LoRa stays first-class) with the live
   `## Implementation status`. This handoff is the pointer; that doc is truth.
2. Per the workspace protocol, run `nix run .#brief -- <repo>` before editing
   under any repo, and read that repo's own docs (`meshtastic-node-kmp` →
   `README.md`; `firmware` → `AGENTS.md`).
3. Memories worth loading: `ble-mesh-interop-bench` (the bench recipe + every
   tooling trap that cost hours), `xcodebuild-device-test-failure-sudo`,
   `pixel6a-wireless-adb`, `ios-ble-kmp-gotchas`, `heltec-v3-serial-dtr-rts`.

## Where the plan stands

| Phase | State | Where |
| --- | --- | --- |
| 1 — client N-transport node (GATT + sender-skip + per-peer delivery) | **done, green, interop PROVEN** | `meshtastic-node-kmp` `main` (`8520a42`) |
| 2 — firmware transport registry (UDP/BLE-adv/MQTT taps, LoRa untouched) | **done, green** (native 1392/1392) | `firmware` `spike/ble-mesh-transport` (`d8ea49801`, pushed) |
| 3 — firmware BLE-GATT mesh-peer edge | **service WRITTEN + committed** (`3022a3776`), native 1418/1418, S3 bring-up proven; cross-device frame exchange **bench-gated** (Pixel lockscreen) | spike worktree/branch |
| 4 — new bearers (Wi-Fi Aware, anti-entropy) | future | — |

**Proven on hardware (2026-09-03):** Android (Pixel 6a) ↔ iOS (iPad) mesh over
BLE GATT, **bidirectional, decoding at the mesh layer** — Pixel `!6337995d` ↔
iPad `!b28c3748` exchanged text both ways, each side running full packet
processing (reassembly → decode → channel decrypt → dedup). Proven with the new
`:monitor` Compose Multiplatform app on dual dashboards — it is now the bench tool.

## Next steps, in order

1. **Phase 3 — the firmware mesh-peer GATT service is WRITTEN + committed**
   (`3022a3776` on `firmware/.claude/worktrees/spike-ble-mesh-transport`, branch
   `spike/ble-mesh-transport`; not pushed). Native 1418/1418; heltec-v3 flashed;
   the service registers + advertises on instance 2 with WiFi off, no OOM. **What
   remains:**
   - **Bench frame-crossing test (blocked on a Pixel unlock).** Physically unlock
     the Pixel 6a with the `node-kmp monitor` app foregrounded (DUAL role); it
     then connects to the v3's mesh-peer service. Watch a v3 NodeInfo frame land
     in the app's rx counter, and a `Send test` from the app land on the v3
     (`BLE GATT mesh RX from=…`). While locked the app's Activity is paused so it
     never scans — `wm dismiss-keyguard` is refused, a lock is set.
   - **v3 bench cleanup afterwards:** restore `network.wifi_enabled=true` + reboot,
     revert `network.enabled_protocols` 7→3.
   - **Gate the other MCUs:** ESP32-C3 (single-core, tight RAM — likely-fail
     candidate) and nRF52 (`Bluefruit.begin(2,0)` + linker RAM); neither board is
     on the bench, both unbuilt. Firmware native tests need Docker on macOS
     (`bin/test-native-docker.sh`).
2. **Tuning backlog** (all logged in the plan doc):
   - iOS-*central* outbound path is flaky at **discovery** (`didDiscoverPeripheral`
     doesn't reliably deliver; ruled out dual↔dual contention and RPA rotation).
     The **inbound** link (iPad-peripheral ← Pixel-central) formed in 6/6 captures
     and is bidirectional alone, so the mesh works — the central direction is
     redundant capacity to harden. A `didFailToConnectPeripheral` handler is in.
   - DUAL-role connection arbitration (only one side dials) + a low (2–3)
     connection cap; per-peer send-queue concurrency (verify Android's device-wide
     GATT-op behaviour on hardware).
   - Send-dedup asymmetry: the Pixel's repeated `Send test` shared a packet id
     (iPad deduped 2 of 3) while the iPad's three were distinct — a monitor /
     `sendText` packet-id question, not transport.
3. **Dogfood API gaps** the monitor surfaced (not yet filed): `GattMeshTransport`
   clock default, a `MeshNode` peer `Flow`, a `MeshTransport` display label;
   Compose role-picker chips don't register `uiautomator` taps (finger taps do);
   iOS simulator framework path is hardcoded to device.
4. **Branch hygiene**: `feat/monitor-app` was fast-forwarded straight onto
   node-kmp `main` (private repo, CI off — fine). `feat/codec-per-transport` is a
   **separate, unrelated** branch (ahead 1) — deliberately untouched.

## The bench

- **Heltec v3** (ESP32-S3) `/dev/cu.usbserial-0001` — runs the spike firmware.
  Console via pyserial with **DTR/RTS off** (opening it otherwise reboots the board).
- **iPad** — devicectl UDID `EF386CA9-5DC4-551F-9D9E-ABDE7F5CF166`; **hardware**
  UDID `00008120-001C1D820A61A01E` (what `idevicesyslog` wants — different
  namespace). Bundle `org.meshtastic.node.monitor`, wrapper in
  `meshtastic-node-kmp/tools/monitor-ios/`.
- **Pixel 6a** — wifi-adb serial `adb-24201JEGR04964-pey7fQ._adb-tls-connect._tcp`
  (the **full** mDNS serial; the bare one fails). Read its dashboard with
  `mcp__meshtastic__android_ui_dump` — **must pass `serial=`**.
- **The `:monitor` app**: `:monitor-android:assembleDebug` → `adb install -r`;
  iOS = `:monitor:linkDebugFrameworkIosArm64` **with the Temurin JDK** then
  `xcodebuild -project tools/monitor-ios/MeshMonitor.xcodeproj` (links the prebuilt
  `monitor/build/bin/iosArm64/debugFramework/Monitor.framework`), then
  `devicectl device install app` + `process launch`.
- **Reading the iPad's own trace** (the thing that looked impossible): `GattDebug`
  is forced on in `MainViewController`; its `MNGATT …` lines go to stdout and are
  captured by `xcrun devicectl device process launch --console --terminate-existing
  --device <UDID> org.meshtastic.node.monitor` (background it, sleep, kill). A
  plain launch (no `--console`) keeps the app up for the user to tap.

## Traps that cost hours (don't re-pay them)

- **A constant identity seed makes every device the same node** (`!2c2926ac`);
  same-id nodes drop each other's frames as "heard myself" — silently, no event —
  over a perfectly live link. Fixed via `platformNodeSeed()`. Any client node
  needs a per-install identity.
- **K/N `NSLog` is unusable for a Kotlin String**: `%s` renders nothing, `%@`
  **crashes on launch**. Use `println` + `--console`. `idevicesyslog` sees system
  `bluetoothd` but **not** third-party app os_log; `log collect` has no device
  support on this macOS; `devicectl` has no log stream.
- Raw `./gradlew` is **blocked** — use `direnv exec <repo> ~/.claude/bin/gradle-queue
  -- <tasks>`; exit 75 = queue timeout, re-run. Kotlin/Native (iOS) needs
  `-Dorg.gradle.java.home=$HOME/.gradle/jdks/eclipse_adoptium-21-aarch64-os_x.2/jdk-21.0.10+7/Contents/Home`
  (Nix JDK SIGSEGVs the link; the macOS Adoptium JDK is **nested**). Android/JVM
  tasks use the default Nix JDK. **Never run two node-kmp gradle builds at once**
  — the daemon "disappears".
- Xcode/devicectl need the nix env stripped: `env -u DEVELOPER_DIR -u SDKROOT -u
  CC -u CXX -u LD -u AR -u NM -u RANLIB -u STRIP -u NIX_CC
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" …` — **inline it**, a shell variable used
  as a command prefix silently fails to run.
- A failing on-device XCUITest triggers `devicectl diagnose` → a **sudo popup**
  (benign). Use `process launch`, not a test, to run the app.
- `@ObjCSignatureOverride` is needed when two delegate overrides share a Kotlin
  signature (`didDisconnectPeripheral` / `didFailToConnectPeripheral`) — the
  selector keyword isn't part of Kotlin overload resolution.

## Constraints — carry these verbatim

- **Never commit** the live channel PSK/URL, the radio private key, or the WiFi
  PSK to **any** file — env vars only. Only toggle the v3 `network.wifi_enabled`
  at runtime (restore `true` + reboot after); never write the stored PSK.
- `meshtastic-node-kmp` is **private, CI off**. The `nixtastic` workspace takes
  **direct pushes to main**. The Meshtastic org **blocks tag deletion** and has
  **immutable releases** — verify a version before any tag push.
- Report status honestly: state what is **proven** vs **not**, verify on-device
  before claiming a fix, and never declare a feature working while it isn't.
