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

## Not the unit, and not a stuck state

Both ruled out by measurement:

- **A `uhubctl` power cycle does not restore it.** Hub `1-2.3` port 2, board
  re-enumerates, stream still carries no `LogRecord`.
- **A second board behaves the same.** The Cardputer
  (`m5stack-cardputer-adv_blemesh`, a different MCU family) reports
  `security.debug_log_api_enabled: True` and streams zero firmware lines too.

So it is not this RAK and not a transient. What is left is the firmware on this
branch, the CLI, or something about how `--listen` requests the stream - and the
awkward fact that it demonstrably worked earlier the same day on the RAK, which
is what makes it a regression rather than a thing that never worked.

Whether the Cardputer ever streamed is unknown; its flag was set by some earlier
session, not by this one.

## Where to start next time

Compare a capture that worked (`/tmp/meshbench-3768276/radio.log` on `james-pc`,
which has `decoded message (id=…)` lines in it) against one that does not. The
CLI is the same, the flag is the same, the board is the same - so the difference
is in what happened between, and four reflashes and a `network.enabled_protocols`
change are the candidates.


## The gate is sound - checked, and it is not the explanation

`RedirectablePrint.cpp:232` and `SerialConsole.cpp:283` both gate emission on

```cpp
config.security.debug_log_api_enabled && !pauseBluetoothLogging
```

`pauseBluetoothLogging` is set true in `handleStartConfig` when a client begins a
config download. It looked like a flag cleared only on the happy path, which
would mean any abandoned `meshtastic --get/--set` left logging silenced for
everyone - and this session made hundreds of those.

**That was wrong.** The three clears are `STATE_SEND_PACKETS` (1027),
`onConfigComplete` (1174), and one at 409 that sits inside **`PhoneAPI::close()`**
(from 357). So an abandoned client clears it on disconnect, and the working
capture's `Lost phone connection` / `PhoneAPI::close()` pair shows close really
does run for a serial client. A power cycle would clear it in any case - it is a
RAM global initialised false - and did not fix anything.

So the gate is not the explanation, and the cause is still open.

## Where to start next time

Diff a capture that worked against one that does not:
`/tmp/meshbench-3768276/radio.log` on `james-pc` still has `decoded message
(id=…)` lines in it. Same CLI, same flag, same board, so the difference lies in
what happened between - four reflashes and a `network.enabled_protocols` change
are the candidates. Two boards on different MCU families behave identically now,
and a `uhubctl` power cycle does not help, so it is neither the unit nor a stuck
RAM state.