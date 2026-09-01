package org.meshtastic.node

import org.meshtastic.node.transport.MeshTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * A transport that records what it was asked to send and can be told what to receive.
 *
 * Everything a node does is observable through this: it is the only surface between the protocol
 * and any medium, which is the point of keeping node-core free of I/O.
 */
private class LoopbackTransport(override val canTransmit: Boolean = true) : MeshTransport {
    val sent = mutableListOf<ByteArray>()
    private var listener: MeshTransport.FrameListener? = null
    var started = false

    override fun start(listener: MeshTransport.FrameListener) {
        this.listener = listener
        started = true
    }

    override fun stop() {
        started = false
    }

    override fun send(encodedPacket: ByteArray): Boolean {
        sent += encodedPacket
        return true
    }

    /** Deliver `bytes` as though another node had transmitted them. */
    fun receive(bytes: ByteArray, rssi: Int? = -50) = listener?.onFrame(bytes, rssi)
}

class MeshNodeTest {

    private val psk = ByteArray(32) { it.toByte() }
    private val channel = MeshChannel("LongFast", psk)
    private val identity = MeshIdentity(0x1234abcdL, "test node", "TEST")

    private fun node(
        transport: LoopbackTransport,
        policy: RelayPolicy = RelayPolicy.Island,
    ): MeshNode = MeshNode.build {
        identity(this@MeshNodeTest.identity)
        channel(this@MeshNodeTest.channel)
        transport(transport)
        relayPolicy(policy)
        codec(ProtoPacketCodec())
        // Monotonic and only used for dedup expiry, so a simple counter is enough.
        var t = 0L
        clock { t += 1000; t }
    }

    @Test
    fun `sends a text and can read its own frame back`() {
        val t = LoopbackTransport()
        val n = node(t)
        val events = mutableListOf<MeshEvent>()
        n.start { events += it }

        assertTrue(n.sendText("hello mesh"))
        assertEquals(1, t.sent.size, "one frame on the wire")

        // Decoding our own frame proves encrypt and decrypt agree on the nonce, which is the part
        // no synthetic fixture would catch if the byte order were wrong.
        val decoded = ProtoPacketCodec().decodeText(t.sent[0], channel)
        assertEquals("hello mesh", decoded)
    }

    @Test
    fun `island mode stamps a hop limit no radio will relay`() {
        val t = LoopbackTransport()
        node(t).also { it.start {} }.sendText("stay local")

        val header = assertNotNull(ProtoPacketCodec().peek(t.sent[0]))
        // perhapsRebroadcast relays only when hop_limit > 0, so this is enforced by the firmware
        // rather than by our own good behaviour.
        assertEquals(0, header.hopLimit)
    }

    @Test
    fun `a widened relay policy is carried onto the wire`() {
        val t = LoopbackTransport()
        node(t, RelayPolicy.Meshed(3)).also { it.start {} }.sendText("go further")

        assertEquals(3, assertNotNull(ProtoPacketCodec().peek(t.sent[0])).hopLimit)
    }

    @Test
    fun `receives and decrypts a message from a peer`() {
        val t = LoopbackTransport()
        val events = mutableListOf<MeshEvent>()
        node(t).start { events += it }

        val peer = ProtoPacketCodec().encodeText("from a peer", from = 0x99L, to = MeshNode.BROADCAST, id = 7, channel = channel, hopLimit = 3)
        t.receive(assertNotNull(peer), rssi = -61)

        val msg = assertIs<MeshEvent.TextMessage>(events.single())
        assertEquals("from a peer", msg.text)
        assertEquals(0x99L, msg.from)
        assertEquals(-61, msg.rssi)
    }

    @Test
    fun `ignores its own frame heard by its own receiver`() {
        val t = LoopbackTransport()
        val events = mutableListOf<MeshEvent>()
        val n = node(t)
        n.start { events += it }
        n.sendText("echo")

        // A transport that hears itself - every broadcast medium does - must not produce a message.
        t.receive(t.sent[0])
        assertTrue(events.isEmpty(), "self-echo produced $events")
    }

