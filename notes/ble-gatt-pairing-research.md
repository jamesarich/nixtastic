# BLE-GATT mesh-peer pairing wall — research + conclusion (2026-09-04)

Why the firmware BLE-GATT mesh-peer link (Phase 3, see
[`multi-transport-mesh.md`](./multi-transport-mesh.md)) connects and discovers
but drops before a frame crosses. Two cited research passes (bitchat / other apps'
source; Android + NimBLE bonding mechanics + Meshtastic docs) plus a read of our
own client code. **This corrects the earlier "the CCCD requires encryption"
guess — it does not.**

## Conclusion (most likely cause): a stale bond on the Pixel, not our firmware

The evidence chain:

1. **Our mesh characteristic + CCCD are already open.** NimBLE auto-creates the
   0x2902 CCCD as `READ|WRITE`, and it inherits `WRITE_ENC`/`WRITE_AUTHEN` **only
   if the characteristic itself carries an ENC/AUTHEN flag**
   (`apache/mynewt-nimble` `ble_gatts.c` `ble_gatts_register_clt_cfg_dsc`). Ours is
   plain `PROPERTY_WRITE | WRITE_NR | NOTIFY` (`ESP32BLEGattMesh.cpp:171-173`), so
   subscribing to it needs no encryption. Per-attribute security is independent of
   the global `sm_bonding` setting.
2. **The firmware never tears the link down on a failed encryption.** The
   NimBLE-Arduino 1.4 `BLE_GAP_EVENT_ENC_CHANGE` handler calls
   `onAuthenticationComplete` and `return 0` — no `ble_gap_terminate`, no status
   check. Our `NimbleBluetooth.cpp:698` log line `"BLE encryption change without
   encrypted link; ignoring"` only *observes*. So the disconnect is driven by the
   **central (Android)** or the link layer, not by us.
3. **A phone that has ever bonded this node auto-encrypts on every later connect.**
   Once `getBondState()==BOND_BONDED`, Android's stack initiates LE encryption at
   connect from the stored LTK, regardless of which attributes the app touches. If
   the node no longer holds a matching key (rebooted / rotated / switched to
   NO_PIN), encryption fails (HCI auth failure, status 5) and Android drops the ACL
   (status 22). This exactly matches our loop: connect → discover OK → drop, and
   **explains why NO_PIN did not help** — the stale bond lives on the *phone*.
4. **We saw the bond loop directly.** The Pixel `bluetooth_manager` dump showed
   the v3 (`34:B7:DA:62:18:C5`, `🌵_18c4`) in `BOND_BONDING` with
   `ACTION_PAIRING_REQUEST`, `Detect bonding failure`, and repeated `Remove from
   storage` — a phone-side bond that keeps failing.
5. Meshtastic's own known-issue corpus (#2793, #7606, discussion #10173, org #357)
   is the same shape and the consistent community fix is **"forget the device on
   the phone, let the app re-add it."**

## The template: `bitleproject/bitle`

An ESP32/NimBLE port of bitchat — **our exact firmware stack** doing unauthenticated
GATT mesh. It configures **zero** BLE security: plain characteristic flags, the
auto CCCD, and it never sets `ble_hs_cfg.sm_bonding/sm_mitm/sm_sc` nor calls
`ble_gap_security_initiate`. bitchat (iOS/Android) does the same: characteristics
`PERMISSION_READ|WRITE` (never `_ENCRYPTED`), no `createBond`, connects with
`connectGatt(ctx, false, cb, TRANSPORT_LE)`. We can't zero-out security wholesale
(the phone-API needs its PIN), but the mesh service must look exactly like bitle's.

## Fixes, ranked

**Diagnostics first (name the cause before more code):**

- **D1. Capture the disconnect status the app receives.** 5 = LL auth failure
  (stale/asymmetric bond); 22 = Android tore down after an encryption it started;
  19 = the node dropped it (look into the host, not the wrapper). One number sets
  the direction.
- **D2. Log `event->enc_change.status`** at `NimbleBluetooth.cpp:698` — names the
  exact SMP/HCI reason; we currently discard it.
- **D3. Test with a phone that has NEVER bonded this node** (Meshtastic app
  force-stopped). If the open subscribe then works, the cause is the stale bond /
  shared-link, not our GATT flags.

