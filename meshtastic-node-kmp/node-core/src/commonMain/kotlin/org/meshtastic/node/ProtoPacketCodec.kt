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
    /**
     * Whether relays may forward our traffic to MQTT - bit 0 of [bitfield], the field's original
     * and still only defined use.
     *
     * Off by default. A client node is a person's own device, and putting its traffic on a public
     * map is a decision to opt into rather than out of.
     */
    private val okToMqtt: Boolean = false,
) : PacketCodec {

    /**
     * `Data.bitfield`, set on every packet we send - and it must be *present*, not merely zero.
     *
     * This is not cosmetic. `hop_start == 0` is ambiguous on the wire: it means either a modern
     * zero-hop broadcast or firmware older than 2.3.0 that never populated the field at all.
     * `Router::classifyHopStart` resolves the ambiguity by looking for this bitfield, which 2.5.0
     * made unconditional - and a packet it classifies as pre-hop is dropped after decoding, before
     * any module, the phone, MQTT or rebroadcast ever see it.
     *
     * So without this field, a node using [RelayPolicy.Island] - which stamps `hop_start = 0` on
     * purpose so no radio relays it - has every packet silently discarded by current firmware. The
     * radio decrypts it, logs it, and throws it away, and the drop log is rate-limited so most of
     * them leave no trace at all.
     */
    private val bitfield: Int = if (okToMqtt) 1 else 0

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
            Data(
                portnum = PortNum.TEXT_MESSAGE_APP,
                payload = message.text.encodeToByteArray().toByteString(),
                bitfield = bitfield,
            )
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
                bitfield = bitfield,
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
        wantResponse: Boolean,
    ): ByteArray? {
        val user = User(
            id = identity.nodeId,
            long_name = identity.longName,
            short_name = identity.shortName,
            public_key = (publicKey ?: ByteArray(0)).toByteString(),
        )
        val plaintext = Data.ADAPTER.encode(
            Data(
                portnum = PortNum.NODEINFO_APP,
                payload = User.ADAPTER.encode(user).toByteString(),
                // NodeInfoModule replies with its own NodeInfo when this is set, which is how a
                // node that has just joined learns its neighbours without waiting out their
                // broadcast interval.
                want_response = wantResponse,
                bitfield = bitfield,
            )
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
                // A PKI packet MUST carry channel 0, and this is not a convention we could choose
                // differently: `Router::perhapsDecode` gates its whole PKI branch on
                // `p->channel == 0`. Stamp the channel hash here and real firmware never even
                // attempts X25519 - it decrypts with the channel key, gets noise, and drops the
                // packet as "bad psk". The DM is not rejected, it is unreadable.
                channel = if (pki != null) PKI_CHANNEL else channel.hash,
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
        /** `MESHTASTIC_PKC_CHANNEL_INDEX`: what a PKI packet must put in `MeshPacket.channel`. */
        const val PKI_CHANNEL = 0

        const val MASK32 = 0xFFFFFFFFL
        const val BROADCAST = 0xFFFFFFFFL

        /** Matches the firmware's DATA_PAYLOAD_LEN. */
        const val MAX_CIPHERTEXT = 237
    }
}