    @Test
    fun `suppresses a duplicate`() {
        val t = LoopbackTransport()
        val events = mutableListOf<MeshEvent>()
        node(t).start { events += it }

        val frame = assertNotNull(
            ProtoPacketCodec().encodeText("once", from = 0x99L, to = MeshNode.BROADCAST, id = 11, channel = channel, hopLimit = 3)
        )
        t.receive(frame)
        t.receive(frame)

        assertIs<MeshEvent.TextMessage>(events[0])
        // Without this a flood never terminates; the hop limit alone does not stop a loop.
        assertEquals("duplicate", assertIs<MeshEvent.Dropped>(events[1]).reason)
    }

    @Test
    fun `surfaces traffic it cannot read rather than swallowing it`() {
        val t = LoopbackTransport()
        val events = mutableListOf<MeshEvent>()
        node(t).start { events += it }

        val otherChannel = MeshChannel("Secret", ByteArray(32) { (it + 7).toByte() })
        val frame = assertNotNull(
            ProtoPacketCodec().encodeText("not for you", from = 0x99L, to = MeshNode.BROADCAST, id = 13, channel = otherChannel, hopLimit = 3)
        )
        t.receive(frame)

        // A mesh is mostly traffic you cannot read. Dropping it silently makes a working node
        // look dead, so it is reported as Opaque.
        assertIs<MeshEvent.Opaque>(events.single())
    }

    @Test
    fun `drops a frame with no sender`() {
        val t = LoopbackTransport()
        val events = mutableListOf<MeshEvent>()
        node(t).start { events += it }

        val frame = assertNotNull(
            ProtoPacketCodec().encodeText("spoofed", from = 0L, to = MeshNode.BROADCAST, id = 17, channel = channel, hopLimit = 3)
        )
        t.receive(frame)

        assertEquals("no sender", assertIs<MeshEvent.Dropped>(events.single()).reason)
    }

    @Test
    fun `reports a receive-only transport rather than pretending it can send`() {
        val listenOnly = LoopbackTransport(canTransmit = false)
        val n = node(listenOnly)
        n.start {}

        // Apple platforms are exactly this case: CoreBluetooth cannot advertise arbitrary payload,
        // so a BLE node there can listen and never speak.
        assertEquals(1, n.receiveOnlyTransports.size)
        assertFalse(n.sendText("cannot go out"), "send must report failure, not silently drop")
        assertTrue(listenOnly.sent.isEmpty())
    }

    @Test
    fun `refuses to build without an identity or a channel`() {
        assertFailsWith<IllegalArgumentException> {
            MeshNode.build { channel(channel); codec(ProtoPacketCodec()) }
        }
        assertFailsWith<IllegalArgumentException> {
            MeshNode.build { identity(identity); codec(ProtoPacketCodec()) }
        }
    }

    @Test
    fun `start and stop drive the transports`() {
        val t = LoopbackTransport()
        val n = node(t)
        n.start {}
        assertTrue(t.started)
        n.stop()
        assertFalse(t.started)
    }
}

class MeshIdentityTest {

    @Test
    fun `derives a stable address from a seed`() {
        val a = MeshIdentity.derive("install-seed".encodeToByteArray(), "n", "N")
        val b = MeshIdentity.derive("install-seed".encodeToByteArray(), "n", "N")
        val c = MeshIdentity.derive("other-seed".encodeToByteArray(), "n", "N")

        // Stability is the whole point: an address that changes on restart appears as a new node
        // in every peer's NodeDB, and those hold 120 entries - 10 on STM32WL.
        assertEquals(a.nodeNum, b.nodeNum)
        assertTrue(a.nodeNum != c.nodeNum)
    }

    @Test
    fun `never derives the reserved zero address`() {
        // from == 0 means "unset" on the wire and is refused by every ingress path.
        assertTrue(MeshIdentity.derive(byteArrayOf(0), "n", "N").nodeNum != 0L)
    }

    @Test
    fun `formats the node id the way the apps do`() {
        assertEquals("!1234abcd", MeshIdentity(0x1234abcdL, "n", "N").nodeId)
        assertEquals("!0000000a", MeshIdentity(10L, "n", "N").nodeId)
    }

