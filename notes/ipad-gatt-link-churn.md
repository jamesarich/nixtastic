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

**The observable exists, and `--listen` is what was hiding it.**

`SerialConsole::log_to_serial` only emits a LogRecord `if (usingProtobufs)`, and
that branch is gated on `!pauseBluetoothLogging` - which `PhoneAPI` sets **true**
the moment a client requests config (`PhoneAPI.cpp:311`). So
`meshtastic --listen` silences the firmware logs it is being used to read. Both
empty captures were that, not a missing log.

A reader that does **not** speak the phone API falls through to the plain-text
branch and gets everything. A bare `pyserial` read of `/dev/ttyACM2`:

```
INFO  | BLE Connected to iPad
WARN  | [BLEMesh] BLE mesh: no spare adv set (0x4), sharing the phone's
INFO  | BLE GATT mesh: conn 1 subscribed (chunk 244)
DEBUG | BLE GATT mesh: write 10 bytes from conn 1 (arrived 3, accepted 3, dropped 0)
```

## So the link works

That run had **zero disconnects**. The iPad connected, subscribed at chunk 244,
and the radio accepted three writes from it - `arrived 3, accepted 3, dropped 0`.

`chunk 244` also confirms the identification: `9D91F3F2` is the RAK4631.

Taken with the contention result above, the whole thread resolves the same way:
**the iPad↔nRF52 GATT link works, and every failure measured today tracked how
many other centrals were dialling the same radios.** What is not established is
where the limit is - the radio logs `no spare adv set (0x4), sharing the phone's`,
so advertising-set pressure is the thing to measure next, not the link itself.

## Why two centrals churn - two separate limits, not one

An earlier version of this note said "one mesh slot, the phone holds the other".
That conflated two different resources. Read from the nRF52 source:

**Connection slots are shared, not reserved.** `NRF52Bluetooth::setup` calls

```cpp
// Two peripheral links: the phone and one mesh peer.
Bluefruit.begin(2, 1);
```

Two peripheral links and one central link. The comment describes the expected
use, not an enforced split: `rearmAdvertising` re-advertises while
`Bluefruit.Periph.connected() < 2`, so the slots go first-come. With no phone
connected, **two mesh centrals can both hold links** - which is why the iPad and
james-pc's node were not simply fighting over one.

**Advertising sets are the scarcer resource.** The mesh advertiser asks the
SoftDevice for its own extended-advertising set, and when that fails:

```cpp
// Sharing handle 0 means suspending the phone advertisement for each burst and
// restoring it afterwards.
LOG_WARN("BLE mesh: no spare adv set (0x%x), sharing the phone's", err);
```

`0x4` is out-of-memory. Sharing handle 0 means every mesh burst **suspends the
phone advertisement and restores it** - so advertising and connectability contend
on one set, and a burst can be scheduled and never transmitted. That is the
`reason=1 after 0 events` termination measured in
[`radio-plain-text-log.md`](./radio-plain-text-log.md), at 1 in 25 bursts.

So the churn under two centrals is not slot exhaustion. Both centrals fit. What
they contend for is the radio's time: two link lifecycles plus a shared
advertising set on one antenna.

**The open design question**, stated properly: whether the mesh advertiser should
get a dedicated set - which is a SoftDevice memory-budget change, the same
`nrf52840_s140_v*.ld` RAM base that already gates the central role - or whether
sharing handle 0 is acceptable given it costs a few percent of bursts.
