package org.meshtastic.node.transport.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.emptyFlow
import org.meshtastic.node.ble.BleMeshAdvert

/**
 * Set this once, early - `Application.onCreate` is the natural place.
 *
 * A Kotlin Multiplatform library cannot take a [Context] through an expect factory without
 * distorting the signature for every other platform, and reaching for one behind the caller's back
 * (a ContentProvider, a static holder populated by the manifest) hides a real dependency. So the
 * host supplies it, and until it does the radio reports itself unusable rather than crashing at
 * the first scan.
 */
public object AndroidBleContext {
    @Volatile
    public var applicationContext: Context? = null
}

public actual fun bleMeshRadio(companyId: Int): BleMeshRadio =
    AndroidBleMeshRadio(companyId, AndroidBleContext.applicationContext)

/**
 * Android BLE, both directions.
 *
 * This is why Kable had to go: it is a central-role library, so a transport built on it could only
 * ever listen. Android is the one platform in this library that can do both, and
 * `startAdvertisingSet` with `setLegacyMode(false)` is the only API that carries more than the 31
 * bytes a legacy advertisement holds - far short of a `MeshPacket`.
 *
 * The caller needs `BLUETOOTH_SCAN` and, to transmit, `BLUETOOTH_ADVERTISE`; both are runtime
 * permissions from API 31. This module deliberately declares neither in a manifest, because a host
 * app scopes them - `neverForLocation` on the scan permission in particular - and a library that
 * merges its own choices into the consumer's manifest takes that decision away.
 */
@SuppressLint("MissingPermission")
private class AndroidBleMeshRadio(
    private val companyId: Int,
    private val context: Context?,
) : BleMeshRadio {

    private val adapter: BluetoothAdapter? =
        context?.getSystemService(BluetoothManager::class.java)?.adapter

    /**
     * Extended advertising is a controller capability, not a version one: plenty of API 26+ devices
     * cannot do it, and `getBluetoothLeAdvertiser` returns null when Bluetooth is off. Reporting
     * that honestly lets a node fall back rather than queue packets nothing will ever send.
     */
    override val canTransmit: Boolean
        get() = adapter?.isLeExtendedAdvertisingSupported == true &&
            adapter.bluetoothLeAdvertiser != null

    override fun advertisements(): Flow<BleAdvertisement> {
        val scanner = adapter?.bluetoothLeScanner ?: return emptyFlow()

        return callbackFlow {
            val callback = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, result: ScanResult) {
                    // Keyed by company ID, so unlike CoreBluetooth there is no prefix to strip.
                    val body = result.scanRecord?.getManufacturerSpecificData(companyId) ?: return
                    trySend(BleAdvertisement(body, result.rssi))
                }

                override fun onBatchScanResults(results: MutableList<ScanResult>) {
                    results.forEach { onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, it) }
                }
            }

            val filter = ScanFilter.Builder()
                // Match the protocol-version byte as well: 0xFFFF is the SIG's test company ID, so
                // anything else using it would otherwise reach our decoder.
                .setManufacturerData(
                    companyId,
                    byteArrayOf(BleMeshAdvert.PROTOCOL_VERSION.toByte()),
                    byteArrayOf(0xFF.toByte()),
                )
                .build()

            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                // A mesh node's payload changes every frame, so the first report from a given
                // address is not the interesting one. Losing the rest looks exactly like an idle
                // mesh, which is the same trap CoreBluetooth sets with allowDuplicates.
                .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                .setReportDelay(0)
                // Legacy-only scanning cannot see the extended advertisements the firmware sends.
                .setLegacy(false)
                .setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
                .build()

            scanner.startScan(listOf(filter), settings, callback)
            awaitClose { scanner.stopScan(callback) }
        }
    }

    override suspend fun advertise(body: ByteArray, durationMs: Long): Boolean {
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return false
        if (!canTransmit) return false

        val parameters = AdvertisingSetParameters.Builder()
            // The whole point: a legacy advertisement holds 31 bytes, and a MeshPacket does not fit.
            .setLegacyMode(false)
            .setConnectable(false)
            .setScannable(false)
            .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM)
            .build()

        val data = AdvertiseData.Builder()
            // Every byte is budgeted; a device name here would push a full-size packet over.
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addManufacturerData(companyId, body)
            .build()

        val callback = object : AdvertisingSetCallback() {}
        return try {
            advertiser.startAdvertisingSet(parameters, data, null, null, null, callback)
            // Bounded, matching the firmware's TX ring: one advertising set is a shared resource,
            // and a frame left up forever silences everything queued behind it.
            delay(durationMs)
            true
        } finally {
            runCatching { advertiser.stopAdvertisingSet(callback) }
        }
    }
}
