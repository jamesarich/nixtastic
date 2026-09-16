# node-kmp against current klib guidance

Reviewed 2026-09-16. Kotlin 2.4.20, Gradle 9.7.1, AGP 9.4.0.

## What already matches the guidance

| guidance | state |
| --- | --- |
| No `expect class` - they are Beta, and functions or interfaces are preferred | **None.** Six `expect fun`/`object`/`val` across the tree and no expect classes at all, so `-Xexpect-actual-classes` is never needed |
| Explicit API mode on a published library | `explicitApi()` in `library-conventions`, so every published module has it |
| klib ABI guarded, and guarded by KGP rather than the legacy plugin | KGP's own `abiValidation`; `checkKotlinAbi` is wired into `check`, and **all ten** published modules have a committed dump |
| No platform types in a common public API | None found |
| No experimental opt-in leaking into published API | None; `@OptIn(ExperimentalForeignApi)` stays internal. The one `@RequiresOptIn` in the tree is ours, not Kotlin's - see below |
| Default hierarchy template, with explicit re-application where a manual edge disables it | Applied; the three modules with a hand-wired JVM+Android edge call it explicitly, which is required |
| Intermediate source sets declared once | `build-logic`'s `jvmAndroidMain()`; was three hand-wirings under two names |

That is a stronger baseline than most KMP libraries carry, and nothing here needs
changing.

## The one real gap: no `@ObjCName`, and what it would actually buy

Nothing in the tree uses `@ObjCName`. **Corrected 2026-09-16 against the
generated header** - an earlier draft of this claimed a Swift consumer sees
`MeshNodeGattMeshNode`, and that is wrong. Kotlin/Native derives a short prefix
from the framework `baseName`, so the header is `MNG`-prefixed:

```
@interface MNGDecodedPacketAck
@interface MNGDecodedPacketNodeInfo
@interface MNGBroadcastPolicyCompanion
@interface MNGAppleGattTransportKt
```

So the real cost is smaller and differently shaped than stated. Three things
`@ObjCName` would fix, in descending order of how much they matter:

1. **Nested types are flattened with the parent concatenated.** `DecodedPacket.Ack`
   exports as `MNGDecodedPacketAck`, so Swift cannot write `DecodedPacket.Ack`.
   This is the one a consumer actually feels.
2. **The `MNG` prefix is on every type**, including ones a caller names often.
3. **Companions and file facades leak** - `…Companion`, `…Kt`.

`MeshNodeGatt` does `export(project(":node-core"))`, so all of node-core is in
that surface. **Nothing in this repo links that framework**: the iPad app links
`Monitor`, which deliberately exports nothing and whose Swift side touches only
`MainViewControllerKt.MainViewController()`. So there is still no consumer to
break, and the window stated below is genuinely open.

Doing it means annotating every public sealed subclass, companion and facade in
node-core - a large mechanical rename of the published Apple surface. Worth a
decision rather than a drive-by: cosmetic for Swift ergonomics, free today, a
source break for any external consumer once one exists.

## Added since: a tenth module, and the tree's first opt-in marker

`:node-bluez` took the D-Bus session and adapter probe out of the two Linux BLE
bearers, which had carried them as verbatim copies. Three structural points fall
out, and they are the interesting part of this review now:

- **Its surface is public but gated.** Cross-module visibility forced `internal`
  to `public`, so every declaration carries `@InternalBluezApi`, a
  `RequiresOptIn(ERROR)` marker - the first in the tree. This is the kotlinx
  pattern for plumbing that must cross a module boundary without joining the
  compatibility promise, and the committed ABI dump is what makes the boundary
  reviewable rather than a claim.
- **It depends on no other module here**, which is deliberate and load-bearing:
  it speaks `BluezProbe`, and each bearer maps that to `TransportAvailability`
  itself. That is what keeps it offerable to Kable - see
  [`kable-donation-inventory.md`](./kable-donation-inventory.md) - and it is why
  `MESH_BLUEZ_ADAPTER` was moved back out to the callers.
- **It is single-target.** A `jvm()`-only published module, which the conventions
  already supported (`node-desktop-ble-macos` is the precedent) and which
  Isolated Projects tolerated without change.

The module count is now ten published, eight of them carrying a committed ABI.

## Two things to know rather than fix

- **klibs are locked to the compiler version.** A consumer on a different Kotlin
  major cannot link these; this is not a project decision, it is how klibs work,
  and it is the reason the protobufs pin matters so much - see
  `notes/wire-builders-only-migration.md` for the related ABI trap.
- **`macosX64` is deprecated** in Kotlin 2.3.20 and scheduled for removal, so the
  Apple desktop target is `macosArm64` alone and correctly so. `watchosX64`,
  `tvosX64` and `watchosArm32` are in the same position.

## Target coverage, after this session

```
node-core, node-phone-api, node-transport-udp   ios x3, linuxArm64, linuxX64, macosArm64
node-transport-mqtt                             ios x2, linuxArm64, linuxX64, macosArm64
node-transport-ble, node-transport-ble-gatt     ios x3, macosArm64
node-desktop-ble-macos                          macosArm64
node-transport-lora, node-transport-wifi-aware  JVM / Android only
```

The two BLE transports and LoRa are the ones that cannot follow to Linux native
without real work - BlueZ is reached through `dbus-java` today, and LoRa through a
JVM USB library. Both need a native client before the target is meaningful, so
declaring the target first would only produce a module that cannot link.
