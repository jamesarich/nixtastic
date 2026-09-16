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

## The one real gap: no `@ObjCName`

Nothing in the tree uses `@ObjCName`. The `MeshNodeGatt` framework exports
`node-core`, so a Swift consumer sees Kotlin names mangled by the default
Objective-C export rules - `MeshNodeGattMeshNode`, `doInit…`, `companion`, and
name collisions resolved by prefixing. `@ObjCName` is how a KMP library gives
Apple consumers an API that reads like Swift.

Worth doing **before** the first consumer builds against it, because changing
exported names afterwards is a source break for them. Not urgent while the only
Apple consumer is the monitor app in this repo.

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
