# Handoff — multi-transport mesh (resume here)

Rewritten 2026-09-04 at the end of the session that put all four bearers in one
Android node, instrumented them per bearer, and found the dead-UDP bug that
instrumentation exists to find. **Start a new session here.** Everything below
is committed; push state is stated per repo.

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

**Three physical prerequisites, none of which an agent can do:**

1. **Unlock the Pixel.** The monitor is installed and running behind the
   keyguard (`wm dismiss-keyguard` is refused; a lock is set), so no dashboard
   can be read.
2. **Attach the V3 to USB and approve a flash** of spike `7153c78`. Its console
   is also the only way to confirm the inferred radio-side cause — grep it for
   `advertising the mesh-peer service on instance 2` vs `peer slot held by conn N`.
3. **Quit the iPad's monitor, or set its GATT role to `peripheral only`.**
   `BLE_GATT_MESH_MAX_LINKS` is 1: whichever central connects first holds the
   radio's mesh slot, and the other phone can never find it — fix or no fix.

**Then, in order:** install the rebuilt APK; the `GATT:` line and the
`gatt links: …` log entry should name the V3's public MAC as a central with
`notify=enabled` (compare against the V3 console's own `BLE incoming connection`
line). `notify=pending` that never turns `enabled`, or `notify=refused`, is the
subscribe failing and now says so. Then the goal: the `gatt` row's rx advances and
the log shows `rx[gatt] …` from the V3's node number. Finally change a knob to
force a node rebuild and confirm the link comes back — previously it never did.
Only after that: push node-kmp and the spike branch.

**Also unverified on-device** from the same batch: the `failed` column (`! n` in
red) on a bearer whose receive path dies, `transport[udp] FAILED: …`, and the
`tx[…] text id=…` line replacing the old stats diff.

## Next steps, in order

1. **Land the workflow output** (above). If its diagnosis was low-confidence it
   will have added instrumentation rather than a fix — read what it added off the
   Pixel, then fix.
2. **Push the firmware spike branch** (ahead 5) once any firmware-side GATT fix is
   in; flash the V3 only with the user's OK (`i approve flashing by bash` was the
   form, once, for a specific build).
3. **v3 bench cleanup:** `network.enabled_protocols` 7→3, `bluetooth.mode`
   `NO_PIN`→`RANDOM_PIN`, reboot. **WiFi stays on** (it is the UDP peer).
4. **Gate the other MCUs:** ESP32-C3 (single-core, tight RAM — likely-fail
   candidate) and nRF52 (`Bluefruit.begin(2,0)` + linker RAM); neither on the
   bench, both unbuilt. Firmware native tests need Docker on macOS.
5. **Tuning backlog** (all in the plan doc): iOS-*central* discovery flakiness
   (`didDiscoverPeripheral` unreliable; inbound link is solid); DUAL-role
   connection arbitration + a low connection cap; per-peer send-queue concurrency;
   the send-dedup asymmetry (repeated `Send test` shared a packet id on the Pixel).
6. **Bigger pieces:** desktop BLE (BlueZ D-Bus on Linux / a CoreBluetooth binding
   on macOS) and LoRa (libusb `UsbBulkPipe`) JVM backends — today the desktop
   lists four bearers and only UDP moves bytes; iOS UDP (multicast entitlement +
   a native socket the app supplies); **iOS LoRa-over-USB is blocked by iOS**.
7. **Dogfood API gaps still open:** `GattMeshTransport` clock default; a
   `MeshNode` peer `Flow`. Done since last time: a `MeshTransport` display label
   (`name`); and the note that Compose chips ignore synthetic taps was **wrong**
   — `android_tap` registers fine.
8. **Monitor polish:** the tuning panel squeezes the log to nothing on a phone
   (a sheet, or collapse peers too); the LoRa stale claim after the device tests
   (`SX1262 command 0x80 failed, status 0xf7` retrying) and the post-TX bulk-IN
   retry.

## The bench

- **Heltec v3** (ESP32-S3) — on WiFi at `192.168.1.180` (the UDP peer), **no USB
  serial attached** at the moment; when it is, console via pyserial with
  **DTR/RTS off** (opening it otherwise reboots the board). Runs spike
  `ea24b26d5`. Config: `enabled_protocols=7`, `wifi_enabled=true`,
  `bluetooth.mode=NO_PIN` (see cleanup). On this build WiFi, BLE and LoRa run
  together.
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

- **Android 17 + targetSdk 37: no `ACCESS_LOCAL_NETWORK` grant → UDP is silently
  dead** (rx 0, sends fail, no error anywhere). Before debugging a socket:
  `adb shell dumpsys package <pkg> | grep LOCAL_NETWORK`; debug builds take
  `pm grant`. INTERNET + a MulticastLock are not enough.
- **`MeshNode.events` swallows a transport that fails to open** (`incoming().catch {}`),
  so "broken" reads as "idle". `TransportFailed` is landing via the workflow; until
  it does, a bearer at 0/0 while a sibling on the same medium flows is *broken*.
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
