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

    /**
     * Rewrite a received packet for forwarding: hop limit decremented, relay marked as us.
     *
     * Needs no key, and that is the point - `hop_limit` is a plaintext field of `MeshPacket`
     * (field 9) while the ciphertext is field 5, so a node relays traffic it cannot read, exactly
     * as `NextHopRouter::perhapsRebroadcast` does. Returns null when the packet is exhausted and
     * must not travel further.
     */
    public fun forForwarding(encodedPacket: ByteArray, relayNodeNum: Long): ByteArray?

    /** Announce ourselves so peers can learn our name and, crucially, our public key. */
    public suspend fun encodeNodeInfo(
        identity: MeshIdentity,
        publicKey: ByteArray?,
        channel: MeshChannel,
        id: Long,
        hopLimit: Int,
    ): ByteArray?
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

    /** A peer describing itself. Carries the public key that makes direct messages to it possible. */
    public data class NodeInfo(
        val longName: String?,
        val shortName: String?,
        val publicKey: ByteArray?,
    ) : DecodedPacket {
        override fun equals(other: Any?): Boolean = this === other || (
            other is NodeInfo && longName == other.longName && shortName == other.shortName &&
                (publicKey?.contentEquals(other.publicKey ?: ByteArray(0)) ?: (other.publicKey == null))
            )

        override fun hashCode(): Int =
            31 * (31 * (longName?.hashCode() ?: 0) + (shortName?.hashCode() ?: 0)) +
                (publicKey?.contentHashCode() ?: 0)
    }

    /** A position report. Coordinates are Meshtastic's 1e-7 degree integers. */
    public data class Position(val latitudeI: Int?, val longitudeI: Int?, val altitude: Int?) : DecodedPacket

    /** Decrypted, but a payload type this library does not model. Still evidence of a live peer. */
    public data class Other(val portnum: Int) : DecodedPacket

    /** Structurally valid but not for us, or on a channel we hold no key for. */
    public data object Unreadable : DecodedPacket
}
