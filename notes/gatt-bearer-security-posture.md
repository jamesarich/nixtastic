# What the GATT bearer lets a stranger do

Written 2026-09-16 because `accepted RequestAuthorization without authentication`
appears in bench logs and reads like a defect. It is an audit line, not an error,
and this is the whole posture in one place.

## The three layers

1. **The bond is unauthenticated, and in the default role anyone can get one.**
   `BluezGattLink` passes
   `isMeshPeer = { peers.handleOf(path) != null || role != GattRole.CENTRAL_ONLY }`,
   and the default role is `DUAL`, so the second clause is always true. Deliberate:
   an inbound central is not in `peers` yet, so it cannot be recognised in advance.
   Only a `CENTRAL_ONLY` node restricts bonds to peers it dialled itself.
2. **The bond buys one service.** `AuthorizeService` throws for any UUID that is
   not the mesh service, so being the host's *default* agent does not auto-approve
   a headset's HFP or a keyboard's HID. The scope is the mesh, not the adapter.
3. **The mesh service has no link-layer security, by design.** `SECMODE_OPEN` on
   nRF52, unauthenticated on ESP32 and BlueZ. A mesh peer is a stranger exactly as
   on LoRa, and the channel PSK is the security.

## So what can a stranger actually do

- **Bond, and write to the mesh characteristic.** Intended. Their frames fail
  channel decryption and are dropped, the same as an unkeyed LoRa transmitter.
- **Occupy a connection slot.** Real, and the cheapest attack here - the nRF52
  carries two peripheral links, one of which is usually the phone. Not mitigated.
- **Nothing else over BLE.** Layer 2 stops every other profile.

What they cannot do is read mesh traffic or forge a node, both of which need the
PSK, and neither of which BLE pairing would have protected anyway.

## The one thing worth revisiting

Layer 1 is wider than it needs to be for a node that is *dialling* as well as
serving. A `DUAL` node accepts a bond from anyone even when the request comes from
a device it would never have dialled. Narrowing it means tracking inbound
connections before the bond request arrives, which BlueZ does not make easy - the
agent must not block, so it reads only memory the link already holds. Worth doing
only if slot exhaustion turns out to matter.
