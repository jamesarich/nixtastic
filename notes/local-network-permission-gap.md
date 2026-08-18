# `android`: ACCESS_LOCAL_NETWORK gates connecting, not just discovering

Traced 2026-08-18, following the open question left by
[`toolchain-sweep-2026-08-18.md`](./toolchain-sweep-2026-08-18.md) §1. The
sweep's cautious "partially verified" was right to be cautious: the gap is real.

## What the platform does

From Google's [local network permission
doc](https://developer.android.com/privacy-and-security/local-network-permission):

- The restriction covers **outgoing TCP connections** and UDP unicast/multicast/
  broadcast, not merely service discovery. It is "implemented deep in the
  networking stack, and thus … apply to all networking APIs" — platform sockets,
  Cronet, OkHttp, Ktor, anything above them.
- A blocked TCP connect "will typically result in a **timeout** error." Not
  `EPERM`, not a fast failure. The only fast diagnostic is
  `android_getnetworkblockedreason()`, an **NDK** API — and this repo has no
  `jniLibs`, `externalNativeBuild` or `ndkVersion`, so it is out of reach.
- The legacy implicit grant is keyed on **targetSdk, not install history**:
  "Apps with INTERNET permission receive an implicit permission grant … This is
  temporary and will be blocked by default once app bumps target SDK to 37."
  There is no grandfathering for an existing install. Shipping targetSdk 37
  breaks existing TCP users the moment they take the app update.

## What the app does

`rememberLocalNetworkPermissionState()` is correct
(`core/ui/src/androidMain/.../PlatformUtils.kt:436`) — gated on API ≥ 37, with a
pre-37 granted fallback, and inert by construction on iOS (`NoopStubs.kt:77`)
and desktop (`jvmMain/PlatformUtils.kt:169`).

It is *requested* in exactly two places, and neither covers connecting:

| Site | Covers |
| --- | --- |
| `ConnectionsScreen.kt:486`, inside `onToggleNetworkScan` | NSD/mDNS discovery only |
| `TakPermissionUtil.kt:31` | the TAK server's loopback bind |

Three paths reach a LAN socket without ever passing through either:

1. **Manual IP entry.** `DeviceList`'s "Add network device manually" opens
   `AddDeviceDialog`; its Add button calls `onAddManualAddress` →
   `ScannerViewModel.connectToManualAddress()` → `changeDeviceAddress()`. No
   permission check anywhere on that chain. A user who types their radio's LAN
   IP without ever touching the scan toggle has never been prompted.
2. **Recent-address reconnect.** `recentTcpDevices` is persisted, so it renders
   with no scan having run. Tapping one calls
   `ScannerViewModel.onSelected(DeviceListEntry.Tcp)` → `changeDeviceAddress()`.
   Same absence.
3. **Startup auto-reconnect.** `MeshServiceOrchestrator` connects to the
   persisted device address at service start, without the Connections screen
   ever composing. This is the worst-affected user: an existing install with a
   persisted TCP radio that simply stops working after the update, with no
   prompt and no error — just a hang.

`ConnectionsScreen` being the parent of the manual-entry UI is what made this
look covered. It is not: the screen *reads* `localNetworkPermission` for banner
and auto-scan logic, but only the scan toggle ever calls `.request()`.

## Fix shape

**(1) and (2) — one PR, `feature/connections`, `commonMain`.** Gate the *entry
point*, not the connect. Gating the "Add network device manually" button rather
than the resulting `connectToManualAddress` avoids holding the typed address
across the permission round-trip, and mirrors the `when` block already in
`onToggleNetworkScan`: granted → proceed; `PERMANENTLY_DENIED` →
`openAppSettings()`; else → `request()`.

- `DeviceList` does not currently receive permission state — thread
  `canUseLocalNetwork` + `onRequestLocalNetwork` in, or hoist the trigger.
- Gate **only** `DeviceListEntry.Tcp` in `onSelected`. Gating BLE/USB breaks them.
- Do **not** carry `persistNetworkAutoScanIntent(true)` into the manual path —
  the user asked to connect to one address, not to turn on scanning.
- Stays in `commonMain`; the permission state is granted-by-construction on the
  other targets, so no expect/actual is needed.
- Test alongside, modelled on `TAKConfigPermissionDeniedTest`.

**(3) — separate, and it is not the same kind of fix.** There is no Activity in
a service, so nothing there can call `.request()`. It has to fail fast and
surface: `checkSelfPermission` in `androidMain`, and a connection-state error
routing the user to Connections rather than waiting out a socket timeout.
Touches the service layer, the connection state machine and strings.