**Then:**

1. **Forget the v3 on the Pixel** (Settings → Bluetooth → the node → Forget), then
   retry NO_PIN clean. 10-second manual action; the community-proven unblock. adb
   `cmd bluetooth_manager unpair` is unsupported on this build, so it is manual or
   via app-side `removeBond` reflection.
2. **Client (`node-transport-ble-gatt` androidMain):**
   - `device.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE)` — today it
     uses the 3-arg overload (`TRANSPORT_AUTO`), a known `status=133` cause
     (`GattLink.android.kt:224`).
   - `requestMtu(517)` **before** `discoverServices()`; wait for `onMtuChanged`.
   - Wait for `onDescriptorWrite` before declaring the peer ready (don't copy
     bitchat's `delay(200)` shortcut).
   - One outstanding GATT op per link; pump the queue on
     `onCharacteristicWrite`/`onNotificationSent`.
   - Self-heal the stale-bond/stale-cache state: `removeBond` + `BluetoothGatt.refresh`
     via reflection before connecting as a mesh peer; never `createBond`.
   - Connect to and discover **only** the mesh service; never read/subscribe a
     phone-API characteristic in that session (a PIN-mode `_ENC` attribute on the
     same node would force encryption on the shared ACL).
3. **Firmware — peripheral subscribe watchdog** (from bitle): if a central connects
   but never writes the CCCD within ~30 s, disconnect it to force rediscovery —
   defeats Android's stale GATT cache (the classic 133 / mute-link case).
4. **Firmware — consider `sm_bonding=0` in NO_PIN only** (`setAuthenticationMode(false,…)`)
   so the node stops writing bonds during NO_PIN "just-works" that later go stale.
   Scope to NO_PIN and validate it doesn't regress the secured phone-API.
5. **Keep the mesh characteristic + CCCD strictly flag-free** (already the case) —
   any ENC flag makes the CCCD inherit `WRITE_ENC` and turns subscribe into a
   bonding trigger.

## Other patterns worth copying (bitchat/bitle, cited)

- **Fragmentation is a fixed constant, not the live MTU** (bitchat: 469-byte
  fragments sized against a constant 512, request MTU 517 only for headroom). Our
  handler derives chunk size from the negotiated MTU — fine, but raise the ESP32
  `CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU` + MSYS buffers so a ~500-byte notify isn't
  truncated.
- **Dual-role arbitration:** make phones always the central (node only dials other
  nodes), reserve inbound slots, dedup duplicate links with a short deny-list
  cooldown — rather than preventing double-dials up front. (bitle
  `BITLE_CENTRAL_RESERVE`, `BITLE_DENY_TTL_MS`.)
- **Re-advertise on every connect/disconnect** so the peripheral never stops being
  discoverable (we already do).

## Key sources

bitchat iOS `permissionlesstech/bitchat`; Android `permissionlesstech/bitchat-android`;
ESP32 `bitleproject/bitle` (`main/bitchat_ble.c`). Martijn van Welie "Making Android
BLE work" parts 2 & 4. `apache/mynewt-nimble` `ble_gatts.c`. `espressif/esp-idf` #3532
(`sm_bonding` is passive). NimBLE-Arduino 1.4 `NimBLEServer.cpp` (ENC_CHANGE doesn't
terminate). Meshtastic firmware #2793, #7606, discussion #10173, org #357 (all fixed
by "forget the device"). Berty BLE blog. GATT-133 explainer + Nordic devzone.

## Refinement (2026-09-04): no COMPLETED bond on the Pixel

The v3 is **not** in the Pixel's saved/paired list — so there is no completed
bond auto-encrypting on reconnect (the Q1-C sub-theory is out). What we saw was
`BOND_BONDING → Detect bonding failure → Remove from storage`, looping: Android
**attempts a fresh bond on every connection and it fails**, cleaning up the
half-bond each time (hence nothing persists in the list). So the question is no
longer "stale key" but **"what makes Android start pairing each time?"** — either
(A) the app touched an encrypted attribute (ATT insufficient-auth → auto-bond),
which for our open mesh char would only happen if it also reads a phone-API
secured char on the same ACL, or (B) the ESP32 sends an SMP Security Request
(firmware `sm_bonding=true` + security callbacks initiating). **Decisive next
measurement: the direction of the first SMP frame** (btsnoop on the phone, or log
`event->enc_change.status` + initiator at `NimbleBluetooth.cpp:698` and rebuild).
`removeBond`/`refresh` on the client is still harmless (no-op with no bond) and
still worth it for the stale-GATT-cache case; `connectGatt(TRANSPORT_LE)` is worth
it unconditionally for the status=133 instability.

