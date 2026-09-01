package org.meshtastic.node

import okio.ByteString.Companion.toByteString
import org.meshtastic.proto.Data
import org.meshtastic.proto.MeshPacket
import org.meshtastic.proto.PortNum

/**
 * The codec for transports that carry a whole encoded `MeshPacket`: UDP multicast and the BLE
 * advertisement transport both do, matching `UdpMulticastHandler` and `BLEMeshHandler`.
 *
 * LoRa is the exception - it puts a bare [MeshFrameHeader] and raw ciphertext on air - which is why
 * [PacketCodec] is an interface rather than this class.
 */
public class ProtoPacketCodec : PacketCodec {

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

    override fun encodeText(
        text: String,
        from: Long,
        to: Long,
        id: Long,
        channel: MeshChannel,
        hopLimit: Int,
    ): ByteArray? {
        val payload = Data(portnum = PortNum.TEXT_MESSAGE_APP, payload = text.encodeToByteArray().toByteString())
        val plaintext = Data.ADAPTER.encode(payload)
        val ciphertext = ChannelCrypto.transform(plaintext, channel.psk, id, from)

        // The receiver reconstructs the CTR nonce from `id` and `from`, so a packet whose payload
        // does not fit cannot simply be truncated - it has to be refused.
        if (ciphertext.size > MAX_CIPHERTEXT) return null

        val packet = MeshPacket(
            from = from.toInt(),
            to = to.toInt(),
            id = id.toInt(),
            channel = channel.hash,
            hop_limit = hopLimit,
            hop_start = hopLimit,
            encrypted = ciphertext.toByteString(),
        )
        return MeshPacket.ADAPTER.encode(packet)
    }

    override fun decodeText(encodedPacket: ByteArray, channel: MeshChannel): String? {
        val pkt = runCatching { MeshPacket.ADAPTER.decode(encodedPacket) }.getOrNull() ?: return null
        val ciphertext = pkt.encrypted?.toByteArray() ?: return null

        val plaintext = ChannelCrypto.transform(
            payload = ciphertext,
            psk = channel.psk,
            packetId = pkt.id.toLong() and MASK32,
            fromNode = pkt.from.toLong() and MASK32,
        )
        // Channel packets carry no MAC, so a wrong key produces plausible-looking bytes rather
        // than an error. A failed protobuf parse is the only signal available, and a successful
        // one on the wrong key is possible - treat readability as a hint, never as authentication.
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
