package org.meshtastic.node

import dev.whyoleg.cryptography.BinarySize.Companion.bytes
import dev.whyoleg.cryptography.CryptographyProvider
import dev.whyoleg.cryptography.DelicateCryptographyApi
import dev.whyoleg.cryptography.algorithms.AES
import dev.whyoleg.cryptography.algorithms.SHA256
import dev.whyoleg.cryptography.algorithms.XDH

/**
 * Per-peer encryption for direct messages.
 *
 * Channel encryption is a shared room: anyone holding the PSK reads everything on it. A DM needs
 * more than that, so Meshtastic wraps it in X25519 -> SHA-256 -> AES-256-CCM, keyed per peer pair.
 * Outside Ham mode there is no fallback - if the destination's public key is unknown the send
 * fails rather than quietly going out under the channel key.
 *
 * Shape, from CryptoEngine::encryptCurve25519:
 *  - shared secret = X25519(our private, their public), hashed with SHA-256 into a 256-bit key
 *  - AES-256-CCM, 8-byte MAC, no AAD (the MAC covers ciphertext only)
 *  - 13-byte CCM nonce: bytes 0..3 packet id, 4..7 a fresh random extraNonce, 8..11 sender, 12 zero
 *  - 12 bytes of wire overhead: the 8-byte MAC then the 4-byte extraNonce, appended to ciphertext
 *
 * Recomputed per packet. There is no ratchet and no session, which is deliberate: a store-and-
 * forward mesh with heavy loss cannot keep two endpoints in step.
 */
@OptIn(DelicateCryptographyApi::class)
public class PkiCrypto(
    provider: CryptographyProvider = meshCryptographyProvider(),
) {
    private val xdh = provider.get(XDH)
    private val sha256 = provider.get(SHA256)
    private val ccm = provider.get(AES.CCM)

    /**
     * Generate this node's X25519 identity.
     *
     * Persist it: the public half is what peers store to reach you, so a node that regenerates on
     * restart becomes unreachable by direct message until every peer re-learns it - the firmware
     * has the same hazard around factory_reset_device.
     */
    public suspend fun generateKeyPair(): MeshKeyPair {
        val pair = xdh.keyPairGenerator(XDH.Curve.X25519).generateKey()
        return MeshKeyPair(
            privateKey = pair.privateKey.encodeToByteArray(XDH.PrivateKey.Format.RAW),
            publicKey = pair.publicKey.encodeToByteArray(XDH.PublicKey.Format.RAW),
        )
    }

    /** Bytes appended to the ciphertext: MAC then extraNonce. `MESHTASTIC_PKC_OVERHEAD`. */
    public val overhead: Int get() = MAC_SIZE + EXTRA_NONCE_SIZE

    /**
     * Encrypt [plaintext] to [peerPublicKey], returning `ciphertext ‖ mac ‖ extraNonce`.
     *
     * [extraNonce] must be freshly random per packet. It is an input rather than generated here so
     * a caller can supply a tested source, and so this stays deterministic under test - a nonce
     * reused with the same key breaks CCM outright.
     */
    public suspend fun encrypt(
        plaintext: ByteArray,
        ourPrivateKey: ByteArray,
        peerPublicKey: ByteArray,
        packetId: Long,
        fromNode: Long,
        extraNonce: Int,
    ): ByteArray {
        val key = deriveKey(ourPrivateKey, peerPublicKey)
        val sealed = key.cipher(tagSize = MAC_SIZE.bytes)
            .encryptWithIv(buildNonce(packetId, fromNode, extraNonce), plaintext)
        // encryptWithIv yields [ciphertext | tag]; the wire wants the 4-byte extraNonce after it.
        return sealed + extraNonceBytes(extraNonce)
    }

    /**
     * Decrypt a packet of the form `ciphertext ‖ mac ‖ extraNonce`, or null if the MAC does not
     * verify - which is the one place in this protocol where a wrong key is actually detectable.
     */
    public suspend fun decrypt(
        payload: ByteArray,
        ourPrivateKey: ByteArray,
        peerPublicKey: ByteArray,
        packetId: Long,
        fromNode: Long,
    ): ByteArray? {
        if (payload.size <= overhead) return null

        val extraNonce = readExtraNonce(payload, payload.size - EXTRA_NONCE_SIZE)
        val sealed = payload.copyOfRange(0, payload.size - EXTRA_NONCE_SIZE)
        val key = deriveKey(ourPrivateKey, peerPublicKey)

        return runCatching {
            key.cipher(tagSize = MAC_SIZE.bytes)
                .decryptWithIv(buildNonce(packetId, fromNode, extraNonce), sealed)
        }.getOrNull()
    }

    /** X25519 then SHA-256, which is the KDF over the raw ECDH output. */
    private suspend fun deriveKey(ourPrivateKey: ByteArray, peerPublicKey: ByteArray): AES.CCM.Key {
        val privateKey = xdh.privateKeyDecoder(XDH.Curve.X25519).decodeFromByteArray(XDH.PrivateKey.Format.RAW, ourPrivateKey)
        val publicKey = xdh.publicKeyDecoder(XDH.Curve.X25519).decodeFromByteArray(XDH.PublicKey.Format.RAW, peerPublicKey)
        val shared = privateKey.sharedSecretGenerator().generateSharedSecretToByteArray(publicKey)
        val hashed = sha256.hasher().hash(shared)
        return ccm.keyDecoder().decodeFromByteArray(AES.Key.Format.RAW, hashed)
    }

    public companion object {
        /** CCM's M parameter. Short by modern standards, but it is what the firmware uses. */
        public const val MAC_SIZE: Int = 8
        public const val EXTRA_NONCE_SIZE: Int = 4

        /**
         * The 13-byte CCM nonce (L = 2 is hardcoded in the firmware's aes-ccm.cpp). Only the
         * extraNonce travels; the rest is reconstructed from packet metadata on receipt.
         */
        public fun buildNonce(packetId: Long, fromNode: Long, extraNonce: Int): ByteArray {
            val nonce = ByteArray(13)
            for (i in 0 until 4) nonce[i] = ((packetId ushr (8 * i)) and 0xFF).toByte()
            for (i in 0 until 4) nonce[4 + i] = ((extraNonce ushr (8 * i)) and 0xFF).toByte()
            for (i in 0 until 4) nonce[8 + i] = ((fromNode ushr (8 * i)) and 0xFF).toByte()
            return nonce // byte 12 stays zero
        }

        private fun extraNonceBytes(extraNonce: Int): ByteArray =
            ByteArray(EXTRA_NONCE_SIZE) { ((extraNonce ushr (8 * it)) and 0xFF).toByte() }

        private fun readExtraNonce(bytes: ByteArray, offset: Int): Int {
            var v = 0
            for (i in 0 until EXTRA_NONCE_SIZE) v = v or ((bytes[offset + i].toInt() and 0xFF) shl (8 * i))
            return v
        }
    }
}

/** An X25519 identity keypair, in the raw 32-byte form the wire and NodeDB use. */
public data class MeshKeyPair(val privateKey: ByteArray, val publicKey: ByteArray) {
    override fun equals(other: Any?): Boolean = this === other || (
        other is MeshKeyPair &&
            privateKey.contentEquals(other.privateKey) &&
            publicKey.contentEquals(other.publicKey)
        )

    override fun hashCode(): Int = 31 * privateKey.contentHashCode() + publicKey.contentHashCode()

    // Never let a private key reach a log.
    override fun toString(): String = "MeshKeyPair(publicKey=${publicKey.size} bytes, privateKey=redacted)"
}
