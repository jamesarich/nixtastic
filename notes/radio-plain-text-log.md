# Reading a radio's own log, and the trap that hides it

`nix run .#radiolog -- [host] [port] [seconds]`.

## Why the obvious tool cannot do this

`meshtastic --listen` is the reachable way to read firmware logs and it silences
them. `SerialConsole::log_to_serial` only emits a LogRecord `if (usingProtobufs)`,
gated on `!pauseBluetoothLogging`, and `PhoneAPI` sets that **true** as soon as a
client requests config (`PhoneAPI.cpp:311`). Two captures during iPad runs came
back with 1537 lines and not one BLE or GATT line because of this, and were nearly
written up as "the LogRecord stream does not carry this subsystem".

A reader that speaks no protobuf falls through to the plain-text branch instead:

```
INFO  | BLE Connected to iPad
INFO  | BLE GATT mesh: conn 1 subscribed (chunk 244)
DEBUG | BLE GATT mesh: write 10 bytes from conn 1 (arrived 3, accepted 3, dropped 0)
```

## The precondition

`usingProtobufs` latches on the first phone-API client and never clears, so a
radio anything has spoken to since boot is silent to this. `--reboot`, wait ~20 s,
then read before anything else touches it. The tool says so when it reads nothing,
because an empty capture otherwise looks like a dead bearer.

## First thing it showed

An advertising set terminating without transmitting:

```
BLE mesh adv set 0 terminated: reason 1 after 0 events (ours=1)
```

`reason=2 after 3 events` is the healthy shape - the burst's three events all
went out. `reason=1 after 0 events` is a timeout with nothing sent, and it
appears on an **idle** radio as well as under iPad load, so it is not caused by
connection pressure.

Seen 1 in 4 bursts in one 170 s window. **Not a rate** - n=4 - but it is a real
loss path on the advertisement bearer, which measures 67-86% where the others
reach 100%, and it is the first mechanism found that could account for that.
