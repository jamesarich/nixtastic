package org.meshtastic.node

/**
 * A channel: the name and pre-shared key that decide which traffic this node can read and write.
 *
 * The [hash] is what appears in `MeshPacket.channel` on the wire. It is a *hint* for choosing a
 * candidate PSK when decrypting, not an integrity check - collisions are cheap to find, so a
 * matching hash must never be treated as authentication.
 */
public data class MeshChannel(
    val name: String,
    val psk: ByteArray,
) {
    /** Matches `Channels::getHash`: XOR of the name bytes and the resolved key bytes. */
    public val hash: Int by lazy {
        val key = ChannelCrypto.resolveKey(psk)
        var h = 0
        for (c in name.encodeToByteArray()) h = h xor (c.toInt() and 0xFF)
        if (key != null) for (b in key) h = h xor (b.toInt() and 0xFF)
        h and 0xFF
    }

    /** True when this channel puts cleartext on the air - an empty PSK, or short-form index 0. */
    public val isCleartext: Boolean get() = ChannelCrypto.resolveKey(psk) == null

    // Data class equality on a ByteArray member would compare references, which is a bug waiting
    // to happen for a type used as a map key.
    override fun equals(other: Any?): Boolean =
        this === other || (other is MeshChannel && name == other.name && psk.contentEquals(other.psk))

    override fun hashCode(): Int = 31 * name.hashCode() + psk.contentHashCode()

    override fun toString(): String = "MeshChannel(name=$name, psk=${psk.size} bytes)"
}
