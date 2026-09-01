package org.meshtastic.node.ble

/**
 * The advertisement framing the BLE-mesh firmware puts on the air.
 *
 * Layout, matching `BLEMeshHandler::buildAdvPayload`:
 * ```
 *   [02][01][flags]                        AD: flags
 *   [len][FF][cid lo][cid hi][ver][proto]  AD: manufacturer-specific data
 * ```
 *
 * The company ID is 0xFFFF, which the Bluetooth SIG reserves for internal and test use. A shipping
 * build needs a member ID - or better, an assigned 16-bit service UUID with the payload as *service
 * data*, because iOS can only scan in the background when filtering by service UUID and therefore
 * cannot see manufacturer data there at all. That is the strongest argument for changing the format
 * before anything depends on it.
 */
public object BleMeshAdvert {

    public const val COMPANY_ID: Int = 0xFFFF
    public const val PROTOCOL_VERSION: Int = 1

    /** A single unfragmented extended advertisement carries 251 bytes, per BLE_HCI_MAX_EXT_ADV_DATA_LEN. */
    public const val ADV_TOTAL_MAX: Int = 251

    /** flags AD (3) + manufacturer-data AD header (2) + company id (2) + version (1). */
    public const val ADV_OVERHEAD: Int = 8

    public const val MAX_PACKET_LEN: Int = ADV_TOTAL_MAX - ADV_OVERHEAD

    /**
     * Walk the AD structures in a raw advertisement and return the encoded `MeshPacket`, or null if
     * this advertisement is not one of ours. Advertisements routinely carry several AD structures,
     * so this scans rather than assuming a position.
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
     * Extract the packet from a manufacturer-data *body* - everything after the company ID, which
     * is the form platform scan APIs hand back (Kable, Android's `getManufacturerSpecificData`,
     * CoreBluetooth's `kCBAdvDataManufacturerData` minus its prefix).
     *
     * Distinct from [extractPacketBytes], which walks whole AD structures: a scanner has already
     * done that walk, and redoing it would mean reassembling a raw advertisement the platform never
     * exposes.
     */
    public fun extractPacketFromBody(body: ByteArray): ByteArray? {
        if (body.size < 2) return null
        if ((body[0].toInt() and 0xFF) != PROTOCOL_VERSION) return null
        return body.copyOfRange(1, body.size)
    }

    /**
     * Build the manufacturer-data body a platform BLE API expects - everything *after* the 2-byte
     * company ID, since Android's `AdvertiseData.addManufacturerData(id, body)` and its equivalents
     * take the company ID as a separate argument.
     */
    public fun buildManufacturerBody(packetBytes: ByteArray): ByteArray =
        ByteArray(1 + packetBytes.size).also {
            it[0] = PROTOCOL_VERSION.toByte()
            packetBytes.copyInto(it, 1)
        }
}
