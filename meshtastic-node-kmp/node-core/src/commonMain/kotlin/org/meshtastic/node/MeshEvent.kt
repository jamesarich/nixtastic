package org.meshtastic.node

/** Something the node observed on the mesh. */
public sealed interface MeshEvent {

    /** A message this node could read. [direct] distinguishes a PKI-protected DM from channel traffic. */
    public data class TextMessage(
        val from: Long,
        val to: Long,
        val text: String,
        val direct: Boolean,
        val rssi: Int?,
    ) : MeshEvent

    /**
     * A packet that arrived intact but could not be read: no key for its channel, or a DM for
     * someone else. Surfaced rather than swallowed - a mesh is mostly traffic you cannot read, and
     * dropping it silently makes a working node look dead.
     */
    public data class Opaque(val from: Long, val to: Long, val channelHash: Int, val rssi: Int?) : MeshEvent

    /** A packet the node declined to act on. */
    public data class Dropped(val from: Long, val id: Long, val reason: DropReason) : MeshEvent

    /** A packet this node forwarded onward. Only ever emitted under [RelayPolicy.Meshed]. */
    public data class Relayed(val from: Long, val id: Long, val hopLimit: Int) : MeshEvent

    /** A peer identified itself, or we learned something new about one. */
    public data class PeerUpdated(val peer: NodeDirectory.Peer) : MeshEvent

    /** A position report from a peer. */
    public data class PositionReport(
        val from: Long,
        val latitudeI: Int?,
        val longitudeI: Int?,
        val altitude: Int?,
    ) : MeshEvent

    public enum class DropReason {
        /** `from == 0`: nothing legitimate advertises without a sender. */
        NO_SENDER,

        /** Out of range for the 3-bit wire field, so not relayable. */
        BAD_HOP_COUNT,

        /** Seen recently. This is what terminates a flood. */
        DUPLICATE,

        /** Not a packet at all. */
        MALFORMED,
    }
}
