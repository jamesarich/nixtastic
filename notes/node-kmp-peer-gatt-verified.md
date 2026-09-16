# node-kmp's own GATT peripheral, verified from another host

Checked 2026-09-16 after a run where the uConsole failed to reach james-pc with
`BlueZ refused the connection: No reply within specified time`, which read as
node-kmp↔node-kmp GATT being broken. It is not.

With james-pc running `MESH_GATT_ROLE=PERIPHERAL_ONLY`, from the uConsole:

```
Device E8:48:B8:C8:20:00 RSSI: 0xffffffbd (-67)
Attempting to connect to E8:48:B8:C8:20:00 ... Connection successful
4d657368-4e6f-6465-4741-545400000001
4d657368-4e6f-6465-4741-545400000002
```

Discoverable, connectable, and serving both the mesh service and its
characteristic. The peripheral half is sound.

## What the timeout was - my first answer was wrong

The failing run had three peers pending at once:

```
central=[dev_28_84_85_78_4E_ED:pending, dev_E8_48_B8_C8_20_00:pending, dev_ED_D2_65_9A_10_F7:pending]
```

I read that as three `Connect()` calls in flight, BlueZ not dialling in parallel,
and the last exceeding its D-Bus reply timeout. **The code says otherwise.**
`BluezGattLink` runs every connect on `Executors.newSingleThreadExecutor`, and
says why:

```kotlin
// One thread, not a pool: BlueZ serialises connects internally, and a queue here keeps a
// slow connect from starving the callbacks that report the last one finishing.
```

So the dials were already serialised and `pending` is a bookkeeping state, not a
call in flight. A peer waiting its turn cannot time out on D-Bus, because its
`Connect()` has not been made yet.

That leaves the timeout as what it says: **one peer's own `Connect()` took longer
than dbus-java's reply timeout.** About that peer or that adapter, not about how
many others were queued behind it - and nothing here identifies which.
