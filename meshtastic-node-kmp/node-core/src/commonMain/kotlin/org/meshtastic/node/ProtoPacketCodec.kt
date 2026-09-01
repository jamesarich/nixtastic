package org.meshtastic.node

import okio.ByteString.Companion.toByteString
import org.meshtastic.proto.Data
import org.meshtastic.proto.MeshPacket
import org.meshtastic.proto.PortNum

/**
 * The codec for transports carrying a whole encoded `MeshPacket`: UDP multicast and the BLE
 * advertisement transport both do, matching `UdpMulticastHandler` and `BLEMeshHandler`.
 */
public class ProtoPacketCodec(
    private val channelCrypto: ChannelCrypto = ChannelCrypto(),
    private val pkiCrypto: PkiCrypto = PkiCrypto(),
) : PacketCodec {

    override fun peek(encodedPacket: ByteArray): PacketHeaderView? {
        val pkt = runCatching { MeshPacket.ADAPTER.decode(encodedPacket) }.getOrNull() ?: return null
        return PacketHeaderView(
            from = pkt.from.toLong() and MASK32,
            to = pkt.to.toLong() and MASK32,
            id = pkt.id.toLong() and MASK32,
            channelHash = pkt.channel,
            hopLimit = pkt.hop_limit,
        )
    }

    override suspend fun encode(message: OutboundMessage): ByteArray? {
        val plaintext = Data.ADAPTER.encode(
            Data(portnum = PortNum.TEXT_MESSAGE_APP, payload = message.text.encodeToByteArray().toByteString())
        )

        val ciphertext = message.pki?.let { pki ->
            pkiCrypto.encrypt(
                plaintext = plaintext,
                ourPrivateKey = pki.ourPrivateKey,
                peerPublicKey = pki.peerPublicKey,
                packetId = message.id,
                fromNode = message.from,
                extraNonce = pki.extraNonce,
            )
        } ?: channelCrypto.transform(plaintext, message.channel.psk, message.id, message.from)

        // The receiver rebuilds the nonce from packet fields, so an over-long payload cannot be
        // truncated into something decryptable - it has to be refused.
        if (ciphertext.size > MAX_CIPHERTEXT) return null

        return MeshPacket.ADAPTER.encode(
            MeshPacket(
                from = message.from.toInt(),
                to = message.to.toInt(),
                id = message.id.toInt(),
                channel = message.channel.hash,
                hop_limit = message.hopLimit,
                hop_start = message.hopLimit,
                pki_encrypted = message.pki != null,
                encrypted = ciphertext.toByteString(),
            )
        )
    }

    override suspend fun decode(encodedPacket: ByteArray, keys: KeyRing): DecodedPacket? {
        val pkt = runCatching { MeshPacket.ADAPTER.decode(encodedPacket) }.getOrNull() ?: return null
        val ciphertext = pkt.encrypted?.toByteArray() ?: return null
        val from = pkt.from.toLong() and MASK32
        val to = pkt.to.toLong() and MASK32
        val id = pkt.id.toLong() and MASK32

        // A direct message to us is tried under PKI first, exactly as Router::perhapsDecode does:
        // channel 0, addressed to us, both keys known.
        val addressedToUs = to == keys.ourNodeNum
        if (addressedToUs && keys.ourPrivateKey != null) {
            val peerKey = keys.peerPublicKey(from)
            if (peerKey != null && ciphertext.size > pkiCrypto.overhead) {
                val plaintext = pkiCrypto.decrypt(ciphertext, keys.ourPrivateKey, peerKey, id, from)
                // Unlike the channel layer this genuinely authenticates: CCM's MAC means a
                // successful decrypt is evidence, not a coincidence.
                if (plaintext != null) {
                    return textOf(plaintext)?.let { DecodedPacket.Text(it, direct = true) } ?: DecodedPacket.Unreadable
                }
            }
        }

        val channel = keys.channels.firstOrNull { it.hash == pkt.channel } ?: return DecodedPacket.Unreadable
        val plaintext = channelCrypto.transform(ciphertext, channel.psk, id, from)
        return textOf(plaintext)?.let { DecodedPacket.Text(it, direct = false) } ?: DecodedPacket.Unreadable
    }

    /**
     * Channel packets carry no MAC, so a wrong key yields plausible-looking bytes rather than an
     * error. A failed protobuf parse is the only signal available, and a *successful* parse under
     * the wrong key is possible - readability is a hint, never authentication.
     */
    private fun textOf(plaintext: ByteArray): String? {
        val data = runCatching { Data.ADAPTER.decode(plaintext) }.getOrNull() ?: return null
        if (data.portnum != PortNum.TEXT_MESSAGE_APP) return null
        return runCatching { data.payload.utf8() }.getOrNull()
    }

    private companion object {
        const val MASK32 = 0xFFFFFFFFL

        /** Matches the firmware's DATA_PAYLOAD_LEN. */
        const val MAX_CIPHERTEXT = 237
    }
}
