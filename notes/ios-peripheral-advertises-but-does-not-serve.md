# The iPad advertises the mesh service and never answers a subscribe

**FIXED 2026-09-16** - the characteristic needed the readable permission; see the end.

Measured 2026-09-16 from `james-pc` running `meshnode-headless` as
`CENTRAL_ONLY`, against an iPad running the Apple node.

## The two roles disagree

- **iPad as central**: works. It subscribes to the uConsole's mesh
  characteristic and exchanges frames both ways, three connections in a row -
  see [`bluez-mesh-link-torn-down-by-profile-probes.md`](./bluez-mesh-link-torn-down-by-profile-probes.md).
- **iPad as peripheral**: advertises `4d657368-4e6f-6465-4741-545400000001`,
  accepts the connection, and never answers the CCCD write:

```
/org/bluez/hci0/dev_7A_E1_DD_FC_E5_1B: BlueZ refused StartNotify (No reply within
  specified time) - this peer's frames will not arrive
/org/bluez/hci0/dev_7A_E1_DD_FC_E5_1B: subscription refused, reconnecting (1/2)
```

Identified by its service set, not its address: `Alias: iPad`, plus ANCS
(`7905f431-…`) and AMS (`89d3502b-…`).

## It degrades the bearer for every other peer

Three central-only runs against the RAK4631, which is two feet away and
advertising throughout:

| run | dialled | ready |
| --- | --- | --- |
| 1 | +0.35 s | +30.3 s |
| 2 | +0.26 s | +10.6 s |
| 3 | +0.29 s | never, in 75 s |

Discovery is not the cost - the peer is dialled in under a second every time.
The variance is all between `Connect()` and `ready`, and run 3's faults name the
mechanism: `br-connection-busy` against the RAK while a connect to the iPad was
outstanding. An unresponsive peer holds a `Device1.Connect()` for the full D-Bus
timeout, and this link runs connects on **one worker thread**, so every other
peer waits behind it.

## Two things this makes visible

- **The backoff is keyed by D-Bus path, and an iOS peer rotates its address.**
  `7A:E1:DD:FC:E5:1B`, `57:AC:61:88:0C:46` and `4E:1E:B5:1E:F8:D9` are the same
  iPad across the session. Each rotation is a new path, so `RetryBackoff` starts
  over and the "give up after 2 subscribes" rule never accumulates. BlueZ resolves
  a resolvable private address to an identity only for a **bonded** device, and
  the mesh bearer deliberately does not bond, so there is no stable key available.
  Holding a peer off has to survive rotation some other way, or not be attempted.
- **One slow connect starves the rest.** The single worker exists so a slow connect
  cannot starve the *callbacks*; it does starve the other *connects*. A peer that
  accepts and then goes silent is the worst case and is now known to exist.

## The database is right, so it is the response that is missing

Read from `james-pc` over a live connection, on `org.meshtastic.node.monitor`
(MeshMonitor) on iPadOS 26.6.1:

```
MESH SERVICE  4d657368-4e6f-6465-4741-545400000001
   char       4d657368-4e6f-6465-4741-545400000002
   flags      write-without-response write notify extended-properties reliable-write
   desc       00002900  (characteristic extended properties)
   desc       00002902  (client characteristic configuration)
```

Calling `StartNotify` on that characteristic returns in 0.1 s with no error, and
`Notifying` stays **false**. BlueZ issued the CCCD write and no answer came back.

Ruled out:

- **No mesh service.** It is there, at the right UUID.
- **No notify property.** Present, with the CCCD beside it.
- **Missing background entitlement.** `UIBackgroundModes` declares both
  `bluetooth-central` and `bluetooth-peripheral`.
- **App not running.** `MeshMonitor{CoreBluetooth}` logs `handlePeerMTUChanged`
  as the central connects, so the process is alive and CoreBluetooth is live in it.

What is left is the subscribe itself.

## Proven at both ends at once

