# What of node-kmp's BLE work Kable could take

Evaluated 2026-09-16 against `JuulLabs/kable` at `503e5d2`, cloned and read
rather than recalled. Prior discovery:
[`kable-peripheral-api-sketch.md`](./kable-peripheral-api-sketch.md) (an API
design for #51, **written 2026-09-13 and still not posted**) and
[`kable-mtu-pr.md`](./kable-mtu-pr.md).

## Already upstream

| | State |
|---|---|
| kable#1202 restore `kotlin-parcelize-runtime` in published Android metadata | merged, shipped in 0.44.1 |
| kable#1253 never block scan callback threads (the DEF CON ANRs) | merged |
| kable#1277 report the negotiated ATT MTU from the JVM peripheral | **open** |
| kable#51 peripheral role | **open since 2021**; our design comment is drafted and unposted |

## The central side has nothing to offer

Kable's Android central already exposes PHY, connection priority, MTU request,
`autoConnect` and bonding. Everything node-kmp does as a central, Kable does.
The gaps are the peripheral role, the scanner's lifecycle, and the JVM backend.

## Candidates, strongest first

### 1. The Android scan-downgrade watchdog - new, unreported, no API change

`BluetoothLeScannerAndroidScanner.advertisements` starts the scan once inside a
`callbackFlow` and never restarts it. Android moves a long-running filtered scan
to a low duty cycle after about five minutes - the platform names it, in logcat:

```
BtScan.ScanManager: regularScanTimeout(...): Moving filtered scan to downgraded scan
```

After that a short advertising burst is missed nearly every time, so a live
transmitter reads as silent with no error anywhere. Measured on a Pixel 6a
(2026-09-05) and fixed in node-kmp by restarting the scan every three minutes,
which registers a fresh client with a fresh timer and stays well under the
five-starts-per-30-s throttle.

Nothing is filed upstream: a search of kable's issues for the downgrade, for
`regularScanTimeout`, and for long-running scans returns nothing.

The fix is about fifteen lines, sits inside the `callbackFlow` Kable already has,
needs no public API, and has one sharp edge worth carrying over - the stop/start
pair has no suspension point, so a racing close must be observed between them or
the new scan outlives the flow.

**This is the one to send first.** It is a silent correctness bug affecting every
Kable consumer that scans for more than five minutes, and unlike #51 it costs
Kable no new surface.

### 2. The peripheral role (#51) - large, designed, unposted

Advertising and a GATT server, the two halves kept separate the way `Scanner`
and `Peripheral` are. node-kmp has working Android, Apple and BlueZ
implementations of both, and the API sketch derives every member from a real
consumer: per-central MTU, `notify` returning the set that accepted, subscribers
as a `StateFlow`, and an `Identifier` shared with the central side so a dual-role
pair can collapse two opposite-facing links into one.

Blocked on nothing but posting it.

### 3. The BlueZ backend - portable as a design, not as code

**Correction to an earlier framing of `:node-bluez`.** Kable's JVM backend is
`kable-btleplug-ffi`: Rust, btleplug, uniffi bindings. Ours is dbus-java, pure
JVM. Making `:node-bluez` free of this library's types was worth doing on its own
merits, but it does not make it drop-in for Kable - handing it over would add a
second, non-Rust JVM backend to a project that has deliberately got one.

What transfers is the decision tree, not the file: the probe ladder (no bus →
no bluetoothd → no adapter → adapter off → ready, each naming a different fix)
and the re-probe flow driven by `PropertiesChanged`/`InterfacesAdded` rather
than polling. Reimplemented against `bluer`, that is the Linux advertiser and
GATT server row of #51's platform table, which btleplug cannot fill - it
describes itself as host/central only.

## Not candidates

- **`Filter.Address` is Android-only**, and silently matches nothing on
  JVM/btleplug rather than throwing. Real, but already worked around in
  `Meshtastic-Android` client-side; an upstream fix is a separate small PR, not
  something node-kmp carries code for.
- **CoreBluetooth needs `CBAttributePermissionsReadable` on a notify-only
  characteristic** or no central can subscribe. Undocumented by Apple, measured
  here by A/B. It is a fact the #51 Apple implementation must encode, not a
  donation by itself.
