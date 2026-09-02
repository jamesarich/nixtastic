package org.meshtastic.node.transport.ble

import io.kotest.matchers.shouldBe
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runTest
import org.meshtastic.node.ble.BleMeshAdvert
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * The framing contract with the firmware's `BLEMeshHandler`.
 *
 * The scan itself needs a radio and is exercised by BleMeshScanTest on macOS; this is the part that
 * has to be right on every platform regardless of whether one is present.
 */
class BleAdvertFramingTest {

    @Test
    fun `a manufacturer body round-trips`() {
        val packet = ByteArray(64) { it.toByte() }
        val body = BleMeshAdvert.buildManufacturerBody(packet)

        // Platform scan APIs hand back the body with the company ID already stripped, so this is
        // the form the transport actually sees.
        assertNotNull(BleMeshAdvert.extractPacketFromBody(body)).contentEquals(packet) shouldBe true
    }

    @Test
    fun `a body from another protocol version is refused`() {
        val body = byteArrayOf((BleMeshAdvert.PROTOCOL_VERSION + 1).toByte(), 1, 2, 3)

        // 0xFFFF is the SIG test company ID, so other users of it will reach this decoder. The
        // version byte is what keeps their payloads from being parsed as mesh packets.
        assertNull(BleMeshAdvert.extractPacketFromBody(body))
    }

    @Test
    fun `an empty or truncated body is refused`() {
        assertNull(BleMeshAdvert.extractPacketFromBody(ByteArray(0)))
        assertNull(BleMeshAdvert.extractPacketFromBody(byteArrayOf(BleMeshAdvert.PROTOCOL_VERSION.toByte())))
    }

    @Test
    fun `the single-PDU budget matches what the firmware enforces`() {
        // 251 is BLE_HCI_MAX_EXT_ADV_DATA_LEN, not the 254 an AUX_ADV_IND could hold: the HCI
        // set-data command spends four of its 255 parameter bytes on its own fields.
        BleMeshAdvert.ADV_TOTAL_MAX shouldBe 251
        BleMeshAdvert.ADV_OVERHEAD shouldBe 8
        BleMeshAdvert.MAX_PACKET_LEN shouldBe 243
    }

    @Test
    fun `a transport over a receive-only radio refuses to send`() {
        // canTransmit is now the platform's answer, so the per-platform assertions live in the
        // platform test source sets. What is true everywhere is that a transport does not pretend:
        // over a radio that cannot transmit, send fails rather than silently dropping.
        val transport = BleMeshTransport(ReceiveOnlyRadio)

        transport.canTransmit shouldBe false
        runTest { transport.send(ByteArray(32)) shouldBe false }
    }

    @Test
    fun `a packet too large for one advertisement is refused rather than truncated`() = runTest {
        val radio = RecordingRadio()
        val transport = BleMeshTransport(radio)

        transport.send(ByteArray(BleMeshAdvert.MAX_PACKET_LEN + 1)) shouldBe false
        radio.advertised.isEmpty() shouldBe true

        // Fragmentation is not something the firmware offers, so the boundary is hard.
        transport.send(ByteArray(BleMeshAdvert.MAX_PACKET_LEN)) shouldBe true
        radio.advertised.single().size shouldBe BleMeshAdvert.MAX_PACKET_LEN + 1 // + the version byte
    }

    @Test
    fun `a sent packet round-trips through what a scanner would hear`() = runTest {
        val radio = RecordingRadio()
        val packet = ByteArray(48) { it.toByte() }

        BleMeshTransport(radio).send(packet) shouldBe true

        // The body we advertise is exactly the body the receive path expects, so the two halves of
        // this transport cannot drift apart.
        assertNotNull(BleMeshAdvert.extractPacketFromBody(radio.advertised.single()))
            .contentEquals(packet) shouldBe true
    }
}

private object ReceiveOnlyRadio : BleMeshRadio {
    override val canTransmit: Boolean = false
    override fun advertisements(): Flow<BleAdvertisement> = emptyFlow()
    override suspend fun advertise(body: ByteArray, durationMs: Long): Boolean = false
}

private class RecordingRadio : BleMeshRadio {
    val advertised = mutableListOf<ByteArray>()
    override val canTransmit: Boolean = true
    override fun advertisements(): Flow<BleAdvertisement> = emptyFlow()
    override suspend fun advertise(body: ByteArray, durationMs: Long): Boolean {
        advertised += body
        return true
    }
}
