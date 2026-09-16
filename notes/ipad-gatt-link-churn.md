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

2. **A node whose links are all down at startup says nothing and never retries.**
   The startup NodeInfo went out while no peer was ready, `broadcast()` carried
   it on nothing, and no send followed in 200 s. On a bearer that churns this
   badly, that means silence rather than degraded delivery. Worth deciding
   whether a carried-by-nothing broadcast should be re-queued when a peer next
   turns ready.

Both were invisible until `GattMeshTransport` began logging the peers each
packet reached - `to []` is the whole of the second finding.
