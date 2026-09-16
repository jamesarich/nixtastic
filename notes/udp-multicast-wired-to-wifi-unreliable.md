# UDP multicast does not cross this LAN's wired/wireless boundary

Measured 2026-09-16 between `james-pc` (wired, `enp0s31f6`, 192.168.1.168) and the
uConsole (wifi, `wlan0`, 192.168.1.23), group `239.0.0.69:4403`.

## What happens

node-kmp to node-kmp, one direction only:

```
uConsole -> james-pc :  rx=1   the peer is discovered, peer[udp] !716e6176 udpA
james-pc -> uConsole :  rx=0   against tx=19
```

## It is the network, not the node

A python listener and a Java listener, run **at the same time on the uConsole**,
both received 0 of 10 sent from james-pc. The same python listener received 4 of 4
sent from the uConsole itself. So the host's stack, the group, the port and the
join are all fine, and both runtimes agree.

One earlier run did receive 5 of 6, so the path is intermittent rather than
blocked outright - the shape of an AP that forwards multicast only while it has a
fresh IGMP membership for the group, or that rate-limits it.

## What it means for the bench

- **A UDP bearer test needs both peers on the same segment.** Wired-to-wired is
  the reliable pair. The uConsole cannot be the UDP peer while it is on wifi.
- Plug the meshtadpole into the **same switch as james-pc**, not wifi: that gives
  the wired pair this test has been missing.
- A one-packet result proves nothing here. Both nodes broadcast a single NODE_INFO
  at startup, so `rx=0 tx=1` is within the loss this path shows anyway - drive
  sustained traffic through the phone API before reading anything into it.

## What was almost committed on the strength of it

The receive path was briefly changed to join the group on the interface the send
path probes, on the theory that the OS was joining a DOWN `eth0` ahead of the live
`wlan0`. The probe was then measured returning `wlan0` correctly, and an explicit
join on `wlan0` received nothing either - so the theory was wrong and the change
was reverted. The existing comment there, that forcing an interface breaks hosts
whose paths already agree, stands.
