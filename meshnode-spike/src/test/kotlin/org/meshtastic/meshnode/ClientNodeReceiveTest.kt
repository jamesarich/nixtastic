package org.meshtastic.meshnode

import org.meshtastic.proto.Data
import org.meshtastic.proto.MeshPacket
import org.meshtastic.proto.PortNum
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The full client-node receive chain, against a frame captured off the air.
 *
 * The vector below is a real Meshtastic packet: it was relayed by a Heltec V3 running the
 * BLE-mesh spike firmware, transmitted as a BLE 5 extended advertisement, and captured by a laptop
 * scanning for company ID 0xFFFF. Nothing here is synthetic — this is what a client node actually
 * has to handle.
 */
class ClientNodeReceiveTest {

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    /** The encoded MeshPacket carried in the advertisement's manufacturer data. */
    private val capturedPacket = hex(
        "0d2eb0613015ffffffff18322a6ca615a970dddf9ee630f139752e447278ba7fd3f3beb470ded846765a6" +
            "2f47cf7a7058d0c2b8e463e5f15ae41dc32979872c92e8ce09038325bcba85626015083632654ad4e6" +
            "8b2e5e19c4b67a545767b7aa2823bc265c5a2e3fbf2d1c79447e79c4f9c9949f41b8ce6d883bf356e0" +
            "b05043ddb03976a450000c040480258406099ffffffffffffffff017803980121a80101b00101"
    )

    /** The PSK for the channel this frame was sent on, from its shared channel URL. */
    private val psk = hex("a9fff91983c66c38abe453d6b3809f2df61e51e40ce5642e2d3c6047d9568d52")

    @Test
    fun `decodes a captured packet`() {
        val pkt = MeshPacket.ADAPTER.decode(capturedPacket)
        assertEquals(0x3061b02eL, pkt.from.toLong() and 0xFFFFFFFFL, "sender")
        assertEquals(0xffffffffL, pkt.to.toLong() and 0xFFFFFFFFL, "broadcast destination")
        assertEquals(0x04050b6eL, pkt.id.toLong() and 0xFFFFFFFFL, "packet id")
        assertEquals(50, pkt.channel, "channel hash hint")
        assertEquals(108, assertNotNull(pkt.encrypted, "ciphertext present").size, "108-byte ciphertext")
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
    fun `builds the CTR nonce the firmware builds`() {
        // packet_id u64 LE, then from u32 LE, then a zero u32 block counter.
        val nonce = ChannelCrypto.buildNonce(packetId = 0x04050b6eL, fromNode = 0x3061b02eL)
        assertEquals("6e0b0504000000002eb0613000000000", nonce.joinToString("") { "%02x".format(it) })
    }

    @Test
    fun `resolves the short-form psk index the way the firmware does`() {
        // 0 means cleartext; 1 is the default PSK unchanged; n>1 increments its last byte by n-1.
        assertEquals(null, ChannelCrypto.resolveKey(byteArrayOf(0)))
        val one = assertNotNull(ChannelCrypto.resolveKey(byteArrayOf(1)))
        val three = assertNotNull(ChannelCrypto.resolveKey(byteArrayOf(3)))
        assertEquals(16, one.size)
        assertEquals((one[15] + 2).toByte(), three[15])
        // A raw key is used as-is.
        assertTrue(ChannelCrypto.resolveKey(psk).contentEquals(psk))
    }

    @Test
    fun `round-trips through the BLE advertisement framing`() {
        val body = BleMeshAdvert.buildManufacturerBody(capturedPacket)
        // Rebuild the full AD the firmware emits: flags structure, then manufacturer data.
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
