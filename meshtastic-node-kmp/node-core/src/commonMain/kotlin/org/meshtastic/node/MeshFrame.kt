package org.meshtastic.node

/**
 * The 16-byte header that precedes the ciphertext on the LoRa wire, and the flag packing that goes
 * with it.
 *
 * Not every transport uses this framing - UDP multicast and the BLE advertisement transport both
 * carry a whole encoded `MeshPacket` instead, which costs bytes but reuses the protobuf codec. It
 * is here because a LoRa transport has no choice: this is what is on air, and it is also what makes
 * a frame heard on one medium byte-identical to the same frame on another.
 */
public data class MeshFrameHeader(
    val to: Long,
    val from: Long,
    val id: Long,
    val flags: Int,
    val channelHash: Int,
    val nextHop: Int,
    val relayNode: Int,
) {
    val hopLimit: Int get() = flags and HOP_LIMIT_MASK
    val wantAck: Boolean get() = (flags and WANT_ACK_MASK) != 0
    val viaMqtt: Boolean get() = (flags and VIA_MQTT_MASK) != 0
    val hopStart: Int get() = (flags and HOP_START_MASK) ushr HOP_START_SHIFT

    public companion object {
        public const val SIZE: Int = 16

        public const val HOP_LIMIT_MASK: Int = 0x07
        public const val WANT_ACK_MASK: Int = 0x08
        public const val VIA_MQTT_MASK: Int = 0x10
        public const val HOP_START_MASK: Int = 0xE0
        public const val HOP_START_SHIFT: Int = 5

        private fun u32(b: ByteArray, o: Int): Long =
            (b[o].toLong() and 0xFF) or ((b[o + 1].toLong() and 0xFF) shl 8) or
                ((b[o + 2].toLong() and 0xFF) shl 16) or ((b[o + 3].toLong() and 0xFF) shl 24)

        private fun putU32(b: ByteArray, o: Int, v: Long) {
            for (i in 0 until 4) b[o + i] = ((v ushr (8 * i)) and 0xFF).toByte()
        }

        public fun decode(bytes: ByteArray, offset: Int = 0): MeshFrameHeader? {
            if (bytes.size - offset < SIZE) return null
            return MeshFrameHeader(
                to = u32(bytes, offset),
                from = u32(bytes, offset + 4),
                id = u32(bytes, offset + 8),
                flags = bytes[offset + 12].toInt() and 0xFF,
                channelHash = bytes[offset + 13].toInt() and 0xFF,
                nextHop = bytes[offset + 14].toInt() and 0xFF,
                relayNode = bytes[offset + 15].toInt() and 0xFF,
            )
        }
    }

    public fun encode(): ByteArray = ByteArray(SIZE).also {
        putU32(it, 0, to)
        putU32(it, 4, from)
        putU32(it, 8, id)
        it[12] = flags.toByte()
        it[13] = channelHash.toByte()
        it[14] = nextHop.toByte()
        it[15] = relayNode.toByte()
    }

    private fun putU32(b: ByteArray, o: Int, v: Long) {
        for (i in 0 until 4) b[o + i] = ((v ushr (8 * i)) and 0xFF).toByte()
    }
}
