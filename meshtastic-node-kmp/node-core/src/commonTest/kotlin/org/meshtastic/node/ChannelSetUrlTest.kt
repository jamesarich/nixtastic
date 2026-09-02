package org.meshtastic.node

import io.kotest.matchers.shouldBe
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class ChannelSetUrlTest {

    private val longFast = MeshChannel("LongFast", byteArrayOf(1))
    private val private = MeshChannel("private", ByteArray(32) { (it * 7).toByte() })

    @Test
    fun `round-trips a channel set`() {
        val original = listOf(longFast, private)

        assertNotNull(ChannelSetUrl.decode(ChannelSetUrl.encode(original))) shouldBe original
    }

    @Test
    fun `keeps the primary channel first`() {
        // Position is the whole encoding of "which one is primary" - ChannelSet has no role field.
        val url = ChannelSetUrl.encode(listOf(private, longFast))

        assertNotNull(ChannelSetUrl.decode(url)).first() shouldBe private
    }

    @Test
    fun `the decoded channel hashes to what a device puts on the wire`() {
        val channel = assertNotNull(ChannelSetUrl.decode(ChannelSetUrl.encode(listOf(private)))).single()

        // The hash is what MeshPacket.channel carries, so getting it wrong means every packet on
        // this channel is passed over as belonging to some other one.
        channel.hash shouldBe (
            "private".encodeToByteArray().fold(0) { h, c -> h xor (c.toInt() and 0xFF) } xor
                channel.psk.fold(0) { h, b -> h xor (b.toInt() and 0xFF) }
            ) and 0xFF
    }

    @Test
    fun `accepts a bare fragment and the apps' add query`() {
        val url = ChannelSetUrl.encode(listOf(longFast))

        assertNotNull(ChannelSetUrl.decode(url.substringAfter('#'))).single().name shouldBe "LongFast"
        assertNotNull(ChannelSetUrl.decode("$url?add=true")).single().name shouldBe "LongFast"
    }

    @Test
    fun `accepts padded and unpadded base64`() {
        // Encoders in the wild disagree; the firmware and the apps strip padding, hand-built URLs
        // sometimes keep it.
        val stripped = ChannelSetUrl.encode(listOf(longFast)).substringAfter('#')
        val padded = stripped + "=".repeat((4 - stripped.length % 4) % 4)

        assertNotNull(ChannelSetUrl.decode(padded)).single().name shouldBe "LongFast"
    }

    @Test
    fun `refuses input that is not a channel URL`() {
        assertNull(ChannelSetUrl.decode("https://meshtastic.org/e/#"))
        assertNull(ChannelSetUrl.decode("not a url at all !!!"))
        // Protobuf reads almost any bytes as an empty message, so "parsed" is not enough on its own.
        assertNull(ChannelSetUrl.decode("https://meshtastic.org/e/#AA"))
    }

    @Test
    fun `a short-form PSK expands to the well-known default key`() {
        val channel = assertNotNull(ChannelSetUrl.decode(ChannelSetUrl.encode(listOf(longFast)))).single()

        // Index 1 is the default PSK unchanged - the key behind every stock radio.
        assertNotNull(ChannelCrypto.resolveKey(channel.psk)).first() shouldBe 0xd4.toByte()
    }
}
