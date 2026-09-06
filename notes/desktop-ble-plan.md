# Desktop BLE: macOS and Windows

Researched 2026-09-05, against SDK headers on this machine and current vendor
documentation rather than recollection. The question was James's: build BLE out for
macOS and Windows too, reuse the CoreBluetooth code if we can, and find out whether
IOBluetooth gains us `ble-adv` on a Mac.

Short answers: **no** to IOBluetooth, **no** to advertising on a Mac at all, **yes**
to reusing the Apple GATT code, and **yes** to advertising on Windows - which is the
surprise, and the one desktop platform whose public API allows it outright.

## Decided 2026-09-06

**The desktop node is a full BLE node, both GATT roles.** Not central-only. That
settles the library question before it is asked again:

- **Kable is out.** Its JVM target wraps **btleplug**, which says of itself "meant to
  be host/central mode only" and points at `bluster` for the peripheral role;
  `bluster` is 0.2.0 and three years stale. So Kable-on-JVM can join a mesh as a
  client but cannot *be* a node, which is the thing this library exists to do.
  (`android` pins Kable 0.44.3 for its own central-role radio link, which is a
  different job and stays.)
- Nothing else in the ecosystem changes that. Blue Falcon's macOS is Kotlin/Native,
  not JVM; SimpleBLE is a C++ central stack needing bindings we would write. **No KMP
  BLE library offers a peripheral role on the JVM at all.**

**Compose Multiplatform desktop is Kotlin/JVM only** - iOS targets Kotlin/Native, the
desktop target does not. So "build the dashboard native" is not a route, on any
platform, and every desktop bearer needs a bridge out of the JVM. This is the same
conclusion the GATT section below reaches from the LoRa side.

**A JNI dynamic library was considered and not taken.** Kotlin/Native
`binaries.sharedLib()` plus a cinterop over `jni.h` is the documented way to reach
CoreBluetooth from a Compose Desktop app, and it would work. It buys nothing over the
helper process below, which already has a passing spike, and it costs JNI symbol
plumbing, a per-architecture dylib, and its signing. Revisit only if IPC latency ever
shows up in a measurement.

**Step 1 of the order below is done** (`ac8d3fd`, node-kmp). The monitor now builds as
a bundle: `bundleID`, `NSBluetoothAlwaysUsageDescription`, and a macOS-only
`packageVersion = "1.0.0"` because jpackage refuses a leading zero in an app-version.

```
gradle :monitor:createDistributable
open monitor/build/compose/binaries/main/app/MeshMonitor.app
```

Verified: the plist carries the key and the identifier, the bundle is ad-hoc signed
with the hardened runtime, and it runs the node and serves the phone API when started
through LaunchServices. The bearers still read `unavailable` because nothing reaches
CoreBluetooth yet, which is the next step and not a regression.

The cost of the change: `open` gives the app no console and jpackage discards stdout,
so the dashboard's own log pane is the only view of a packaged run. Getting stdout
back means cloning the app image and repointing `Contents/app/*.cfg` at a wrapper
class, and re-signing after every edit. The `java -jar` uber jar stays for Linux and
for quick dev runs; it can never do BLE on macOS.

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

**What the spike did NOT settle, now closed:** it ran from a terminal-launched JVM, so
TCC attributed the request to the terminal. A bundled `.app` is attributed to the app
and needs its own `Info.plist` key, and the monitor's `nativeDistributions` block had
no macOS section at all. `ac8d3fd` adds one. What is still unproven is the whole chain
at once - bundle, helper binary, TCC grant - because no bundled build has yet spawned
the helper.

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

**The constraint most likely to sink the route does not.** Checked 2026-09-06: most of
the Bluetooth API is marked `DualApiPartition` in the WinRT metadata, which is
Microsoft's own marker for "usable from a desktop application", and `GattServiceProvider`
is documented as the peripheral-role entry point for exactly that. The capability
declaration that would be needed is an MSIX/UWP concern, and jpackage's MSI is a plain
Win32 app, not that. So a full node is reachable on Windows.

Kotlin/Native `mingwX64` was weighed as a way to keep it all Kotlin and set aside:
WinRT is a COM ABI whose supported binding is C++/WinRT, which is C++ and so beyond
cinterop, and nothing found suggests anyone has driven the C ABI headers from
Kotlin/Native. The Rust route stays.

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
1. ~~Give the desktop app a bundle identity.~~ **Done, `ac8d3fd`** - see above. James's
   call 2026-09-06 was to do the packaging first, because it gates every route and can
   be checked on its own.
2. **Settle the on-air format**, knowing the above. It constrains everything else and
   changing it later breaks every deployed node.
3. **macOS GATT bridge.** Best value per line: a quarter of a new backend's cost,
   reusing code already proven on hardware. Its two preconditions, the TCC spike and
   the bundle, are both done. First slice should be the packaged app spawning the
   existing `macosArm64` helper and reporting its manager state, which proves bundle,
   helper and TCC grant together before any transport code is wired.
4. **Windows**, now wanted outright rather than conditionally: the desktop node is a
   full BLE node, and Windows is the only desktop platform that can also advertise,
   which makes it the only way to grow the advertisement mesh past Android.
5. **macOS advertising** - only ever as an external radio, and only if something
   actually needs it.
