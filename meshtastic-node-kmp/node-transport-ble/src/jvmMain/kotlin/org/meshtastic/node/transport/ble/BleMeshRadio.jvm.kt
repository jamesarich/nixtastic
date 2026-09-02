package org.meshtastic.node.transport.ble

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

public actual fun bleMeshRadio(companyId: Int): BleMeshRadio = UnsupportedBleMeshRadio

/**
 * The JVM has no BLE of its own, so this hears nothing and says nothing.
 *
 * Present rather than absent so a desktop application can depend on this module for the types and
 * assemble a node from the transports that do work there - and so a JVM node reports itself as
 * having no usable BLE instead of appearing to scan and silently finding nothing.
 *
 * Linux could have both directions through BlueZ over D-Bus: `org.bluez.Adapter1.StartDiscovery`
 * with `org.bluez.Device1.ManufacturerData` for receive, and a registered
 * `org.bluez.LEAdvertisement1` for transmit. That is a real implementation rather than a shim, and
 * it belongs in its own module.
 */
private object UnsupportedBleMeshRadio : BleMeshRadio {
    override val canTransmit: Boolean = false
    override fun advertisements(): Flow<BleAdvertisement> = emptyFlow()
    override suspend fun advertise(body: ByteArray, durationMs: Long): Boolean = false
}
