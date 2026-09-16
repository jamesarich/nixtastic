# Two reasons a UDP node hears nothing from a real Meshtastic node

Measured 2026-09-16 on `james-pc` against `meshtastic/meshtasticd:latest` in
Docker (`--net=host`, `Lora: Module: sim`, `network.enabled_protocols = 1`).

## The released meshtasticd is on a different multicast group

```
ss -lunp   ->   UNCONN  224.0.0.69:4403
node-kmp        239.0.0.69:4403
```

Firmware PR **#8612 "Fix multicast address"** moved the group from `224.0.0.69`
to `239.0.0.69`. `224.0.0.0/24` is the local network control block, which is not
meant to carry application traffic; `239/8` is the administratively scoped range.
Our checkout carries the new address and so does node-kmp, but the published
`meshtasticd:latest` image predates the change.

So **a node-kmp node and a released meshtasticd cannot see each other over UDP at
all**, in either direction, and nothing logs a reason - each simply hears silence
on its own group. Pointing the node at the old group with `MESH_UDP_GROUP` took it
straight to `rx=16`.

This is worth knowing before reading any UDP bearer result: check what the peer
is actually bound to (`ss -lunp | grep 4403`) before believing a zero.

## An empty channel name means the modem preset, and the node assumes LongFast

With the group matched, frames arrived and none decoded. The peer's channel name
is empty, and firmware's `Channels::getName` substitutes the **modem preset's**
display name for a blank name before hashing it - so a peer on `SHORT_TURBO`
hashes as `ShortTurbo` while a node that assumes `LongFast` computes a different
channel hash and opens nothing.

Setting the peer back to `LONG_FAST` gave **6/6 decoded, meshtasticd to node** -
the UDP bearer working against real firmware code.

### The obvious fix is wrong, measured

`ChannelSetUrl.decode(url)` takes a `defaultName` for exactly this, and
`ChannelSetUrl.loraConfig(url)` returns the sharer's modem preset, so deriving
the name from the URL looks right. It was tried and **reverted**:

- The URL does track the preset. `EhYIARAIGPQD…` carries `10 08` (SHORT_TURBO);
  on LONG_FAST the field is absent, proto3 omitting the zero. Not stale.
- So during the run that decoded **6/6**, the peer was on SHORT_TURBO - and the
  node, assuming `LongFast`, opened every packet.
- With the preset read from the URL the node logged
  `channel 'ShortTurbo' from MESH_CHANNEL_URL` and every frame arrived
  `rx[udp] opaque`.

**This peer hashes its blank channel name as `LongFast` while running
SHORT_TURBO** - and the firmware source says it should not:

- `Channels::getName` substitutes `DisplayFormatters::getModemPresetDisplayName`
  for a blank name, gated on `config.lora.use_preset`.
- That peer reported `lora.use_preset: True`.
- `getModemPresetDisplayName(SHORT_TURBO, false, true)` returns `"ShortTurbo"`.
  It returns `"Custom"` only when `usePreset` is false.

So the contradiction is real, not a misreading of the source. Two measurements
cannot both be explained: the peer decoded 6/6 while the node assumed `LongFast`
and the URL said preset 8, and decoded 0/6 once the node used `ShortTurbo`.

The one uncontrolled variable is **when the container finished rebooting**. A
config write reboots it, and the URL was read 35 s later; if the device was still
serving its old config at that moment, the device may have been LongFast during
the good run and the URL simply stale *for that read*. Settling it needs the
preset verified with `--get` immediately before **and** after a run, and the
node's computed channel hash logged.

Not worth chasing further for bench purposes: naming the channel removes the
substitution entirely and measures 15/15 each way.

## Proven, on a channel with a name

Give the peer an explicit channel name and the whole substitution question goes
away - the hash is over a name both ends can see:

```
meshtastic --host 127.0.0.1 --ch-index 0 --ch-set name UdpBench
```

node-kmp then joins by URL and the bearer runs **both ways against real firmware
code**:

```
channel 'UdpBench' from MESH_CHANNEL_URL, 1 in the set
meshtasticd -> node   6/6
node -> meshtasticd   3/3
```

So a bench UDP run should always name its channel. A blank name is only
ambiguous because both ends have to guess the same substitution.

## Bench recipe

```
docker run -d --name meshd-udp --net=host --restart unless-stopped \
  -v ~/meshd-udp/config.yaml:/etc/meshtasticd/config.yaml \
  -v ~/meshd-udp/prefs:/prefs meshtastic/meshtasticd:latest
```

`--restart unless-stopped` is required: a config write reboots the node and
`execv()` fails inside the container, so it exits. The `/prefs` volume is what
makes the config survive that restart. See [[meshtasticd-sim-rig]] for the
`Module: sim` rules.
