# The BLE and UDP bearers against current practice

Audited 2026-09-16 by reading the implementations, alongside the LoRa audit in
[`lora-radio-parity-audit.md`](./lora-radio-parity-audit.md).

## BLE GATT

| practice | state |
| --- | --- |
| **Chunk to the negotiated MTU, per peer** | Yes, and per *subscriber* on the peripheral side - "a subscriber's MTU may be smaller than any seen so far; fragmenting above it silently truncates every notify" |
| **Re-read the write size after negotiation** | Yes, with the CoreBluetooth caveat recorded: it exposes no MTU-updated callback to a central and reports the pre-negotiation minimum until asked again |
| **Notify, not indicate, for a stream** | Notify. Indications are acknowledged one at a time and would serialise the bearer; the peripheral's confirm path exists only because the API demands it |
| **2M PHY where the platform allows it** | Requested (`MESH_GATT_PHY=LE_2M`). Ignored on Apple, correctly: iOS negotiates 2M at the controller and an app cannot choose |
| **No link-layer security requirement on the mesh characteristic** | Deliberate, and the right call - the mesh layer encrypts, so a bond would add nothing and cost a pairing prompt. Every peripheral here is open: `SECMODE_OPEN` on nRF52, unauthenticated on ESP32, and unauthenticated on BlueZ |

The one Apple-side defect found this session - a characteristic declaring
`notify` with only the write permission, which CoreBluetooth silently refuses to
deliver subscriptions for - is fixed and verified by a controlled A/B.

## UDP multicast

| practice | state |
| --- | --- |
| **Administratively scoped group** | `239.0.0.69`, matching firmware after PR #8612. The pre-#8612 `224.0.0.69` sat in the link-local control block, which is not for application traffic - see [`udp-group-and-preset-parity.md`](./udp-group-and-preset-parity.md) |
| **Address reuse so several nodes share a host** | `SO_REUSEADDR` everywhere, and `SO_REUSEPORT` as well on BSD, where the first alone does not let a second socket share a multicast port |
| **Send on the interface that routes to the group** | Probed per send, because a `MulticastSocket` with no interface set does not necessarily leave by the route that reaches the group - and the loopback copy hides it, so a local capture shows packets no other host sees |
| **Join left to the OS** | Deliberate. Forcing an interface on the join was tried this session and reverted: it broke nothing that was working and fixed nothing that was broken, because the failure was a group mismatch |

Measured 15/15 each way against a `meshtasticd` container.

## Where practice is deliberately not followed

**No TTL is set on the multicast send.** The default of 1 keeps mesh traffic on
the local segment, which is what this bearer is for; raising it would leak a
local mesh across routed boundaries. Worth stating because it looks like an
omission and is not.

**No explicit connection-parameter request on BLE.** Every platform here either
refuses the request (iOS) or applies its own policy, and the bearer's traffic is
bursty rather than latency-bound. The one measured consequence - a peer that
accepts a link and never answers a subscribe holding the adapter for the call's
timeout - was addressed at the retry layer instead, in `969c43f`.
