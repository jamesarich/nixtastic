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

## Re-measured with the bench quiet - it is not the iPad, and not a radio crash

The first run had `:node-headless` on james-pc scanning and dialling the same
radios throughout. Repeated with those stopped and nothing else changed:

| | first run | bench quiet |
| --- | --- | --- |
| peers ready | 12 | 4 |
| disconnects | 20 | 4 |
| frames carried | **0** | **1** |

```
MNGATT sent 1 chunk(s) to [3FD7485B-0281-5300-C1CB-DFB2BD71A9EA]
```

So the iPad links, subscribes and **writes**. "Non-functional" was wrong; the
catastrophic run was contention between two centrals dialling the same
peripherals.

**Not a radio crash either.** `rebootCount` read before and after the run on both
radios: `/dev/ttyACM1` 1 → 1, `/dev/ttyACM2` 0 → 0. That eliminates the blocker
the README records for Apple centrals against this firmware - the controller
asserting ~200 ms in - as the cause here. Nothing rebooted.

## What is left is one peer, and it is the nRF52 - my first guess was backwards

Every disconnect in the quiet run was the same peer, `9D91F3F2`, always
`The connection has timed out unexpectedly.` The other stayed up and took a write.

I inferred from MTU that `9D91F3F2` was the ESP32: it negotiated `chunk=244`
against the healthy peer's `chunk=512`, and
[[esp32-demands-pairing-on-mesh-links]] records the ESP32 pulling mesh peers into
MITM pairing. **That was wrong.**

Settled by taking the Cardputer's GATT peer role off the air
(`network.enabled_protocols` 6 → 2, restored after):

| | with the Cardputer serving | with it off |
| --- | --- | --- |
| peers discovered | `3FD7485B`, `9D91F3F2` | `9D91F3F2` only |
| disconnects | 4, all `9D91F3F2` | 6, all `9D91F3F2` |

The peer that disappeared is the one that **worked**. So `3FD7485B` was the
Cardputer, the ESP32 is fine against an iOS central, and `9D91F3F2` is the
**RAK4631** - the nRF52 carrying the spike firmware.

That is the pair the README already calls out: an Apple node against this
firmware. It is not a reboot - `rebootCount` on the RAK has read 0 before, during
and after every run today - so whatever the controller does, it does not restart
the device. The failure is a connection that times out, not a crash.

**Attempted, and the observable does not exist.** Capturing the nRF52 side while
an iOS central connected produced 1537 lines with `debug_log_api_enabled` set and
**not one BLE or GATT firmware line** - only the Python client's own debug output
and nodeinfo. The Cardputer behaved the same way earlier. The LogRecord stream
does not carry this subsystem, and the run also ended with
`Meshtastic serial port disconnected ... (multiple access on port?)`, so the API
port cannot be held open for a capture while anything else touches the radio.

What would actually work, none of it done: a second UART on the nRF52, or a build
with the BLE subsystem's log level raised and read over that UART, or a BLE
sniffer capturing the SMP exchange - which is what would show whether the iOS
central is being asked to pair and timing out.
