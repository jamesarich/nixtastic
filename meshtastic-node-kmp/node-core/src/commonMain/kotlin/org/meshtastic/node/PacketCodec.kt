package org.meshtastic.node

/**
 * Turns mesh packets into bytes and back.
 *
 * An interface rather than a concrete class so `node-core` stays free of a protobuf dependency at
 * its own boundary, and so a transport that frames differently - LoRa puts a 16-byte
 * [MeshFrameHeader] and raw ciphertext on air, where UDP and BLE advertisements carry a whole
 * encoded `MeshPacket` - can supply its own without the node caring.
 */
public interface PacketCodec {

    /** Header fields needed for routing decisions, without decrypting anything. */
    public fun peek(encodedPacket: ByteArray): PacketHeaderView?

    /** Encode and encrypt a text message. Returns null if it cannot be represented. */
    public fun encodeText(
        text: String,
        from: Long,
        to: Long,
        id: Long,
        channel: MeshChannel,
        hopLimit: Int,
    ): ByteArray?

    /** Decrypt and extract a text payload, or null if this is not readable text on [channel]. */
    public fun decodeText(encodedPacket: ByteArray, channel: MeshChannel): String?
}

/** The routing-relevant fields of a packet, readable without its key. */
public data class PacketHeaderView(
    val from: Long,
    val to: Long,
    val id: Long,
    val channelHash: Int,
    val hopLimit: Int,
)
