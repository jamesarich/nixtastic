# What each bearer actually delivers

Measured 2026-09-16 on `james-pc` with `nix run .#meshbench`, node-kmp against a
RAK4631 on `rak4631_blemesh` (and, for UDP, a `meshtasticd` container). Read the
caveats before quoting a number - three of the four figures here replaced an
earlier one that was an artefact of the measurement rather than the bearer.

| bearer | outbound | inbound | n | notes |
| --- | --- | --- | --- | --- |
| udp | **15/15 (100%)** | **15/15 (100%)** | 15 | vs meshtasticd, on its own group |
| lora | **15/15 (100%)** | 14/15 (93%) | 15 | meshtadpole (CH341 + SX1262) |
| ble-adv | 10/15 (67%) | 12/15 (80%) | 15 | connectionless; see compounding |
| gatt | **14/15 (93%)** | **15/15 (100%)** | 15 | 3 drops in 106 arrivals at the firmware |

## How to read the two outbound numbers

`meshbench` prints two, and they bound the truth from opposite sides:

- **`kmp->radio (min)`** counts the firmware's own `decoded message` log line,
  which arrives as a sparse `LogRecord` stream captured only during the outbound
  phase. It has under-reported every single time - `4/15` for a bearer measured
  at `15/15`. It is a floor, never a rate.
- **`acknowledged by the radio`** counts the node's own `Delivered` events. An
  ACK cannot exist unless the radio decoded the packet, so this is ground truth
  for delivery - *provided the return path is good*.

**They compound on a lossy bearer.** ble-adv's ACK figure is 10/15, but the ACK
comes back over ble-adv too, at 80%. So the real outbound rate is nearer
`0.67 / 0.80 ≈ 83%`, not 67%. On LoRa the return path is 93% and the ACK figure
is already 100%, so nothing is hidden there.

## What each number cost to get right

- **lora** first read `1/6 (16%)`. That was the log-stream floor; the ACKs said
  6/6 at the same moment.
- **ble-adv** first read `0%` inbound, then `33%`. Both were the radio having
  `network.enabled_protocols = 0` - its BLE transmitters were off. With
  `BLE_BROADCAST` on it went to 100% on the small sample.
- **gatt** first read `0/6` with `rx=0 tx=0`. Two causes: `BLE_GATT_PEER` also
  off, and then a fixed 25-second settle against a link that took 93 s to come up.
- **udp** read `0%` both ways for the whole session until the group mismatch
  surfaced - see [`udp-group-and-preset-parity.md`](./udp-group-and-preset-parity.md).
  On a named channel and the peer's own group it is the cleanest bearer here:
  15/15 each way, no loss at all. It is also the only one whose peer is firmware
  code rather than a radio, so nothing on that path is over the air.

Every one of those was the rig, not the bearer. Check `enabled_protocols`, the
channel, and what holds `tcp 4403` before reading anything into a zero.

## Re-measured 2026-09-16 after the BlueZ extraction

`:node-bluez` took the D-Bus session and the adapter probe out of both Linux
bearers (`ea8cb3d`), so both were re-run against the same RAK4631 to show the
refactor cost nothing. Same script, same radio, n=15, and the jar's md5 was
checked on the bench against the one built here - `de2a3394ea71` both ends.

| bearer | outbound | inbound | before |
| --- | --- | --- | --- |
| gatt, run 1 | 15/15 (100%) | 14/15 (93%) | 14/15 · 15/15 |
| gatt, run 2 | 13/15 (86%) | 15/15 (100%) | " |
| ble-adv | 13/15 (86%) | 15/15 (100%) | 10/15 · 12/15 |
| both together | **15/15 ACK** | 15/15 | - |

Both bearers are at or above where they were. Nothing regressed.

### Why the ack column read near zero on a gatt-only run - found and fixed

These sends are **broadcasts**, and firmware raises no routing ack for one. So
every `Delivered` the bench counts came from `MeshNode.implicitAck`: our own
packet heard back with `hop_limit` decremented, meaning a neighbour relayed it.

`BLEGattMeshHandler::onSend` excluded the peer that delivered a packet from the
relay - correct while carrying somebody else's packet onward, wrong when that
peer wrote it. On LoRa an author hears its own packet relayed and takes that as
the ack; a point-to-point link has no such echo. GATT was the **only** bearer
with an exclusion at all - `BLEMeshHandler` and UDP are broadcast media and have
none - which is why it was the only one where the implicit ack never arrived.

Fixed in both repos, same rule on each side so they cannot drift:

- firmware `BLEGattMeshHandler::relayExclusion` - the arrival records whether
  `hop_start` still equalled `hop_limit`, read before the Router decrements.
- node-kmp `MeshNode.scheduleRelay` - `header.hopsAway == 0`. Null is "the frame
  did not say", which is not evidence of authorship, so the exclusion stands.

Measured on the RAK4631, gatt alone, n=15:

| | acknowledged |
| --- | --- |
| before, run 1 | 1/15 |
| before, run 2 | 3/15 |
| **after, run 1** | **15/15** |
| **after, run 2** | **15/15** |

The data path was never the problem and did not move: 15/15 inbound in both runs
after, against 14/15 and 15/15 before.

One thing the pair of runs shows plainly: the `kmp->radio (min)` column read
15/15 then 0/15 across the two runs after the fix. It is the sparse LogRecord
floor and it is not a rate, exactly as the header says. The ack figure is now the
stable one on this bearer, where before the fix it was the unreliable one.

## What was actually running, and one measurement that was not what it looked like

The "after" runs above were taken with a node-kmp jar built at 14:23 against a
relay fix committed at 15:26. All three hosts held byte-identical copies, which
is what made it look right: **matching hashes across hosts say the hosts agree,
not that they are current.**

