package org.meshtastic.node

import org.meshtastic.node.ble.BleMeshAdvert
import org.meshtastic.proto.Data
import org.meshtastic.proto.MeshPacket
import org.meshtastic.proto.PortNum
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The whole client-node receive chain, against a frame captured off the air.
 *
 * The vector is a real Meshtastic packet: relayed by a Heltec V3 running the BLE-mesh spike
 * firmware, transmitted as a BLE 5 extended advertisement, and captured by a laptop scanning for
 * company ID 0xFFFF. Nothing here is synthetic, which is the point - a hand-built fixture would
 * have agreed with a wrong nonce byte order just as readily as a right one.
 */
class CapturedFrameTest {

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private val capturedPacket = hex(
        "0d2eb0613015ffffffff18322a6ca615a970dddf9ee630f139752e447278ba7fd3f3beb470ded846765a6" +
            "2f47cf7a7058d0c2b8e463e5f15ae41dc32979872c92e8ce09038325bcba85626015083632654ad4e6" +
            "8b2e5e19c4b67a545767b7aa2823bc265c5a2e3fbf2d1c79447e79c4f9c9949f41b8ce6d883bf356e0" +
            "b05043ddb03976a450000c040480258406099ffffffffffffffff017803980121a80101b00101"
    )

    /** The PSK of the channel it was sent on, from that channel's shared URL. */
    private val psk = hex("a9fff91983c66c38abe453d6b3809f2df61e51e40ce5642e2d3c6047d9568d52")

    @Test
    fun `decodes a captured packet`() {
        val pkt = MeshPacket.ADAPTER.decode(capturedPacket)
        assertEquals(0x3061b02eL, pkt.from.toLong() and 0xFFFFFFFFL, "sender")
        assertEquals(0xffffffffL, pkt.to.toLong() and 0xFFFFFFFFL, "broadcast destination")
        assertEquals(0x04050b6eL, pkt.id.toLong() and 0xFFFFFFFFL, "packet id")
        assertEquals(50, pkt.channel, "channel hash hint")
        assertEquals(108, assertNotNull(pkt.encrypted, "ciphertext present").size)
    }

    @Test
    fun `decrypts a captured packet to a position message`() {
        val pkt = MeshPacket.ADAPTER.decode(capturedPacket)
        val plain = ChannelCrypto.transform(
            payload = assertNotNull(pkt.encrypted, "ciphertext present").toByteArray(),
            psk = psk,
            packetId = pkt.id.toLong() and 0xFFFFFFFFL,
            fromNode = pkt.from.toLong() and 0xFFFFFFFFL,
        )
        val data = Data.ADAPTER.decode(plain)
        assertEquals(PortNum.POSITION_APP, data.portnum, "decrypts to a position message")
        assertEquals(36, data.payload.size, "36-byte position payload")
    }

    @Test
    fun `round-trips through the BLE advertisement framing`() {
        val body = BleMeshAdvert.buildManufacturerBody(capturedPacket)
        // flags(3) + len(1) + type(1) + company id(2) + body
        val adv = ByteArray(3 + 1 + 1 + 2 + body.size)
        adv[0] = 2; adv[1] = 0x01; adv[2] = 0x06
        adv[3] = (1 + 2 + body.size).toByte(); adv[4] = 0xFF.toByte()
        adv[5] = 0xFF.toByte(); adv[6] = 0xFF.toByte()
        body.copyInto(adv, 7)

        val extracted = assertNotNull(BleMeshAdvert.extractPacketBytes(adv))
        assertTrue(extracted.contentEquals(capturedPacket), "survives the AD walk unchanged")
    }
}
