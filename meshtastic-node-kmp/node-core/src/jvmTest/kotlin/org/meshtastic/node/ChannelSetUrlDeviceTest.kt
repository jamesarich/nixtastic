package org.meshtastic.node

import io.kotest.matchers.shouldBe
import kotlin.test.Test
import kotlin.test.assertNotNull

/**
 * The decoder against a URL a radio actually emitted.
 *
 * Round-tripping our own encoder cannot catch a field number we got wrong in both directions, so
 * this is the only test of the pair that proves anything about interoperability. A channel URL *is*
 * a key, so it comes from the environment and is never written down here; the test skips without it.
 */
class ChannelSetUrlDeviceTest {

    @Test
    fun `decodes a URL a real device emitted`() {
        val fromDevice = System.getenv("MESH_INTEROP_CHANNEL_URL") ?: return

        val channels = assertNotNull(ChannelSetUrl.decode(fromDevice))
        channels.isNotEmpty() shouldBe true
        channels.first().name.isNotEmpty() shouldBe true
        // A device's primary channel always has a usable key; a URL that decodes to a cleartext
        // channel means we mis-parsed the psk field rather than that the radio is unencrypted.
        channels.first().isCleartext shouldBe false
    }
}
