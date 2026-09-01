package org.meshtastic.node

import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class RelayPolicyTest {

    @Test
    fun `island is the default and cannot be relayed`() {
        RelayPolicy.Island.hopLimit shouldBe 0
    }

    @Test
    fun `a meshed policy must name a hop limit the wire can carry`() {
        RelayPolicy.Meshed(3).hopLimit shouldBe 3
        assertFailsWith<IllegalArgumentException> { RelayPolicy.Meshed(0) }
        assertFailsWith<IllegalArgumentException> { RelayPolicy.Meshed(RelayPolicy.HOP_MAX + 1) }
    }
}

class PacketHistoryTest {

    @Test
    fun `suppresses duplicates and forgets them after expiry`() {
        val history = PacketHistory(expiryMs = 1000)

        history.wasSeenRecently(from = 1, id = 7, nowMs = 0) shouldBe false
        history.wasSeenRecently(from = 1, id = 7, nowMs = 10) shouldBe true
        history.wasSeenRecently(from = 2, id = 7, nowMs = 10) shouldBe false
        history.wasSeenRecently(from = 1, id = 7, nowMs = 5000) shouldBe false
    }

    @Test
    fun `stays bounded under sustained traffic`() {
        val history = PacketHistory(capacity = 4, expiryMs = Long.MAX_VALUE / 2)
        repeat(20) { history.wasSeenRecently(from = it.toLong(), id = 1, nowMs = it.toLong()) }

        (history.size <= 4) shouldBe true
    }
}

class MeshFrameHeaderTest {

    @Test
    fun `round-trips with its flag packing`() {
        val header = MeshFrameHeader(
            to = 0xFFFFFFFF, from = 0x3061b02e, id = 0x04050b6e,
            flags = 3 or MeshFrameHeader.WANT_ACK_MASK or (5 shl MeshFrameHeader.HOP_START_SHIFT),
            channelHash = 50, nextHop = 0x2e, relayNode = 0x11,
        )
        val decoded = assertNotNull(MeshFrameHeader.decode(header.encode()))

        decoded shouldBe header
        decoded.hopLimit shouldBe 3
        decoded.hopStart shouldBe 5
        decoded.wantAck shouldBe true
        decoded.viaMqtt shouldBe false
        header.encode().size shouldBe MeshFrameHeader.SIZE
    }

    @Test
    fun `rejects a short buffer`() {
        assertNull(MeshFrameHeader.decode(ByteArray(MeshFrameHeader.SIZE - 1)))
    }
}

class MeshIdentityTest {

    @Test
    fun `derives a stable address from a seed`() {
        val a = MeshIdentity.derive("install-seed".encodeToByteArray(), "n", "N")
        val b = MeshIdentity.derive("install-seed".encodeToByteArray(), "n", "N")
        val c = MeshIdentity.derive("other-seed".encodeToByteArray(), "n", "N")

        // Stability is the point: an address that changes on restart appears as a new node in every
        // peer's NodeDB, and those hold 120 entries - 10 on STM32WL.
        a.nodeNum shouldBe b.nodeNum
        a.nodeNum shouldNotBe c.nodeNum
    }

    @Test
    fun `never derives the reserved zero address`() {
        MeshIdentity.derive(byteArrayOf(0), "n", "N").nodeNum shouldNotBe 0L
    }

    @Test
    fun `formats the node id the way the apps do`() {
        MeshIdentity(0x1234abcd, "n", "N").nodeId shouldBe "!1234abcd"
        MeshIdentity(10, "n", "N").nodeId shouldBe "!0000000a"
    }

    @Test
    fun `rejects an unusable identity`() {
        assertFailsWith<IllegalArgumentException> { MeshIdentity(0, "n", "N") }
        assertFailsWith<IllegalArgumentException> { MeshIdentity(1, "n", "") }
    }
}

class MeshChannelTest {

    @Test
    fun `hash is a byte and depends on both name and key`() {
        val a = MeshChannel("LongFast", ByteArray(32) { it.toByte() })
        val b = MeshChannel("LongFast", ByteArray(32) { (it + 1).toByte() })
        val c = MeshChannel("Secret", ByteArray(32) { it.toByte() })

        (a.hash in 0..255) shouldBe true
        (a.hash != b.hash || a.hash != c.hash) shouldBe true
    }

    @Test
    fun `recognises a cleartext channel`() {
        MeshChannel("Open", ByteArray(0)).isCleartext shouldBe true
        MeshChannel("Open", byteArrayOf(0)).isCleartext shouldBe true
        MeshChannel("Closed", ByteArray(16) { 1 }).isCleartext shouldBe false
    }

    @Test
    fun `compares by key contents rather than identity`() {
        // Default data-class equality on a ByteArray compares references, which would make two
        // identical channels unequal and break any map keyed on one.
        MeshChannel("A", byteArrayOf(1, 2)) shouldBe MeshChannel("A", byteArrayOf(1, 2))
        MeshChannel("A", byteArrayOf(1, 2)).hashCode() shouldBe MeshChannel("A", byteArrayOf(1, 2)).hashCode()
    }

    @Test
    fun `does not print key material`() {
        MeshChannel("A", byteArrayOf(0xd, 0xe)).toString().contains("13") shouldBe false
    }
}
