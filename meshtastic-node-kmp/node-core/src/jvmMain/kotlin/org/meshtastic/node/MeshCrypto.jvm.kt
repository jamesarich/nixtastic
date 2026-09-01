package org.meshtastic.node

import dev.whyoleg.cryptography.CryptographyProvider
import dev.whyoleg.cryptography.providers.jdk.JDK
import org.bouncycastle.jce.provider.BouncyCastleProvider

/**
 * BouncyCastle rather than the platform default, because the JDK ships no AES-CCM.
 *
 * Constructed directly rather than installed into [java.security.Security]: registering a JCA
 * provider globally changes crypto for the whole process, which is not a library's decision to make
 * on its host application's behalf.
 */
internal actual fun meshCryptographyProvider(): CryptographyProvider =
    CryptographyProvider.JDK(BouncyCastleProvider())
