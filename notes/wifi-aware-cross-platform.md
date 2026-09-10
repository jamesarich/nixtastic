# Wi-Fi Aware across platforms: what the standard gives, what Apple exposes

Written 2026-09-09, the day the Android bearer was proven on hardware. The
question was "isn't Wi-Fi Aware a documented standard, so why is Apple a separate
transport?" It is a standard, the workspace was right to shelve Apple, and it was
right for a reason it had not stated. Three claims this workspace carried are now
either sourced or corrected below.

## The answer in one paragraph

Wi-Fi Aware (NAN) has **two layers**: a discovery layer that carries small
connectionless datagrams (Follow-Up frames, Service Specific Info), and a data-path
layer (NDP) that carries an IP link. Android exposes both. Apple exposes **only the
data path**, only to devices the user has already paired through a picker, only over
TLS via the Network framework. Our bearer lives entirely on the discovery layer.
So the gap is not a missing Apple feature, it is a different layer, and no amount of
standard-conformance closes it. Cross-platform meshing stays a **mesh-layer bridge
over a shared BLE plane**, with Aware as the Android-to-Android accelerator it
already is.

## Correction, first: there is no macOS Wi-Fi Aware

`multi-transport-mesh.md` and `meshtastic-node-kmp/AGENTS.md` both say "iOS 26 and
macOS 26 ship a `WiFiAware` framework". Wrong. Apple's own availability data lists
exactly three platforms:

    iOS 26.0, iPadOS 26.0, Mac Catalyst 26.0

Read from Apple's own documentation JSON, all **29** symbol pages the framework
owns, fetched 2026-09-09. Every one of the 28 platform records is one of those
three. No macOS, no visionOS, no watchOS, no tvOS. (The four macOS records you
find by grepping the raw JSON belong to `NWPath`, `NWError` and the other Network
framework symbols the docs cross-reference, not to `WiFiAware`.)

Mac Catalyst is an iPad app rebuilt for the Mac, not AppKit. Whether Catalyst
Wi-Fi Aware actually works on Mac Wi-Fi hardware is **unverified**; Apple documents
the availability and nobody in the sweep below had tried it. Either way the desktop
node is out of reach, because it is a JVM process and no macOS framework exists for
it to bind to.

**The framework is still moving.** Availability across those 29 pages is 26.0 for
almost everything, with three later additions: `WAConnection` and `WASharedSecret`
in **26.4**, `WAPerformanceForecast` in **27.0**. None of them opens the discovery
layer. `WASharedSecret` is derived *from an established connection*
(`connection.deriveSharedSecret(for:method:context:)`, SPAKE2-style) so that TLS,
QUIC or IPSec above it can be keyed without the user typing anything. It
presupposes pairing rather than replacing it. Its documentation is the one place
Apple names a **Wi-Fi Aware 5.0** standard, so the spec has moved past the 4.0 that
everything below is about.

## What the standard actually splits into

| Layer | What it carries | Android API | Apple API |
| --- | --- | --- | --- |
| Discovery | Service publish/subscribe, match filters, SSI | `PublishConfig` / `SubscribeConfig` | `WAPublishableService` / `WASubscribableService`, declared in `Info.plist` |
| Discovery messaging | Follow-Up frames, up to `maxServiceSpecificInfoLen` bytes, connectionless, no session | `DiscoverySession.sendMessage` | **none** |
| Data path (NDP) | An IP link between two peers | `WifiAwareNetworkSpecifier` + `requestNetwork` | `NetworkBrowser` / `NetworkListener` / `NetworkConnection` |
| Pairing (spec 4.0) | PASN, NPK, 6-digit PIN bootstrap | `AwarePairingConfig`, opt-in | mandatory, user-driven |

Android implements Wi-Fi Aware **2.0, 3.0, 3.1 and 4.0** (source.android.com,
`docs/core/connect/wifi-aware`). Pairing and suspension are vendor HAL capabilities,
not CDD mandates, which is why they vary by handset even on one Android build.

## What Apple actually shipped

The complete public symbol list of the `WiFiAware` framework, taken from Apple's
documentation JSON rather than a summary:

    WACapabilities, Feature
    WAService, WASubscribableService, WAPublishableService
    WAPairedDevice, Devices, DevicesSequence, PairingInfo
    WASubscriberBrowser, WAPublisherListener, DatapathParameters
    NWParameters, NWParametersBuilder, WAParameters
    WAEndpoint, WAConnection
    WASharedSecret
    NWPath, WAPath, WAPerformanceMode, WAAccessCategory,
      WAPerformanceReport, WAPerformanceForecast
    NWError, WAError

