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
import kotlin.test.Test
import kotlin.test.assertIs
import kotlin.test.assertNotNull

private class AckTransport : MeshTransport {
    override val canTransmit: Boolean = true
    val sent = mutableListOf<ByteArray>()
    private val frames = MutableSharedFlow<InboundFrame>(extraBufferCapacity = 16)

    override fun incoming(): Flow<InboundFrame> = frames.asSharedFlow()
    override suspend fun send(encodedPacket: ByteArray): Boolean {
        sent += encodedPacket
        return true
    }

    suspend fun receive(bytes: ByteArray) {
        frames.subscriptionCount.first { it > 0 }
        frames.emit(InboundFrame(bytes, -50))
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class AckTest {

    private val channel = MeshChannel("LongFast", ByteArray(32) { it.toByte() })
    private val codec = ProtoPacketCodec()
    private val us = MeshIdentity(0xAAAA, "us", "US")
    private val peer = 0xBBBBL

    private fun TestScope.node(
        t: AckTransport,
        ourKey: ByteArray? = null,
        peerKey: ByteArray? = null,
    ) = MeshNode(backgroundScope) {
        identity = us
        channels += channel
        transports += t
        codec = this@AckTest.codec
        privateKey = ourKey
        peerPublicKey = { if (it == peer) peerKey else null }
        var clockMs = 0L
        clock = { clockMs += 1000; clockMs }
    }

    @Test
    fun `a directed message can ask to be acknowledged`() = runTest {
        // A directed text is a PKI message, so it needs both keys before it can be sent at all -
        // want_ack rides on a message that exists.
        val ourKeys = PkiCrypto().generateKeyPair()
        val peerKeys = PkiCrypto().generateKeyPair()
        val t = AckTransport()

        node(t, ourKeys.privateKey, peerKeys.publicKey)
            .sendText("please confirm", to = peer, wantAck = true) shouldBe true

        assertNotNull(codec.peek(t.sent.single())).wantAck shouldBe true
    }

    @Test
    fun `a broadcast never asks for acknowledgement`() = runTest {
        val t = AckTransport()
        node(t).sendText("to everyone", wantAck = true)

        // Every hearer replying at once is the classic way to melt a shared channel, so the
        // request is dropped rather than honoured.
        assertNotNull(codec.peek(t.sent.single())).wantAck shouldBe false
    }

    @Test
    fun `receiving a directed packet that wants an ack sends one back`() = runTest {
        val t = AckTransport()
        val n = node(t)
        val incoming = assertNotNull(
            codec.encode(OutboundMessage("confirm me", peer, us.nodeNum, 77, channel, 3, wantAck = true))
        )

        n.events.test {
            t.receive(incoming)
            awaitItem()
        }

        val ack = assertNotNull(codec.peek(t.sent.single()))
        ack.to shouldBe peer
        // Decoding it as the original sender would: the receipt names the packet it confirms.
        val decoded = codec.decode(t.sent.single(), KeyRing(listOf(channel), ourNodeNum = peer))
        assertIs<DecodedPacket.Ack>(decoded).requestId shouldBe 77L
    }

    @Test
    fun `a broadcast that wants an ack is not acknowledged`() = runTest {
        val t = AckTransport()
        val n = node(t)
        val broadcast = assertNotNull(
            codec.encode(OutboundMessage("hi all", peer, MeshNode.BROADCAST, 78, channel, 3, wantAck = true))
        )

        n.events.test {
            t.receive(broadcast)
            awaitItem()
        }

        t.sent.isEmpty() shouldBe true
    }

    @Test
    fun `a packet on a channel we hold no key for cannot be acknowledged`() = runTest {
        val t = AckTransport()
        val n = node(t)
        val foreign = MeshChannel("Secret", ByteArray(32) { (it + 3).toByte() })
        val incoming = assertNotNull(
            codec.encode(OutboundMessage("opaque", peer, us.nodeNum, 79, foreign, 3, wantAck = true))
        )

        n.events.test {
            t.receive(incoming)
            awaitItem()
        }

        // Not a policy choice - a receipt has to be encrypted on the channel it answers, and we
        // have no key for that one. The sender will time out, which is the correct outcome: it
        // reached a node that cannot talk to it.
        t.sent.isEmpty() shouldBe true
    }

    @Test
    fun `a payload we do not model is still acknowledged`() = runTest {
        val t = AckTransport()
        val n = node(t)

        // Telemetry, which this library does not interpret - but it arrived on a channel we hold,
        // and want_ack asks whether it arrived, not whether we understood it.
        val data = org.meshtastic.proto.Data(
            portnum = org.meshtastic.proto.PortNum.TELEMETRY_APP,
            payload = okio.ByteString.of(1, 2, 3),
        )
        val sealed = ChannelCrypto().transform(
            org.meshtastic.proto.Data.ADAPTER.encode(data), channel.psk, packetId = 80, fromNode = peer,
        )
        val packet = org.meshtastic.proto.MeshPacket(
            from = peer.toInt(), to = us.nodeNum.toInt(), id = 80, channel = channel.hash,
            hop_limit = 3, hop_start = 3, want_ack = true, encrypted = okio.ByteString.of(*sealed),
        )

        n.events.test {
            t.receive(org.meshtastic.proto.MeshPacket.ADAPTER.encode(packet))
            awaitItem()
        }

        t.sent.size shouldBe 1
        val decoded = codec.decode(t.sent.single(), KeyRing(listOf(channel), ourNodeNum = peer))
        assertIs<DecodedPacket.Ack>(decoded).requestId shouldBe 80L
    }

    @Test
    fun `an incoming ack is surfaced as delivery`() = runTest {
        val t = AckTransport()
        val n = node(t)
        val ack = assertNotNull(
            codec.encodeAck(toNodeNum = us.nodeNum, requestId = 4242, from = peer, channel = channel, id = 5, hopLimit = 3)
        )

        n.events.test {
            t.receive(ack)
            val delivered = assertIs<MeshEvent.Delivered>(awaitItem())
            delivered.from shouldBe peer
            delivered.requestId shouldBe 4242L
        }
    }

    @Test
    fun `an ack is readable without any key exchange`() = runTest {
        // Channel-encrypted, never PKI: a sender must be able to read the receipt whether or not
        // the two have exchanged keys, which is why ROUTING_APP stays out of the PKI path.
        val ack = assertNotNull(
            codec.encodeAck(toNodeNum = us.nodeNum, requestId = 11, from = peer, channel = channel, id = 6, hopLimit = 3)
        )
        val decoded = codec.decode(ack, KeyRing(listOf(channel), ourNodeNum = us.nodeNum, ourPrivateKey = null))

        assertIs<DecodedPacket.Ack>(decoded).requestId shouldBe 11L
    }
}