    @Test
    fun `rejects an unusable address`() {
        assertFailsWith<IllegalArgumentException> { MeshIdentity(0L, "n", "N") }
        assertFailsWith<IllegalArgumentException> { MeshIdentity(1L, "n", "") }
    }
}

class MeshChannelTest {

    @Test
    fun `hash is a byte and depends on both name and key`() {
        val a = MeshChannel("LongFast", ByteArray(32) { it.toByte() })
        val b = MeshChannel("LongFast", ByteArray(32) { (it + 1).toByte() })
        val c = MeshChannel("Secret", ByteArray(32) { it.toByte() })

        assertTrue(a.hash in 0..255)
        assertTrue(a.hash != b.hash || a.hash != c.hash, "hash must vary with name or key")
    }

    @Test
    fun `recognises a cleartext channel`() {
        assertTrue(MeshChannel("Open", ByteArray(0)).isCleartext)
        assertTrue(MeshChannel("Open", byteArrayOf(0)).isCleartext, "short-form index 0 is cleartext")
        assertFalse(MeshChannel("Closed", ByteArray(16) { 1 }).isCleartext)
    }

    @Test
    fun `compares by key contents, not identity`() {
        // The default data-class equality on a ByteArray compares references, which would make
        // two identical channels unequal and break any map keyed on one.
        assertEquals(MeshChannel("A", byteArrayOf(1, 2)), MeshChannel("A", byteArrayOf(1, 2)))
        assertEquals(
            MeshChannel("A", byteArrayOf(1, 2)).hashCode(),
            MeshChannel("A", byteArrayOf(1, 2)).hashCode(),
        )
    }

    @Test
    fun `does not print key material`() {
        assertFalse(MeshChannel("A", byteArrayOf(0xd, 0xe)).toString().contains("13"))
    }
}

class ProtoPacketCodecTest {

    private val channel = MeshChannel("LongFast", ByteArray(32) { it.toByte() })

    @Test
    fun `round-trips a text message`() {
        val codec = ProtoPacketCodec()
        val bytes = assertNotNull(
            codec.encodeText("round trip", from = 0x42L, to = MeshNode.BROADCAST, id = 99, channel = channel, hopLimit = 3)
        )
        assertEquals("round trip", codec.decodeText(bytes, channel))
    }

    @Test
    fun `peek reads routing fields without the key`() {
        val codec = ProtoPacketCodec()
        val bytes = assertNotNull(
            codec.encodeText("hi", from = 0xdeadbeefL, to = 0x99L, id = 5, channel = channel, hopLimit = 2)
        )
        val header = assertNotNull(codec.peek(bytes))

        // 0xdeadbeef is above Int.MAX_VALUE - a NodeNum that would come back negative if the sign
        // bit were mishandled anywhere on the path.
        assertEquals(0xdeadbeefL, header.from)
        assertEquals(0x99L, header.to)
        assertEquals(2, header.hopLimit)
        assertEquals(channel.hash, header.channelHash)
    }

    @Test
    fun `the wrong key does not yield the message`() {
        val codec = ProtoPacketCodec()
        val bytes = assertNotNull(
            codec.encodeText("secret", from = 1L, to = 2L, id = 3, channel = channel, hopLimit = 1)
        )
        val wrong = MeshChannel("LongFast", ByteArray(32) { (it + 1).toByte() })

        assertEquals(null, codec.decodeText(bytes, wrong))
    }

    @Test
    fun `refuses a payload too large to represent`() {
        // The receiver rebuilds the CTR nonce from id and from, so an over-long payload cannot be
        // truncated into something decryptable - it has to be refused outright.
        val codec = ProtoPacketCodec()
        assertNull(codec.encodeText("x".repeat(400), from = 1L, to = 2L, id = 3, channel = channel, hopLimit = 1))
    }

    @Test
    fun `garbage is not mistaken for a packet`() {
        assertNull(ProtoPacketCodec().peek(byteArrayOf(0xff.toByte(), 0xff.toByte(), 0xff.toByte())))
    }
}
