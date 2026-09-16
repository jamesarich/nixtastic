# The BlueZ central loses any peer that asks to pair

Measured 2026-09-15. node-kmp's BlueZ central refuses to pair, by design: the
mesh characteristic is unauthenticated on every platform and a mesh peer is a
stranger, exactly as on LoRa. The consequence is that it cannot hold a link to
a peer whose *stack* asks for security, whatever the mesh characteristic says -
link security is negotiated for the connection, not per attribute.

Two peers, same outcome, different routes:

| peer | what happens |
| --- | --- |
| ESP32 firmware node | NimBLE's device-global MITM mode asks immediately; the agent declines; `le-connection-abort-by-local`, no frames. See `esp32-demands-pairing-on-mesh-links.md`. |
| iOS node running our own app | link comes up and works for ~36 s, then `SMP timeout ... (status=65535)`, `smpPairingCompleted status=4827`, `LE Link disconnected ... reason 705` |

The iOS case is the clearer one because both ends are ours. The iPad accepted
the incoming connection from `james-pc`, reported `Device ready`, and held it -
then something started SMP, our agent never answered, and iOS dropped the link
on the 30-second SMP timeout. The 36 seconds between connect and teardown is
that timeout plus the setup.

Our own attributes are not what asks: the Apple peripheral declares
`CBAttributePermissionsWriteable`, the BlueZ peripheral declares plain
`write`/`write-without-response`/`notify`, and both firmware platforms declare
the mesh characteristic with no encryption requirement.

## Why this matters more than it looks

Android is the only central that holds these links, and it does so by *avoiding*
the question - it skips bonded devices outright and the platform completes Just
Works silently without consulting an agent. BlueZ consults its agent, ours
declines, and the peer is left waiting.

So "never pair" is not implementable as "always decline" on BlueZ. The options
are to answer the request rather than ignore it, to drop the peer immediately
rather than let it sit through a 30-second timeout, or to accept an
unauthenticated bond for peers advertising the mesh service. Which of those is
right is a security decision about what a mesh peer is allowed to be.

## Reproducing

Launch the app on the iPad (`pymobiledevice3 developer dvt launch
org.meshtastic.node.monitor`), capture with `pymobiledevice3 syslog live -pn
bluetoothd`, and run `nix run .#meshprobe -- <host> BEARERS=gatt SECONDS=60`.
The central reports `le-connection-abort-by-local`; the iPad log carries the SMP
timeout.
