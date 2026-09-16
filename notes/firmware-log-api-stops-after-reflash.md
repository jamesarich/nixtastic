# The firmware's log-over-phone-API stops emitting, and toggling does not restore it

Seen 2026-09-16 on the bench RAK4631 (`rak4631_blemesh`, `/dev/ttyACM2`).

## What works and then does not

With `security.debug_log_api_enabled` true, `meshtastic --port … --listen`
carries the firmware's own log lines as protobuf `LogRecord`s - `decoded message
(id=… transport = N)`, `BLE GATT mesh: …` and the rest. That is what meshbench's
outbound column counts.

After three UF2 reflashes in one session it stopped:

```
security.debug_log_api_enabled: True
lines captured by --listen : 2923
firmware log lines in them  : 0
```

The protobuf stream is healthy - 2923 lines of nodeinfo, packets and config - and
carries no `LogRecord` at all. Setting the flag false, committing, setting it true
again and committing does **not** bring it back.

## Why it matters more than it looks

Four separate measurements this session were distorted by this stream being
sparse or absent, always in the direction of under-reporting:

- meshbench's `kmp->radio` column read 1/6 for a bearer the ACKs proved at 6/6,
  and 4/15 for one measured at 15/15. It is labelled `(min)` for this reason.
- The GATT RX-queue drop count was a sample with no denominator, and the run that
  was supposed to test a bigger ring produced **zero** mesh lines, so 4/15 against
  0/15 was never a controlled comparison.

Anything counted from this stream is a floor, and when the stream is dead it is
a floor of zero. Check `grep -cE "(DEBUG|INFO|WARN) *\|"` on the capture before
reading a zero as a bearer fault.

## Not established

Whether the trigger is the reflash itself, a count of reflashes, or something
else that happened alongside. A power cycle has not been tried, and neither has a
different board - the Cardputer would say whether it is this unit.
