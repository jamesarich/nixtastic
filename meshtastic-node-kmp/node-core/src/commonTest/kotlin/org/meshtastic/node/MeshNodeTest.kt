package org.meshtastic.node

import app.cash.turbine.test
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.meshtastic.node.transport.InboundFrame
import org.meshtastic.node.transport.MeshTransport
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertIs
import kotlin.test.assertNotNull

/**
 * A transport with the medium replaced by a flow the test drives.
 *
 * It is the only surface between the protocol and any medium, which is what keeps node-core free of
 * I/O and lets every behaviour below be exercised without a socket or a radio.
 */
private class FakeTransport(override val canTransmit: Boolean = true) : MeshTransport {
    val sent = mutableListOf<ByteArray>()
    private val frames = MutableSharedFlow<InboundFrame>(extraBufferCapacity = 16)

    override fun incoming(): Flow<InboundFrame> = frames.asSharedFlow()

    override suspend fun send(encodedPacket: ByteArray): Boolean {
        sent += encodedPacket
        return true
    }

    suspend fun receive(bytes: ByteArray, rssi: Int? = -50) {
        // Wait for the node to actually be collecting. events is shared with WhileSubscribed, so
        // subscription happens asynchronously after .test{} enters - emitting before that would
        // drop the frame into a flow nobody is listening to and fail the test for the wrong reason.
        frames.subscriptionCount.first { it > 0 }
        frames.emit(InboundFrame(bytes, rssi))
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MeshNodeTest {

    private val psk = ByteArray(32) { it.toByte() }
    private val channel = MeshChannel("LongFast", psk)
    private val identity = MeshIdentity(0x1234abcd, "test node", "TEST")
    private val codec = ProtoPacketCodec()

    // backgroundScope, not the test scope: a node's events flow is shared for the lifetime of its
    // scope by design, so binding it to the test scope would leave runTest waiting forever on a
    // coroutine that is behaving correctly. backgroundScope is cancelled when the test ends.
    private fun TestScope.node(
        transport: FakeTransport,
        policy: RelayPolicy = RelayPolicy.Island,
        privateKey: ByteArray? = null,
        peerKey: (Long) -> ByteArray? = { null },
    ) = MeshNode(backgroundScope) {
        identity = this@MeshNodeTest.identity
        channels += this@MeshNodeTest.channel
        transports += transport
        relayPolicy = policy
        codec = this@MeshNodeTest.codec
        this.privateKey = privateKey
        peerPublicKey = peerKey
        var t = 0L
        clock = { t += 1000; t }
        random = Random(1234) // deterministic packet ids and nonces
    }

    private suspend fun peerFrame(text: String, from: Long = 0x99, id: Long = 7, hopLimit: Int = 3) =
        assertNotNull(
            codec.encode(OutboundMessage(text, from, MeshNode.BROADCAST, id, channel, hopLimit))
        )

    @Test
    fun `sends a text that decodes back to the same message`() = runTest {
        val t = FakeTransport()
        val n = node(t)

        n.sendText("hello mesh") shouldBe true
        t.sent.size shouldBe 1

        // Round-tripping our own frame proves encrypt and decrypt agree on the nonce, which is the
        // part no hand-built fixture would catch if the byte order were wrong.
        val decoded = codec.decode(t.sent[0], KeyRing(listOf(channel), identity.nodeNum))
        assertIs<DecodedPacket.Text>(decoded).text shouldBe "hello mesh"
    }

    @Test
    fun `island mode stamps a hop limit no radio will relay`() = runTest {
        val t = FakeTransport()
        node(t).sendText("stay local")

        // perhapsRebroadcast relays only when hop_limit > 0, so this is enforced by shipped
        // firmware rather than by our own good behaviour.
        assertNotNull(codec.peek(t.sent[0])).hopLimit shouldBe 0
    }

    @Test
    fun `a widened relay policy is carried onto the wire`() = runTest {
        val t = FakeTransport()
        node(t, RelayPolicy.Meshed(3)).sendText("go further")

        assertNotNull(codec.peek(t.sent[0])).hopLimit shouldBe 3
    }

    @Test
    fun `receives and decrypts a message from a peer`() = runTest {
        val t = FakeTransport()
        val n = node(t)

        n.events.test {
            t.receive(peerFrame("from a peer"), rssi = -61)

            val msg = assertIs<MeshEvent.TextMessage>(awaitItem())
            msg.text shouldBe "from a peer"
            msg.from shouldBe 0x99L
            msg.rssi shouldBe -61
            msg.direct shouldBe false
        }
    }

    @Test
    fun `ignores its own frame heard by its own receiver`() = runTest {
        val t = FakeTransport()
        val n = node(t)

        n.events.test {
            n.sendText("echo")
            // Every broadcast medium hears itself; that must not surface as an incoming message.
            t.receive(t.sent[0])
            expectNoEvents()
        }
    }

    @Test
    fun `suppresses a duplicate`() = runTest {
        val t = FakeTransport()
        val n = node(t)

        n.events.test {
            val frame = peerFrame("once", id = 11)
            t.receive(frame)
            t.receive(frame)

            assertIs<MeshEvent.TextMessage>(awaitItem())
            // Without this a flood never terminates; the hop limit alone does not stop a loop.
            assertIs<MeshEvent.Dropped>(awaitItem()).reason shouldBe MeshEvent.DropReason.DUPLICATE
        }
    }

    @Test
    fun `surfaces traffic it cannot read rather than swallowing it`() = runTest {
        val t = FakeTransport()
        val n = node(t)
        val other = MeshChannel("Secret", ByteArray(32) { (it + 7).toByte() })

        n.events.test {
            t.receive(assertNotNull(codec.encode(OutboundMessage("not for you", 0x99, MeshNode.BROADCAST, 13, other, 3))))

            // A mesh is mostly traffic you cannot read. Silence would make a working node look dead.
            assertIs<MeshEvent.Opaque>(awaitItem())
        }
    }

    @Test
    fun `drops a frame with no sender`() = runTest {
        val t = FakeTransport()
        val n = node(t)

        n.events.test {
            t.receive(peerFrame("spoofed", from = 0, id = 17))
            assertIs<MeshEvent.Dropped>(awaitItem()).reason shouldBe MeshEvent.DropReason.NO_SENDER
        }
    }

    @Test
    fun `reports a receive-only transport rather than pretending it can send`() = runTest {
        val listenOnly = FakeTransport(canTransmit = false)
        val n = node(listenOnly)

        // Apple platforms are exactly this: CoreBluetooth cannot advertise arbitrary payload, so a
        // BLE node there can listen and never speak.
        n.receiveOnlyTransports.size shouldBe 1
        n.sendText("cannot go out") shouldBe false
        listenOnly.sent.isEmpty() shouldBe true
    }

    @Test
    fun `a direct message needs both keys and is readable only by its recipient`() = runTest {
        val pki = PkiCrypto()
        val us = pki.generateKeyPair()
        val peer = pki.generateKeyPair()
        val peerNum = 0x99L

        val t = FakeTransport()
        val n = node(t, privateKey = us.privateKey, peerKey = { if (it == peerNum) peer.publicKey else null })

        n.sendText("private", to = peerNum) shouldBe true

        // The peer reads it as a direct message...
        val asPeer = codec.decode(
            t.sent[0],
            KeyRing(listOf(channel), ourNodeNum = peerNum, ourPrivateKey = peer.privateKey) { us.publicKey },
        )
        assertIs<DecodedPacket.Text>(asPeer).let {
            it.text shouldBe "private"
            it.direct shouldBe true
        }

        // ...and someone holding only the channel PSK does not, which is the entire point.
        val asBystander = codec.decode(t.sent[0], KeyRing(listOf(channel), ourNodeNum = 0x77))
        assertIs<DecodedPacket.Unreadable>(asBystander)
    }

    @Test
    fun `a direct message is refused when the peer key is unknown`() = runTest {
        val us = PkiCrypto().generateKeyPair()
        val t = FakeTransport()
        val n = node(t, privateKey = us.privateKey, peerKey = { null })

        // The firmware fails the send rather than falling back to channel encryption, because
        // falling back would leak a private message to everyone holding the PSK.
        n.sendText("private", to = 0x99) shouldBe false
        t.sent.isEmpty() shouldBe true
    }

    @Test
    fun `refuses to build without an identity or a channel`() = runTest {
        val thrownWithoutIdentity =
            runCatching { MeshNode(backgroundScope) { channels += channel } }.exceptionOrNull()
        val thrownWithoutChannel =
            runCatching { MeshNode(backgroundScope) { identity = this@MeshNodeTest.identity } }.exceptionOrNull()

        assertIs<IllegalArgumentException>(thrownWithoutIdentity)
        assertIs<IllegalArgumentException>(thrownWithoutChannel)
    }
}
