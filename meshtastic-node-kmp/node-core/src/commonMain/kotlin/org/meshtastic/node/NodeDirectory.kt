package org.meshtastic.node

/**
 * What this node knows about its neighbours.
 *
 * The radio equivalent is the NodeDB, and its size is not incidental: firmware holds 120 entries,
 * and 10 on STM32WL. A client node that let this grow without bound would be fine itself while
 * teaching every radio that hears it to evict real peers, so the cap and the eviction policy here
 * mirror the constraint rather than the convenience.
 *
 * The directory is also what makes direct messages work in practice. A DM needs the recipient's
 * X25519 public key, which arrives in their `NodeInfo` broadcast - so a node that never listens for
 * NodeInfo can never send a DM, no matter how complete its crypto is.
 */
public class NodeDirectory(
    private val capacity: Int = DEFAULT_CAPACITY,
) {
    /** A peer as last heard. */
    public data class Peer(
        val nodeNum: Long,
        val longName: String? = null,
        val shortName: String? = null,
        /** Their X25519 public key, once a NodeInfo has carried it. Required to DM them. */
        val publicKey: ByteArray? = null,
        val lastHeardMs: Long = 0,
        val rssi: Int? = null,
    ) {
        val nodeId: String get() = "!" + nodeNum.toString(16).padStart(8, '0')

        override fun equals(other: Any?): Boolean = this === other || (
            other is Peer && nodeNum == other.nodeNum && longName == other.longName &&
                shortName == other.shortName && publicKey.contentEqualsNullable(other.publicKey) &&
                lastHeardMs == other.lastHeardMs && rssi == other.rssi
            )

        override fun hashCode(): Int {
            var result = nodeNum.hashCode()
            result = 31 * result + (longName?.hashCode() ?: 0)
            result = 31 * result + (shortName?.hashCode() ?: 0)
            result = 31 * result + (publicKey?.contentHashCode() ?: 0)
            result = 31 * result + lastHeardMs.hashCode()
            return 31 * result + (rssi ?: 0)
        }
    }

    // Insertion-ordered so the least recently *updated* entry is first, which is what we evict.
    private val peers = LinkedHashMap<Long, Peer>()

    public val size: Int get() = peers.size

    public fun all(): List<Peer> = peers.values.toList()

    public fun get(nodeNum: Long): Peer? = peers[nodeNum]

    /** The key needed to send [nodeNum] a direct message, if we have heard their NodeInfo. */
    public fun publicKeyOf(nodeNum: Long): ByteArray? = peers[nodeNum]?.publicKey

    /**
     * Record that we heard from [nodeNum]. Called for every packet, readable or not - presence on
     * the mesh does not require being able to read what was said.
     */
    public fun heard(nodeNum: Long, nowMs: Long, rssi: Int? = null): Peer =
        upsert(nodeNum) { it.copy(lastHeardMs = nowMs, rssi = rssi ?: it.rssi) }

    /** Record identity details from a NodeInfo broadcast. */
    public fun learn(
        nodeNum: Long,
        nowMs: Long,
        longName: String? = null,
        shortName: String? = null,
        publicKey: ByteArray? = null,
        rssi: Int? = null,
    ): Peer = upsert(nodeNum) {
        it.copy(
            longName = longName ?: it.longName,
            shortName = shortName ?: it.shortName,
            // An empty key field means "not carried", not "cleared" - never drop a key we hold.
            publicKey = publicKey?.takeIf { k -> k.isNotEmpty() } ?: it.publicKey,
            lastHeardMs = nowMs,
            rssi = rssi ?: it.rssi,
        )
    }

    private fun upsert(nodeNum: Long, update: (Peer) -> Peer): Peer {
        val existing = peers.remove(nodeNum) ?: Peer(nodeNum)
        val updated = update(existing)
        peers[nodeNum] = updated // re-inserted, so it becomes the most recent
        if (peers.size > capacity) {
            peers.keys.firstOrNull()?.let { if (it != nodeNum) peers.remove(it) }
        }
        return updated
    }

    public companion object {
        /** Matches the firmware's MAX_NUM_NODES on nRF52840 and ESP32. */
        public const val DEFAULT_CAPACITY: Int = 120
    }
}

private fun ByteArray?.contentEqualsNullable(other: ByteArray?): Boolean =
    if (this == null || other == null) this === other else contentEquals(other)
