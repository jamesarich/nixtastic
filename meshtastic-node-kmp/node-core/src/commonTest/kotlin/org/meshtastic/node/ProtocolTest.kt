package org.meshtastic.node

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Pure protocol behaviour, with no platform or I/O involved. */
class ProtocolTest {

    @Test
    fun `builds the CTR nonce the firmware builds`() {
        val nonce = ChannelCrypto.buildNonce(packetId = 0x04050b6eL, fromNode = 0x3061b02eL)
        assertEquals("6e0b0504000000002eb0613000000000", nonce.joinToString("") { b ->
            val v = b.toInt() and 0xFF
            "0123456789abcdef"[v ushr 4].toString() + "0123456789abcdef"[v and 0xF]
        })
    }

    @Test
    fun `resolves the short-form psk index the way the firmware does`() {
        assertNull(ChannelCrypto.resolveKey(byteArrayOf(0)), "index 0 is cleartext")
        assertNull(ChannelCrypto.resolveKey(ByteArray(0)), "empty psk is cleartext")
        val one = assertNotNull(ChannelCrypto.resolveKey(byteArrayOf(1)))
        val three = assertNotNull(ChannelCrypto.resolveKey(byteArrayOf(3)))
        assertEquals(16, one.size)
        assertEquals((one[15] + 2).toByte(), three[15], "index n increments the last byte by n-1")
        val raw = ByteArray(32) { it.toByte() }
        assertTrue(assertNotNull(ChannelCrypto.resolveKey(raw)).contentEquals(raw), "a raw key is used as-is")
    }

    @Test
    fun `island mode is the default and cannot be relayed`() {
        assertEquals(0, RelayPolicy.Island.hopLimit, "hop_limit 0 means no radio will relay it")
        assertEquals(3, RelayPolicy.Meshed(3).hopLimit)
        assertFailsWith<IllegalArgumentException> { RelayPolicy.Meshed(0) }
        assertFailsWith<IllegalArgumentException> { RelayPolicy.Meshed(8) }
    }

    @Test
    fun `packet history suppresses duplicates and expires them`() {
        val history = PacketHistory(expiryMs = 1000)
        assertFalse(history.wasSeenRecently(from = 1, id = 7, nowMs = 0), "first sighting")
        assertTrue(history.wasSeenRecently(from = 1, id = 7, nowMs = 10), "duplicate")
        assertFalse(history.wasSeenRecently(from = 2, id = 7, nowMs = 10), "different sender")
        assertFalse(history.wasSeenRecently(from = 1, id = 7, nowMs = 5000), "expired, so seen afresh")
    }

    @Test
    fun `packet history is bounded`() {
        val history = PacketHistory(capacity = 4, expiryMs = Long.MAX_VALUE / 2)
        repeat(20) { history.wasSeenRecently(from = it.toLong(), id = 1, nowMs = it.toLong()) }
        assertTrue(history.size <= 4, "stays within capacity, was ${history.size}")
    }

    @Test
    fun `frame header round-trips with its flag packing`() {
        val header = MeshFrameHeader(
            to = 0xFFFFFFFFL, from = 0x3061b02eL, id = 0x04050b6eL,
            flags = 3 or MeshFrameHeader.WANT_ACK_MASK or (5 shl MeshFrameHeader.HOP_START_SHIFT),
            channelHash = 50, nextHop = 0x2e, relayNode = 0x11,
        )
        val decoded = assertNotNull(MeshFrameHeader.decode(header.encode()))
        assertEquals(header, decoded)
        assertEquals(3, decoded.hopLimit)
        assertEquals(5, decoded.hopStart)
        assertTrue(decoded.wantAck)
        assertFalse(decoded.viaMqtt)
        assertEquals(MeshFrameHeader.SIZE, header.encode().size)
    }

    @Test
    fun `frame header rejects a short buffer`() {
        assertNull(MeshFrameHeader.decode(ByteArray(MeshFrameHeader.SIZE - 1)))
    }
}
