# BlueZ's battery client is what makes iOS ask to pair

Measured 2026-09-16 from a `btmon` capture on the uConsole (`2C:CF:67:D8:AD:A9`,
BlueZ 5.82, `hci0` Cypress) while the iPad drove our mesh GATT bearer. The
capture is the whole chain, three times over, with no gaps to infer across.

## The chain

The uConsole is the **peripheral**; the iPad connects to it. BlueZ then probes
the *iPad's* services on that same connection - profile probing does not care
which side dialled - and the battery client (`profiles/battery/bas.c`,
`read_initial_battery_level_cb`) reads the iPad's Battery Level:

```
#133  ATT: Read Request        Handle: 0x0020 Type: Battery Level (0x2a19)
#134  ATT: Error Response      Error: Insufficient Authentication (0x05)
#135  SMP: Security Request    Bonding, No MITM, SC          <- 168 us later
#137  SMP: Pairing Request     IO capability: KeyboardDisplay   (the iPad's prompt)
#138  SMP: Pairing Response    IO capability: NoInputNoOutput
      ... nothing further; no public keys are ever exchanged ...
#265  HCI Disconnect           Reason: Authentication Failure (0x05)
```

iOS marks Battery Level as needing an authenticated link. BlueZ answers a 0x05
by escalating to an SMP Security Request, which is exactly what surfaces as a
pairing dialog on the iPad. The pairing then stalls - the iPad shows the prompt
and goes no further - and ~30 s later bluetoothd tears the link down itself.

That 30 s is the whole lifetime of every connection in the capture: connect at
37.5 s, dropped at 70.3 s; connect at 70.9 s, dropped at 103.0 s. Not a mesh
problem, not our code - our GATT application is never on this path.

## The mesh bearer itself is fine

The same capture shows the iPad and the uConsole exchanging mesh frames
cleanly, on all three connections, with zero ATT errors:

```
#78   ATT: Write Request   Handle: 0x0043 (CCCD)  Data: 0100   Notification
#79   ATT: Write Response
#81   ATT: Handle Value Notification  Handle: 0x0042  c001c9840c80002ae55d
#84   ATT: Write Request              Handle: 0x0042  c00139f6ac94f78125bc
```

Handle 0x0042 is `4d657368-4e6f-6465-4741-545400000002` - ASCII `MeshNodeGATT`
- in service `...000001`, so this is the mesh peer bearer, not the phone API.
Both ends carry the service: the uConsole exposes it at 0x0040-0x0043 and the
iPad at 0x003e-0x0042.

So **iOS does work as a mesh GATT central against our BlueZ peripheral.** It
hears the advertisement because the CM5 adapter is legacy-only
(`LE Set Advertising Parameters`, ADV_IND), which is the one thing
[`ios-cannot-hear-ble-mesh-adverts.md`](./ios-cannot-hear-ble-mesh-adverts.md)
says iOS needs. What never happened is the reverse direction: the uConsole's
client side discovered the iPad's mesh characteristic (#76, handle 0x0040) and
then went to the battery read instead of subscribing to it.

## The fix

`battery` is a named bluetoothd plugin, and `-P` disables it:

```
sudo systemctl edit bluetooth.service     # ExecStart=
                                          # ExecStart=/usr/libexec/bluetooth/bluetoothd -P battery
sudo systemctl restart bluetooth
```

Nothing else in the capture needs it - Device Name (0x0003) and Appearance
(0x0005) are read by BlueZ's own device code, both succeeded, and neither
triggers security. Unverified until it runs; the causal chain is measured, the
remedy is not.

## The same shape, mirrored, on james-pc

`E8:48:B8:C8:20:00` in that capture is **james-pc's own Realtek adapter** - btmon
prints "TP-Link Systems Inc" from the OUI registry, which is not the vendor of
the dongle. So james-pc is in the capture after all, and it fails the same way
with the roles swapped:

```
#176  ATT: Read Request    Handle: 0x0015  f36b109d-66f2-a9a1-1241-6838dbe57277
#177  ATT: Error Response  Error: Insufficient Encryption (0x0f)
      ... SMP ... User Confirmation Negative Reply ...
#188  HCI Disconnect       Reason: Authentication Failure
```

Handle 0x0015 is inside **james-pc's Microphone Control service (0x0013-0x0016)**
- PipeWire/WirePlumber's LE Audio GATT server. It demands encryption, the
uConsole's bluetoothd probes it because probing is unconditional, and the link
dies. Six times in the capture, on a 5-10 s cycle.

So it is not one plugin and not one peer. **Any service on either side that
demands encryption will drag a mesh link into a pairing it does not need, and
BlueZ tears the link down when that pairing fails.** The iPad's Battery Level
and james-pc's LE Audio are two instances of one bug.

## Which means `-P battery` is the wrong fix

It removes one trigger out of many and asks the user for root to enable meshing,
which is not a thing a mesh app may require. The fix has to be application-level
and has to make the pairing *succeed quietly* rather than remove its causes one
at a time. Candidates, untested:

- Set `Device1.Trusted = true` on a dialled mesh peer, which is what BlueZ's
  Just Works repair policy consults before it asks any agent.
- Make the agent's accept path actually reached. It is: the central logs
  `4 x accepted RequestAuthorization without authentication`. The uConsole side
  in this capture answered `User Confirmation Negative Reply` ~90 us after the
  event, which is too fast for a D-Bus round trip to the JVM, so on that host
  BlueZ answered for itself - `new_auth()` returns NULL and BlueZ replies
  negatively when no default agent is available.

## Still open

**No ATT 0x0e is in this capture**, because it is the peripheral's HCI and the
error is raised toward the central. Reproduced on demand 2026-09-16 with both
ends on `meshnode-headless`: the peripheral logs `subscribers=[bluez-subscribers]`
- its `StartNotify` ran - while the central logs
`BlueZ refused StartNotify (ATT error: 0x0e)` for the same link, and the
subscriber lives ~32 s, the pairing-timeout lifetime above.

BlueZ raises `BT_ATT_ERROR_UNLIKELY` (0x0e) from `gatt-server.c` when
`gatt_db_attribute_write()` finds no write handler on the addressed attribute -
so the central is writing a CCCD handle the peripheral's database does not treat
as one. A stale cached GATT database on the central would do that, and so would
a handle that moved: the uConsole indicated `Service Changed 0x003c-0x0043` on
connect, and the mesh CCCD sits at 0x0043. Needs a capture on the **central**.
