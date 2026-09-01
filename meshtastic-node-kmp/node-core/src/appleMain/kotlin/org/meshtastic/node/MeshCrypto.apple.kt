package org.meshtastic.node

import dev.whyoleg.cryptography.CryptographyProvider
import dev.whyoleg.cryptography.providers.openssl3.Openssl3

/** CryptoKit has no AES-CCM; the prebuilt openssl3 provider does. */
internal actual fun meshCryptographyProvider(): CryptographyProvider = CryptographyProvider.Openssl3
