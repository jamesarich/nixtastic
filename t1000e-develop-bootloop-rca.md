# RCA: T1000-E bootloops on phone connect (firmware develop 2.8.0.d16ae2b)

**Date:** 2026-07-07
**Device:** Seeed SenseCAP T1000-E (nRF52840), node `0x70fdde9b`
**Firmware:** `2.8.0.d16ae2b` (meshtastic/firmware `develop` tip, built + flashed locally)
**App:** Meshtastic-Android `com.geeksville.mesh.fdroid.debug` (fresh build off `main`)

## Symptom
Device reboots ~15–30 s into every BLE session, re-enumerates USB, and loops for
as long as a phone keeps reconnecting. Stable indefinitely (83 s+ observed) when
no phone is connected.

## Trigger (deterministic, reproduced 3×)
1. App connects, pulls full config (`nonce=69420`) then nodes (`nonce=69421`).
2. Node DB is **empty** — gradient replay drains 0/0/0/0 entries.
3. App sends an `ADMIN` packet: **`set_time_only`** (every client does this on connect
   to sync the radio clock).
4. Firmware: `Upgrade time to quality NTP` → **`Time source acquired (None -> NTP),
   triggering NodeInfo recheck`** → `NodeInfo: scheduling immediate periodic check`
   → router handles the self-addressed admin packet → **silent reset.**

Last log line every time: `Router: Partially randomized packet id …`. No fault handler
output (hard fault / watchdog resets before flushing over USB CDC).

## Root cause
Regression in the **2.8/develop "time source acquired → immediate NodeInfo recheck"**
path (new code, not in 2.7.x), fired by the phone's routine `set_time_only` admin on
connect. The fault is in that recheck scheduling and/or the immediately-following router
handling of the self-directed admin packet.

**Ruled out:** node-DB v25 migration / gradient-sync replay (DB empty, 0 entries replayed,
still crashes); the Android app (it never crashes — it just sees `HCI_ERR_CONNECTION_TOUT`
(0x08) when the radio drops, and reconnects, driving the loop).

## Why "only while the phone is connected"
No phone → no `set_time_only` → the crash path never executes. The app sends it on every
connect, so every connect ⇒ crash ⇒ reconnect ⇒ crash = bootloop.

## Scope
- **Firmware `develop` only.** Stable **2.7.26.54e0d8d** ran cleanly on this exact device
  (verified earlier this session). Not app- or data-dependent.

## Recommendation
1. **Immediate:** roll back the T1000-E to **2.7.26.54e0d8d** (known-good).
2. **Upstream:** file against meshtastic/firmware `develop` — crash on `set_time_only`
   admin / NodeInfo-recheck-on-time-acquisition (nRF52). Attach a SWD/gdb backtrace using
   the debug ELF `firmware-tracker-t1000-e-2.8.0.d16ae2b.elf` (USB CDC yields no trace).

## Evidence
- Device serial: full config → `set_time_only` → time-acquired/NodeInfo-recheck → reset
  (3× identical); USB re-enumerated `ttyACM2`→`ttyACM3` on crash.
- Pixel logcat: `HCI_ERR_CONNECTION_TOUT (0x08)`, `Serial connection not available` — peer
  vanished, app retried.
