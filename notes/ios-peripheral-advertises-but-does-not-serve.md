# The iPad advertises the mesh service and never answers a subscribe

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

What is left is the subscribe itself. CoreBluetooth answers a CCCD write without
the application's help, so either the request is not reaching it or the link is
gone by the time it would answer. The next reading is on the Apple side - whether
a `CBPeripheralManager` is actually serving this database or the advertisement
outlives the manager that published it.
