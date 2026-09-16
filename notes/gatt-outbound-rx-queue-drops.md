# GATT outbound loses writes, and the RX queue is not why

Measured 2026-09-16, node-kmp as `CENTRAL_ONLY` on `james-pc` against a RAK4631
on `rak4631_blemesh`, 15 messages each way.

```
bearer     kmp->radio (min) radio->kmp (first)
gatt            4/15 (26%)     15/15 (100%)
```

Inbound is perfect and comes from the RAK itself - `rx[gatt] text from
!3d01e450`, which is its node number - so there is no relay through another peer
and the acknowledgement path is sound. Outbound really is about a quarter.

## The queue was the first suspect and it is not the cause

The firmware logs `BLE GATT mesh: RX queue full, dropping a 43-byte write` and
ten of them appeared in the first run, which looked conclusive. Three runs say
otherwise:

| run | ring | queue-full drops | outbound |
| --- | --- | --- | --- |
| 3892036 | 6 | 10 | 4/15 |
| 3912932 | 24 | **0** | 0/15 |
| 3925210 | 6 | **0** | 0/15 |

Outbound is broken whether the queue overflows or not, and raising the ring from
6 to 24 slots (RAM 41.1% -> 44.9%) removed the drops without recovering a single
message. Reverted.

## Reading the firmware log here, which took three attempts to get right

`BLE GATT mesh:` covers `setupService`, the CCCD callback and the queue-full
warning. meshbench starts `meshtastic --listen` **after** waiting for the bearer
to be ready, so the subscribe has already happened and `onCccd` is never inside
the capture window. In practice the only mesh line that can appear is the
queue-full warning - so **zero mesh lines means zero drops, not a broken log
stream**, which is what an earlier version of this note wrongly concluded.

## Answered: the writes never reach `onWrite`

An arrival log was added to `onWrite` - every write, logged after the lock -
and the next run measured:

```
decoded message lines : 24     (so the log stream is flowing)
BLE GATT mesh lines   :  0     (so onWrite never fired, not once)
node counters         : tx=31  rx=38
```

`LOG_DEBUG` reaches the host - the `decoded message` lines are the same level -
so zero arrivals is not a logging artefact. **The central's writes never arrive at
the firmware's characteristic write callback.** Inbound is unaffected: the same
characteristic notifies at 15/15.

That also retires the queue as a suspect for good. Nothing can overflow a ring
that is never written to.

## A reproducible working case, and a reproducible failing one

The one run where writes **did** arrive:

```
node low4 (!1597f6f7), state dir reused, MESH_TRANSPORTS=gatt, CENTRAL_ONLY,
no MESH_CHANNEL_URL, --listen held for the whole 170 s
  -> 42 arrivals at onWrite, arrived/accepted counters climbing, zero drops
```

Every meshbench run: **0 arrivals**. The differences between them are few and all
testable one at a time:

| | working run | meshbench runs |
| --- | --- | --- |
| state dir | reused, identity already established | fresh per run |
| channel | default LongFast + default PSK | the radio's own URL |
| `--listen` window | whole run | outbound phase only |
| driver | sent by hand through the phone API | meshbench's phases |

**Two hypotheses are already dead.** Write type is not it - write-with-response
produced 0 arrivals too, with 30 decoded-message lines proving the stream was
live. And the role election is not it: shedding requires
`peers.hasSubscriberFor(peer)`, and a `CENTRAL_ONLY` node runs no peripheral, so
it has no subscribers and `resolve` returns before it can shed. The election gates
nothing else in the link.

The node-id correlation that suggested the election - five failing runs all with
an id above the RAK's, the working run below it - is therefore **coincidence
until something explains it**. Five samples of a ~24% event is not a finding.

Next: take the working run and change one thing at a time toward the meshbench
shape. The channel is the first to try, because it is the only difference that
touches what the node sends rather than how it is driven.

## An earlier suspect, now dead

Every central writes **without response** - BlueZ `type=command`, Android
`WRITE_TYPE_NO_RESPONSE`, Apple `CBCharacteristicWriteWithoutResponse` - and the
nRF52 characteristic declares `CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP` with
`setWriteCallback(onWrite, true)`. If Bluefruit delivers only write-with-response
to that callback, every fragment this bearer sends is discarded by the stack
before any of our code sees it, which fits every measurement here.

Testing it is one line at the central: write with response once and see whether
`onWrite` fires. That has not been done.

## Previously unexplained, now superseded

The node reports the writes going out (`tx=41` for 15 messages, fragments
included), the firmware drops none of them, and the firmware decodes none of them
either. So the writes are either not reaching the ATT layer or not surviving
reassembly. BlueZ's `WriteValue` with `type=command` is fire-and-forget and
reports nothing back, so the node cannot tell the difference today.

The next measurement is on the firmware side and needs no host-side counting:
log in `onWrite` - arrival, length and conn - so the ring's input can be compared
against what the central believes it sent. `pushRx` still only speaks when it
drops something.
