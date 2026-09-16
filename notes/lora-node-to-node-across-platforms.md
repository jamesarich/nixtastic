# Two node-kmp nodes talk over LoRa, on different platforms and backends

Proven on the bench 2026-09-15. Not a node-to-radio test: both ends are
`meshnode-headless`, so this exercises node-kmp's own LoRa transmit and receive
path in both directions.

| node | host | backend | radio |
| --- | --- | --- | --- |
| `pcbench` | james-pc, x86-64 | CH341 over libusb | SX1261 on a USB stick |
| `uconsole` | uConsole, aarch64 Debian | spidev + libgpiod | SX1262 on `/dev/spidev1.0` |

Both tuned identically without being told to: `SX1261 V2D 2D02 tuned 906.875 MHz
LongFast US slot 19/104 power 10 dBm`.

Each run announces NODE_INFO once at startup, so whichever node is already
listening is the one that hears it. Running it both ways covers both directions:

| start order | result |
| --- | --- |
| uConsole first | uConsole decoded `peer[lora] !a8a9102b pcbench` |
| james-pc first | james-pc decoded `peer[lora] !c0acf107 uconsole2` |

Both also decoded the live `!f2775c7e olm3sh seeed Solar` node, so the link is
not a two-node curiosity - it is the public LongFast channel.

## The invocation the uConsole needs

The pinout is the vendor's, not a guess - see the `uconsole-lora-rig` memory for
how it was measured, and for the `gpio=25=op,dh` line `config.txt` needs first.

```
MESH_TRANSPORTS=lora MESH_LORA_REGION=US \
MESH_LORA_SPIDEV=/dev/spidev1.0 \
MESH_LORA_GPIO_BUSY=24 MESH_LORA_GPIO_RESET=25 MESH_LORA_GPIO_DIO1=26 \
MESH_LORA_TCXO_VOLTS=1.8 MESH_LORA_DIO2_RF_SWITCH=true \
java -jar meshnode-headless.jar
```

The availability fix landed today shows here too: this jar reports
`Ready` then `Active` with no Unavailable between, on both hosts and both
backends.
