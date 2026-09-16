# The GATT bearer loses writes in the firmware's RX ring

Measured 2026-09-16, node-kmp as `CENTRAL_ONLY` on `james-pc` against a RAK4631
on `rak4631_blemesh`, 15 messages each way.

```
bearer     kmp->radio (min) radio->kmp (first)
gatt            4/15 (26%)     15/15 (100%)
counters        rx=53 tx=41
```

Inbound is perfect, so the acknowledgement path is sound and the outbound figure
is not an artefact of a lossy return leg - it really is about 27%.

## What the firmware says

```
BLE GATT mesh: RX queue full, dropping a 43-byte write from conn 1
```

Ten of the twenty-four mesh log lines in that run are that warning. The node's
writes were spread over 95 seconds, so this is not one burst.

## Why the ring fills

- `BLE_GATT_MESH_RX_QUEUE_SIZE` is **6** (`NRF52BLEGattMesh.h`).
- `BLEGattMeshHandler::runOnce` returns `pumpTx() ? 10 : 100`, so an idle handler
  polls every **100 ms**. `pumpRx` then drains the whole ring in a `while`, so the
  drain is not the bottleneck once it runs - the wake interval is.
- **No central applies back-pressure.** All three write without response:
  BlueZ `WRITE_COMMAND`, Android `WRITE_TYPE_NO_RESPONSE`, Apple
  `CBCharacteristicWriteWithoutResponse`. Consistent across platforms, and
  flow-controlled on none of them.

So a packet's fragments arrive back-to-back into six slots that are emptied at
most ten times a second.

## Not yet established

**What share of the 11 lost messages this accounts for.** The firmware log
reaches the host as a sparse `LogRecord` stream - the same limitation that made
meshbench's outbound column a floor - so ten observed drops is a sample, not a
total. The mechanism is confirmed; its exact contribution is not.

## Candidate fixes, none tested

- Raise `BLE_GATT_MESH_RX_QUEUE_SIZE`. Cheapest, and moves the cliff rather than
  removing it.
- Shorten the idle `runOnce` interval. Costs power on a battery node.
- Write with response from the central, which is the only option that actually
  applies back-pressure - and the slowest, one round trip per fragment. The Apple
  link's own comment already notes the trade.

Measure the share first: the right fix depends on whether this is most of the
loss or a fraction of it.

## The ring is not the fix - tested

Raised `BLE_GATT_MESH_RX_QUEUE_SIZE` from 6 to 24 (RAM 41.1% -> 44.9%, an extra
9 KB; each slot is a 516-byte `RxChunk` regardless of the 43-byte writes that were
being dropped), flashed, and re-ran the same n=15 measurement:

```
ring 6    kmp->radio 4/15     radio->kmp 15/15
ring 24   kmp->radio 0/15     radio->kmp 15/15
```

Not an improvement, and **not a controlled comparison either**: the ring-24 run
produced *zero* `BLE GATT mesh` log lines against twenty-four before, so the
firmware side said nothing at all. 4 versus 0 out of 15 is within the noise of a
log stream that sparse.

What it does establish is that the queue depth is not what caps outbound delivery
at roughly a quarter - nine more kilobytes of ring bought nothing. Reverted; the
bench is back on the committed six-slot build.

So the drops are real and are **not** the whole story. The next measurement has to
count what the firmware *accepts*, which needs a counter it does not currently
keep - `pushRx` logs only on drop. A periodic accepted/dropped pair in the
handler's status would settle it and would not depend on the log stream carrying
every line.
