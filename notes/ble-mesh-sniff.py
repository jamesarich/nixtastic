"""Scan for Meshtastic BLE-mesh advertisements and decode them.

Doubles as the smallest possible client-side receiver: everything below the
`manufacturer_data` lookup is exactly what a Kotlin client node would have to do.
"""

import asyncio
import sys

from bleak import BleakScanner
from meshtastic.protobuf import mesh_pb2

COMPANY_ID = 0xFFFF
PROTO_VERSION = 1

seen = {}


def handle(device, adv):
    blob = adv.manufacturer_data.get(COMPANY_ID)
    if not blob or len(blob) < 2:
        return
    if blob[0] != PROTO_VERSION:
        return

    payload = blob[1:]
    pkt = mesh_pb2.MeshPacket()
    try:
        pkt.ParseFromString(payload)
    except Exception as exc:  # noqa: BLE001
        print(f"  !! undecodable {len(payload)}B from {device.address}: {exc}")
        return

    # A frame with no sender, or one that decodes to nothing, is not ours.
    if pkt.id == 0 and pkt.__getattribute__("from") == 0:
        return

    key = (getattr(pkt, "from"), pkt.id)
    if key in seen:
        seen[key] += 1
        return
    seen[key] = 1

    print(
        f"  MESH ADV  from=0x{getattr(pkt, 'from'):08x} to=0x{pkt.to:08x} "
        f"id=0x{pkt.id:08x} ch={pkt.channel} hop={pkt.hop_limit}/{pkt.hop_start} "
        f"enc={len(pkt.encrypted)}B transport={pkt.transport_mechanism} "
        f"rssi={adv.rssi} via={device.address}"
    )
    print(f"    VECTOR adv_payload={payload.hex()}")
    sys.stdout.flush()


async def main(seconds: float):
    print(f"scanning {seconds}s for company 0x{COMPANY_ID:04x} manufacturer data...")
    scanner = BleakScanner(detection_callback=handle)
    await scanner.start()
    await asyncio.sleep(seconds)
    await scanner.stop()
    print(f"done. distinct mesh frames: {len(seen)}, total adverts: {sum(seen.values())}")


asyncio.run(main(float(sys.argv[1]) if len(sys.argv) > 1 else 30.0))
