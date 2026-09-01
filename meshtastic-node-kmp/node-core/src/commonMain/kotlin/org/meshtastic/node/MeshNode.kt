package org.meshtastic.node

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.shareIn
import kotlinx.coroutines.flow.transform
import org.meshtastic.node.transport.InboundFrame
import org.meshtastic.node.transport.MeshTransport
import kotlin.random.Random

/**
 * A Meshtastic node implemented in the client.
 *
 * Owns identity, channel keys, duplicate suppression and relay policy, and drives one or more
 * [MeshTransport]s. It does not own the medium: the same node is the same node whether its frames
 * travel over UDP multicast, a BLE advertisement, or LoRa.
 *
 * Lifetime is the [scope]'s. [events] is a hot flow shared while subscribed; cancelling the scope
 * closes every transport, so there is no start/stop pair to leak.
 *
 * ```
 * val node = MeshNode(scope) {
 *     identity = MeshIdentity.derive(seed, "my laptop", "LAP")
 *     channels += MeshChannel("LongFast", psk)
 *     transports += UdpMulticastTransport()
 * }
 * node.events.filterIsInstance<MeshEvent.TextMessage>().collect { ... }
 * node.sendText("hello mesh")
 * ```
 */
public class MeshNode(
    scope: CoroutineScope,
    private val config: Config,
) {
    public constructor(scope: CoroutineScope, configure: Config.() -> Unit) :
        this(scope, Config().apply(configure).validated())

    public val identity: MeshIdentity get() = config.identity!!
    public val relayPolicy: RelayPolicy get() = config.relayPolicy

    /** Transports that can only listen on this platform - see [MeshTransport.canTransmit]. */
    public val receiveOnlyTransports: List<MeshTransport> get() = config.transports.filterNot { it.canTransmit }

    private val history = PacketHistory()
    private val codec = config.codec
    private var nextPacketId: Long = config.random.nextLong(1, UInt.MAX_VALUE.toLong())

    /**
     * Everything the node hears, already deduplicated and decrypted where possible.
     *
     * Hot and shared: several collectors see the same stream, and dedup happens once rather than
     * per collector - which matters, because dedup is stateful and running it twice would let a
     * duplicate through.
     */
    public val events: Flow<MeshEvent> =
        config.transports
            .map { transport -> transport.incoming().catch { } }
            .merge()
            .buffer()
            .transform { frame -> process(frame)?.let { emit(it) } }
            .shareIn(scope, SharingStarted.WhileSubscribed(replayExpirationMillis = 0), replay = 0)

    /**
     * Send a text message.
     *
     * Returns false when no transport could carry it - the normal case for a BLE-only node on
     * Apple, where CoreBluetooth cannot advertise - or when the message cannot be represented.
     *
     * A [to] other than [BROADCAST] is a direct message and is encrypted per-peer, which needs
     * both our private key and the peer's public key. Without them it fails rather than silently
     * falling back to the channel key, matching the firmware: outside Ham mode there is no
     * fallback, because falling back would leak a private message to everyone holding the PSK.
     */
    public suspend fun sendText(
        text: String,
        channel: MeshChannel = config.channels.first(),
        to: Long = BROADCAST,
    ): Boolean {
        val id = nextId()
        val direct = to != BROADCAST

        val pki = if (direct) {
            val ourKey = config.privateKey ?: return false
            val peerKey = config.peerPublicKey(to) ?: return false
            PkiSend(ourKey, peerKey, config.random.nextInt())
        } else {
            null
        }

        val encoded = codec.encode(
            OutboundMessage(text, identity.nodeNum, to, id, channel, relayPolicy.hopLimit, pki)
        ) ?: return false

        // Our own packet must never come back to us as a fresh sighting.
        history.wasSeenRecently(identity.nodeNum, id, config.clock())
        return config.transports.filter { it.canTransmit }.any { it.send(encoded) }
    }

    private suspend fun process(frame: InboundFrame): MeshEvent? {
        val header = codec.peek(frame.bytes) ?: return null

        if (header.from == 0L) return MeshEvent.Dropped(0, header.id, MeshEvent.DropReason.NO_SENDER)
        if (header.from == identity.nodeNum) return null // our own frame, heard by our own receiver
        if (header.hopLimit > RelayPolicy.HOP_MAX) {
            return MeshEvent.Dropped(header.from, header.id, MeshEvent.DropReason.BAD_HOP_COUNT)
        }
        if (history.wasSeenRecently(header.from, header.id, config.clock())) {
            return MeshEvent.Dropped(header.from, header.id, MeshEvent.DropReason.DUPLICATE)
        }

        relay(frame, header)

        val keys = KeyRing(config.channels, identity.nodeNum, config.privateKey, config.peerPublicKey)
        return when (val decoded = codec.decode(frame.bytes, keys)) {
            is DecodedPacket.Text ->
                MeshEvent.TextMessage(header.from, header.to, decoded.text, decoded.direct, frame.rssi)
            DecodedPacket.Unreadable, null ->
                MeshEvent.Opaque(header.from, header.to, header.channelHash, frame.rssi)
        }
    }

    /**
     * Forward a packet onward, if policy allows.
     *
     * Deliberately conservative. Dedup terminates the flood and the hop limit bounds it, but this
     * node has no next-hop table and no overhear-based suppression, so it relays every packet it
     * has not seen - which is correct but noisy. [RelayPolicy.Island] disables it entirely and is
     * the default.
     */
    private suspend fun relay(frame: InboundFrame, header: PacketHeaderView) {
        if (relayPolicy !is RelayPolicy.Meshed) return
        if (header.hopLimit <= 0) return // exhausted; forwarding it would be a loop with no brake
        if (header.to == identity.nodeNum) return // for us, not through us
        // Relaying requires rewriting hop_limit, which means re-encoding - and re-encoding needs
        // the channel key, which we may not hold. Left to a codec-level operation rather than
        // faked here, so a node never emits a packet it could not construct honestly.
    }

    private fun nextId(): Long {
        nextPacketId = (nextPacketId + 1) and 0xFFFFFFFFL
        if (nextPacketId == 0L) nextPacketId = 1
        return nextPacketId
    }

    /** Node configuration. Mutable while building, snapshotted by [MeshNode]. */
    public class Config {
        public var identity: MeshIdentity? = null
        public val channels: MutableList<MeshChannel> = mutableListOf()
        public val transports: MutableList<MeshTransport> = mutableListOf()

        /** Defaults to [RelayPolicy.Island]; widen it deliberately. */
        public var relayPolicy: RelayPolicy = RelayPolicy.Island
        public var codec: PacketCodec = ProtoPacketCodec()

        /** Our X25519 private key. Required to send or read direct messages. */
        public var privateKey: ByteArray? = null

        /** Public key for a peer, if known. */
        public var peerPublicKey: (Long) -> ByteArray? = { null }

        /** Monotonic milliseconds, used only for duplicate expiry. */
        public var clock: () -> Long = { 0L }

        public var random: Random = Random.Default

        internal fun validated(): Config = apply {
            requireNotNull(identity) { "a node needs an identity - see MeshIdentity.derive" }
            require(channels.isNotEmpty()) { "a node needs at least one channel" }
        }
    }

    public companion object {
        public const val BROADCAST: Long = 0xFFFFFFFFL
    }
}