There is no message type, no datagram type, no SSI accessor and no send call
anywhere in it. Grepping all 29 pages for a send-shaped symbol returns only
Swift's own `Sendable` conformances. Every byte crosses through `NetworkConnection` over TLS on an NDP to
a `WAPairedDevice`. Four consequences:

- **Pairing is mandatory and is user-driven.** Apple's own doc: pair through
  `DeviceDiscoveryUI` (a device picker plus a PIN) or `AccessorySetupKit`. Apple DTS
  answered "is this pairing mandatory" with a flat yes, that being how Wi-Fi Aware
  works (developer.apple.com/forums/thread/791628; reached through a fetch summary,
  not the raw page). A mesh bearer cannot ask a user to pair each stranger it meets,
  which is the same wall GATT hit.
- **Service names are DNS-SD, and short.** `Info.plist` key `WiFiAwareServices`, each
  entry `_name._tcp` or `_name._udp`, the name part at most 15 characters, letters,
  digits and hyphens only, per RFC 6763 4.1.2 and RFC 6335 5.1. Apple documents this
  name as "the fully qualified name of a service **as it's sent over the air**", so it
  is the on-air NAN service name, not an Apple-local label. An invalid name crashes
  the app rather than failing.
- **The entitlement is `com.apple.developer.wifi-aware`**, whose value is an array
  containing `Publish`, `Subscribe`, or both. At least one is required.
- **iPhone 12 and later**, per Espressif's write-up of the same framework.

## The bench measurement that kills a "reportedly"

`multi-transport-mesh.md` says "Apple also requires a Wi-Fi Aware **4.0** peer (Pixel
9 reportedly is not one)". The first half is sourced; the second half is now false on
this bench. Both phones, `adb shell dumpsys wifiaware`, 2026-09-09:

| | Pixel 6a | Pixel 9 Pro |
| --- | --- | --- |
| build | `CP41.260814.003.A2` | `CP41.260814.003.B1` |
| Android | 17 (SDK 37) | 17 (SDK 37) |
| `isNanPairingSupported` | **false** | **true** |
| `supportedPairingCipherSuites` | 0 | **48** (PASN 128 + PASN 256) |
| `gtkCipherSuites` | 0 | 64 |
| `isSuspensionSupported` | false | true |
| `supportedCipherSuites` (data path) | 1 (NCS SK 128) | 1 (NCS SK 128) |
| `maxServiceSpecificInfoLen` | 255 | 255 |
| `maxNdiInterfaces` / `maxNdpSessions` | 1 / 8 | 1 / 8 |

Same OS, same build train, opposite answers. Aware 4.0 pairing is a **chipset and
vendor-HAL capability**, not an Android version. The forum report that Pixel 9 lacked
it (August 2025) was true when written and is not true now. `isNanPairingSupported`
here is the framework's `Characteristics.isAwarePairingSupported()`, documented
against "Wi-Fi Aware Specification version 4.0".

So we own a 4.0-capable peer. That matters for the experiment at the bottom.

## Cross-platform Aware in the field: what breaks

All of this is from Apple developer-forum threads 790195, 801280 and 801289, posted
between June and September 2025, and every quotation below reached this note through
a fetch summary rather than the raw page. It has **not been re-verified since**, and
no primary source dated 2026 was found either way. Given `WASharedSecret` landed in
26.4 and a 27.0 symbol exists, treat the specifics as a starting point, not as
current state.

- Apple requires peers to implement **Wi-Fi Aware 4.0**. The source is the *Accessory
  Design Guidelines for Apple Devices*, which gained a Wi-Fi Aware chapter at WWDC25.
  It is not on any documentation page; Apple DTS points people at the PDF.
- **Discovery fails in both directions with a non-4.0 peer.** iOS logs
  `Discovery: Dropping event, <mac> missing DCEA attribute` (Device Capability
  Extension Attribute, a 4.0 attribute). The reporter's Android publish frames did not
  carry it.
- **Pairing fails even with a 4.0 peer.** On a Galaxy S25, then the only handset the
  thread found with `isAwarePairingSupported() == true`, Android discovers an iOS
  publisher, no PIN is displayed on iOS, and the Android pairing attempt returns
  **status 15**, authentication rejected on challenge failure.
- **NDP setup fails after a nominally successful pairing.** Android reports
  `onPairingSetupSucceeded` and `onPairingVerificationSucceed`, Apple logs
  `state: authenticated`, the device does not persist into iOS Settings > Privacy &
  Security > Paired Devices, and Apple never answers the NDP request.
- Radars filed: **FB18751572, FB19568037, FB19570341, FB19683706**. This is the
  sourcing for what the notes called "radars open".
- Apple DTS's position, verbatim: *"If you've determined that your other vendor's
  device doesn't meet the requirements in Accessory Design Guidelines for Apple
  Devices, that's something you'll have to discuss with that vendor."*

