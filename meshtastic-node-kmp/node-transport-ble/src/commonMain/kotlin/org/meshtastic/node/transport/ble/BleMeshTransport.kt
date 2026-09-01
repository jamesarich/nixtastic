package org.meshtastic.node.transport.ble

import com.juul.kable.Advertisement
import com.juul.kable.Filter
import com.juul.kable.Scanner
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.mapNotNull
import org.meshtastic.node.ble.BleMeshAdvert
import org.meshtastic.node.transport.InboundFrame
import org.meshtastic.node.transport.MeshTransport

/**
 * Mesh over connectionless BLE extended advertisements.
 *
 * The transport the library exists for: unlike UDP it needs no access point and no infrastructure
 * at all, which is the situation a mesh is actually for. Frames match what the firmware's
 * `BLEMeshHandler` emits - a whole encoded `MeshPacket` inside manufacturer data.
 *
 * **Receive only.** Kable is a central-role library: it scans, it does not advertise. Transmitting
 * needs the peripheral role, and there the platforms diverge sharply enough that a shared
 * abstraction would misrepresent them:
 *
 *  - **Android** can transmit, via `BluetoothLeAdvertiser.startAdvertisingSet` with
 *    `setLegacyMode(false)`, gated on `isLeExtendedAdvertisingSupported()` and needing the
 *    `BLUETOOTH_ADVERTISE` runtime permission from API 31.
 *  - **Apple platforms cannot transmit at all.** CoreBluetooth accepts only
 *    `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`; arbitrary payload
 *    is not expressible. An Apple node can listen to a BLE mesh and never speak on it.
 *
 * So [canTransmit] is false, and a platform that can send supplies a sending transport alongside
 * this one. Honest rather than limiting: a node holding only receive-only transports says so, and
 * `MeshNode.sendText` returns false rather than silently dropping.
 *
 * One more constraint worth knowing before shipping: iOS can only scan in the background while
 * filtering by *service UUID*, so manufacturer data is invisible to a backgrounded app. That fix
 * belongs in the on-air format - service data under an assigned 16-bit UUID - and needs agreeing
 * with the firmware rather than working around here.
 */
public class BleMeshTransport(
    private val companyId: Int = BleMeshAdvert.COMPANY_ID,
    private val scanner: Scanner<Advertisement> = defaultScanner(companyId),
) : MeshTransport {

    override val canTransmit: Boolean = false

    /**
     * Frames heard on the air. Cold, as Kable's own advertisements flow is: collection starts the
     * scan and cancellation stops it, so scanning lives exactly as long as the node's scope.
     */
    override fun incoming(): Flow<InboundFrame> = scanner.advertisements.mapNotNull { advertisement ->
        // Kable strips the 2-byte company ID, so what is left is [version][MeshPacket] - the shape
        // buildManufacturerBody produces.
        val body = advertisement.manufacturerData(companyId) ?: return@mapNotNull null
        val packet = BleMeshAdvert.extractPacketFromBody(body) ?: return@mapNotNull null
        InboundFrame(packet, advertisement.rssi)
    }

    override suspend fun send(encodedPacket: ByteArray): Boolean = false

    public companion object {
        /**
         * Filtering in the scanner rather than in the flow, so the platform can push it down to the
         * controller - on a phone that is the difference between a background scan the OS allows to
         * run and one it throttles.
         */
        public fun defaultScanner(companyId: Int = BleMeshAdvert.COMPANY_ID): Scanner<Advertisement> = Scanner {
            filters {
                match {
                    manufacturerData = listOf(
                        Filter.ManufacturerData(
                            id = companyId,
                            // Match the protocol-version byte too: 0xFFFF is the SIG test company
                            // ID, so anything else using it would otherwise reach our decoder.
                            data = byteArrayOf(BleMeshAdvert.PROTOCOL_VERSION.toByte()),
                            dataMask = byteArrayOf(0xFF.toByte()),
                        ),
                    )
                }
            }
        }
    }
}
