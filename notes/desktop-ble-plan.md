# Desktop BLE: macOS and Windows

Researched 2026-09-05, against SDK headers on this machine and current vendor
documentation rather than recollection. The question was James's: build BLE out for
macOS and Windows too, reuse the CoreBluetooth code if we can, and find out whether
IOBluetooth gains us `ble-adv` on a Mac.

Short answers: **no** to IOBluetooth, **no** to advertising on a Mac at all, **yes**
to reusing the Apple GATT code, and **yes** to advertising on Windows - which is the
surprise, and the one desktop platform whose public API allows it outright.

## Where each platform stands

| | ble-adv rx | ble-adv **tx** | GATT (dual role) | Reachable from the JVM today |
| --- | --- | --- | --- | --- |
| Android | ✓ | ✓ | ✓ | n/a |
| Linux / BlueZ | ✓ *(proven)* | platform yes, **this adapter refuses** | written, unproven | ✓ shipped |
| **macOS** | ✓ *(native)* | **impossible** | ✓ *(native, hardware-proven)* | ✗ needs a bridge |
| **Windows** | ✓ | ✓ **allowed** | ✓ | ✗ needs a native helper |
| iOS | ✓ | impossible | ✓ | n/a |

## macOS

### Advertising: impossible, and not for want of looking

The macOS SDK's own header settles it:

> Starts advertising. Supported advertising data types are
> `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`.
> - `MacOSX.sdk/…/CBPeripheralManager.h:178`

`MacOSX.sdk` and `iPhoneOS.sdk`'s CoreBluetooth headers are **byte-identical**
(`diff` clean on this machine). So "two keys only" is one class's restriction across
both OSes, not an iOS policy with a Mac carve-out to find. Apple's prose is harder
still: any other key yields *an error*, not a silent drop.

**IOBluetooth does not help.** Its entire public surface is classic BR/EDR - device
inquiry, L2CAP, RFCOMM, SDP, OBEX, HandsFree. No LE advertising, no LE scanning, no
GATT. `IOBluetoothHostController`, despite calling itself "an object representation
of a Bluetooth host controller (HCI)", exposes only `defaultController`, a delegate,
`powerState`, class-of-device, address and name. **There is no send-raw-command
method.** macOS gives third parties no public raw HCI.

A private route exists and is not usable: the *private* IOBluetooth framework has
`BluetoothHCISendRawCommand`, which SEEMOO's InternalBlue hooks. Undocumented,
unstable across releases, researched on Intel Macs with Broadcom parts, and unproven
on Apple Silicon where the controller is on-SoC. Not a foundation.

**If ble-adv on a Mac ever matters, it is an external-radio feature** - an nRF52840
dongle over CDC serial, the same shape as `node-transport-lora`'s CH341A stick. It is
not a BLE-stack feature, and no amount of API archaeology will make it one.

### GATT: worth doing, and cheaper than it looks

The framing "a macOS backend is N lines behind seam X" does not hold, and it matters:

- On macOS **native** (`macosArm64`) the answer is **zero lines**. All 711 lines of
  `appleMain` already compile and run there, under live CoreBluetooth tests, with no
  UIKit and no iOS gating. That code is already hardware-proven (Pixel↔Mac, iPad↔Mac).
- The gap is that `:monitor` is a **JVM** Compose Desktop app, and **a JVM class
  cannot be a `CBCentralManagerDelegate`**. The delegates are what feed
  `GattPeerTable`, so wherever the delegates live, the peer table, the arbiter and the
  tx lock live too.

So a JVM macOS backend sits behind the outer `GattLink` interface (4 required
members), **not** behind `GattLinkBase` (5) - and the work is a *bridge*, not a port.

**Route: a Kotlin/Native `macosArm64` helper process** that instantiates the existing
`gattLink()` and speaks a framed protocol over stdio or a unix socket to a
`MacOsHelperGattLink` in `jvmMain`, alongside the existing `isLinux(osName)` branch.
Roughly **300–400 new lines**, against 711 lines of Apple code and 1357 lines of
common logic reused unchanged - about a quarter of what the BlueZ backend cost
(1578 lines), and unlike a new backend it inherits every hardware-earned CoreBluetooth
fix automatically. `node-phone-api`'s `StreamFrame.kt` already compiles for both
`macosArm64` and `jvm`, so the framing primitive exists on both ends of the pipe.

