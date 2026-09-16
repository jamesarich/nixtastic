# An ESP32 node demands pairing on a mesh link; an nRF52 does not

Measured on the bench 2026-09-15 with one BlueZ central dialling both radios in
the same run.

| peer | firmware | result |
| --- | --- | --- |
| Cardputer `28:84:85:78:4E:ED` | ESP32 / NimBLE | 13 × `declined RequestAuthorization`, 4 × `le-connection-abort-by-local`, link never held |
| `⛅_10f7` `ED:D2:65:9A:10:F7` | nRF52 / Bluefruit | reached `ready` and stayed for 21 consecutive status lines, no faults |

The nRF52 link is `LE.Connected: yes` with `LE.Paired: no` and `LE.Bonded: no`,
which is the intended shape: the mesh characteristic is unauthenticated by
design, exactly as on LoRa, and the channel PSK is the security.

## Why the two differ

The nRF52 sets security **per characteristic** and opens the mesh service
explicitly - `NRF52Bluetooth.cpp:395`, `meshBleService.setPermission(SECMODE_OPEN,
SECMODE_OPEN)` - while each phone-API characteristic gets `SECMODE_ENC_NO_MITM`
of its own.

The ESP32 sets security **for the device**. `NimbleBluetooth.cpp:1183-1197`:
whenever `config.bluetooth.mode != NO_PIN` it calls
`security.setCapability(ESP_IO_CAP_OUT)` and
`security.setAuthenticationMode(/* bonding */ true, /* MITM */ true, /* SC */ true)`.
That is NimBLE-wide, so it governs a mesh-peer connection that asked for none of
it. `ESP32BLEGattMesh.cpp:216` declaring the mesh characteristic with no
encryption or pairing requirement does not escape it.

The firmware sees the consequence on every mesh connection and already logs it:
`BLE encryption change without encrypted link; ignoring`.

## What it costs

Every client that dials an ESP32 mesh peer is pulled into MITM pairing:

- On Linux, BlueZ asks its agent, node-kmp's declines, and the link is torn
  down - `gatt rx=0 tx=0` across a 60 s run. Where gnome-shell holds the default
  agent instead, the pairing dialog appears on the desktop.
- On iOS and Android the platform raises its own pairing prompt, which is what
  a user sees as a dialog naming the radio.

So the BLE GATT mesh bearer does not currently work between a BlueZ node and an
ESP32 node, while the same central holds an nRF52 node cleanly.

## Open

Whether the ESP32 should follow the nRF52's per-characteristic model is a
firmware security decision, not a client one - the global mode is what makes the
phone API's MITM pairing work. Setting `bluetooth.mode = NO_PIN` on the radio is
the only switch that avoids it today, and it weakens the phone API's pairing to
Just Works, so it is a bench workaround rather than a fix.
