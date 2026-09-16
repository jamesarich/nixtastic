# node-kmp's LoRa against the firmware's radio contract

Audited 2026-09-16 by reading both sides, after a bench run measured the bearer at
15/15 outbound and 14/15 inbound.

## Every gate the firmware applies, node-kmp applies

| firmware behaviour | node-kmp |
| --- | --- |
| **Duty cycle** - own transmissions over a rolling hour, under the region's limit | `LoraAirtime.dutyCycleAllowed`, rolling hour |
| **Channel utilization** - everything heard or sent in the last minute, capped | `LoraAirtime.channelUtilPct` against `MAX_CHANNEL_UTIL_PCT`, citing `airtime.h` |
| **Both gates together for background traffic**, duty cycle alone for the rest | `txAllowed` vs `dutyCycleAllowed`, split the same way |
| **CAD before transmit** (`isChannelActive()`), two symbols | `Sx1262Driver.channelBusy()`, "two symbols, the default", rewriting CAD parameters at the configured SF rather than RadioLib's fixed SF9 |
| **CSMA contention window** before a flood | `ContentionWindow` in `node-core`, driven from `LoraTransport` |
| **Frequency slot from the channel name hash** | `LoraChannelPlan.defaultSlot`, including the preset-hash override path |
| **Modem presets** and their airtime maths | `LoraModemPreset` with bandwidth, SF, CR per preset |

The TX loop is the firmware's: receive, drain mid-frame, CAD, transmit, wait for
TX_DONE, back to receive.

## What this audit corrected

A first pass grepped only the module's top-level `commonMain` and found no CAD at
all, which read as a serious parity gap - a node transmitting over other people's
packets. The implementation is in `commonMain/.../sx1262/`, one directory down.
**Nothing was wrong; the search was.**

Worth recording because it is the session's recurring failure in miniature: a
negative result from an instrument nobody checked. The same shape produced a dead
log stream that was alive, a bearer at 27% that was at 93%, and four other wrong
conclusions.

## Genuinely open on LoRa

Nothing in the radio contract. The measured inbound loss (14/15) is the medium -
this bearer has no link-layer acknowledgement, and the node already declines to
transmit when the channel is busy or its budget is spent, which is the behaviour
that makes a shared band work rather than a defect to fix.
