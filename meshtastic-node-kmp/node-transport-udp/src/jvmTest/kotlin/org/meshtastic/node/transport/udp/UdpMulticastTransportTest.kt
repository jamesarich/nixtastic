package org.meshtastic.node.transport.udp

import app.cash.turbine.test
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.meshtastic.node.ChannelCrypto
import org.meshtastic.node.DecodedPacket
import org.meshtastic.node.KeyRing
import org.meshtastic.node.MeshChannel
import org.meshtastic.node.MeshNode
import org.meshtastic.node.OutboundMessage
import org.meshtastic.node.ProtoPacketCodec
import java.net.NetworkInterface
import kotlin.random.Random
import kotlin.time.Duration.Companion.seconds
import kotlin.test.Test
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Real sockets, not a fake. This is the transport that will meet released firmware first, so the
 * parts that only fail against a live network - joining the group on the right interface, the
 * cold-flow lifecycle, actually receiving a datagram - need exercising for real.
 *
 * Deliberately not on port 4403. That is the live Meshtastic multicast port, and a test that used
 * it would inject frames into any real mesh on the same segment.
 */
class UdpMulticastTransportTest {

    private val port = 45_000 + Random.Default.nextInt(1000)
    private val group = "239.0.0.71" // not 239.0.0.69 either, for the same reason

    /**
     * A real interface in preference to loopback: macOS does not reliably deliver multicast on lo0,
     * so a loopback-first choice makes these tests fail on a working stack. The group and port used
     * here are not Meshtastic's, so this stays inert on any network it touches.
     *
     * Returns null when the host has nothing multicast-capable, which is a legitimate CI shape -
     * the tests then skip rather than fail.
     */
    private fun testInterface(): NetworkInterface? =
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && it.supportsMulticast() }
            .firstOrNull { !it.isLoopback }

    // No explicit interface: the OS picks, which is what a caller on a plain host gets.
    private fun transport(@Suppress("UNUSED_PARAMETER") nif: NetworkInterface?) =
        UdpMulticastTransport(group = group, port = port)

    @Test
    fun `a frame sent on the group is received from it`() = runBlocking {
        val nif = testInterface() ?: return@runBlocking
        val receiver = transport(nif)
        val sender = transport(nif)
        val payload = "over the wire".encodeToByteArray()

        receiver.incoming().test(timeout = 20.seconds) {
            // The flow is cold: the socket exists only once collection starts, so send after.
            withTimeout(10_000) {
                var delivered = false
                while (!delivered) {
                    sender.send(payload)
                    // UDP is lossy and the join may not have taken effect on the first attempt;
                    // retrying is what a real transport user would experience too.
                    val frame = awaitItem()
                    if (frame.bytes.contentEquals(payload)) delivered = true
                }
                delivered shouldBe true
            }
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `reports no rssi because udp has none to report`() = runBlocking {
        val nif = testInterface() ?: return@runBlocking
        val receiver = transport(nif)
        val sender = transport(nif)

        receiver.incoming().test(timeout = 20.seconds) {
            withTimeout(10_000) {
                sender.send("x".encodeToByteArray())
                // A zero here would misrepresent "unknown" as a real measurement of 0 dBm.
                assertNotNull(awaitItem()).rssi shouldBe null
            }
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `two nodes exchange a message end to end`() = runBlocking {
        val nif = testInterface() ?: return@runBlocking
        val channel = MeshChannel("LongFast", ByteArray(32) { it.toByte() })
        val codec = ProtoPacketCodec()

        val aliceTransport = transport(nif)
        val bobTransport = transport(nif)

        // Its own scope, cancelled below: outside runTest there is no backgroundScope, and the
        // events flow lives as long as the scope it is given.
        val scope = CoroutineScope(SupervisorJob())
        val bob = MeshNode(scope) {
            identity = org.meshtastic.node.MeshIdentity(0xB0B, "bob", "BOB")
            channels += channel
            transports += bobTransport
            var t = 0L
            clock = { t += 1000; t }
        }

        // The whole stack over a real socket: encode, encrypt, datagram, decrypt, decode.
        val frame = assertNotNull(
            codec.encode(OutboundMessage("end to end", 0xA11CE, MeshNode.BROADCAST, 42, channel, hopLimit = 3))
        )

        bob.events.test(timeout = 25.seconds) {
            // Retransmit from a separate coroutine rather than between awaits. events is shared
            // with WhileSubscribed, so subscription completes asynchronously after test{} enters,
            // and a single send racing that would be lost with nothing left to wake the await.
            // A real node retransmits too, so this is not a workaround so much as the usual shape.
            val sender = scope.launch {
                while (isActive) {
                    aliceTransport.send(frame)
                    delay(250)
                }
            }

            var seen = false
            while (!seen) {
                val event = awaitItem()
                if (event is org.meshtastic.node.MeshEvent.TextMessage && event.text == "end to end") {
                    event.from shouldBe 0xA11CEL
                    event.direct shouldBe false
                    seen = true
                }
            }
            sender.cancel()
            cancelAndIgnoreRemainingEvents()
        }
        scope.cancel()
    }

    @Test
    fun `the payload on the wire is what the firmware expects`() = runTest {
        // UdpMulticastHandler decodes a whole encoded MeshPacket and requires the encrypted
        // variant; anything else it drops. This asserts the shape rather than the socket.
        val channel = MeshChannel("LongFast", ByteArray(32) { it.toByte() })
        val codec = ProtoPacketCodec()

        val frame = assertNotNull(
            codec.encode(OutboundMessage("shape", 0x1234, MeshNode.BROADCAST, 7, channel, hopLimit = 3))
        )
        val header = assertNotNull(codec.peek(frame))
        header.from shouldBe 0x1234L
        header.channelHash shouldBe channel.hash

        val decoded = codec.decode(frame, KeyRing(listOf(channel), ourNodeNum = 0x9999))
        assertIs<DecodedPacket.Text>(decoded).text shouldBe "shape"
    }

    @Test
    fun `defaults match the firmware's multicast handler`() {
        // Group and port are a contract with UdpMulticastHandler, not a preference.
        UdpMulticastTransport.DEFAULT_GROUP shouldBe "239.0.0.69"
        UdpMulticastTransport.DEFAULT_PORT shouldBe 4403
        assertTrue(UdpMulticastTransport().canTransmit)
    }

    @Test
    fun `channel crypto survives the round trip that the socket carries`() = runTest {
        val crypto = ChannelCrypto()
        val psk = ByteArray(32) { (it * 7).toByte() }
        val plaintext = "unchanged by transit".encodeToByteArray()

        val sealed = crypto.transform(plaintext, psk, packetId = 1, fromNode = 2)
        crypto.transform(sealed, psk, packetId = 1, fromNode = 2) shouldBe plaintext
    }
}
