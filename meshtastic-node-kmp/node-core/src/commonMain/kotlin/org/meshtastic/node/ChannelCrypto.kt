package org.meshtastic.node

import dev.whyoleg.cryptography.CryptographyProvider
import dev.whyoleg.cryptography.DelicateCryptographyApi
import dev.whyoleg.cryptography.algorithms.AES

/**
 * Meshtastic per-channel symmetric encryption.
 *
 * No Meshtastic client implements this today: the radio does it, and clients only ever see decoded
 * packets over the phone API. A client that participates as a node has to do it itself, because
 * every mesh transport - LoRa, UDP multicast, BLE advertisement - carries `MeshPacket`s whose
 * payload is still `encrypted`.
 *
 * AES-CTR, keyed by the channel PSK. CTR is symmetric, so [transform] serves both directions.
 *
 * There is no AEAD, and that is not an oversight: channel packets carry no MAC. The
 * `MeshPacket.channel` byte is a hash *hint* for picking a candidate PSK, not an integrity check -
 * collisions are cheap to find, so a matching hash is never authentication.
 */
// AES-CTR is 'delicate' precisely because it authenticates nothing. That is not a choice open
// to us: it is what Meshtastic puts on the air, and a client that wants to read the mesh has
// to speak it. The consequences are spelled out in the class doc.
@OptIn(DelicateCryptographyApi::class)
public class ChannelCrypto(
    provider: CryptographyProvider = meshCryptographyProvider(),
) {
    private val aes = provider.get(AES.CTR)

    /**
     * Encrypt or decrypt [payload] - CTR is its own inverse, so this is the same call either way.
     * Returns [payload] unchanged when the channel has no key (cleartext channel, or Ham mode).
     */
    public suspend fun transform(
        payload: ByteArray,
        psk: ByteArray,
        packetId: Long,
        fromNode: Long,
    ): ByteArray {
        val keyBytes = resolveKey(psk) ?: return payload
        val key = aes.keyDecoder().decodeFromByteArray(AES.Key.Format.RAW, keyBytes)
        // encryptWithIv, not encrypt: the nonce is derived from packet fields on both sides, so it
        // must not be generated or prepended for us.
        return key.cipher().encryptWithIv(buildNonce(packetId, fromNode), payload)
    }

    public companion object {
        /** Meshtastic's well-known default PSK ("AQ=="), the base for the 1-byte short form. */
        private val DEFAULT_PSK = byteArrayOf(
            0xd4.toByte(), 0xf1.toByte(), 0xbb.toByte(), 0x3a.toByte(),
            0x20.toByte(), 0x29.toByte(), 0x07.toByte(), 0x59.toByte(),
            0xf0.toByte(), 0xbc.toByte(), 0xff.toByte(), 0xab.toByte(),
            0xcf.toByte(), 0x4e.toByte(), 0x69.toByte(), 0x01.toByte(),
        )

        /**
         * Resolve a `ChannelSettings.psk` field to the actual AES key, following the firmware's
         * size semantics exactly (CryptoEngine / Channels.h):
         *
         *  - 0 bytes       -> no encryption; returns null and the packet is cleartext on air
         *  - 1 byte        -> index into the well-known default PSK. 0 is cleartext; 1 is the
         *                     default unchanged; 2..255 increments its last byte by (n-1)
         *  - 16 / 32       -> a raw AES-128 / AES-256 key, used as-is
         *  - 2..15, 17..31 -> zero-padded to 16 or 32. A defensive fallback for malformed input.
         */
        public fun resolveKey(psk: ByteArray): ByteArray? = when {
            psk.isEmpty() -> null
            psk.size == 1 -> when (val idx = psk[0].toInt() and 0xFF) {
                0 -> null
                else -> DEFAULT_PSK.copyOf().also {
                    it[it.size - 1] = (it[it.size - 1] + (idx - 1)).toByte()
                }
            }
            psk.size == 16 || psk.size == 32 -> psk
            psk.size < 16 -> psk.copyOf(16)
            psk.size < 32 -> psk.copyOf(32)
            else -> psk.copyOf(32)
        }

        /**
         * The 128-bit CTR nonce: `packet_id` as u64 LE, then `from` as u32 LE, then a u32 block
         * counter starting at zero.
         *
         * Both ids are 32-bit on the wire but taken as [Long] here, because Kotlin's Int is signed
         * and a NodeNum above 0x7FFFFFFF is entirely ordinary.
         */
        public fun buildNonce(packetId: Long, fromNode: Long): ByteArray {
            val nonce = ByteArray(16)
            for (i in 0 until 8) nonce[i] = ((packetId ushr (8 * i)) and 0xFF).toByte()
            for (i in 0 until 4) nonce[8 + i] = ((fromNode ushr (8 * i)) and 0xFF).toByte()
            return nonce // bytes 12..15 stay zero: the block counter
        }
    }
}
