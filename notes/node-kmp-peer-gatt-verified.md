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

## What the timeout was, as far as the evidence goes

The run that failed had three peers pending at once:

```
central=[dev_28_84_85_78_4E_ED:pending, dev_E8_48_B8_C8_20_00:pending, dev_ED_D2_65_9A_10_F7:pending]
```

`Device1.Connect()` is a blocking D-Bus call and BlueZ does not dial in parallel,
so with three in flight the last can exceed the reply timeout. That fits what was
seen and is **not** established: it would take a run dialling one peer at a time
to show the timeout goes away.

Recorded so the next session does not start from "peer GATT does not work". It
does; a peer that times out under a fan-out of dials is a different question.
