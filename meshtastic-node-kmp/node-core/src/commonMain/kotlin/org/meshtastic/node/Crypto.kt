package org.meshtastic.node

/**
 * The single platform seam in node-core.
 *
 * AES-CTR is all the channel layer needs, and every target has it: `javax.crypto` on JVM and
 * Android, CryptoKit on Apple. Keeping it behind one expect/actual means the protocol code above is
 * pure Kotlin and testable on any target, and a platform that wants a hardware-backed key store can
 * swap this without touching the protocol.
 */
internal expect fun aesCtrTransform(key: ByteArray, iv: ByteArray, data: ByteArray): ByteArray
