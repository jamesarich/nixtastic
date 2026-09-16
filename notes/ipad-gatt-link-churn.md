# The iPad joins over GATT and then cannot hold a link

Measured 2026-09-16 on an iPad (A16, iPad15,7) running `:monitor` installed by
`nix run .#iosdeploy`, framework built the same hour. 200 seconds, two peers.

## What works

Dual role comes up clean: the peripheral advertises, the central scans, and both
peers are discovered, connected, service-discovered and subscribed.

```
MNGATT link role=DUAL peripheral=true central=true
MNGATT didDiscoverServices 4931417D count=1 error=none
MNGATT writable peer ready 4931417D
MNGATT notify state 4931417D on=true chunk=512 error=none
MNGATT notify state 9D91F3F2 on=true chunk=244 error=none
```

`chunk=512` is the largest MTU this library has negotiated anywhere.

## What does not

**12 peers reached ready. 20 disconnected.** No frame was ever carried.

| peer | disconnect reason | count |
| --- | --- | --- |
| 9D91F3F2 | The connection has timed out unexpectedly. | 15 |
| 4931417D | The specified device has disconnected from us. | 4 |
| 4931417D | Unknown error. | 1 |

The single send in the whole run went nowhere:

```
MNGATT sent 7 chunk(s) to []
```

## Two separate things

1. **The link churn.** Same shape as the earlier iPad lifetimes, now with the
   exact CoreBluetooth strings and a rate. `9D91F3F2` times out every time;
   `4931417D` is dropped by the peer. Different reasons, so probably different
   causes, and neither is diagnosed.

2. ~~**A node whose links are all down at startup says nothing and never
   retries.**~~ **Resolved: firmware parity, not a defect.** `BroadcastPolicy`
   announces after `initialDelay = 2.seconds` and then every
   `nodeInfoInterval = 3.hours`, which is firmware's
   `default_node_info_broadcast_secs`. The `to []` is that first announcement
   firing before any link came up, and three hours is genuinely the next
   scheduled one.

   Nor should link-up trigger one: firmware's `sendOurNodeInfo` is called when it
   **hears** somebody - a received NodeInfo, a request, the phone asking, a
   `want_ack` reply - and the GATT mesh handler has no announce-on-connect path
   at all. A node that hears nothing says nothing, on either implementation.

   So the silence is a symptom of finding 1, not a second finding. On a bearer
   whose links hold, the first thing heard draws a reply.

The first finding stands and is the whole problem. `to []` was still worth having:
it is what showed the send had gone nowhere, which is why the silence could be
chased to its cause rather than guessed at.