## Do not wait for the regulator to force this open

Apple shipped Wi-Fi Aware because the EU made it, under DMA Article 6(7). It is worth
knowing exactly how much leverage remains, and the answer is none. The Commission's
interoperability factsheet of **2026-05-11** lists "high bandwidth peer-to-peer Wi-Fi
connection" as **already delivered**, satisfied by the iOS 26.0 framework, and lists
close-range wireless file transfer as delivered too. The obligations still open are
elsewhere: notifications and proximity pairing (2026-06-01), automatic audio switching
(partial 2026-06-01, full 2027-06-01), background execution (end of 2026).

Nothing in the DMA text obliges Apple to expose the discovery layer, or to interoperate
with any particular Android handset. Planning on "the EU will fix it" is planning on
nothing.

## Prior art: what everyone else concluded

**Knit** (`getknit/Knit`, GPL-3.0, Kotlin, on Play and F-Droid) is the closest thing
to our bearer that exists: an Android mesh messenger running Wi-Fi Aware and BLE
simultaneously behind one transport seam. Its `docs/IOS_PORT_REVIEW.md`, dated
2026-07-04, reached our conclusion independently and enumerates four blockers rather
than one:

1. Pairing is mandatory and user-mediated.
2. No follow-up messaging, so their entire coordination plane has no Apple equivalent.
3. **No raw-PSK data path.** Their NDP uses a fixed app-wide 32-byte PMK via `setPmk`;
   Apple derives NDP keys from its pairing ceremony. Even if discovery matched, the
   data paths would not. Our notes did not have this one.
4. The service-name format, which forced them to rename before release.

Their verdict: *"Wi-Fi Aware is not a cross-platform plane, and likely never will be
for this app. Treat NAN as the Android to Android accelerator it already is."* They
ship iOS as a BLE-only mesh, and their composite transport handles the radio asymmetry
with no orchestration change, because an iOS peer just looks like a BLE-only Android
peer. That is the same shape as our unified seam.

**bitchat** (`permissionlesstech/bitchat`, 36k stars, iOS and Android, both stores) is
the most successful cross-platform mesh messenger there is, and its local plane is
**BLE only**, with Nostr over the internet as the second transport. No Wi-Fi Aware
anywhere. When the biggest player in this space picks BLE plus an internet fallback,
that is a data point about where the effort pays.

**Nobody is doing unpaired cross-platform Aware.** A GitHub code search for
`WAPairedDevice` returns, besides mirrors of Apple's own docs, exactly two real
products: **Signal-iOS** (`Signal/DeviceTransfer/WiFiAware/`, device-to-device transfer
between two iPhones) and **moblin** (a livestreaming app, `Moblin/Media/WiFiAware/`).
Both are Apple-to-Apple, both are paired-by-design, both are precisely the use case
Apple built the framework for.

**Firmware, for completeness.** ESP-IDF has a full NAN stack including 4.0 pairing
(`nan_pairing.c`, `nan_security.c`, PASN via `ESP_WIFI_PASN_SUPPORT`), shipping
experimental in v6.1, and Espressif demonstrated an ESP32-C5 pairing with an iPhone on
iOS 26 using a six-digit PIN. Two reasons it does not reach us. First, silicon:
`SOC_WIFI_NAN_SUPPORT` is set on classic ESP32, S2, C5 and C61, and is **absent on S3,
C3 and C6**, which is most of the Meshtastic fleet. Second, the whole pairing chain
sits behind `IDF_EXPERIMENTAL_FEATURES` on IDF 6.1, and firmware pins pioarduino
`platform-espressif32` **55.03.311** (`variants/esp32/esp32-common.ini`), an Arduino
core on IDF 5.5, not bare IDF 6.1. There is no `esp32c5` variant in the tree at all.
Worth revisiting only if a C5-class board enters the fleet.

## What this changes for us

**Nothing about the Android bearer, which is the right design.** Our transport sends
connectionless follow-up frames to any discovered neighbour with no pairing and no
connection lifecycle. Knit's `docs/NAN_CONCURRENCY_REAUDIT.md` is 297 lines of
on-device evidence about NDI scarcity, leaked responder requests pinning the one NDI,
and a coin-flip re-attach race, and **every one of those failures is on the NDP side**.
Our design never enters that code. The one-NDI limit that shapes their whole
architecture costs us nothing.

**Four operational facts from that same document our bearer does not yet handle.**
Measured on Pixel 7/8/9 Pro XL, Android 16, and consistent with the AOSP framework:

- **Deep Doze disables Aware entirely** (`PARAM_ON_IDLE_DISABLE_AWARE_DEFAULT = 1`,
  shell override only). Screen-off drops 2.4 GHz discovery windows to every 8th, about
  4 s worst-case latency, and disables 5 and 6 GHz windows outright.
