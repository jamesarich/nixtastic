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

    /** What this node knows about its neighbours, built from what it hears. */
    public val directory: NodeDirectory = NodeDirectory()
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
            // publicKeyFor, not config.peerPublicKey: a key learned from a NodeInfo broadcast is
            // exactly as usable as one supplied up front, and requiring manual wiring would make
            // direct messages unreachable for anyone who did not already know the peer.
            val peerKey = publicKeyFor(to) ?: return false
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
        val header = codec.peek(frame.bytes)
            ?: return MeshEvent.Dropped(0, 0, MeshEvent.DropReason.MALFORMED)

        if (header.from == 0L) return MeshEvent.Dropped(0, header.id, MeshEvent.DropReason.NO_SENDER)
        if (header.from == identity.nodeNum) return null // our own frame, heard by our own receiver
        if (header.hopLimit > RelayPolicy.HOP_MAX) {
            return MeshEvent.Dropped(header.from, header.id, MeshEvent.DropReason.BAD_HOP_COUNT)
        }

        val now = config.clock()
        if (history.wasSeenRecently(header.from, header.id, now)) {
            return MeshEvent.Dropped(header.from, header.id, MeshEvent.DropReason.DUPLICATE)
        }

        // Presence first: hearing a node is evidence it exists, whether or not we can read it.
        directory.heard(header.from, now, frame.rssi)

        val relayed = relay(frame, header)

        val keys = KeyRing(config.channels, identity.nodeNum, config.privateKey, ::publicKeyFor)
        return when (val decoded = codec.decode(frame.bytes, keys)) {
            is DecodedPacket.Text ->
                MeshEvent.TextMessage(header.from, header.to, decoded.text, decoded.direct, frame.rssi)

            is DecodedPacket.NodeInfo -> MeshEvent.PeerUpdated(
                directory.learn(
                    nodeNum = header.from,
                    nowMs = now,
                    longName = decoded.longName,
                    shortName = decoded.shortName,
                    publicKey = decoded.publicKey,
                    rssi = frame.rssi,
                )
            )

            is DecodedPacket.Position ->
                MeshEvent.PositionReport(header.from, decoded.latitudeI, decoded.longitudeI, decoded.altitude)

            // Decrypted but unmodelled, or unreadable. Both are worth surfacing: a mesh is mostly
            // traffic you cannot read, and silence would make a working node look dead.
            is DecodedPacket.Other, DecodedPacket.Unreadable, null ->
                relayed ?: MeshEvent.Opaque(header.from, header.to, header.channelHash, frame.rssi)
        }
    }

    /**
     * Forward a packet onward, if policy allows.
     *
     * No key is needed and none is used: `hop_limit` is a plaintext `MeshPacket` field, so a node
     * forwards traffic it cannot read - which is what makes a mesh a mesh rather than a collection
     * of listeners.
     *
     * Deliberately conservative all the same. Dedup terminates the flood and the hop limit bounds
     * it, but this node has no next-hop table and no overhear-based suppression, so it forwards
     * every packet it has not already seen: correct, and noisier than a radio would be.
     * [RelayPolicy.Island] disables it entirely and is the default.
     */
    private suspend fun relay(frame: InboundFrame, header: PacketHeaderView): MeshEvent? {
        if (relayPolicy !is RelayPolicy.Meshed) return null
        if (header.to == identity.nodeNum) return null // for us, not through us
        val forwarded = codec.forForwarding(frame.bytes, identity.nodeNum) ?: return null

        val sent = config.transports.filter { it.canTransmit }.any { it.send(forwarded) }
        return if (sent) MeshEvent.Relayed(header.from, header.id, header.hopLimit - 1) else null
    }

    /** Keys we were given explicitly win; otherwise whatever a NodeInfo broadcast taught us. */
    private fun publicKeyFor(nodeNum: Long): ByteArray? =
        config.peerPublicKey(nodeNum) ?: directory.publicKeyOf(nodeNum)

    /**
     * Broadcast who we are, including our public key.
     *
     * Not optional in practice: a peer cannot send this node a direct message until it has our
     * X25519 public key, and this is the only way it travels. Call it on join and periodically -
     * radios re-announce roughly every few minutes.
     */
    public suspend fun announce(channel: MeshChannel = config.channels.first()): Boolean {
        val publicKey = config.publicKey
        val encoded = codec.encodeNodeInfo(identity, publicKey, channel, nextId(), relayPolicy.hopLimit)
            ?: return false
        return config.transports.filter { it.canTransmit }.any { it.send(encoded) }
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

        /** Our X25519 public key, broadcast by [announce] so peers can reach us. */
        public var publicKey: ByteArray? = null

        /**
         * Public key for a peer, consulted before the directory. Supply one to pin keys from your
         * own store; leave it and the node uses whatever NodeInfo broadcasts have taught it.
         */
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
