package org.meshtastic.node

/**
 * Duplicate suppression, keyed on `(from, id)` exactly as the firmware's `PacketHistory` is.
 *
 * This is what terminates a flood. Every node re-broadcasts a packet it has not seen, and drops one
 * it has; combined with the hop limit decrementing per relay, that bounds propagation. A node
 * without it must not relay at all, or it will amplify every frame it hears.
 *
 * Time is passed in rather than read, so the protocol layer stays pure and the expiry behaviour is
 * directly testable without a clock abstraction.
 */
public class PacketHistory(
    private val capacity: Int = DEFAULT_CAPACITY,
    private val expiryMs: Long = DEFAULT_EXPIRY_MS,
) {
    private data class Key(val from: Long, val id: Long)

    // Insertion-ordered, so the oldest entry is the first one - which is what we evict.
    private val seen = LinkedHashMap<Key, Long>()

    /**
     * Record `(from, id)` as seen at [nowMs] and report whether it had been seen recently.
     * Returns true when this is a duplicate and the caller should drop it.
     */
    public fun wasSeenRecently(from: Long, id: Long, nowMs: Long): Boolean {
        expire(nowMs)
        val key = Key(from, id)
        val existing = seen[key]
        seen[key] = nowMs
        if (seen.size > capacity) {
            val oldest = seen.keys.firstOrNull()
            if (oldest != null && oldest != key) seen.remove(oldest)
        }
        return existing != null
    }

    public val size: Int get() = seen.size

    private fun expire(nowMs: Long) {
        val cutoff = nowMs - expiryMs
        val it = seen.entries.iterator()
        while (it.hasNext()) {
            if (it.next().value < cutoff) it.remove() else break // insertion-ordered: rest are newer
        }
    }

    public companion object {
        public const val DEFAULT_CAPACITY: Int = 512
        /** The firmware forgets a packet after ~5 minutes; match it so relay behaviour agrees. */
        public const val DEFAULT_EXPIRY_MS: Long = 5 * 60 * 1000L
    }
}
