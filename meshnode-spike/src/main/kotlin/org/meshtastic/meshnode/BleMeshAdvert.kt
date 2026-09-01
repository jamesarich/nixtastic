package org.meshtastic.meshnode

/**
 * Parsing for the BLE-mesh advertisement framing the firmware puts on the air.
 *
 * Layout, matching `BLEMeshHandler::buildAdvPayload`:
 * ```
 *   [02][01][flags]                        AD: flags
 *   [len][FF][cid lo][cid hi][ver][proto]  AD: manufacturer-specific data
 * ```
 * The company ID is 0xFFFF, which the Bluetooth SIG reserves for internal/test use — a shipping
 * build needs a member ID, or better an assigned 16-bit service UUID, because iOS can only scan in
 * the background when filtering by service UUID and so cannot see manufacturer data at all there.
 */
public object BleMeshAdvert {

    public const val COMPANY_ID: Int = 0xFFFF
    public const val PROTOCOL_VERSION: Int = 1

    /**
     * Walk the AD structures in a raw advertisement and return the encoded `MeshPacket` bytes, or
     * null if this advertisement is not one of ours. Advertisements routinely carry several AD
     * structures, so this scans rather than assuming a position.
     */
    public fun extractPacketBytes(adv: ByteArray): ByteArray? {
        var offset = 0
        while (offset + 1 < adv.size) {
            val adLen = adv[offset].toInt() and 0xFF
            // An AD structure spans adv[offset]..adv[offset + adLen]; anything else is truncated.
            if (adLen == 0 || offset + adLen >= adv.size) return null

            val adType = adv[offset + 1].toInt() and 0xFF
            if (adType == 0xFF && adLen >= 4) {
                val company = (adv[offset + 2].toInt() and 0xFF) or ((adv[offset + 3].toInt() and 0xFF) shl 8)
                val version = adv[offset + 4].toInt() and 0xFF
                if (company == COMPANY_ID && version == PROTOCOL_VERSION) {
                    // Skip the type byte, the 2-byte company ID and the 1-byte version.
                    return adv.copyOfRange(offset + 5, offset + 1 + adLen)
                }
            }
            offset += adLen + 1
        }
        return null
    }

    /**
     * Build the manufacturer-data body a platform BLE API wants — that is, everything after the
     * 2-byte company ID, since Android's `AdvertiseData.addManufacturerData(id, body)` and the
     * equivalents take the company ID separately.
     *
     * Note this is unusable on Apple platforms: CoreBluetooth accepts only
     * `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey` when advertising,
     * so an iOS or macOS client can receive on this transport but never transmit.
     */
    public fun buildManufacturerBody(packetBytes: ByteArray): ByteArray =
        ByteArray(1 + packetBytes.size).also {
            it[0] = PROTOCOL_VERSION.toByte()
            packetBytes.copyInto(it, 1)
        }
}
