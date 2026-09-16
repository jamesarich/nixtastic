# A BlueZ central cannot subscribe to our BlueZ peripheral (ATT 0x0e)

Isolated 2026-09-16 between `james-pc` (central) and the uConsole (peripheral),
both running `meshnode-headless`.

## What happens

The central's `StartNotify` fails with `Operation failed with ATT error: 0x0e` -
*Unlikely Error* - and the peer is dropped and redialled. Meanwhile the
peripheral registers subscribers and reports **no faults at all**. The two ends
disagree about whether the subscription succeeded.

## What it is not

- **Not the central.** The same central subscribes successfully to the ESP32
  firmware peripheral: after the MITM change the Cardputer carried `rx=1 tx=1`.
  Our BlueZ peripheral is the odd one out.
- **Not `AcquireNotify`.** BlueZ prefers the socket path where an application
  offers it, and ours refuses with `NotSupported` - but `onRefused` is wired to
  `fault`, and the peripheral's fault map is empty, so BlueZ never called it.
- **Not a missing `Notifying` signal.** The property was never announced on the
  bus; adding `PropertiesChanged` for it is correct and changed nothing here.
  Refuted on the bench, not assumed.
- **Not pairing.** Both ends now accept an unauthenticated bond and the
  authorization faults are gone.
- **Not the classic bearer.** A stale `BREDR.Bonded: yes` on the central was
  forcing BR/EDR page timeouts; `bluetoothctl remove` cleared that, and the
  remaining failure is pure LE.

## Where it must be

Inside the peripheral's BlueZ, between our application returning from
`StartNotify` successfully and the ATT response the remote receives. Nothing in
either application's own logic is left in the path.

## What would settle it

The ATT exchange itself. `btmon` is the tool and it needs root - verified as
failing with `Failed to bind channel: Operation not permitted` for the ordinary
user on both hosts - as does raising `bluetoothd` to debug, which needs the
service restarted. Both are sudo, so this is where an unprivileged session ends.

Worth capturing on the peripheral rather than the central: the error is
generated there.

A `btmon` capture was taken on the peripheral 2026-09-16, but with the iPad as
the central rather than `james-pc` - no 0x0e appears in it, and that subscribe
succeeds. See
[`bluez-battery-client-raises-ios-pairing.md`](./bluez-battery-client-raises-ios-pairing.md)
for what that capture did settle. The `james-pc` pairing still needs its own.
