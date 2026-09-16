# The firmware log stream is alive; the mesh-GATT lines are not

Corrected 2026-09-16 after an earlier version of this note claimed the whole
`LogRecord` stream had died. **It had not.** The test behind that claim was a
40-second idle `--listen` grepped for `(DEBUG|INFO|WARN) |`, a pattern that
matches none of these lines, in a window where nothing was decoded anyway.

## What is actually true

Three GATT runs on the bench RAK4631, same command, same flag:

| run | `decoded message` | `BLE GATT mesh` | outbound |
| --- | --- | --- | --- |
| 3892036 (ring 6) | 38 | **24** | 4/15 |
| 3912932 (ring 24) | 16 | **0** | 0/15 |
| 3925210 (ring 6 + counters) | 24 | **0** | 0/15 |

The stream carries firmware lines in all three. What disappeared is the
mesh-specific logging - and with it, any visibility into the bearer.

## How to test it properly

`decoded message` only appears when a packet is decoded, so a quiet window
produces none legitimately. Never read an idle capture as evidence the stream is
down. Grep a capture that had traffic, for the literal the firmware actually
emits, and check the count against a known-good run rather than against zero.

## What this leaves open

`BLE GATT mesh:` covers `setupService`, the CCCD callback and the queue-full
warning. Zero of them, in runs whose inbound measured 15/15 over that same
bearer, is not yet explained: inbound is counted on the node's side, so the radio
was notifying, and a notifying radio that logs nothing about its mesh service is
the thing to chase next.

The earlier conclusions drawn while the stream was believed dead - that the
GATT drop share could not be measured, and that the RX-ring comparison was
uncontrolled - still stand on their own evidence: run 3912932 genuinely had no
mesh lines to compare against run 3892036's twenty-four.