Both traces captured over the same 180 seconds, with the app launched fresh so
`devicectl --console` owned its stdout (attaching to a running instance captures
nothing - it foregrounds rather than spawns):

```
iPad      MNGATT peripheralManager state=5
          MNGATT addService + startAdvertising
          MNGATT central subscribed ...            <- ZERO occurrences

james-pc  3 x dev_54_00_0A_78_71_4E: BlueZ refused StartNotify (No reply within
              specified time) - this peer's frames will not arrive
          1 x subscription refused, reconnecting (1/2)
          1 x subscription refused, reconnecting (2/2)
```

`54:00:0A:78:71:4E` is the iPad - `bluetoothctl info` gives `Alias: iPad` with
ANCS and AMS beside the mesh UUID.

So the central wrote the CCCD three times in that window, and CoreBluetooth
delivered `peripheralManager(_:central:didSubscribeTo:)` to the application
**not once**. The service is published, the peripheral manager is powered on, and
the subscribe never arrives. It is not a case of the central never trying.

## The one structural oddity left

The characteristic is built with `permissions = CBAttributePermissionsWriteable`
and no readable bit:

```kotlin
CBMutableCharacteristic(
    type = characteristicUuid,
    properties = CBCharacteristicPropertyWrite or CBCharacteristicPropertyWriteWithoutResponse or
        CBCharacteristicPropertyNotify,
    value = null,
    permissions = CBAttributePermissionsWriteable,
)
```

Apple's reference for that initialiser does **not** state that notify requires the
read permission, so this is a hypothesis and not a citation. It is testable: add
`CBAttributePermissionsReadable`, deploy, and re-run this exact pair of traces.


## Fixed: the characteristic needed to be readable

```kotlin
permissions = CBAttributePermissionsReadable or CBAttributePermissionsWriteable
```

It declared `notify` with the write bit alone, and CoreBluetooth delivered no
`didSubscribeTo` at all. With the readable bit added, built and installed to the
iPad (iPadOS 26.6.1, `devicectl device install app`):

```
MNGATT didReceiveWrite 10B control
MNGATT central subscribed 4931417D maxUpdate=512 negotiated=244
```

Three runs, a subscribe in each, where every run before had none. The HELLO
arrives as a write, so the peripheral both subscribes and receives.

Apple's reference for that initialiser does not state the requirement. This is
measured, not cited.

## What it did not fix: the link does not last

Re-measured with a framework built from current source - the earlier figures were
taken against a nine-day-stale one, see
[`node-kmp-logging-options.md`](./node-kmp-logging-options.md):

```
ready 19:01:29 -> gone 19:01:37    8 s
ready 19:02:59 -> gone 19:03:22   23 s
ready 19:03:42 -> gone 19:04:26   44 s
```

Over that 220-second run the central reached `ready` three times and the iPad
logged **one** `central subscribed` and **one** `didReceiveWrite`. The central's
faults for it:

```
4 x BlueZ refused StartNotify (No reply within specified time)
1 x subscription refused, reconnecting (1/2)
1 x subscription refused, reconnecting (2/2)
```

So the first subscribe succeeds and later ones time out.

### Both earlier candidates are eliminated

- **Not address rotation.** The peer held `7E:76:C9:40:BA:B9` for the whole run,
  across all three connections.
- **Not the profile-probe teardown.** `journalctl -u bluetooth` over that window
  carries no midi, battery, deviceinfo, pairing or encryption line at all.

### What is left

`StartNotify (No reply within specified time)` is a D-Bus timeout: BlueZ did not
answer within the call's deadline, which means the peer did not answer the CCCD
write. The one that worked was the first of the run.

So the question narrows to why a **re**-subscribe from the same central identity
goes unanswered when the first did not - CoreBluetooth reports the same central as
`4931417D` across reconnects, and the peripheral may consider it still subscribed
while BlueZ, which has torn its own state down, asks again.