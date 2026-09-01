package org.meshtastic.node.transport.udp

import org.meshtastic.node.transport.MeshTransport
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import kotlin.concurrent.thread

/**
 * Mesh over UDP multicast - the transport that works against released firmware with nothing to
 * merge.
 *
 * `UdpMulticastHandler` already ships in the firmware and is compiled in wherever
 * `HAS_UDP_MULTICAST=1` is set, which is `variants/esp32/esp32-common.ini` and therefore most ESP32
 * boards. Group and port match it exactly, and the payload is a whole encoded `MeshPacket`, so a
 * node speaking this is a peer of any such radio on the same segment.
 *
 * It is not a substitute for a radio link: multicast needs a shared L2 segment, meaning an access
 * point or a hotspot. BLE needs no infrastructure at all, which is why the two are complements
 * rather than alternatives. What UDP buys is that the crypto and routing above it get validated
 * against real hardware long before any BLE work lands.
 *
 * Callers on Android must additionally hold a `WifiManager.MulticastLock` - without one the socket
 * silently receives nothing - and from targetSdk 37 `ACCESS_LOCAL_NETWORK`, whose failure mode is a
 * timeout rather than an error.
 */
public class UdpMulticastTransport(
    private val group: String = DEFAULT_GROUP,
    private val port: Int = DEFAULT_PORT,
    private val networkInterface: NetworkInterface? = null,
) : MeshTransport {

    override val canTransmit: Boolean = true

    private var socket: MulticastSocket? = null
    private var receiver: Thread? = null
    @Volatile private var running = false

    override fun start(listener: MeshTransport.FrameListener) {
        if (running) return
        val addr = InetAddress.getByName(group)
        val sock = MulticastSocket(port).apply {
            reuseAddress = true
            // The InetAddress overload is deprecated and picks an interface by routing table,
            // which on a laptop with a VPN or a container bridge is regularly the wrong one.
            val nif = networkInterface ?: firstMulticastInterface()
                ?: error("no multicast-capable network interface; UDP mesh needs an AP or hotspot")
            joinGroup(InetSocketAddress(addr, port), nif)
        }
        socket = sock
        running = true

        receiver = thread(name = "mesh-udp-rx", isDaemon = true) {
            // MeshPacket tops out at 450 bytes encoded; 1024 leaves room without a second read.
            val buf = ByteArray(1024)
            while (running) {
                try {
                    val dgram = DatagramPacket(buf, buf.size)
                    sock.receive(dgram)
                    // No RSSI: UDP has no such measurement, and a zero would misrepresent one.
                    listener.onFrame(dgram.data.copyOf(dgram.length), null)
                } catch (_: Exception) {
                    if (running) continue else break
                }
            }
        }
    }

    override fun stop() {
        running = false
        socket?.close()
        socket = null
        receiver = null
    }

    override fun send(encodedPacket: ByteArray): Boolean {
        val sock = socket ?: return false
        return try {
            sock.send(DatagramPacket(encodedPacket, encodedPacket.size, InetAddress.getByName(group), port))
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun firstMulticastInterface(): NetworkInterface? =
        NetworkInterface.getNetworkInterfaces().toList()
            .firstOrNull { it.isUp && it.supportsMulticast() && !it.isLoopback }

    public companion object {
        /** Matches UdpMulticastHandler's udpIpAddress. */
        public const val DEFAULT_GROUP: String = "239.0.0.69"
        /** Matches UDP_MULTICAST_DEFAUL_PORT, which is the TCP API port. */
        public const val DEFAULT_PORT: Int = 4403
    }
}
