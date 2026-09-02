package org.meshtastic.node

import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import okio.ByteString.Companion.toByteString
import org.meshtastic.proto.ChannelSet
import org.meshtastic.proto.ChannelSettings

/**
 * The `https://meshtastic.org/e/#...` channel URL - a base64url `ChannelSet` in the fragment.
 *
 * This is how a human moves a channel between devices, so a node that cannot read one cannot be
 * configured by the same means as every radio and phone app. It is also the only way to get a
 * channel's key off a device you own without reading its flash.
 *
 * The fragment is a URL fragment, so it never leaves the browser - which is what makes it
 * acceptable to put a key there at all.
 */
@OptIn(ExperimentalEncodingApi::class)
public object ChannelSetUrl {

    private const val PREFIX = "https://meshtastic.org/e/#"

    // Encoders in the wild disagree about padding: the firmware and the Android app strip it, some
    // hand-built URLs keep it. Accepting either costs nothing and rejecting one is a support burden.
    private val base64 = Base64.UrlSafe.withPadding(Base64.PaddingOption.PRESENT_OPTIONAL)

    /**
     * Decode a channel URL to its channels, primary first.
     *
     * Accepts a whole URL or a bare fragment, and tolerates the `?add=true` query the apps append.
     * Returns null when the input is not a channel URL or does not parse.
     */
    public fun decode(url: String): List<MeshChannel>? {
        val fragment = url.substringAfter('#', missingDelimiterValue = url)
            .substringBefore('?')
            .trim()
        if (fragment.isEmpty()) return null

        val bytes = runCatching { base64.decode(fragment) }.getOrNull() ?: return null
        val set = runCatching { ChannelSet.ADAPTER.decode(bytes) }.getOrNull() ?: return null

        // A ChannelSet with no settings decodes fine from arbitrary bytes - protobuf is happy to
        // read almost anything as an empty message - so an empty result means "not a channel URL"
        // rather than "a channel URL with no channels".
        if (set.settings.isEmpty()) return null

        return set.settings.map { MeshChannel(name = it.name, psk = it.psk.toByteArray()) }
    }

    /** The inverse, for sharing this node's channels the way a radio would. */
    public fun encode(channels: List<MeshChannel>): String {
        val set = ChannelSet(
            settings = channels.map { ChannelSettings(name = it.name, psk = it.psk.toByteString()) },
        )
        return PREFIX + base64.encode(ChannelSet.ADAPTER.encode(set)).trimEnd('=')
    }
}
