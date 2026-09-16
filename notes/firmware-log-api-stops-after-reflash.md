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


## A latent bug in the gate, and the leading candidate

`RedirectablePrint.cpp:232` and `SerialConsole.cpp:283` both gate emission on

```cpp
config.security.debug_log_api_enabled && !pauseBluetoothLogging
```

`pauseBluetoothLogging` is a plain global in `main.cpp`, set **true** in
`PhoneAPI.cpp:311` when a client begins a config download, and cleared in three
places that all sit on the *completion* path - `STATE_SEND_PACKETS` (1027),
`onConfigComplete` (1174) and the close/reset path (409).

So **a client that starts a config download and goes away before finishing it
leaves logging paused for everyone**, indefinitely, until some later client
completes a full handshake. Every short-lived `meshtastic --get/--set/--info`
call is a config download, and a `timeout` that fires mid-handshake is exactly
that shape. This session made hundreds of them against both boards.

It is the leading candidate and **not proven to be today's cause**: the close
path at 409 also clears the flag, and the working capture shows
`FromRadio=STATE_SEND_PACKETS` followed by `Lost phone connection`, so that run
did reach a clearing state. A power cycle should also have cleared it, being a
RAM global initialised false, and did not.

Worth fixing on its own merits regardless of this session: a global that silences
diagnostics and is only cleared on the happy path is a bad shape, and the obvious
repair is to clear it whenever a phone connection ends, not only when it ends
well.