**Rejected: making the desktop app Kotlin/Native.** Compose Multiplatform has no
Kotlin/Native macOS target, and `node-transport-lora` is jvm+android only - that route
would cost the LoRa bearer outright, which is the one bearer proven on hardware.

**The de-risking spike is DONE, 2026-09-05, and it passed.** The existing
`macosArm64` test binary was spawned from a plain `java` process via `ProcessBuilder`,
exactly as a bridge would:

```
[from JVM child] MNGATT peripheralManager state=5        (poweredOn, not unauthorized)
[from JVM child] MNGATT addService + startAdvertising    (peripheral role)
[from JVM child] MNGATT notify state BADA1045 on=true chunk=512   (central role)
[from JVM child] MNGATT central subscribed 7F157477 negotiated=512
[from JVM child] MNGATT didReceiveWrite 10B control
```

Both GATT roles work in a JVM-spawned child, and TCC did not block it - the manager
reaches `poweredOn` rather than the `unauthorized` state (3) a denial produces. So the
process boundary is not the problem, and route A is viable rather than speculative.

**What the spike does NOT settle:** it ran from a terminal-launched JVM, so TCC
attributed the request to the terminal. A bundled `.app` is attributed to the app and
still needs its `Info.plist` key. Note also that the monitor's
`nativeDistributions` block has **no macOS section at all**, so
`NSBluetoothAlwaysUsageDescription` is missing, and the documented
`java -jar MeshMonitor-*.jar` launch has no `Info.plist` - TCC attributes the request
to the terminal there.

## Windows

**The one desktop platform whose public API explicitly permits arbitrary
manufacturer-specific data (`0xFF`).** Better than Apple, level with BlueZ. So
`ble-adv` on Windows is not blocked by the platform - it is blocked by the JVM: WinRT
is a COM/`IInspectable` ABI with no Java projection, so every route needs compiled
native code or a helper process.

**Route: a Rust helper using `windows-rs` over loopback IPC.** The deciding constraint
is not elegance - it is that this repo builds on a Mac with CI off, and Rust is the
only route whose native artifact the existing build can produce (it cross-compiles to
Windows from macOS; C++/WinRT does not, since mingw ships no WinRT headers and MSVC
needs a Windows box).

Check before committing to it: whether an **unpackaged** desktop app - which a Compose
Desktop jar is - may use these APIs at all. That is the constraint most likely to sink
the route.

## The finding that changes a decision not yet made

`AGENTS.md` → "Before this can go public" proposes moving the on-air format from
manufacturer data under `0xFFFF` to **service data under an assigned 16-bit UUID**, to
fix iOS background scanning. Both investigations independently found that would be a
poor trade:

- **Apple still could not transmit.** `CBAdvertisementDataServiceDataKey` is a
  scan-result key, absent from `startAdvertising`'s supported list exactly like the
  manufacturer-data key.
- **Windows would become receive-only.** Its publisher treats Service Data
  (`0x16`/`0x20`/`0x21`) as system-reserved and throws.

Manufacturer data is the only advertisement format Android, Linux **and** Windows can
all transmit. The change buys iOS background *receive* and costs Windows transmit
while doing nothing for Apple transmit. That belongs in the conversation with the
firmware, not in the archaeology afterwards. Recorded in `AGENTS.md` too.

## Suggested order

0. ~~De-risk the macOS bridge with a TCC spike.~~ **Done, and it passed** - see above.
1. **Settle the on-air format**, knowing the above. It constrains everything else and
   changing it later breaks every deployed node.
2. **macOS GATT bridge.** Best value per line: a quarter of a new backend's cost,
   reusing code already proven on hardware. Do the TCC spike first.
3. **Windows**, if `ble-adv` beyond Android and Linux is wanted. It is the only
   desktop platform that can advertise, which makes it the only way to grow the
   advertisement mesh past Android.
4. **macOS advertising** - only ever as an external radio, and only if something
   actually needs it.
