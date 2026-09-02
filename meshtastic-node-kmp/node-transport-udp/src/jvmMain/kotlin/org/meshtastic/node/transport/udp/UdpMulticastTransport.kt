package org.meshtastic.node.transport.udp

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import org.meshtastic.node.transport.InboundFrame
import org.meshtastic.node.transport.MeshTransport
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import kotlin.coroutines.coroutineContext

/**
 * Mesh over UDP multicast - the transport that works against released firmware with nothing to
 * merge.
 *
 * `UdpMulticastHandler` already ships and is compiled in wherever `HAS_UDP_MULTICAST=1` is set,
 * which is `variants/esp32/esp32-common.ini` and so most ESP32 boards. Group, port and payload
 * match it exactly - a whole encoded `MeshPacket` - so a node speaking this is a peer of any such
 * radio on the same segment.
 *
 * Not a substitute for a radio link: multicast needs a shared L2 segment, meaning an access point
 * or a hotspot. BLE needs no infrastructure at all, which is why the two are complements. What UDP
 * buys is that the crypto and routing above it get validated against real hardware long before any
 * BLE work lands.
 *
 * Android callers must additionally hold a `WifiManager.MulticastLock` - without one the socket
 * silently receives nothing - and from targetSdk 37 `ACCESS_LOCAL_NETWORK`, whose failure mode is a
 * timeout rather than an error.
 */
public class UdpMulticastTransport(
    private val group: String = DEFAULT_GROUP,
    private val port: Int = DEFAULT_PORT,
    private val networkInterface: NetworkInterface? = null,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : MeshTransport {

    override val canTransmit: Boolean = true

    override fun incoming(): Flow<InboundFrame> = callbackFlow {
        val address = InetAddress.getByName(group)

        // Not `apply`: inside it, `port` resolves to MulticastSocket.getPort() - which is -1 on an
        // unconnected socket - rather than to this class's property, and the join fails with
        // "port out of range: -1".
        val socket = MulticastSocket(port)
        socket.reuseAddress = true
        // A null interface lets the OS choose, which is what makes this work on a plain host.
        // Pinning one is available for the case it exists to solve - a laptop with a VPN or a
        // container bridge, where the routing table's choice is wrong - but forcing an interface by
        // default breaks delivery on machines whose send and receive paths would otherwise agree.
        socket.joinGroup(InetSocketAddress(address, port), networkInterface)

        val reader = Thread({
            // MeshPacket tops out at 450 bytes encoded; 1024 leaves room without a second read.
            val buffer = ByteArray(1024)
            while (!socket.isClosed) {
                try {
                    val datagram = DatagramPacket(buffer, buffer.size)
                    socket.receive(datagram)
                    trySend(InboundFrame(datagram.data.copyOf(datagram.length)))
                } catch (_: Exception) {
                    if (socket.isClosed) break
                }
            }
        }, "mesh-udp-rx").apply { isDaemon = true; start() }

        // Cold by contract: the socket exists only while someone is collecting.
        awaitClose {
            socket.close()
            reader.interrupt()
        }
    }.flowOn(dispatcher)

    /**
     * The interface to transmit on.
     *
     * Receiving works with the OS's own choice, but transmitting does not: a `MulticastSocket` with
     * no interface set does not necessarily leave by the route that reaches the group, and on macOS
     * it demonstrably does not - the loopback copy still appears with the right source address, so
     * a local capture shows packets going out that no other host on the segment ever sees. That
     * failure looks exactly like a radio ignoring valid packets.
     *
     * Connecting an unconnected datagram socket sends nothing; it just runs the route lookup and
     * fixes the source address, which is precisely the interface the kernel would have used.
     */
    private val sendInterface: NetworkInterface? by lazy {
        networkInterface ?: runCatching {
            DatagramSocket().use { probe ->
                probe.connect(InetAddress.getByName(group), port)
                NetworkInterface.getByInetAddress(probe.localAddress)
            }
        }.getOrNull()
    }

    override suspend fun send(encodedPacket: ByteArray): Boolean = withContext(dispatcher) {
        runCatching {
            // A separate short-lived socket rather than the receiving one: send is independent of
            // whether anything is collecting, and sharing would tie the two lifetimes together.
            MulticastSocket().use { socket ->
                sendInterface?.let { socket.networkInterface = it }
                socket.send(
                    DatagramPacket(encodedPacket, encodedPacket.size, InetAddress.getByName(group), port)
                )
            }
            coroutineContext.isActive
        }.getOrDefault(false)
    }

    public companion object {
        /** Matches UdpMulticastHandler's udpIpAddress. */
        public const val DEFAULT_GROUP: String = "239.0.0.69"

        /** Matches UDP_MULTICAST_DEFAUL_PORT, which is the TCP API port. */
        public const val DEFAULT_PORT: Int = 4403
    }
}