## RESOLVED on the bench (2026-09-04): pairing wall fixed; egress bug found + isolated

Walked the whole thing to ground on the heltec-v3 + a Mac BLE central (bleak).

**1. Pairing wall — root cause + FIX (committed `6c1c7feba`).** The node was the
one initiating the failed pairing: even in NO_PIN the firmware called
`setAuthenticationMode(bonding=true,…)`, so it advertised the SMP bonding bit and
a central "just works"-paired on connect; that pairing failed and the ACL dropped
before the (open) mesh characteristic could be used. Fix: `setAuthenticationMode(false,false,false)`
in the NO_PIN branch only (PIN modes untouched). **Verified:** after the fix the
`"BLE encryption change without encrypted link"` line is gone (0 occurrences) and
a clean central connects with no pairing.

**2. Stale central-side bonds are a real, separate gotcha.** The Mac refused the
first connect with CoreBluetooth `Code=14 "Peer removed pairing information"` — a
*central* holding a bond the node has wiped. On the Mac it cleared itself when the
node's RPA rotated (next connect succeeded). The Pixel showed the equivalent
`BOND_BONDING → failure → Remove from storage` loop. Lesson: any central that ever
bonded this node in a PIN mode must forget it (or the client must `removeBond`).

**3. Connect + subscribe PROVEN (Mac, bleak, no pairing).** A clean central:
discovers the mesh service, finds the characteristic (`write / write-no-rsp /
notify`), and `start_notify` (CCCD write) **succeeds**. So the GATT-permission
design is correct end to end.

**4. Egress bug — ISOLATED (not yet fixed).** With a Mac subscribed and the v3
originating packets, **0 notifications arrive.** Diagnostics (spike commit
`55ee523b2`, REVERT later) show exactly why:
- `onSend` fires for every originated packet (transport registry is correct) —
  `BLE GATT mesh: onSend queued id=… len=…`.
- `pumpTx` runs but always `peers=0/0`.
- **`onSubscribe` / `onWrite` NEVER fire**, and the central's connection logs as a
  generic `BLE incoming connection` (the phone-API path), never my instance-2
  `peer conn`. So no peer is ever registered, so `platformPeers()==0`.
- **Root cause:** the central connects via the **phone-API advertising instance
  (0)**, not the mesh instance (2). Both instances' GAP callbacks chain to the
  shared `nimbleServerGapEvent`, so a CCCD subscribe *should* dispatch to the mesh
  characteristic — but Meshtastic's phone-API notifies its own characteristics
  blindly and **never depends on `onSubscribe`**, so that server subscribe-dispatch
  path is effectively unused/unexercised, and the mesh-peer transport is the first
  code to rely on it. Net: `ESP32BLEGattMesh` registers peers only via
  `onSubscribe` (and `onWrite`), neither of which fires for these connections.

**FIX DIRECTION (next session):** stop gating peer registration on `onSubscribe`.
Register a mesh peer on **connect** — hook `NimbleBluetoothServerCallback::onConnect`
(fires for every connection regardless of advertising instance, the same place
`onDisconnect` is already chained) — and/or on the first `onWrite`. Then notify all
connected mesh-service links and let NimBLE drop notifies to any that haven't
enabled their CCCD (`ble_gatts_notify_custom` is a no-op for an unsubscribed conn).
Re-check the `viaMeshAdv` / no-echo-to-arrival-peer bookkeeping under that model.
Then re-run the Mac bleak `gatt_listen.py` (subscribe, then `send_text` from the
v3) — a notify arriving there is the proof. Bench v3 currently runs
`2.8.0.6c1c7fe` + the diag probes, config `enabled_protocols=7`, WiFi off, NO_PIN.
