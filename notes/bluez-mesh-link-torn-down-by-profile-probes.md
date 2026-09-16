# Why a BlueZ mesh link kept dying, end to end

Root-caused 2026-09-16 on the bench: `james-pc` (BlueZ 5.85, Realtek
`E8:48:B8:C8:20:00`), the uConsole (BlueZ 5.82, `2C:CF:67:D8:AD:A9`) and an
iPad, from one `btmon` capture plus `journalctl -u bluetooth` on both hosts.

Supersedes `bluez-peripheral-subscribe-att-0x0e.md`, whose "not pairing" line was
wrong.

## One bug, three faces

**bluetoothd probes every service on every connection, in both directions.** It
does not care which side dialled, and it does not care that the application only
wants one characteristic. Its client profiles then read attributes that demand
security, and BlueZ escalates to SMP. What happens next is the mesh link's
problem:

| Probe | Reads | Gets | Result |
| --- | --- | --- | --- |
| `profiles/battery/bas.c` | iPad Battery Level `0x2a19` | `0x05` Insufficient Authentication | iPad shows a pairing prompt |
| `profiles/midi/midi.c` | uConsole BLE-MIDI I/O | `0x0f` Insufficient Encryption | SMP, then teardown |
| `profiles/deviceinfo/deviceinfo.c` | PnP ID | `0x0e` Unlikely Error | logged, harmless |

Both hosts log the middle one continuously:

```
profiles/midi/midi.c:midi_io_initial_read_cb() MIDI I/O: Failed to read initial request
```

The MIDI service is the uConsole's own (`03b80e5a-…` at 0x0013-0x0017, char
`7772e5db-3868-4112-a1a9-f2669d106bf3` - btmon prints that UUID byte-reversed).

## What actually killed the link: a stale, asymmetric bond

Measured, not inferred:

```
uConsole → james-pc :  Paired: yes   Bonded: yes
james-pc → uConsole :  Paired: no    Bonded: no
```

BlueZ's `main.conf` default is `JustWorksRepairing = never`. A Just Works
pairing from a device it already holds as paired is refused **before any agent
is consulted** - which is why the capture shows `User Confirmation Negative
Reply` ~90 µs after the request, far too fast for a D-Bus round trip to our
JVM agent. The refusal becomes `Pairing Failed`, then
`HCI Disconnect: Authentication Failure`.

**And that is where ATT 0x0e came from.** Every in-flight ATT operation on a
link being torn down returns `BT_ATT_ERROR_UNLIKELY` - our `StartNotify`, and
bluetoothd's own PnP ID read, which logs the same 0x0e under a different name.
The central saw 0x0e while the peripheral logged `subscribers=[bluez-subscribers]`
because both were true: the subscribe landed, then the link died under it.

`bluetoothctl remove` on the side still holding the bond - no root - took the
0x0e count from 4 in 85 s to **zero**, and both ends to `Paired/Bonded/Connected:
yes`.

## Then cross-transport key derivation bit

With a symmetric bond stored, the next run failed differently:
`br-connection-not-supported` × 4, and the peer never reached `ready`.

The LE bond is made with CT2 set (`Bonding, No MITM, SC, No Keypresses, CT2`),
so BlueZ derives a **BR/EDR link key from it**. `bluetoothctl info` then reports
`BREDR.Bonded: yes` for a peer with no classic radio in play, and the next
`Device1.Connect()` dials a bearer that does not exist. `Connect()` fails the
whole call when any leg fails, so a working LE leg was being thrown away.

Fixed in `meshtastic-node-kmp` (`2435c00`): a classic-bearer refusal is checked
against `Device1.Connected` before it is believed. Result on the same pair:

```
central=[/org/bluez/hci0/dev_2C_CF_67_D8_AD_A9:ready]   steady
bearers gatt rx=1 tx=1     (both ends)
0x0e: 0    faults for that peer: none
```

## What this means for the product

`-P battery` was the wrong instinct. It removes one trigger of several, and it
asks a user for root to enable meshing. The durable answers are:

1. **Keep the mesh characteristic security-free** (already true) so the bearer
   never needs a bond of its own.
2. **Let the bond happen quietly when a probe forces one**, rather than refusing
   and eating a teardown - the agent's accept path, which is reached and works.
3. **Survive BlueZ reporting a whole-call failure for one dead bearer** - done.
4. **Clear an asymmetric bond rather than retrying into it.** Not yet
   implemented: the node can see `Paired` on its own side and a peer that will
   not re-pair, and `Device1.Pair()`/`Adapter1.RemoveDevice()` are both
   unprivileged. This is the remaining piece.

## And a fourth face: the cache hides the peer entirely

Measured after a bond was established. `bluetoothctl info` on the central:

```
Paired: yes
UUID: Vendor specific  (03b80e5a-...)        <- BLE-MIDI, still there
                                             <- the mesh UUID is GONE
```

For an **unpaired** device BlueZ reports the UUIDs from the advertisement; for a
**paired** one it reports the stored GATT service list. If that stored list was
written from a session where the mesh service was not up, the mesh UUID is simply
absent - and `advertisesMeshService(UUIDs)`, which is how the central decides
whether to dial, says no. Forever: the cache is on disk and survives reboots.

The symptom is the worst kind. The peripheral advertises, both nodes report
`Active`, and the central's log never mentions the peer at all - not a fault, not
a refusal, nothing. In one run here the central spent 95 s talking to a stranger
while the node it was paired with sat two feet away advertising.

`bluetoothctl remove` restored it, and the mesh UUID came back on the next
session. `Adapter1.RemoveDevice` is unprivileged, so the node can do this itself -
but not from the path that exists today, because a peer that is never *reserved*
never accumulates the refusals that would trigger it. **Open.** The gate probably
has to trust the discovery filter - `SetDiscoveryFilter(UUIDs=[mesh])` is already
set, so a device BlueZ reports during that discovery matched by advertisement -
rather than re-reading a property the cache can poison.

Disabling probe profiles is a packaging concern if anyone wants it - a
`bluetooth.service.d` drop-in in meshtasticd's deb, root at install time - never
a runtime ask.
