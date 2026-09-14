# Kable peripheral role: API sketch for JuulLabs/kable#51

Status: draft, 2026-09-13, not posted. This is the comment twyatt asked for on #51
in 2021 ("happy to discuss possible designs if the community wants to try and
tackle this effort and submit PRs"). Every member below has a consumer in
`meshtastic-node-kmp`'s `GattLink`; nothing is speculative.

Why node-kmp is not a Kable consumer today: `notes/desktop-ble-plan.md`
(decided 2026-09-06: "the desktop node is a full BLE node, both GATT roles").

Suggested home in the workspace: `notes/kable-peripheral-api-sketch.md`.

---

## Draft comment for #51

I maintain a dual-role GATT mesh transport in Kotlin Multiplatform: every node is
a central *and* a peripheral, on Android, Apple and JVM/Linux. It couldn't be
built on Kable because Kable has no peripheral role, so the platform halves were
written by hand. Having done that once, here is the API shape that fell out,
mapped onto Kable's existing idioms, as the design discussion this issue asked for.

### Scope

A peripheral role is two things, worth keeping separate the way `Scanner` and
`Peripheral` are on the central side:

1. **Advertising**: putting a payload on the air. No connection involved.
2. **A GATT server**: hosting services, accepting writes, notifying subscribers.

Web Bluetooth has neither, which was the uniformity concern raised in 2021. The
precedent for that is already in Kable: `Peripheral.rssi()` throws
`UnsupportedOperationException` on JavaScript, and `Filter.Address` is
Android-only. A peripheral role would follow the same rule: `Advertiser()` and
`GattServer()` throw `UnsupportedOperationException` on `js`/`wasmJs` at build
time, and the README's platform table says so.

### 1. Advertising

```kotlin
public fun Advertiser(builderAction: AdvertiserBuilder.() -> Unit = {}): PlatformAdvertiser

public expect class AdvertiserBuilder internal constructor() {
    public fun services(vararg uuids: Uuid)
    public var localName: String?
    /** Manufacturer-specific data, keyed by company ID. Android and JVM/Linux only. */
    public fun manufacturerData(companyId: Int, data: ByteArray)
    public fun logging(init: LoggingBuilder)
}

public interface Advertiser {
    /**
     * Cold: collection starts advertising, cancellation stops it. Emits state changes
     * (started, stopped by the OS, failed with a platform reason) so a consumer can
     * tell "not advertising" from "advertising into an empty room".
     */
    public val state: Flow<AdvertisingState>
}
```

Platform facts that shape the builder:

- **Android** has two advertisers. Legacy `startAdvertising` carries 31 bytes;
  `startAdvertisingSet` with `setLegacyMode(false)` carries 251 on a 5.0+
  controller. The builder should take the extended path when the payload exceeds
  31 bytes or the consumer asks (`extended = true` on the Android builder, the
  way `scanSettings` is Android-only today). Needs `BLUETOOTH_ADVERTISE` on
  API 31+.
- **Apple** `CBPeripheralManager.startAdvertising` accepts exactly two keys,
  `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`.
  `manufacturerData` throws `UnsupportedOperationException` there. This is a
  CoreBluetooth limit the library cannot paper over.
- **JVM** has no advertiser in btleplug, which says of itself "host/central mode
  only". Linux has BlueZ `LEAdvertisingManager1` over D-Bus, Windows has
  `BluetoothLEAdvertisementPublisher`, and macOS from the JVM has nothing without
  a native bridge. The honest first cut is Linux via `bluer` in a second Rust
  crate next to `kable-btleplug-ffi`, and `UnsupportedOperationException`
  elsewhere.

### 2. GATT server

```kotlin
public fun GattServer(builderAction: GattServerBuilder.() -> Unit = {}): PlatformGattServer

public expect class GattServerBuilder internal constructor() {
    public fun service(uuid: Uuid, primary: Boolean = true, init: LocalServiceBuilder.() -> Unit)
    public fun logging(init: LoggingBuilder)
}

public class LocalServiceBuilder {
    public fun characteristic(
        uuid: Uuid,
        properties: Characteristic.Properties,   // the existing value class
        permissions: Permissions,
        init: LocalCharacteristicBuilder.() -> Unit = {},
    )
}

public interface GattServer {
    /** Cold: collection registers the services and opens the server; cancellation tears it down. */
    public val requests: Flow<Request>

    /** Centrals currently connected to this server, each with its live MTU. */
    public val centrals: StateFlow<List<Central>>

    /** Which centrals have subscribed (CCCD) to a characteristic: the peers a notify reaches. */
    public fun subscribers(characteristic: Characteristic): StateFlow<Set<Central>>

    /**
     * Notify (or indicate, per the characteristic's properties) subscribed centrals.
     * Returns the centrals that accepted the notification, so a caller can track delivery
     * per peer rather than per call.
     */
    public suspend fun notify(
        characteristic: Characteristic,
        value: ByteArray,
        to: Collection<Central>? = null,   // null = every subscriber
    ): Set<Central>
}

public interface Central {
    public val identifier: Identifier     // same type the central side uses, so dual-role code can match them
    public val mtu: StateFlow<Int>        // negotiated; 23 until the exchange
}

public sealed class Request {
    public abstract val central: Central
    public class Read(val characteristic: Characteristic, val offset: Int) : Request() {
        public suspend fun respond(value: ByteArray)
        public suspend fun reject(status: GattStatus)
    }
    public class Write(
        val characteristic: Characteristic,
        val value: ByteArray,
        val offset: Int,
        val responseNeeded: Boolean,
    ) : Request() {
        public suspend fun respond()
        public suspend fun reject(status: GattStatus)
    }
    // Descriptor read/write in the same shape. CCCD writes are handled by the server
    // and surface through `subscribers`.
}
```

What each member is for, from a real consumer:

- **`Central.mtu` per connection**, not per server. A fragmenting protocol sizes
  chunks as `mtu - 3` for each peer, and peers negotiate differently.
- **`notify` returns the accepted set.** "Every fragment reached some peer" and
  "some peer received every fragment" are different things, and only the second
  is delivery. A count cannot express it.
- **`subscribers` as a `StateFlow`.** A CCCD write the OS accepted is the same
  event on Android (`onDescriptorWriteRequest`) and Apple (`didSubscribeTo`).
  Exposing it lets a consumer stop guessing when a notify is safe.
- **`Request.central` carries the identity.** The writer's identity is how a
  relay avoids echoing a frame back to the peer it came from.
- **`Identifier` shared with the central side.** A dual-role pair (both nodes
  scan and both advertise) ends up with two links in opposite directions and has
  to collapse them to one. That is only possible if the peripheral side's
  `Central` and the central side's `Advertisement.identifier` are comparable.

### Platform mapping

| | Advertiser | GattServer |
|---|---|---|
| Android | `BluetoothLeAdvertiser` (legacy + `startAdvertisingSet`) | `BluetoothGattServer` |
| Apple | `CBPeripheralManager.startAdvertising` (name + UUIDs only) | `CBPeripheralManager` services, `updateValue(_:for:onSubscribedCentrals:)` |
| JVM Linux | BlueZ `LEAdvertisingManager1` via `bluer` | BlueZ `GattManager1.RegisterApplication` via `bluer` |
| JVM Windows | `BluetoothLEAdvertisementPublisher` | `GattServiceProvider` |
| JVM macOS | needs a native bridge; unsupported at first | same |
| js / wasmJs | `UnsupportedOperationException` | `UnsupportedOperationException` |

### What I can offer

The Android and Apple halves exist and work, as does a BlueZ implementation over
dbus-java (the JVM one would want re-basing onto `bluer` to sit next to
btleplug). If the shape above is roughly what you'd accept, I'd propose landing
it as a new `kable-peripheral` module so `kable-core`'s central-only surface
stays where it is, in three PRs: API + Android, then Apple, then JVM/Linux.
Happy to start with a design PR containing only the `commonMain` interfaces and
the README table if you'd rather see it that way first.
