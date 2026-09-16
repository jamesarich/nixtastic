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

`ChannelSetUrl.decode(url)` takes a `defaultName` for exactly this and
`node-headless` does not pass one, so it always assumes the default preset.
`ChannelSetUrl.loraConfig(url)` returns the sharer's `LoRaConfig`, modem preset
included, so the URL already carries what is needed. **Parity gap, open.**

Setting the peer back to `LONG_FAST` gave **6/6 decoded, meshtasticd to node** -
the UDP bearer working against real firmware code.

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
