package org.meshtastic.node

/**
 * Turns mesh packets into bytes and back.
 *
 * An interface because framing is per-transport: UDP and BLE advertisements carry a whole encoded
 * `MeshPacket`, where LoRa puts a bare 16-byte [MeshFrameHeader] and raw ciphertext on air.
 */
public interface PacketCodec {

    /** Header fields needed for routing decisions, without decrypting anything. */
    public fun peek(encodedPacket: ByteArray): PacketHeaderView?

    /** Encode and encrypt an outbound message, or null if it cannot be represented. */
    public suspend fun encode(message: OutboundMessage): ByteArray?

    /** Decrypt and interpret an inbound packet against the keys we hold. */
    public suspend fun decode(encodedPacket: ByteArray, keys: KeyRing): DecodedPacket?
}

/** The routing-relevant fields of a packet, readable without any key. */
public data class PacketHeaderView(
    val from: Long,
    val to: Long,
    val id: Long,
    val channelHash: Int,
    val hopLimit: Int,
)

/** A message this node is sending. */
public data class OutboundMessage(
    val text: String,
    val from: Long,
    val to: Long,
    val id: Long,
    val channel: MeshChannel,
    val hopLimit: Int,
    /** Set for a direct message; null for channel traffic. */
    val pki: PkiSend? = null,
)

/** What a direct message needs beyond the channel key. */
public data class PkiSend(
    val ourPrivateKey: ByteArray,
    val peerPublicKey: ByteArray,
    /** Must be freshly random per packet - reuse with the same key breaks CCM outright. */
    val extraNonce: Int,
) {
    override fun equals(other: Any?): Boolean = this === other || (
        other is PkiSend &&
            ourPrivateKey.contentEquals(other.ourPrivateKey) &&
            peerPublicKey.contentEquals(other.peerPublicKey) &&
            extraNonce == other.extraNonce
        )

    override fun hashCode(): Int =
        31 * (31 * ourPrivateKey.contentHashCode() + peerPublicKey.contentHashCode()) + extraNonce

    override fun toString(): String = "PkiSend(extraNonce=$extraNonce)" // never print key material
}

/** The keys available when interpreting an inbound packet. */
public data class KeyRing(
    val channels: List<MeshChannel>,
    val ourNodeNum: Long,
    val ourPrivateKey: ByteArray? = null,
    /** Public key for a peer, if known. Direct messages cannot be read without it. */
    val peerPublicKey: (Long) -> ByteArray? = { null },
)

/** The outcome of interpreting a packet. */
public sealed interface DecodedPacket {
    /** Readable text, and how it was protected. */
    public data class Text(val text: String, val direct: Boolean) : DecodedPacket

    /** Structurally valid but not for us, or on a channel we hold no key for. */
    public data object Unreadable : DecodedPacket
}
