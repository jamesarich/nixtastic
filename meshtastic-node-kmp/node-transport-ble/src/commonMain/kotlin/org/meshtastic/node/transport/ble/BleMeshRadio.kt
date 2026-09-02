package org.meshtastic.node.transport.ble

import kotlinx.coroutines.flow.Flow
import org.meshtastic.node.ble.BleMeshAdvert

/** One advertisement heard on the air, with the company ID already stripped. */
public class BleAdvertisement(
    /** `[version][MeshPacket]` - what [BleMeshAdvert.extractPacketFromBody] expects. */
    public val body: ByteArray,
    public val rssi: Int?,
)

/**
 * The platform's connectionless BLE, reduced to the two things a mesh needs: hear advertisements,
 * and emit them.
 *
 * Deliberately not a general BLE abstraction. Nothing here connects, discovers a service or reads a
 * characteristic, because a mesh over advertisements never does any of those - and an interface
 * that offered them would have to answer for three platforms that disagree completely about how
 * they work.
 *
 * The asymmetry is real and permanent, not a gap to be filled later:
 *
 *  - **Android** can do both. `BluetoothLeAdvertiser.startAdvertisingSet` with
 *    `setLegacyMode(false)` puts up to 251 bytes on the air.
 *  - **Apple platforms can only receive.** `CBPeripheralManager.startAdvertising` accepts exactly
 *    two keys, `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`;
 *    arbitrary payload is not expressible in the API at all. No library can work around this, which
 *    is why [canTransmit] is a property of the platform rather than of our implementation.
 *  - **JVM** has no BLE of its own. BlueZ over D-Bus would give Linux both directions.
 */
public interface BleMeshRadio {

    /** Whether this platform can put a mesh packet on the air. See the note above before assuming. */
    public val canTransmit: Boolean

    /**
     * Advertisements carrying our company ID. Cold: collection starts the scan and cancellation
     * stops it, so the radio is only powered up while a node is actually listening.
     */
    public fun advertisements(): Flow<BleAdvertisement>

    /**
     * Advertise [body] for [durationMs], then stop. Returns false when the platform cannot transmit.
     *
     * Bounded rather than continuous, because that is what the firmware does: `BLEMeshHandler`
     * holds a TX ring and gives each frame a short slot. A packet advertised forever would occupy
     * the only advertising set the mesh has and silence everything queued behind it.
     */
    public suspend fun advertise(body: ByteArray, durationMs: Long = DEFAULT_ADVERTISE_MS): Boolean

    public companion object {
        /** Matches `BLE_MESH_ADV_DURATION_MS` - long enough for neighbours mid-scan-window to hear it. */
        public const val DEFAULT_ADVERTISE_MS: Long = 300
    }
}

/** The platform's radio. */
public expect fun bleMeshRadio(companyId: Int = BleMeshAdvert.COMPANY_ID): BleMeshRadio
