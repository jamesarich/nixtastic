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
import kotlin.test.assertNull

private class RelayTransport(override val canTransmit: Boolean = true) : MeshTransport {
    val sent = mutableListOf<ByteArray>()
    private val frames = MutableSharedFlow<InboundFrame>(extraBufferCapacity = 16)

    override fun incoming(): Flow<InboundFrame> = frames.asSharedFlow()
    override suspend fun send(encodedPacket: ByteArray): Boolean {
        sent += encodedPacket
        return true
    }

    suspend fun receive(bytes: ByteArray, rssi: Int? = -50) {
        frames.subscriptionCount.first { it > 0 }
        frames.emit(InboundFrame(bytes, rssi))
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class RelayTest {

    private val channel = MeshChannel("LongFast", ByteArray(32) { it.toByte() })
    private val codec = ProtoPacketCodec()
    private val us = MeshIdentity(0x1111, "relay", "RLY")

    private fun TestScope.node(t: RelayTransport, policy: RelayPolicy) = MeshNode(backgroundScope) {
        identity = us
        channels += channel
        transports += t
        relayPolicy = policy
        codec = this@RelayTest.codec
        var clockMs = 0L
        clock = { clockMs += 1000; clockMs }
        random = Random(7)
    }

    private suspend fun frameFrom(from: Long, id: Long, hopLimit: Int, text: String = "passing through") =
        assertNotNull(codec.encode(OutboundMessage(text, from, MeshNode.BROADCAST, id, channel, hopLimit)))

    @Test
    fun `a meshed node forwards a packet it cannot read`() = runTest {
        val t = RelayTransport()
        val n = node(t, RelayPolicy.Meshed(3))
        // A channel we hold no key for: the node cannot read this, and must forward it anyway.
        val foreign = MeshChannel("Secret", ByteArray(32) { (it + 9).toByte() })
        val frame = assertNotNull(
            codec.encode(OutboundMessage("opaque", 0x2222, MeshNode.BROADCAST, 5, foreign, hopLimit = 3))
        )

        n.events.test {
            t.receive(frame)
            assertIs<MeshEvent.Relayed>(awaitItem())
        }

        t.sent.size shouldBe 1
        // Forwarding is what makes this a mesh rather than a set of listeners; needing the key
        // would make it impossible, and hop_limit is plaintext precisely so it is not needed.
        assertNotNull(codec.peek(t.sent[0])).hopLimit shouldBe 2
    }

    @Test
    fun `an island node forwards nothing`() = runTest {
        val t = RelayTransport()
        val n = node(t, RelayPolicy.Island)

        n.events.test {
            t.receive(frameFrom(0x2222, 5, hopLimit = 3))
            awaitItem() // the message itself
        }

        t.sent.isEmpty() shouldBe true
    }

    @Test
    fun `an exhausted packet is not forwarded`() = runTest {
        val t = RelayTransport()
        val n = node(t, RelayPolicy.Meshed(3))

        n.events.test {
            // hop_limit 0 means every radio has already declined to relay it; so do we, or the
            // packet would circulate with nothing left to stop it.
            t.receive(frameFrom(0x2222, 6, hopLimit = 0))
            awaitItem()
        }

        t.sent.isEmpty() shouldBe true
    }

    @Test
    fun `a packet addressed to us is not forwarded onward`() = runTest {
        val t = RelayTransport()
        val n = node(t, RelayPolicy.Meshed(3))
        val toUs = assertNotNull(
            codec.encode(OutboundMessage("yours", 0x2222, us.nodeNum, 8, channel, hopLimit = 3))
        )

        n.events.test {
            t.receive(toUs)
            awaitItem()
        }

        t.sent.isEmpty() shouldBe true
    }

    @Test
    fun `a duplicate is neither surfaced nor forwarded twice`() = runTest {
        val t = RelayTransport()
        val n = node(t, RelayPolicy.Meshed(3))
        val frame = frameFrom(0x2222, 9, hopLimit = 3)

        n.events.test {
            t.receive(frame)
            awaitItem()
            t.receive(frame)
            assertIs<MeshEvent.Dropped>(awaitItem()).reason shouldBe MeshEvent.DropReason.DUPLICATE
        }

        // One forward, not two: this is what stops a flood amplifying itself.
        t.sent.size shouldBe 1
    }

    @Test
    fun `forwarding stamps us as the relay`() = runTest {
        val t = RelayTransport()
        val n = node(t, RelayPolicy.Meshed(3))

        n.events.test {
            t.receive(frameFrom(0x2222, 10, hopLimit = 3))
            awaitItem()
        }

        // The wire carries only the low byte of the relayer's NodeNum - a next-hop hint, and the
        // firmware is explicit that it is not an identity.
        val relayed = ProtoPacketCodec().forForwarding(t.sent[0], 0)
        assertNotNull(relayed)
    }

    @Test
    fun `forForwarding refuses an exhausted packet and needs no key`() = runTest {
        val exhausted = frameFrom(0x2222, 11, hopLimit = 0)
        assertNull(codec.forForwarding(exhausted, 0x1111))

        val live = frameFrom(0x2222, 12, hopLimit = 2)
        val forwarded = assertNotNull(codec.forForwarding(live, 0x1111))
        assertNotNull(codec.peek(forwarded)).hopLimit shouldBe 1
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class NodeDirectoryTest {

    @Test
    fun `records presence separately from identity`() {
        val dir = NodeDirectory()
        dir.heard(0x99, nowMs = 100, rssi = -40)

        val peer = assertNotNull(dir.get(0x99))
        peer.lastHeardMs shouldBe 100
        peer.rssi shouldBe -40
        // Hearing a node proves it exists; it says nothing about who it is.
        assertNull(peer.longName)
    }

    @Test
    fun `learns identity and the key that makes direct messages possible`() {
        val dir = NodeDirectory()
        val key = ByteArray(32) { it.toByte() }
        dir.learn(0x99, nowMs = 1, longName = "bob", shortName = "BOB", publicKey = key)

        dir.publicKeyOf(0x99)?.contentEquals(key) shouldBe true
        assertNotNull(dir.get(0x99)).longName shouldBe "bob"
    }

    @Test
    fun `never forgets a key because a later packet omitted it`() {
        val dir = NodeDirectory()
        val key = ByteArray(32) { 7 }
        dir.learn(0x99, 1, publicKey = key)
        dir.learn(0x99, 2, longName = "renamed", publicKey = null)

        // An absent field means "not carried", not "cleared" - dropping the key would silently
        // break direct messages to that peer.
        dir.publicKeyOf(0x99)?.contentEquals(key) shouldBe true
        assertNotNull(dir.get(0x99)).longName shouldBe "renamed"
    }

    @Test
    fun `evicts the least recently heard once full`() {
        val dir = NodeDirectory(capacity = 3)
        repeat(5) { dir.heard(it.toLong() + 1, nowMs = it.toLong()) }

        dir.size shouldBe 3
        // The cap mirrors the firmware's 120 - 10 on STM32WL - because a client that grew without
        // bound would teach every radio that hears it to evict real peers.
        assertNull(dir.get(1))
        assertNotNull(dir.get(5))
    }

    @Test
    fun `re-hearing a peer keeps it from being evicted`() {
        val dir = NodeDirectory(capacity = 2)
        dir.heard(1, 0)
        dir.heard(2, 1)
        dir.heard(1, 2) // refreshed, so 2 is now the oldest
        dir.heard(3, 3)

        assertNotNull(dir.get(1))
        assertNull(dir.get(2))
    }

    @Test
    fun `formats the node id the way the apps do`() {
        NodeDirectory().heard(0x1234abcd, 0).nodeId shouldBe "!1234abcd"
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class NodeInfoExchangeTest {

    private val channel = MeshChannel("LongFast", ByteArray(32) { it.toByte() })
    private val codec = ProtoPacketCodec()

    @Test
    fun `announcing carries our name and public key to peers`() = runTest {
        val keys = PkiCrypto().generateKeyPair()
        val t = RelayTransport()
        val me = MeshIdentity(0xAAAA, "my laptop", "LAP")

        val node = MeshNode(backgroundScope) {
            identity = me
            channels += channel
            transports += t
            privateKey = keys.privateKey
            publicKey = keys.publicKey
            codec = this@NodeInfoExchangeTest.codec
            var clockMs = 0L
            clock = { clockMs += 1000; clockMs }
        }

        node.announce() shouldBe true

        val decoded = codec.decode(t.sent.single(), KeyRing(listOf(channel), ourNodeNum = 0xBBBB))
        val info = assertIs<DecodedPacket.NodeInfo>(decoded)
        info.longName shouldBe "my laptop"
        info.shortName shouldBe "LAP"
        // Without this the peer can never DM us, however good its crypto is.
        info.publicKey?.contentEquals(keys.publicKey) shouldBe true
    }

    @Test
    fun `hearing a peer's announcement enables a direct message to it`() = runTest {
        val ourKeys = PkiCrypto().generateKeyPair()
        val peerKeys = PkiCrypto().generateKeyPair()
        val peerNum = 0xBBBBL

        val t = RelayTransport()
        val node = MeshNode(backgroundScope) {
            identity = MeshIdentity(0xAAAA, "us", "US")
            channels += channel
            transports += t
            privateKey = ourKeys.privateKey
            publicKey = ourKeys.publicKey
            codec = this@NodeInfoExchangeTest.codec
            var clockMs = 0L
            clock = { clockMs += 1000; clockMs }
        }

        // Before hearing them, we hold no key and must refuse rather than fall back.
        node.sendText("too early", to = peerNum) shouldBe false

        val theirAnnouncement = assertNotNull(
            codec.encodeNodeInfo(
                MeshIdentity(peerNum, "peer", "PR"), peerKeys.publicKey, channel, id = 3, hopLimit = 3,
            )
        )

        node.events.test {
            t.receive(theirAnnouncement)
            val peer = assertIs<MeshEvent.PeerUpdated>(awaitItem()).peer
            peer.longName shouldBe "peer"
        }

        // Now the directory has their key, the same send succeeds - no manual key wiring.
        node.sendText("now reachable", to = peerNum) shouldBe true

        val dm = t.sent.last()
        val asPeer = codec.decode(
            dm,
            KeyRing(listOf(channel), ourNodeNum = peerNum, ourPrivateKey = peerKeys.privateKey) { ourKeys.publicKey },
        )
        assertIs<DecodedPacket.Text>(asPeer).let {
            it.text shouldBe "now reachable"
            it.direct shouldBe true
        }
    }

    @Test
    fun `a position report is surfaced rather than lumped in with the unreadable`() = runTest {
        val t = RelayTransport()
        val node = MeshNode(backgroundScope) {
            identity = MeshIdentity(0xAAAA, "us", "US")
            channels += channel
            transports += t
            codec = this@NodeInfoExchangeTest.codec
            var clockMs = 0L
            clock = { clockMs += 1000; clockMs }
        }

        // Built the way a radio would: POSITION_APP inside the channel-encrypted payload.
        val position = org.meshtastic.proto.Position(latitude_i = 515_000_000, longitude_i = -1_260_000, altitude = 42)
        val data = org.meshtastic.proto.Data(
            portnum = org.meshtastic.proto.PortNum.POSITION_APP,
            payload = okio.ByteString.of(*org.meshtastic.proto.Position.ADAPTER.encode(position)),
        )
        val sealed = ChannelCrypto().transform(
            org.meshtastic.proto.Data.ADAPTER.encode(data), channel.psk, packetId = 21, fromNode = 0xCCCC,
        )
        val packet = org.meshtastic.proto.MeshPacket(
            from = 0xCCCC, to = MeshNode.BROADCAST.toInt(), id = 21, channel = channel.hash,
            hop_limit = 3, hop_start = 3, encrypted = okio.ByteString.of(*sealed),
        )

        node.events.test {
            t.receive(org.meshtastic.proto.MeshPacket.ADAPTER.encode(packet))
            val report = assertIs<MeshEvent.PositionReport>(awaitItem())
            report.from shouldBe 0xCCCCL
            report.latitudeI shouldBe 515_000_000
        }
    }
}
