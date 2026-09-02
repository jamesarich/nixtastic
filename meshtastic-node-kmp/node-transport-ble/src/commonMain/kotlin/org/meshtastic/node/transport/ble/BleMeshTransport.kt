package org.meshtastic.node.transport.ble

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.mapNotNull
import org.meshtastic.node.ble.BleMeshAdvert
import org.meshtastic.node.transport.InboundFrame
import org.meshtastic.node.transport.MeshTransport

/**
 * Mesh over connectionless BLE extended advertisements.
 *
 * The transport this library exists for: unlike UDP it needs no access point and no infrastructure
 * at all, which is the situation a mesh is actually for. Frames match what the firmware's
 * `BLEMeshHandler` emits - a whole encoded `MeshPacket` inside manufacturer data.
 *
 * [canTransmit] is the platform's answer, not ours: Android can advertise, Apple cannot, and the
 * JVM has no BLE at all. A node that holds only receive-capable transports reports that through
 * `MeshNode.receiveOnlyTransports`, and `sendText` returns false rather than silently dropping.
 *
 * One constraint worth knowing before shipping: iOS can only scan in the background while filtering
 * by *service UUID*, so manufacturer data is invisible to a backgrounded app. The fix belongs in
 * the on-air format - service data under an assigned 16-bit UUID - and needs agreeing with the
 * firmware rather than working around here.
 */
public class BleMeshTransport(
    private val radio: BleMeshRadio = bleMeshRadio(),
) : MeshTransport {

    override val canTransmit: Boolean get() = radio.canTransmit

    override fun incoming(): Flow<InboundFrame> = radio.advertisements().mapNotNull { advertisement ->
        BleMeshAdvert.extractPacketFromBody(advertisement.body)
            ?.let { InboundFrame(it, advertisement.rssi) }
    }

    override suspend fun send(encodedPacket: ByteArray): Boolean {
        // The single-advertisement budget. Fragmentation is not an option the firmware offers, so
        // an over-long packet is refused rather than truncated into something undecodable.
        if (encodedPacket.size > BleMeshAdvert.MAX_PACKET_LEN) return false
        return radio.advertise(BleMeshAdvert.buildManufacturerBody(encodedPacket))
    }
}
