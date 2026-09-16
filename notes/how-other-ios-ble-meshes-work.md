# How other iOS BLE meshes work, and what it says about ours

Comparison research, 2026-09-16, prompted by two of our own findings: iOS never
receives our mesh advertisement, and a BlueZ central cannot hold an iOS peer.

The closest comparable is **bitchat** (`permissionlesstech/bitchat` and
`bitchat-android`), a BLE mesh messenger with interoperating iOS, macOS and
Android implementations.

## What they do

**Nothing rides in the advertisement.** `BLERadioController.advertisementData()`
is exactly one key:

```swift
[CBAdvertisementDataServiceUUIDsKey: [BLEService.serviceUUID]]
```

No local name (deliberately, for privacy), no manufacturer data. Advertisements
are for *discovery*; every byte of payload goes over a GATT connection. That is
not a design preference - `CBPeripheralManager.startAdvertising` accepts only a
local name and service UUIDs, so an iOS peripheral cannot put a packet in an
advertisement even if it wanted to.

**The characteristic is unencrypted, and pairing never happens.** iOS:

```swift
CBMutableCharacteristic(type: characteristicUUID,
                        properties: [.notify, .write, .writeWithoutResponse, .read],
                        permissions: [.readable, .writeable])
```

Android: `PERMISSION_READ or PERMISSION_WRITE`, and the CCCD likewise. No
`PERMISSION_*_ENCRYPTED`, no bonding. Confidentiality is a Noise session in the
application layer, not BLE link security.

**Both roles at once, and background survival.** They run central and peripheral
concurrently, restore the peripheral through
`CBPeripheralManagerRestoredStateServicesKey`, respond to every write
immediately ("we must respond within a few milliseconds or the central will
timeout"), and queue notifications against
`peripheralManagerIsReady(toUpdateSubscribers:)` for backpressure.

## What that says about ours

**The GATT bearer is the same design.** Our mesh characteristic is
`write | write-without-response | notify`, unauthenticated on every platform,
with the channel PSK doing what Noise does for them. We arrived at the same
shape independently.

**The advertisement bearer is not a thing on iOS, for anyone.** Ours carries a
whole `MeshPacket` in manufacturer data in an extended PDU. No iOS app does
this, because CoreBluetooth cannot send it and - as we measured - iOS does not
report receiving it either. So `notes/ios-cannot-hear-ble-mesh-adverts.md` is
not a gap against the field; it is where the field already is. An Apple node
joins over GATT, full stop.

**Our SMP problem is not an iOS mesh problem - it is a BlueZ-as-central
problem.** bitchat never meets it because both ends are phones: an iOS or
Android central reading an unencrypted characteristic never triggers security.
The linux-bluetooth list and the BlueZ tracker carry our symptom repeatedly -
a central reads an attribute needing authentication, gets *Insufficient
Authentication*, and an SMP Security Request loop ends in a disconnect.

That points at a fix we had not considered: **let iOS be the central.** If the
iPad dials us, it reads only our own unencrypted attributes and nothing ever
asks for security. Bonding, which was the option on the table, is not needed.

### Where that test stands

Unproven, for a bench reason rather than a design one. `james-pc`'s Realtek
adapter cannot advertise at all (`james-pc-realtek-bt-adapter`), so an iOS
central can never discover it. A `PERIPHERAL_ONLY` run there is clean - zero
faults, no aborts, no SMP - and also silent, which is consistent with both "it
works" and "nobody could see us". The uConsole can advertise legacy, which is
enough for a 128-bit service UUID in 31 bytes, but its `PERIPHERAL_ONLY` run
logged no advertising line either way, so that one is inconclusive rather than
negative.

The next step is to confirm the peripheral actually registers an advertisement
before drawing any conclusion from silence.

## Sources

- <https://github.com/permissionlesstech/bitchat> - `BLERadioController.swift`,
  `BLEService+LinkLayerPeripheralRole.swift`
- <https://github.com/permissionlesstech/bitchat-android> - `AppConstants.kt`,
  `BluetoothGattServerManager.kt`
- <https://www.spinics.net/lists/linux-bluetooth/msg92248.html> - iOS central
  with a BlueZ peripheral disconnecting on insufficient auth
- <https://github.com/bluez/bluez/issues/650>, <https://github.com/bluez/bluez/issues/153>
