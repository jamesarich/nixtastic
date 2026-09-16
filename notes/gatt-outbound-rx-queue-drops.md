# GATT outbound is 93%, and every low figure was the harness

Measured 2026-09-16, node-kmp as `CENTRAL_ONLY` on `james-pc` against a RAK4631
on `rak4631_blemesh`, 15 messages each way, with a current jar and a readiness
gate that waits for the radio under test.

```
bearer     kmp->radio (min) radio->kmp (first)
gatt           14/15 (93%)     15/15 (100%)

firmware counters : arrived 106, accepted 103, dropped 3
transport=10 decodes from the node : 108
```

## What the earlier figures actually measured

This bearer was reported at 4/15, then 0/15, then 8/15 over one session. None of
those were the bearer:

- **A stale jar.** meshbench runs whatever sits at `$KMP` on the bench host while
  a hand-driven test ships its own elsewhere. The two drifted for most of a
  session, so meshbench measured a build predating the fixes under test. It now
  prints the jar's timestamp and hash.
- **A readiness gate that waited for the wrong peer.** It matched the first
  `:ready` in the node's log, which on a bench with several mesh peers is some
  other device. In one run the node began sending at 18:23:00 and the radio linked
  at 18:24:19 - the entire outbound phase went out before the link existed. It now
  waits for `!<the radio's own myNodeNum>`.

## The RX queue, finally in proportion

The firmware's `RX queue full, dropping` warning was the first suspect and looked
conclusive. With a denominator it is **3 drops in 106 arrivals - 2.8%**. Raising
the ring from 6 to 24 slots was tried and reverted: it removed the drops and
recovered nothing measurable, because they were never the problem.

Getting to that denominator needed a counter on the drop line itself, since the
firmware log reaches the host as a sparse stream and one surviving line has to
carry the rate. `pushRx` spoke only when it turned a write away.

## What is left

The `acknowledged by the radio` column reads 5/15 here against the log's 14/15 -
the reverse of every other bearer, where the log column is the floor. Worth
understanding before quoting either as *the* number, but it does not change the
conclusion: 106 writes arrived and 103 were accepted.
