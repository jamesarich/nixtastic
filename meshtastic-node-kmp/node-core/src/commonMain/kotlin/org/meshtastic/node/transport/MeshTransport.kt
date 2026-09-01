package org.meshtastic.node.transport

/**
 * One way of getting mesh frames to and from other nodes.
 *
 * Implementations carry an already-encoded `MeshPacket` and nothing more: encryption, dedup and
 * relay policy all live above this line, so a transport is only ever responsible for moving bytes
 * and reporting what it heard.
 *
 * Transports differ far more than "a socket vs a radio" suggests, and the differences are not
 * hidden here because they change what a caller can expect:
 *
 *  - **UDP multicast** works on every platform but needs an access point, an Android
 *    `MulticastLock` plus `ACCESS_LOCAL_NETWORK`, and Apple's restricted multicast entitlement.
 *  - **BLE advertisement** needs no infrastructure at all and is the reason this library exists,
 *    but is send-capable only on Android and Linux: CoreBluetooth cannot advertise arbitrary
 *    payload, so Apple platforms can listen and never speak.
 *  - **BLE GATT** is the Apple fallback, and is point-to-point - reaching N peers costs N writes,
 *    and no peer overhears another.
 */
public interface MeshTransport {

    /** Whether this transport can send on the current platform, not merely receive. */
    public val canTransmit: Boolean

    public fun start(listener: FrameListener)

    public fun stop()

    /** Broadcast one encoded `MeshPacket`. Returns false if it could not be queued. */
    public fun send(encodedPacket: ByteArray): Boolean

    public fun interface FrameListener {
        /**
         * @param rssi signal strength where the medium reports one, null where it does not - UDP
         *   has no such thing, and inventing a zero would misrepresent it as a real measurement.
         */
        public fun onFrame(encodedPacket: ByteArray, rssi: Int?)
    }
}
