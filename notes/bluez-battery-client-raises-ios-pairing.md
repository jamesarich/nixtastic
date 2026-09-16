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

## Two things the capture also shows

- **No ATT 0x0e anywhere.** The failure in
  [`bluez-peripheral-subscribe-att-0x0e.md`](./bluez-peripheral-subscribe-att-0x0e.md)
  did not reproduce here, because this capture is iPad-to-uConsole; `james-pc`
  never appears in it. That isolation still needs its own capture.
- **A TP-Link LE Audio device (`E8:48:B8:C8:20:00`)** - Microphone Control,
  Volume Control, Broadcast Audio Scan - dials the uConsole every 5-10 s, gets
  a `User Confirmation Negative Reply` and disconnects, restarting advertising
  each time. Who sends that reply is not settled: it lands ~90 us after the
  event, which is fast for a D-Bus round trip to our agent but not impossible.
