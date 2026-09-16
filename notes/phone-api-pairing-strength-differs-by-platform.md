# The phone API demanded a stronger link on ESP32 than on nRF52

Found 2026-09-15 while tracing why an ESP32 pulls BLE mesh peers into pairing.
The same `config.bluetooth.mode` produces a different security *level* on the
two platforms, so the same setting protects the phone API differently depending
on which radio a user owns.

## What each platform asks for

**ESP32** (`src/nimble/NimbleBluetooth.cpp`). The phone-API characteristics are
declared `PROPERTY_*_AUTHEN | PROPERTY_*_ENC` (lines 1255-1265): access needs an
*authenticated* encrypted link. The stack is configured to match at 1183-1197 -
`setCapability(ESP_IO_CAP_OUT)` and `setAuthenticationMode(bonding, MITM, SC)`.

**nRF52** (`src/platform/nrf52/NRF52Bluetooth.cpp`). The same characteristics get
`SECMODE_ENC_NO_MITM` (line 261 and 263-293): access needs an encrypted link,
authenticated or not. A passkey is still offered - `setPIN` and
`setIOCaps(true, false, false)` at 387-389 - but the attributes do not require
that it was proven.

The distinction is deliberate elsewhere in that same file: the DFU services take
`SECMODE_ENC_WITH_MITM` (lines 426 and 429), and the phone-API lines carry
`// FIXME, secure this!!!` and `// FIXME secure this!`.

## Why it matters

A central with no input and no output degrades pairing to Just Works, which
yields an encrypted but *unauthenticated* link. That link:

- **reaches the phone API on an nRF52**, because `ENC_NO_MITM` is satisfied;
- **is refused by an ESP32**, whose `AUTHEN` flags are not.

So a passkey shown on an nRF52's screen is advisory where an ESP32's is
enforced, under identical configuration.

## Bearing on the BLE mesh work

This is upstream behaviour, not something the mesh bearer introduced, and the
mesh characteristic itself is unauthenticated by design on both platforms. It
explains the second half of why the platforms behave differently for a mesh
peer: `notes/esp32-demands-pairing-on-mesh-links.md` covers the first half,
which is that the ESP32's requirements are device-global.

## Resolved on the nRF52 side, 2026-09-16

The nRF52 characteristics now take `SECMODE_ENC_WITH_MITM`, matching the service
that already held them at that level and the DFU services beside them, so the
passkey it displays has to be proven. Existing Just Works pairings must pair
again.

ESP32 cannot follow. Its MITM requirement is device-global, and that is exactly
what drags a mesh peer which never touches the phone API into passkey pairing -
see `esp32-demands-pairing-on-mesh-links.md`. So the platforms still differ, but
now deliberately and for a stated reason rather than by accident.

Also worth recording, because it misled this note when first written:
`meshBleService` in `NRF52Bluetooth.cpp` is the phone-API service, not the
mesh-peer service. The mesh-peer service is `NRF52BLEGattMesh.cpp` and carries no
security.