- **The NAN discovery MAC re-randomizes every 1800 s** (`mac_random_interval_sec`).
  A peer handle goes stale every half hour and it reads exactly like a peer restart.
- **Subscribe is hard-coded to `MATCH_ONCE`** at the HAL boundary, publish to
  `MATCH_NEVER`. One `onServiceDiscovered` per peer, not a repeating callback. A
  changed SSI should re-fire it, which is firmware-dependent and untested.
- **`sendMessage` is lossier than it looks**: service-level `retryCount=0`, a per-UID
  queue of 50 with a 10 s per-message timeout, and `maxQueuedTransmitMessages=8`.

**One thing to change now, while it is free.** Our service name is `meshtastic-mesh`.
That is not an Apple-conformant name: Apple needs `_name._proto`, so the equivalent is
`_meshtastic._udp`. This buys nothing for the Android follow-up plane today. It buys
discovery-layer name compatibility with any future Apple or 4.0-peer transport, and
renaming later is a discovery hard-partition between old and new builds. The bearer
landed 2026-09-09 and ships in no product, so the cost is zero today and permanent
later. Knit hit exactly this and forced the rename into their pre-release break.

**If an Apple Aware transport is ever built**, the shape is fixed and it is not our
bearer: a separate `node-transport-wifi-aware-apple`, paired devices only, TCP or UDP
over an NDP through `NetworkConnection`, Apple to Apple. A separate transport, not an
`actual`, which is the call GATT already made. It needs the Mac, an entitlement, and
iOS 26 hardware.

## Unproven, and the next sitting

Unproven: that Mac Catalyst Wi-Fi Aware works on real Mac hardware. That the 2025
interop failures still reproduce in September 2026. That an `_meshtastic._udp` rename
has no effect on the Android-to-Android path.

### The interop experiment, staged and blocked on signing

Attempted 2026-09-09 with the iPad plugged in. Everything is ready except one thing,
and that thing is a new finding.

**Apple Wi-Fi Aware needs a paid Apple Developer Program membership.** Building
Apple's own sample against a free personal team fails at provisioning, not at compile:

    error: Cannot create a iOS App Development provisioning profile for
    "org.meshtastic.node.waprobe". Personal development teams, including
    "James Rich", do not support the Wi-Fi Aware capability.

So the cost of any Apple Aware work is not just "needs the Mac". It needs a paid seat,
and the probe app has to be signed by a team that owns the
`com.apple.developer.wifi-aware` entitlement. James's Apple ID does carry a paid
Company team (**Meshtastic LLC**, `GCH7VS5Y9R`), so the path exists, but building under
it registers an App ID and a provisioning profile in the **org's** developer account.
Not done: that is an org decision, and it was deferred on 2026-09-09 pending asking.

**What is already staged**, so the run is minutes once signing is settled:

- Apple's sample, `BuildingPeerToPeerApps.zip`, downloaded and unpacked. Its entitlement
  file requests both `Subscribe` and `Publish`.
- **The service name to match is `_sat-simulation._udp`**, declared in the sample's
  `Info.plist` under `WiFiAwareServices` and in `WiFiAware+Extensions.swift`. This is the
  same name the forum reporter in thread 790195 used, so a failure here is directly
  comparable to theirs.
- iPad (A16, `iPad15,7`) on **iPadOS 26.6.1**, paired, developer mode enabled. Xcode 26.6.
- The Pixel 9 Pro, measured above as a 4.0 peer, is the Android half. Our own transport
  takes the service name as a constructor argument, so pointing it at
  `_sat-simulation._udp` needs no code change.
- Build invocation that reaches "provisioning" cleanly (note the stripped Nix
  environment, without which none of this runs):

      env -u DEVELOPER_DIR -u SDKROOT -u CC -u CXX -u LD -u AR -u NM -u RANLIB \
          -u STRIP -u NIX_CC PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        xcodebuild -project "Wi-Fi Aware Sample.xcodeproj" \
          -scheme "Wi-Fi Aware Sample" -destination "id=<iPad udid>" \
          -allowProvisioningUpdates DEVELOPMENT_TEAM=GCH7VS5Y9R build

**What the run answers.** Have the Pixel publish `_sat-simulation._udp` and open the
sample's `DevicePicker` on the iPad. If the picker never lists the Pixel, Apple does not
see a non-Apple publisher at all and cross-platform Aware is dead at discovery. If it
lists it and pairing then fails, we are reproducing the 2025 status-15 wall on our own
hardware with a peer we have *measured* to be 4.0-capable, which is one better than any
report in the threads above. Either outcome retires the year-old sourcing.
