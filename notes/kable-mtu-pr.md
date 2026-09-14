Title: Report the negotiated ATT MTU from the JVM peripheral

## Problem

`BtleplugPeripheral.maximumWriteValueLengthForType` returns a constant `23 - 3`, so every JVM consumer sizes writes for the default MTU no matter what the link negotiated. A peripheral that negotiated 247 (or 517, which the Meshtastic firmware asks for) still gets 20-byte chunks, and a fragmenting protocol spends many times the round trips it needs.

btleplug already reports the value: `btleplug::api::Peripheral::mtu()` is populated by every backend Kable ships natives for - BlueZ reads the characteristic `MTU` property during service discovery, CoreBluetooth derives it from `maximumWriteValueLength(for:)` when `ServicesDiscovered` arrives, and WinRT stores it from `MaxPduSizeChanged`. It just wasn't exported through the ffi.

## Change

- `kable-btleplug-ffi`: export `Peripheral::mtu()`, returning the platform peripheral's negotiated MTU (btleplug's `DEFAULT_MTU_SIZE`, 23, until services have been discovered).
- `BtleplugPeripheral.maximumWriteValueLengthForType` forwards the query from `Connecting.Services` up (btleplug reports the default itself until discovery has run) and returns the default outside a connection, matching the Android backend's `mtu.value ?: DEFAULT_ATT_MTU`. An ffi error from a disconnect racing the query is folded into the default, so a plain query never throws.
- `Peripheral.maximumWriteValueLengthForType` KDoc gains the JVM line alongside the Android, iOS and JavaScript ones.

No public Kotlin API change; the JVM API dump is unchanged. The ffi gains one method, which the generated bindings pick up at build.

One sharp edge, in btleplug rather than here: on BlueZ older than 5.62 the `MTU` property is absent and btleplug's BlueZ backend `unwrap()`s it (`bluez/peripheral.rs:145`). That path was unreachable from Kable before this change. Current LTS distributions ship well past 5.62, so it is a concern for legacy hosts only; happy to add a `catch_unwind` guard in the ffi if you'd rather not expose it at all.

Not covered by tests: the JVM backend has no test source set, and the value is only observable against a real peripheral. Observed on Linux (BlueZ 5.87) against a Meshtastic radio, which asks for an MTU of 517, via a throwaway `jvmTest` that scans, connects and queries `maximumWriteValueLengthForType(WithoutResponse)` at each stage:

| Stage | Before this change | After |
|---|---|---|
| Before `connect()` | 20 | 20 |
| `Connecting.Services`, as `services` is first published | 20 | 514 |
| `Connected` | 20 | 514 |
| After `disconnect()` | 20 | 20 |

BlueZ agrees: polling the characteristic's `MTU` property over D-Bus on a `bluetoothctl` connection reads 23 until `ServicesResolved` flips to true and 517 from then on.

---

*Disclosure: drafted with an AI assistant (Claude Code), then reviewed by me. Motivated by [meshtastic-node-kmp](https://github.com/meshtastic/meshtastic-node-kmp), whose GATT transport sizes fragments from the live MTU per send. Verified locally with `cargoLintRust`, `lintKotlin`, `compileKotlinJvm`, `jvmApiCheck` and the hardware run above; `cargoLintClippy` fails on Linux `main` before this change, on an unused `serde` import in `peripheral_id.rs` that is only compiled under `cfg(target_os = "linux")`, so it never fires on the macOS runner where CI runs `check`.*

Suggested labels: `patch`, `jvm`.
