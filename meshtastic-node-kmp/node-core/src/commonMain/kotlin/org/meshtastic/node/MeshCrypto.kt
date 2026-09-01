package org.meshtastic.node

import dev.whyoleg.cryptography.CryptographyProvider

/**
 * The crypto backend this library uses, chosen per platform.
 *
 * The only expect/actual in node-core, and it exists for one reason: **AES-CCM**. Meshtastic's PKI
 * layer for direct messages needs it, and it is unusually scarce - the JDK's default JCA provider
 * does not have it (`NoSuchAlgorithmException: Cannot find any provider supporting
 * AES/CCM/NoPadding`) and neither does Apple's CryptoKit. openssl3 has it everywhere but publishes
 * no JVM artifact.
 *
 * So: BouncyCastle behind the JDK provider on JVM, openssl3 on Apple targets. Everything above this
 * line stays common.
 */
internal expect fun meshCryptographyProvider(): CryptographyProvider
