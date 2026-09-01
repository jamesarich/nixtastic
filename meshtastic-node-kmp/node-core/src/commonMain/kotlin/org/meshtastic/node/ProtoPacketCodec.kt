package org.meshtastic.node

import okio.ByteString.Companion.toByteString
import org.meshtastic.proto.Data
import org.meshtastic.proto.MeshPacket
import org.meshtastic.proto.PortNum
import org.meshtastic.proto.Position
import org.meshtastic.proto.Routing
import org.meshtastic.proto.User

/**
 * The codec for transports carrying a whole encoded `MeshPacket`: UDP multicast and the BLE
 * advertisement transport both do, matching `UdpMulticastHandler` and `BLEMeshHandler`.
 */
public class ProtoPacketCodec(
    private val channelCrypto: ChannelCrypto = ChannelCrypto(),
    private val pkiCrypto: PkiCrypto = PkiCrypto(),
) : PacketCodec {

    override fun peek(encodedPacket: ByteArray): PacketHeaderView? {
        val pkt = decodePacket(encodedPacket) ?: return null
        return PacketHeaderView(
            from = pkt.from.toLong() and MASK32,
            to = pkt.to.toLong() and MASK32,
            id = pkt.id.toLong() and MASK32,
            channelHash = pkt.channel,
            hopLimit = pkt.hop_limit,
            wantAck = pkt.want_ack,
        )
    }

    override suspend fun encode(message: OutboundMessage): ByteArray? {
        val plaintext = Data.ADAPTER.encode(
            Data(portnum = PortNum.TEXT_MESSAGE_APP, payload = message.text.encodeToByteArray().toByteString())
        )
        return seal(
            plaintext, message.from, message.to, message.id, message.channel, message.hopLimit,
            message.pki, wantAck = message.wantAck,
        )
    }

    override suspend fun encodeAck(
        toNodeNum: Long,
        requestId: Long,
        from: Long,
        channel: MeshChannel,
        id: Long,
        hopLimit: Int,
    ): ByteArray? {
        val plaintext = Data.ADAPTER.encode(
            Data(
                portnum = PortNum.ROUTING_APP,
                payload = Routing.ADAPTER.encode(Routing(error_reason = Routing.Error.NONE)).toByteString(),
                // What makes this an acknowledgement of something rather than a bare routing
                // message: the sender matches it against the id it is waiting on.
                request_id = requestId.toInt(),
            )
        )
        // Channel-encrypted, never PKI: the sender has to be able to read the receipt whether or
        // not the two of us have exchanged keys. ROUTING_APP is one of the portnums the firmware
        // deliberately keeps out of the PKI path for the same reason.
        return seal(plaintext, from, toNodeNum, id, channel, hopLimit, pki = null, wantAck = false)
    }

    override suspend fun encodeNodeInfo(
        identity: MeshIdentity,
        publicKey: ByteArray?,
        channel: MeshChannel,
        id: Long,
        hopLimit: Int,
    ): ByteArray? {
        val user = User(
            id = identity.nodeId,
            long_name = identity.longName,
            short_name = identity.shortName,
            public_key = (publicKey ?: ByteArray(0)).toByteString(),
        )
        val plaintext = Data.ADAPTER.encode(
            Data(portnum = PortNum.NODEINFO_APP, payload = User.ADAPTER.encode(user).toByteString())
        )
        // Never PKI-encrypted, even when addressed: peers have to read this to learn the very key
        // PKI would need. The firmware routes NODEINFO_APP through channel encryption for exactly
        // that reason, alongside ROUTING, TRACEROUTE and POSITION.
        return seal(plaintext, identity.nodeNum, BROADCAST, id, channel, hopLimit, pki = null)
    }

    override fun forForwarding(encodedPacket: ByteArray, relayNodeNum: Long): ByteArray? {
        val pkt = decodePacket(encodedPacket) ?: return null
        if (pkt.hop_limit <= 0) return null // exhausted; forwarding it would be a loop with no brake

        // No key involved, and that is the whole trick: hop_limit is a plaintext MeshPacket field
        // (9) while the ciphertext is field 5, so a node forwards traffic it cannot read - which is
        // what makes a mesh a mesh, and what NextHopRouter::perhapsRebroadcast does.
        return MeshPacket.ADAPTER.encode(
            pkt.copy(
                hop_limit = pkt.hop_limit - 1,
                // The wire carries only the low byte of the relayer's NodeNum. Collisions are
                // possible and the firmware knows it: a next-hop hint, never an identity.
                relay_node = (relayNodeNum and 0xFF).toInt(),
            )
        )
    }

    override suspend fun decode(encodedPacket: ByteArray, keys: KeyRing): DecodedPacket? {
        val pkt = decodePacket(encodedPacket) ?: return null
        val ciphertext = pkt.encrypted?.toByteArray() ?: return null
        val from = pkt.from.toLong() and MASK32
        val to = pkt.to.toLong() and MASK32
        val id = pkt.id.toLong() and MASK32

        // A direct message to us is tried under PKI first, as Router::perhapsDecode does.
        if (to == keys.ourNodeNum && keys.ourPrivateKey != null) {
            val peerKey = keys.peerPublicKey(from)
            if (peerKey != null && ciphertext.size > pkiCrypto.overhead) {
                val plaintext = pkiCrypto.decrypt(ciphertext, keys.ourPrivateKey, peerKey, id, from)
                // Unlike the channel layer this genuinely authenticates: CCM's MAC means a
                // successful decrypt is evidence rather than coincidence.
                if (plaintext != null) return interpret(plaintext, direct = true)
            }
        }

        val channel = keys.channels.firstOrNull { it.hash == pkt.channel } ?: return DecodedPacket.Unreadable
        val plaintext = channelCrypto.transform(ciphertext, channel.psk, id, from)
        return interpret(plaintext, direct = false)
    }

    private suspend fun seal(
        plaintext: ByteArray,
        from: Long,
        to: Long,
        id: Long,
        channel: MeshChannel,
        hopLimit: Int,
        pki: PkiSend?,
        wantAck: Boolean = false,
    ): ByteArray? {
        val ciphertext = pki?.let {
            pkiCrypto.encrypt(plaintext, it.ourPrivateKey, it.peerPublicKey, id, from, it.extraNonce)
        } ?: channelCrypto.transform(plaintext, channel.psk, id, from)

        // The receiver rebuilds the nonce from packet fields, so an over-long payload cannot be
        // truncated into something decryptable - it has to be refused.
        if (ciphertext.size > MAX_CIPHERTEXT) return null

        return MeshPacket.ADAPTER.encode(
            MeshPacket(
                from = from.toInt(),
                to = to.toInt(),
                id = id.toInt(),
                channel = channel.hash,
                hop_limit = hopLimit,
                hop_start = hopLimit,
                want_ack = wantAck,
                pki_encrypted = pki != null,
                encrypted = ciphertext.toByteString(),
            )
        )
    }

    /**
     * Interpret decrypted bytes.
     *
     * Channel packets carry no MAC, so a wrong key yields plausible-looking bytes rather than an
     * error. A failed parse is the only signal available, and a *successful* parse under the wrong
     * key is possible - readability is a hint, never authentication.
     */
    private fun interpret(plaintext: ByteArray, direct: Boolean): DecodedPacket {
        val data = runCatching { Data.ADAPTER.decode(plaintext) }.getOrNull() ?: return DecodedPacket.Unreadable

        return when (data.portnum) {
            PortNum.TEXT_MESSAGE_APP ->
                runCatching { data.payload.utf8() }.getOrNull()
                    ?.let { DecodedPacket.Text(it, direct) }
                    ?: DecodedPacket.Unreadable

            PortNum.NODEINFO_APP ->
                runCatching { User.ADAPTER.decode(data.payload) }.getOrNull()
                    ?.let { DecodedPacket.NodeInfo(it.long_name, it.short_name, it.public_key.toByteArray().takeIf { k -> k.isNotEmpty() }) }
                    ?: DecodedPacket.Unreadable

            PortNum.ROUTING_APP ->
                // An ack is a Routing with no error. A Routing *with* an error is a delivery
                // failure report, which is a different thing and not modelled here.
                runCatching { Routing.ADAPTER.decode(data.payload) }.getOrNull()
                    ?.takeIf { it.error_reason == Routing.Error.NONE && data.request_id != 0 }
                    ?.let { DecodedPacket.Ack(data.request_id.toLong() and MASK32) }
                    ?: DecodedPacket.Other(data.portnum.value)

            PortNum.POSITION_APP ->
                runCatching { Position.ADAPTER.decode(data.payload) }.getOrNull()
                    ?.let { DecodedPacket.Position(it.latitude_i, it.longitude_i, it.altitude) }
                    ?: DecodedPacket.Unreadable

            // Decrypted successfully but not a type this library models. Still evidence of a live
            // peer, so it is reported rather than discarded.
            else -> DecodedPacket.Other(data.portnum.value)
        }
    }

    private fun decodePacket(bytes: ByteArray): MeshPacket? =
        runCatching { MeshPacket.ADAPTER.decode(bytes) }.getOrNull()

    private companion object {
        const val MASK32 = 0xFFFFFFFFL
        const val BROADCAST = 0xFFFFFFFFL

        /** Matches the firmware's DATA_PAYLOAD_LEN. */
        const val MAX_CIPHERTEXT = 237
    }
}
