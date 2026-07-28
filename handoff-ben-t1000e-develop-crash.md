# Bug: T1000-E (nRF52840) hard-resets on every phone connect — `develop` 2.8

**Reporter:** James  ·  **Date:** 2026-07-07
**Handoff to:** @thebentern

## TL;DR
On `develop`, a T1000-E crash-loops the moment a client (Android app) connects over BLE.
It is **stable with no client connected**. The crash is deterministic and fires right after
the app's routine `set_time_only` admin command, in the **new 2.8 "time acquired → immediate
NodeInfo recheck"** path. Rolling back to `2.7.26.54e0d8d` fixes it. Node DB is empty, so it is
**not** the v25 migration / gradient-sync replay.

## Environment
| | |
|---|---|
| Firmware | `2.8.0.d16ae2b` — `develop` @ `d16ae2b09` ("Rename power.h to Power.h", #10919) |
| protobufs submodule | `1ae3be3` (v2.7.26-95) |
| Board / env | `tracker-t1000-e` (Seeed SenseCAP T1000-E, nRF52840) |
| Node | `0x70fdde9b` |
| App | Meshtastic-Android `main`, `com.geeksville.mesh.fdroid.debug` |
| Build/flash | local `pio run -e tracker-t1000-e` + adafruit-nrfutil serial DFU |
| Known-good | `2.7.26.54e0d8d` — verified stable on this same unit |

## Repro (100%, 3/3)
1. Flash `tracker-t1000-e` @ develop tip; boot with **no** BLE client → stable (verified 83 s+ uptime).
2. Connect the Android app over BLE.
3. App pulls config (`nonce=69420`) then nodes (`nonce=69421`); then sends `AdminMessage.set_time_only`.
4. Device hard-resets ~1 s later, USB re-enumerates (`ttyACM2`→`ttyACM3`), app reconnects → loop.

## Serial trace (identical every run; trimmed)
```
INFO  Client wants config, nonce=69420
DEBUG   Send config: device/position/power/network/display/lora/bluetooth/security …
DEBUG   Unhandled module config type 14
INFO  Config Send Complete
INFO  Client wants config, nonce=69421     (nodes)
INFO    Begin position replay: 0 entries   ← DB EMPTY — replay path is not involved
INFO    Replay drain complete (status count=0)
DEBUG PACKET FROM PHONE (to=self, Portnum=6 ADMIN)
INFO  [Router] Received Admin … Handle admin payload 43   (set_time_only)
INFO  [Router] Client received set_time_only command
DEBUG [RTC]    Upgrade time to quality NTP
DEBUG [Router] Time source acquired (None -> NTP), triggering NodeInfo recheck   ← NEW in 2.8
DEBUG [Router] NodeInfo: scheduling immediate periodic check                      ← NEW in 2.8
DEBUG [Router] Routing sniffing (the admin pkt) … Initial packet id … Partially randomized packet id
*** silent reset — no fault handler output over USB CDC ***
```
No panic/backtrace is emitted (hard fault or WDT resets before flushing).

## Prime suspects (new-in-2.8 code in the crash window)
- **`src/gps/RTC.cpp:16` `triggerNodeInfoCheckOnTimeSource()`** — on `RTCQualityNone → >None`
  calls `nodeInfoModule->triggerImmediateNodeInfoCheck()`. Invoked from `perhapsSetRTC()`
  (`src/gps/RTC.cpp` ~line 275, the `shouldSet` branch) — i.e. **synchronously inside AdminModule's
  `set_time_only` handling**, which itself runs inside the router's packet dispatch.
- **`src/modules/NodeInfoModule.cpp:129 triggerImmediateNodeInfoCheck()`** → `setIntervalFromNow(0)`
  → fires a NodeInfo broadcast almost immediately, plausibly re-entrant with the in-flight admin
  packet still being handled/re-emitted by the router (`Router: Partially randomized packet id …`
  is the last line before reset).
- Admin entry point: `src/modules/AdminModule.cpp:578` (`set_time_only_tag`).

Hypothesis: the immediate NodeInfo recheck triggered from within the RTC-set path (called from
within admin/router dispatch) causes a re-entrancy / send-from-callback fault on nRF52. `nodeInfoModule`
non-null is checked, but the immediate send may occur in a context the mesh send path doesn't expect.

## Ruled out
- **v25 NodeDB migration / gradient-sync replay** — DB empty, replays 0/0/0/0, still crashes.
- **The Android app** — never crashes; only observes the peer drop:
  `HCI_ERR_CONNECTION_TOUT (0x08)` / `Serial connection not available` then reconnects (drives the loop).
- **Hardware / this specific unit** — same board runs `2.7.26` flawlessly.

## What I can provide
- The debug ELF with symbols: `firmware-tracker-t1000-e-2.8.0.d16ae2b.elf` (build tree available).
- A live SWD/gdb backtrace on request (USB CDC yields none) — say the word and I'll wire JLink/pyocd
  to the T1000-E pads and capture the fault PC/LR + stack.
- Full raw serial + Pixel logcat captures.

## Ask
Confirm whether `triggerNodeInfoCheckOnTimeSource → triggerImmediateNodeInfoCheck` firing
synchronously from `perhapsSetRTC()` (inside admin/router dispatch) is safe on nRF52, or should be
deferred (e.g. set a flag / schedule off-thread) rather than sending from within the RTC-set callback.
