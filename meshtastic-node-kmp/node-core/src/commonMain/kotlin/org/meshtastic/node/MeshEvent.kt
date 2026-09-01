package org.meshtastic.node

/** Something the node observed on the mesh. */
public sealed interface MeshEvent {

    /** A text message on a channel this node holds the key for. */
    public data class TextMessage(
        val from: Long,
        val to: Long,
        val channel: MeshChannel,
        val text: String,
        val rssi: Int?,
    ) : MeshEvent

    /**
     * A packet that arrived intact but could not be read: no key for its channel, or it is a DM
     * encrypted to someone else. Surfaced rather than swallowed - a mesh is mostly traffic you
     * cannot read, and silently dropping it makes a working node look dead.
     */
    public data class Opaque(
        val from: Long,
        val to: Long,
        val channelHash: Int,
        val bytes: Int,
        val rssi: Int?,
    ) : MeshEvent

    /** A packet this node decided not to act on, with the reason. */
    public data class Dropped(val from: Long, val id: Long, val reason: String) : MeshEvent
}
