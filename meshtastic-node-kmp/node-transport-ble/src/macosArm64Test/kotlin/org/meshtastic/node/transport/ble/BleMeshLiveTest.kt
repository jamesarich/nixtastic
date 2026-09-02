package org.meshtastic.node.transport.ble

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.toKString
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.meshtastic.node.ChannelSetUrl
import org.meshtastic.node.MeshEvent
import org.meshtastic.node.MeshIdentity
import org.meshtastic.node.MeshNode
import org.meshtastic.node.ProtoPacketCodec
import org.meshtastic.node.RelayPolicy
import platform.Foundation.NSDate
import platform.Foundation.timeIntervalSince1970
import platform.posix.getenv
import kotlin.test.Test
import kotlin.test.fail
import kotlin.time.Duration.Companion.seconds

/**
 * The BLE transport against a radio putting mesh packets on the air.
 *
 * Skipped unless `MESH_INTEROP_CHANNEL_URL` names the radio's channel, and it needs a radio built
 * with `BLE_MESH` whose `enabled_protocols` includes `BLE_BROADCAST`:
 *
 *     MESH_INTEROP_CHANNEL_URL='https://meshtastic.org/e/#...' \
 *         gradle :node-transport-ble:macosArm64Test
 *
 * Timing-dependent by nature: it needs a radio to actually send something on our channel while it
 * runs. A run that fails after the first test passed usually means the mesh went quiet, not that
 * anything regressed - rerun before investigating.
 *
 * On ESP32 this cannot be proven at the same time as UDP. `main-esp32.cpp` initialises NimBLE only
 * when `bluetooth.enabled && !network.wifi_enabled`, and the mesh handler waits on
 * `nimbleBluetooth->isActive()` before touching GAP - so with WiFi up the BLE mesh arms and never
 * advertises. Turn WiFi off on the radio and reboot it before running this.
 */
@OptIn(ExperimentalForeignApi::class)
class BleMeshLiveTest {

    private val channelUrl: String? = getenv("MESH_INTEROP_CHANNEL_URL")?.toKString()

    private fun nowMs(): Long = (NSDate().timeIntervalSince1970() * 1000).toLong()

    @Test
    fun `hears mesh advertisements on the air`() = runBlocking {
        val url = channelUrl ?: return@runBlocking println(
            "BleMeshLiveTest skipped: set MESH_INTEROP_CHANNEL_URL to run it against a radio",
        )
        ChannelSetUrl.decode(url) ?: fail("MESH_INTEROP_CHANNEL_URL did not decode")

        // The transport alone, before any decoding. This separates "Bluetooth saw nothing" from
        // "we saw frames and could not read them" - two failures that look identical from the
        // node's events flow, and the first of which is usually permission or a radio in the
        // wrong mode rather than anything in this library.
        val frames = withTimeoutOrNull(150.seconds) {
            BleMeshTransport().incoming().take(1).toList()
        } ?: fail(
            "No mesh advertisements in 150s. A radio only advertises when it has a packet to " +
                "send, so an idle mesh is genuinely silent - but check: the radio has BLE_BROADCAST in " +
                "network.enabled_protocols AND network.wifi_enabled = false (on ESP32 the BLE " +
                "stack does not come up otherwise); this process has macOS Bluetooth permission, " +
                "whose denial is silent; and the radio logs 'BLE mesh Bluetooth ready, scanning'.",
        )

        println("ble: heard ${frames.size} mesh advertisement(s), ${frames[0].bytes.size} bytes, rssi ${frames[0].rssi}")
    }

    @Test
    fun `decrypts a packet heard over BLE`() = runBlocking {
        val url = channelUrl ?: return@runBlocking
        val decoded = ChannelSetUrl.decode(url) ?: fail("MESH_INTEROP_CHANNEL_URL did not decode")

        val scope = CoroutineScope(SupervisorJob())
        val node = MeshNode(scope) {
            identity = MeshIdentity.derive("kmp-ble-bench".encodeToByteArray(), "kmp ble", "KBLE")
            channels += decoded
            transports += BleMeshTransport()
            codec = ProtoPacketCodec()
            relayPolicy = RelayPolicy.Island
            clock = { nowMs() }
        }

        try {
            // A node holding only this transport is receive-only, and says so rather than silently
            // dropping what it is asked to send.
            if (node.receiveOnlyTransports.size != 1) fail("BLE transport should be receive-only")

            val readable = withTimeoutOrNull(150.seconds) {
                node.events.first { it !is MeshEvent.Dropped && it !is MeshEvent.Opaque }
            } ?: fail(
                "Heard advertisements but decoded nothing readable in 150s. If the first test " +
                    "passed, the frames are arriving and this is a channel-key or framing problem, " +
                    "not a Bluetooth one.",
            )

            println("ble: decoded $readable")
        } finally {
            scope.cancel()
        }
    }
}