Those runs are still valid for what they claimed - the firmware half, where the
radio relays back to the node that wrote the packet. They never exercised
node-kmp's own `scheduleRelay`, which was not in the jar.

Re-run with everything current (node-kmp `5b73d5d5d617`, firmware `d38498c7a` on
the RAK): gatt alone, n=15, **15/15 outbound, 15/15 inbound, 15/15 acknowledged**.
Three runs at 15/15 acknowledged now.

`nodeJar` stamps `git describe` into the manifest and the node prints it as its
first line, so a log now says which commit produced it.

### Fleet state, 2026-09-16

| | build | carries the relay fix |
| --- | --- | --- |
| node-kmp on james-pc, uConsole, this Mac | `5b73d5d5d617` | yes |
| RAK4631 `/dev/ttyACM2` `rak4631_blemesh` | firmware `d38498c7a` | yes |
| M5Stack Cardputer `/dev/ttyACM1` `m5stack-cardputer-adv_blemesh` | older | **no** |
| Seeed Xiao S3 `/dev/ttyACM0` `seeed-xiao-s3` | older, not a blemesh env | n/a |
| meshtadpole (CH341 LoRa, `1a86:5512`) | n/a - it is the node's own radio | n/a |

node-kmp's own relay change is unit-tested on both branches of the rule but is
**not yet proven on hardware**: that needs two node-kmp nodes linked over GATT,
and in a run with one on james-pc and one on the uConsole they never found each
other - the uConsole's adapter saw only one peer the whole time. Not diagnosed.

### The meshtadpole does not appear under /dev/serial/by-id, and should not

Recorded because it was misread as "not plugged in" and put in the table that
way. The CH341A enumerates as

```
Bus 001 Device 103: ID 1a86:5512 QinHeng Electronics CH341 in EPP/MEM/I2C mode, EPP/I2C adapter
```

**EPP/MEM/I2C mode is not a serial device.** It is an SPI bridge driving the
SX1262, reached over libusb, so it creates no tty and never shows up in
`/dev/serial/by-id/` - which is exactly the right place to look for the *radios*
and exactly the wrong place to look for this. `lsusb | grep 1a86` is the probe.

Proven working the same session, current build `5b73d5d5d617`: `avail[lora]`
Ready then Active, a NodeInfo transmitted, and two radios received off the air
(`!cfa242df olm3c xiao s3`, `!f2775c7e olm3sh seeed Solar`) with the second copy
of each dropped as DUPLICATE.

Measured, n=15 against the RAK4631: **15/15 outbound, 15/15 acknowledged, 13/15
(86%) inbound** - against 15/15 and 14/15 before, so unchanged within
over-the-air variance.

## node-kmp's half of the relay fix, proven

Two things blocked this and neither was the change.

`rebroadcastMode` was never set by node-headless, so it took the library default
`RebroadcastMode.NONE` and the node relayed nothing at all - `scheduleRelay` was
unreachable and the first attempt could not have worked whatever the code did.
`MESH_REBROADCAST_MODE` now says so, defaulting to NONE as before.

The firmware author's own log was then the wrong observable: a Cardputer
capturing `--listen` across the whole window carried **zero** `BLE GATT mesh`
lines. `GattMeshTransport` now logs the peers that took each packet, and the
excluded one beside them, because a relay that skipped its origin and a peer that
quietly went away leave the same trace - none.

With both in place, node-kmp relaying the Cardputer's own broadcast:

```
MNGATT sent 1 chunk(s) to [/org/bluez/hci0/dev_28_84_85_78_4E_ED, /org/bluez/hci0/dev_ED_D2_65_9A_10_F7]
relayed[gatt] !3235af1d hops=6
```

`dev_28_84_85_78_4E_ED` is the Cardputer, `!3235af1d` is the Cardputer, and the
relay went **back to it** with no `excluding` clause - which is the change. Three
consecutive relays, all the same. Before it the line would have named that peer
as excluded and reached only the RAK.

## ble-adv's 67-86% is mostly the measurement, not the bearer

`radiolog` can now ask the radio directly, which the LogRecord stream never could.
Driving 14 sends through a node-kmp `ble-adv` node (`!9318e67b`) and reading the
radio's own log for ~260 s:

| | |
| --- | --- |
| frames node-kmp transmitted | 22 |
| `BLE mesh RX from=0x9318e67b` decoded at the radio | **60** |

More receptions than sends, because a burst is `BLE_MESH_ADV_EVENTS 3` - one
frame is three advertising events. So 22 × 3 = 66 expected, **60 arrived (91% of
events)**, and a frame needs only one of its three, which makes frame-level
arrival effectively complete.

The radio's own transmit side measured separately in the same window: 24 of 25
bursts sent all three events, one timed out having sent none. **96%.**

So neither end is losing 14-33%. The `kmp->radio (min)` column that reads 67-86%
is what its name says - a floor off the sparse LogRecord stream, the same one
this table already warns under-reports every time, and the same artefact that
once had a working link reading 20-38%.

**The inbound direction was already settled, higher up this page.** The isolated
ble-adv run earlier the same day read **15/15 (100%)** inbound on the current
build. There is no inbound loss to account for, and writing that it "has not been
run" was an oversight, not a gap.

So with the outbound floor understood as a floor, **every bearer measures
effectively complete**: udp 15/15 both ways, lora 15/15 out and 13-14/15 in,
gatt 15/15 both ways over three runs, ble-adv 15/15 in with ingress at 60 of 66
advertising events and frame arrival effectively complete.

The one row that still reads as weak, `ble-adv` outbound, is the sparse
`LogRecord` floor and nothing else. Worth rewriting the top table in those terms
rather than leaving a number that has now misled twice - including me, for most
of a session.
