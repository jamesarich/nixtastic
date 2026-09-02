package org.meshtastic.node.transport.ble

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import platform.CoreBluetooth.CBAdvertisementDataManufacturerDataKey
import platform.CoreBluetooth.CBCentralManager
import platform.CoreBluetooth.CBCentralManagerDelegateProtocol
import platform.CoreBluetooth.CBCentralManagerScanOptionAllowDuplicatesKey
import platform.CoreBluetooth.CBManagerStatePoweredOn
import platform.CoreBluetooth.CBPeripheral
import platform.Foundation.NSData
import platform.Foundation.NSNumber
import platform.darwin.NSObject
import platform.darwin.dispatch_queue_create
import platform.posix.memcpy

@OptIn(ExperimentalForeignApi::class)
internal fun NSData.toByteArray(): ByteArray {
    val size = length.toInt()
    if (size == 0) return ByteArray(0)
    return ByteArray(size).apply { usePinned { memcpy(it.addressOf(0), bytes, length) } }
}

public actual fun bleMeshRadio(companyId: Int): BleMeshRadio = AppleBleMeshRadio(companyId)

/**
 * CoreBluetooth, directly.
 *
 * Receive only, and not because of anything here: `CBPeripheralManager.startAdvertising` accepts
 * only a local name and a list of service UUIDs, so a mesh packet cannot be expressed as an Apple
 * advertisement at all.
 */
private class AppleBleMeshRadio(private val companyId: Int) : BleMeshRadio {

    override val canTransmit: Boolean = false

    @OptIn(ExperimentalForeignApi::class)
    override fun advertisements(): Flow<BleAdvertisement> = callbackFlow {
        // Our own serial queue rather than the main one: delivery must not depend on a run loop the
        // host may not be running, which is exactly the situation in a test binary.
        val queue = dispatch_queue_create("org.meshtastic.node.ble.scan", null)

        val delegate = object : NSObject(), CBCentralManagerDelegateProtocol {

            override fun centralManagerDidUpdateState(central: CBCentralManager) {
                // Scanning before the manager reports poweredOn is silently discarded, so the scan
                // starts here rather than at construction.
                if (central.state != CBManagerStatePoweredOn) return
                // Without allowDuplicates CoreBluetooth reports each device once and then goes
                // quiet - and a mesh node's whole point is that its payload changes every frame.
                // The failure is silent and looks exactly like an idle mesh.
                val options = mapOf<Any?, Any?>(CBCentralManagerScanOptionAllowDuplicatesKey to true)
                central.scanForPeripheralsWithServices(serviceUUIDs = null, options = options)
            }

            override fun centralManager(
                central: CBCentralManager,
                didDiscoverPeripheral: CBPeripheral,
                advertisementData: Map<Any?, *>,
                RSSI: NSNumber,
            ) {
                val blob = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? NSData)
                    ?.toByteArray() ?: return
                // CoreBluetooth hands back the company ID inline, unlike Android's keyed accessor.
                if (blob.size < 3) return
                val id = (blob[0].toInt() and 0xFF) or ((blob[1].toInt() and 0xFF) shl 8)
                if (id != companyId) return

                trySend(BleAdvertisement(blob.copyOfRange(2, blob.size), RSSI.intValue))
            }
        }

        val central = CBCentralManager(delegate, queue)
        // CBCentralManager holds its delegate weakly. Without a strong reference of our own the
        // delegate is collected and the scan runs forever reporting nothing.
        var strongDelegate: CBCentralManagerDelegateProtocol? = delegate

        awaitClose {
            central.stopScan()
            central.delegate = null
            strongDelegate = null
        }
    }

    override suspend fun advertise(body: ByteArray, durationMs: Long): Boolean = false
}
