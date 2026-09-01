package org.meshtastic.node.transport

import kotlinx.coroutines.flow.Flow

/** A frame as it arrived, with whatever the medium could say about it. */
public data class InboundFrame(
    val bytes: ByteArray,
    /** Signal strength where the medium reports one. Null for UDP, which has no such notion - a
     *  zero would misrepresent "unknown" as "a real measurement of 0 dBm". */
    val rssi: Int? = null,
) {
    override fun equals(other: Any?): Boolean =
        this === other || (other is InboundFrame && bytes.contentEquals(other.bytes) && rssi == other.rssi)

    override fun hashCode(): Int = 31 * bytes.contentHashCode() + (rssi ?: 0)
}

/**
 * One way of getting mesh frames to and from other nodes.
 *
 * Implementations carry an already-encoded `MeshPacket` and nothing more: encryption, dedup and
 * relay policy all live above this line, so a transport is only responsible for moving bytes.
 *
 * [incoming] is a cold [Flow] - collecting it opens the medium, cancelling closes it - so a node's
 * lifetime is its coroutine scope's, with no separate start/stop to leak.
 *
 * The differences between transports are not hidden here, because they change what a caller can
 * expect:
 *
 *  - **UDP multicast** works on every platform but needs an access point, an Android
 *    `MulticastLock`, and Apple's restricted multicast entitlement.
 *  - **BLE advertisement** needs no infrastructure and is the reason this library exists, but is
 *    send-capable only on Android and Linux: CoreBluetooth cannot advertise arbitrary payload, so
 *    Apple platforms can listen and never speak. Hence [canTransmit].
 *  - **BLE GATT** is the Apple fallback, and is point-to-point - N peers costs N writes, and no
 *    peer overhears another.
 */
public interface MeshTransport {

    /** Whether this transport can send on the current platform, not merely receive. */
    public val canTransmit: Boolean

    /** Frames heard on the medium. Cold: collection opens it, cancellation closes it. */
    public fun incoming(): Flow<InboundFrame>

    /** Broadcast one encoded `MeshPacket`. Returns false if it could not be sent. */
    public suspend fun send(encodedPacket: ByteArray): Boolean
}
