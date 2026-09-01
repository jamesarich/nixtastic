package org.meshtastic.node.transport.ble

import io.kotest.matchers.shouldBe
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
    fun `the transport reports that it cannot transmit`() {
        // Kable is central-role only. Apple cannot advertise arbitrary payload at all, so this is
        // not a gap to fill later on every platform - it is the truth on some of them.
        BleMeshTransport().canTransmit shouldBe false
    }
}
