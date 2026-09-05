# Physical node inventory - agent sessions

Evidence window: 2026-07-02 → 2026-08-26 (no session transcripts predate 2026-07-02).
Rule for a row: a physical radio I opened a local session with (serial / TCP) **or** flashed on the bench. Mesh neighbours heard over RF are excluded. "Last session" = last actual connection, not last USB enumeration.

| # | Node / owner | Board | USB serial | Node id | Transport | Firmware at last contact | First → last session | Attached now |
|---|---|---|---|---|---|---|---|---|
| 1 | `olm3sh rak solar` ⛅ | RAK4631 (nRF52840) | `7885014CB2C5B186` | `!d9d277c3` / 3654449091 | USB `/dev/ttyACM0-1` | 2.8.0.abd3348, CLIENT_MUTE, US | 2026-07-02 → 2026-08-22 | yes (ACM1) |
| 2 | `olm3c` ☕ - bench OTAFIX unit | RAK4631 (nRF52840) | `E6947CB9383DC08D` | `!d630cd5c` / 3593522524 | USB `/dev/ttyACM0-1` | 2.8.0.74119c0, US, LONG_FAST | 2026-08-17 → 2026-08-22 | no |
| 3 | `E2E-DUT-heltec` / `WIPE-ME-6526` | Heltec V3 (ESP32-S3) | CP2102 `0001` (fleet key `noserial:f331aa383f2d`) | `!483ba531` → `!da6218c4` → `!2902d082` | USB `/dev/ttyUSB0` | 2.8.0.0fef83d (also ran 2.7.25 / 2.7.26) | 2026-07-02 → 2026-08-15 | yes (USB0) |
| 4 | `E2E-TESTER-tbeam` TEST | LilyGO T-Beam S3 Core | `34:B7:DA:57:56:F0` | `!f8f277b5` / 4176639925 | USB `/dev/ttyACM0` | 2.8.0.8abae90, US | 2026-07-02 → 2026-08-15 | no |
| 5 | (unnamed) | Seeed XIAO S3 | `E8:06:90:9E:85:A0` | `!909e85a0` / 2426308000 | USB `/dev/ttyACM0-2` | 2.7.26.54e0d8d, US | 2026-07-02 → 2026-07-08 | yes (ACM0) |
| 6 | (unnamed) | Seeed Wio Tracker L1 (nRF52840) | `623E3BB420B0F9C7` | not read | USB `/dev/ttyACM1` + UF2 mass storage | 2.7.26.54e0d8d after an S140 factory-erase UF2 | 2026-08-15 | no |
| 7 | (unnamed) | Seeed Tracker T1000-E (nRF52840) | `FC26F58108817236` | `!70fdde9b` / 1895685787 | USB `/dev/ttyACM2` | 2.8.0.d16ae2b, region UNSET | 2026-07-07 → 2026-07-08 | no |
| 8 | `olm3sh tadpole` 🐸 | Pi 5 + RAK6421 Pi HAT + RAK13300 (SX1262) | n/a | `!7c62f165` / 2086859109 | TCP `192.168.1.142:4403` | meshtasticd 2.7.15, US915, CLIENT_MUTE | 2026-08-21 | shelved (hat unstacked) |
| 9 | `mbp-bench` MBP → `TaterSalad` 🥔 | Meshtadpole USB stick (CH341 + SX1262), NixOS MBP host | n/a | `!37423401` / 927085569 | TCP, `meshtastic --host localhost` over ssh to 192.168.1.176 | meshtasticd 2.7.26 (`hwModel: PORTDUINO`), US, CLIENT | 2026-08-22 | on the MBP |

**9 physical radios; 3 of them on `james-pc`'s USB right now.**

## Notes

- **Row 3 is one board, three node numbers.** The Heltec V3 on `/dev/ttyUSB0` re-derived its node num across the two-pass factory erases in the PR #6526 work on 2026-08-15 (`1211868465` → `3663861956` → `688050306`), with `long_name` flipping between `E2E-DUT-heltec` and `WIPE-ME-6526` on the same port.
- **Two distinct RAK4631s**, separable only by USB serial: `7885014CB2C5B186` (the solar node, the one in the fleet registry) and `E6947CB9383DC08D` (the bench unit behind the OTAFIX bootloader and BLE-OTA work on 17 and 21–22 Aug). Both were plugged into `james-pc` simultaneously on 2026-08-22, on rotating `ttyACM*` numbers - the serial is the only reliable key.
- **Row 6 has no node id.** Every `device_info` against `/dev/ttyACM1` that day errored; contact was via the UF2 bootloader volume and the Android app's DFU flow, not the serial API. The app reported `Verification timed out`, but the following screen read `Currently Installed: 2.7.26.54e0d8d` - the write landed, only the verify step timed out.
- Rows 5 and 4 were enumerated later than their last session (Xiao S3 on 08-21/22 and again today; T-Beam through 08-20) without a connection being opened.
- Row 8's radio is real (SX1262 on a Pi HAT) but the stack is shelved pending Adafruit #2223 stacking headers.
- Row 9 is a real LoRa stick over CH341/libusb, not a simulated node - the kernel `spi-ch341` driver had to be blacklisted for meshtasticd to claim it.

## Deliberately excluded

- Mesh neighbours from node-DB dumps - heard over RF, never connected to.
- The `meshtasticd` sim rig (`Module: sim` + UDP multicast) and local `meshtastic --host 127.0.0.1` targets on `james-pc` - virtual, no radio.
- Android emulators (`emulator-5554/5556`) and the ATAK fleet nodes (`tcp:K9-REX` etc.) - virtual.
- Pixel 6a `24201JEGR04964` - adb host for the app, not a node.
- The ~9 desktop-app databases under `~/.meshtastic/` (Apr–Aug) - app-side connections, outside the agent-session rule.
- The OTAFIX v0.9.2 "17-board validation" - no local flash or connect evidence for those boards; community-validated.

## Sources

`~/.meshtastic_mcp/fleetsuite.db` (`devices`, `flash_events`); session transcripts under `~/.claude/projects/*/**.jsonl` (`mcp__meshtastic__device_info` / `list_devices` / `serial_open` results, `meshtastic --info` output, `dmesg` and `UsbHostManager` lines); a live `list_devices` run on 2026-08-26.
