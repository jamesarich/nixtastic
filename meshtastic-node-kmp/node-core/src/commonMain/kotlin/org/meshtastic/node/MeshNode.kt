package org.meshtastic.node

import org.meshtastic.node.transport.MeshTransport

/**
 * A Meshtastic node implemented in the client.
 *
 * Owns the identity, the channel keys, duplicate suppression and the relay policy, and drives one
 * or more [MeshTransport]s. What it deliberately does not own is the transport's medium: a node is
 * the same node whether its frames travel over UDP multicast, a BLE advertisement, or LoRa.
 *
 * Construct through [Builder]:
 * ```
 * val node = MeshNode.build {
 *     identity(MeshIdentity.derive(seed, "my laptop", "LAP"))
 *     channel(MeshChannel("LongFast", psk))
 *     transport(UdpMulticastTransport())
 * }
 * node.start { event -> ... }
 * ```
 */
public class MeshNode private constructor(
    public val identity: MeshIdentity,
    private val channels: List<MeshChannel>,
    private val transports: List<MeshTransport>,
    public val relayPolicy: RelayPolicy,
    private val codec: PacketCodec,
    private val history: PacketHistory,
    private val clock: () -> Long,
) {
    private var listener: ((MeshEvent) -> Unit)? = null
    private var nextPacketId: Long = 1

    /** Transports that can only listen on this platform - see [MeshTransport.canTransmit]. */
    public val receiveOnlyTransports: List<MeshTransport> get() = transports.filterNot { it.canTransmit }

    public fun start(onEvent: (MeshEvent) -> Unit) {
        listener = onEvent
        transports.forEach { t -> t.start { bytes, rssi -> onFrame(bytes, rssi) } }
    }

    public fun stop() {
        transports.forEach { it.stop() }
        listener = null
    }

    /**
     * Send a text message. Returns false when no transport could carry it - which on Apple
     * platforms is the normal case for a BLE-only node, since CoreBluetooth cannot advertise.
     */
    public fun sendText(text: String, channel: MeshChannel = channels.first(), to: Long = BROADCAST): Boolean {
        val id = nextPacketId++
        val encoded = codec.encodeText(
            text = text,
            from = identity.nodeNum,
            to = to,
            id = id,
            channel = channel,
            hopLimit = relayPolicy.hopLimit,
        ) ?: return false

        // Our own packet must never come back to us as a fresh sighting.
        history.wasSeenRecently(identity.nodeNum, id, clock())
        return transports.filter { it.canTransmit }.map { it.send(encoded) }.any { it }
    }

    private fun onFrame(encodedPacket: ByteArray, rssi: Int?) {
        val emit = listener ?: return
        val header = codec.peek(encodedPacket) ?: return

        if (header.from == 0L) return emit(MeshEvent.Dropped(0, header.id, "no sender"))
        if (header.from == identity.nodeNum) return // our own frame, heard by our own receiver
        if (header.hopLimit > RelayPolicy.HOP_MAX) {
            return emit(MeshEvent.Dropped(header.from, header.id, "hop limit out of range"))
        }
        if (history.wasSeenRecently(header.from, header.id, clock())) {
            return emit(MeshEvent.Dropped(header.from, header.id, "duplicate"))
        }

        val channel = channels.firstOrNull { it.hash == header.channelHash }
        val text = channel?.let { codec.decodeText(encodedPacket, it) }
        if (channel != null && text != null) {
            emit(MeshEvent.TextMessage(header.from, header.to, channel, text, rssi))
        } else {
            emit(MeshEvent.Opaque(header.from, header.to, header.channelHash, encodedPacket.size, rssi))
        }

        // Relaying is deliberately not done here. A node without the flood and next-hop policy
        // must not rebroadcast, or it amplifies every frame it hears; dedup alone is not enough.
    }

    public class Builder internal constructor() {
        private var identity: MeshIdentity? = null
        private val channels = mutableListOf<MeshChannel>()
        private val transports = mutableListOf<MeshTransport>()
        private var relayPolicy: RelayPolicy = RelayPolicy.Island
        private var codec: PacketCodec? = null
        private var clock: () -> Long = { 0L }

        public fun identity(value: MeshIdentity) { identity = value }
        public fun channel(value: MeshChannel) { channels += value }
        public fun transport(value: MeshTransport) { transports += value }

        /** Defaults to [RelayPolicy.Island]; widen it deliberately. */
        public fun relayPolicy(value: RelayPolicy) { relayPolicy = value }
        public fun codec(value: PacketCodec) { codec = value }

        /** Monotonic milliseconds, used only for duplicate expiry. */
        public fun clock(value: () -> Long) { clock = value }

        internal fun build(): MeshNode {
            val id = requireNotNull(identity) { "a node needs an identity - see MeshIdentity.derive" }
            require(channels.isNotEmpty()) { "a node needs at least one channel" }
            val c = requireNotNull(codec) { "a node needs a PacketCodec" }
            return MeshNode(id, channels.toList(), transports.toList(), relayPolicy, c, PacketHistory(), clock)
        }
    }

    public companion object {
        public const val BROADCAST: Long = 0xFFFFFFFFL

        public fun build(configure: Builder.() -> Unit): MeshNode = Builder().apply(configure).build()
    }
}
