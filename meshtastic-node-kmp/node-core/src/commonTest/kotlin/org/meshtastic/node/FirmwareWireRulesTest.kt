package org.meshtastic.node

import io.kotest.matchers.shouldBe
import kotlinx.coroutines.test.runTest
import okio.ByteString.Companion.toByteString
import org.meshtastic.proto.Data
import org.meshtastic.proto.MeshPacket
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * Two rules that current firmware enforces and that nothing in our own round trips would catch.
 *
 * Both were found the same way - a radio on the bench decrypting our packets, logging them, and
 * discarding them - and both are invisible to a library talking only to itself.
 */
class FirmwareWireRulesTest {

    private val channel = MeshChannel("LongFast", ByteArray(32) { it.toByte() })
    private val codec = ProtoPacketCodec()
    private val us = 0xAAAAL
    private val peer = 0xBBBBL

    private suspend fun dataOf(encoded: ByteArray, pki: PkiSend? = null, ourPriv: ByteArray? = null): Data {
        val pkt = MeshPacket.ADAPTER.decode(encoded)
        val ciphertext = assertNotNull(pkt.encrypted).toByteArray()
        val id = pkt.id.toLong() and 0xFFFFFFFFL
        val from = pkt.from.toLong() and 0xFFFFFFFFL
        val plaintext = if (pki != null) {
            assertNotNull(PkiCrypto().decrypt(ciphertext, ourPriv!!, pki.peerPublicKey, id, from))
        } else {
            ChannelCrypto().transform(ciphertext, channel.psk, id, from)
        }
        return Data.ADAPTER.decode(plaintext)
    }

    @Test
    fun `every outgoing packet carries a present bitfield`() = runTest {
        // Presence, not value. classifyHopStart reads the field's presence to tell a modern
        // zero-hop broadcast from firmware older than 2.3.0; absent it, Island mode's hop_start = 0
        // makes every packet we send look ancient and it is dropped after decryption.
        val text = assertNotNull(codec.encode(OutboundMessage("hi", us, MeshNode.BROADCAST, 1, channel, 0)))
        val nodeInfo = assertNotNull(
            codec.encodeNodeInfo(MeshIdentity(us, "us", "US"), null, channel, 2, 0)
        )
        val ack = assertNotNull(codec.encodeAck(peer, requestId = 9, from = us, channel = channel, id = 3, hopLimit = 0))

        for (packet in listOf(text, nodeInfo, ack)) {
            assertNotNull(dataOf(packet).bitfield)
        }
    }

    @Test
    fun `the bitfield withholds MQTT consent by default`() = runTest {
        val default = assertNotNull(codec.encode(OutboundMessage("hi", us, MeshNode.BROADCAST, 1, channel, 0)))
        val consenting = ProtoPacketCodec(okToMqtt = true)
            .encode(OutboundMessage("hi", us, MeshNode.BROADCAST, 1, channel, 0))

        // Bit 0 is ok_to_mqtt. A client node is someone's own device; putting its traffic on a
        // public map is opt-in.
        dataOf(default).bitfield shouldBe 0
        dataOf(assertNotNull(consenting)).bitfield shouldBe 1
    }

    @Test
    fun `a PKI packet carries channel zero and a channel packet carries its hash`() = runTest {
        val keys = PkiCrypto().generateKeyPair()
        val theirs = PkiCrypto().generateKeyPair()
        val pki = PkiSend(keys.privateKey, theirs.publicKey, extraNonce = 7)

        val direct = assertNotNull(
            codec.encode(OutboundMessage("private", us, peer, 4, channel, 0, pki = pki))
        )
        val broadcast = assertNotNull(codec.encode(OutboundMessage("public", us, MeshNode.BROADCAST, 5, channel, 0)))

        // Router::perhapsDecode gates its entire PKI branch on `p->channel == 0`. With the channel
        // hash here the radio never attempts X25519 at all: it tries the channel key, gets noise,
        // and drops the packet as "bad psk". The message is not rejected - it is unreadable.
        assertNotNull(codec.peek(direct)).channelHash shouldBe 0
        assertNotNull(codec.peek(broadcast)).channelHash shouldBe channel.hash

        // And it still decrypts for its recipient, which is what makes channel 0 safe to stamp:
        // the channel byte was only ever a hint for choosing a PSK, and PKI needs no such hint.
        val asPeer = codec.decode(
            direct,
            KeyRing(listOf(channel), ourNodeNum = peer, ourPrivateKey = theirs.privateKey) { keys.publicKey },
        )
        assertNotNull(asPeer)
    }

    @Test
    fun `a PKI packet is opaque to a holder of the channel key`() = runTest {
        val keys = PkiCrypto().generateKeyPair()
        val theirs = PkiCrypto().generateKeyPair()
        val direct = assertNotNull(
            codec.encode(
                OutboundMessage("private", us, peer, 6, channel, 0, pki = PkiSend(keys.privateKey, theirs.publicKey, 7))
            )
        )

        // Channel 0 must not become a way for a bystander to read a DM: with no matching hash there
        // is nothing to try, and the PKI attempt needs a private key they do not have.
        val bystander = codec.decode(direct, KeyRing(listOf(channel), ourNodeNum = 0xCCCC))
        (bystander is DecodedPacket.Unreadable) shouldBe true
    }

    @Test
    fun `hop start mirrors the relay policy so a radio can tell how far a packet came`() = runTest {
        val meshed = assertNotNull(codec.encode(OutboundMessage("far", us, MeshNode.BROADCAST, 7, channel, 3)))
        val pkt = MeshPacket.ADAPTER.decode(meshed)

        // hop_start is the hop_limit at origination; a receiver subtracts to get hops travelled.
        // Sending hop_start < hop_limit is classified INVALID and dropped before decryption.
        pkt.hop_start shouldBe 3
        pkt.hop_limit shouldBe 3
    }

    @Test
    fun `an island packet is zero-hop but still well formed`() = runTest {
        val island = assertNotNull(codec.encode(OutboundMessage("here", us, MeshNode.BROADCAST, 8, channel, 0)))
        val pkt = MeshPacket.ADAPTER.decode(island)

        pkt.hop_limit shouldBe 0
        pkt.hop_start shouldBe 0
        // The pairing that makes zero-hop legible rather than archaic.
        assertNotNull(dataOf(island).bitfield)
    }

    @Test
    fun `a packet with no bitfield is what the firmware treats as pre-2_3_0`() = runTest {
        // Documenting the shape we must never emit, so the rule above cannot be silently reverted.
        val ancient = MeshPacket.ADAPTER.encode(
            MeshPacket(
                from = us.toInt(), to = MeshNode.BROADCAST.toInt(), id = 9, channel = channel.hash,
                hop_limit = 0, hop_start = 0,
                encrypted = ChannelCrypto()
                    .transform(Data.ADAPTER.encode(Data(portnum = org.meshtastic.proto.PortNum.TEXT_MESSAGE_APP)), channel.psk, 9, us)
                    .toByteString(),
            )
        )
        assertNull(Data.ADAPTER.decode(ChannelCrypto().transform(
            assertNotNull(MeshPacket.ADAPTER.decode(ancient).encrypted).toByteArray(), channel.psk, 9, us,
        )).bitfield)
    }
}
