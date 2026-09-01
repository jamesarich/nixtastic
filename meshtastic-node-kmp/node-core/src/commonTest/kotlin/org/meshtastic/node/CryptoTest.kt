package org.meshtastic.node

import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class ChannelCryptoTest {

    private val crypto = ChannelCrypto()
    private val psk = ByteArray(32) { it.toByte() }

    @Test
    fun `is its own inverse`() = runTest {
        val plaintext = "the quick brown fox".encodeToByteArray()
        val ciphertext = crypto.transform(plaintext, psk, packetId = 42, fromNode = 0x3061b02e)

        ciphertext shouldNotBe plaintext
        crypto.transform(ciphertext, psk, packetId = 42, fromNode = 0x3061b02e) shouldBe plaintext
    }

    @Test
    fun `a different packet id yields different ciphertext`() = runTest {
        // The nonce is packet-derived, so reuse across packets would be a keystream reuse bug.
        val plaintext = ByteArray(32)
        val a = crypto.transform(plaintext, psk, packetId = 1, fromNode = 7)
        val b = crypto.transform(plaintext, psk, packetId = 2, fromNode = 7)

        a shouldNotBe b
    }

    @Test
    fun `a cleartext channel passes bytes through untouched`() = runTest {
        val plaintext = "in the clear".encodeToByteArray()

        crypto.transform(plaintext, ByteArray(0), 1, 1) shouldBe plaintext
        crypto.transform(plaintext, byteArrayOf(0), 1, 1) shouldBe plaintext
    }

    @Test
    fun `builds the nonce the firmware builds`() {
        val nonce = ChannelCrypto.buildNonce(packetId = 0x04050b6e, fromNode = 0x3061b02e)

        nonce.toHex() shouldBe "6e0b0504000000002eb0613000000000"
    }

    @Test
    fun `resolves the short-form psk index the way the firmware does`() {
        assertNull(ChannelCrypto.resolveKey(byteArrayOf(0)), "index 0 is cleartext")
        assertNull(ChannelCrypto.resolveKey(ByteArray(0)), "empty psk is cleartext")

        val one = assertNotNull(ChannelCrypto.resolveKey(byteArrayOf(1)))
        val three = assertNotNull(ChannelCrypto.resolveKey(byteArrayOf(3)))
        one.size shouldBe 16
        three[15] shouldBe (one[15] + 2).toByte()

        val raw = ByteArray(32) { it.toByte() }
        assertNotNull(ChannelCrypto.resolveKey(raw)).toHex() shouldBe raw.toHex()
    }
}

class PkiCryptoTest {

    private val pki = PkiCrypto()


    @Test
    fun `a peer can read what was sent to it`() = runTest {
        val alice = pki.generateKeyPair()
        val bob = pki.generateKeyPair()
        val plaintext = "for your eyes only".encodeToByteArray()

        val sealed = pki.encrypt(plaintext, alice.privateKey, bob.publicKey, packetId = 9, fromNode = 1, extraNonce = 0x11223344)
        // ECDH is symmetric: Bob derives the same key from his private and Alice's public.
        val opened = pki.decrypt(sealed, bob.privateKey, alice.publicKey, packetId = 9, fromNode = 1)

        opened shouldBe plaintext
    }

    @Test
    fun `wire overhead is the twelve bytes the firmware reserves`() = runTest {
        val alice = pki.generateKeyPair()
        val bob = pki.generateKeyPair()
        val plaintext = ByteArray(20)
        val sealed = pki.encrypt(plaintext, alice.privateKey, bob.publicKey, 1, 1, 0)

        pki.overhead shouldBe 12
        sealed.size shouldBe plaintext.size + 12
    }

    @Test
    fun `a third party holding the channel key still cannot read it`() = runTest {
        val alice = pki.generateKeyPair()
        val bob = pki.generateKeyPair()
        val eve = pki.generateKeyPair()
        val sealed = pki.encrypt("secret".encodeToByteArray(), alice.privateKey, bob.publicKey, 1, 1, 0)

        // This is the whole point of the PKI layer: channel membership is not readership.
        pki.decrypt(sealed, eve.privateKey, alice.publicKey, 1, 1) shouldBe null
    }

    @Test
    fun `tampering is detected`() = runTest {
        val alice = pki.generateKeyPair()
        val bob = pki.generateKeyPair()
        val sealed = pki.encrypt("intact".encodeToByteArray(), alice.privateKey, bob.publicKey, 1, 1, 0)
        val tampered = sealed.copyOf().also { it[0] = (it[0] + 1).toByte() }

        // Unlike the channel layer, CCM's MAC makes a wrong or altered packet detectable rather
        // than merely unparseable.
        pki.decrypt(tampered, bob.privateKey, alice.publicKey, 1, 1) shouldBe null
    }

    @Test
    fun `the wrong packet id does not decrypt`() = runTest {
        val alice = pki.generateKeyPair()
        val bob = pki.generateKeyPair()
        val sealed = pki.encrypt("bound".encodeToByteArray(), alice.privateKey, bob.publicKey, 9, 1, 0)

        // The nonce is rebuilt from packet metadata, so the ciphertext is bound to its packet.
        pki.decrypt(sealed, bob.privateKey, alice.publicKey, packetId = 10, fromNode = 1) shouldBe null
    }

    @Test
    fun `builds the thirteen byte ccm nonce`() {
        val nonce = PkiCrypto.buildNonce(packetId = 0x04050b6e, fromNode = 0x3061b02e, extraNonce = 0x11223344)

        nonce.size shouldBe 13
        // id, then extraNonce, then sender, all little-endian; byte 12 reserved.
        nonce.toHex() shouldBe "6e0b050444332211" + "2eb06130" + "00"
    }
}

internal fun ByteArray.toHex(): String = joinToString("") {
    val v = it.toInt() and 0xFF
    "0123456789abcdef"[v ushr 4].toString() + "0123456789abcdef"[v and 0xF]
}
