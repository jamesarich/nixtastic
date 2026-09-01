package org.meshtastic.node

/**
 * Who this node is on the mesh.
 *
 * A client that participates as a node needs an identity of its own, and cannot borrow the radio's:
 * `MeshService::handleToRadio` sets `p.from = 0` on everything a client submits, with the comment
 * "We don't let clients assign nodenums to their sent messages". So a node is not an extension of
 * the phone API - it is a peer, and it has to say who it is.
 *
 * [nodeNum] is the 32-bit address other nodes see. Taken as a [Long] because Kotlin's Int is signed
 * and a NodeNum above 0x7FFFFFFF is entirely ordinary.
 */
public data class MeshIdentity(
    val nodeNum: Long,
    val longName: String,
    val shortName: String,
) {
    init {
        require(nodeNum in 1..0xFFFFFFFFL) { "nodeNum must be a non-zero 32-bit value, was $nodeNum" }
        require(shortName.isNotEmpty()) { "shortName must not be empty" }
    }

    /** The `!hex` form used in channel URLs, logs and the apps. */
    public val nodeId: String get() = "!" + nodeNum.toString(16).padStart(8, '0')

    public companion object {
        /**
         * Derive a stable NodeNum from a per-installation seed.
         *
         * Radios use the low bytes of their MAC. A client has no equivalent, so callers should
         * persist [seed] once (per install, not per launch) and pass the same value every time:
         * a node whose address changes on restart shows up as a new node in every peer's NodeDB,
         * and those tables hold 120 entries - 10 on STM32WL.
         */
        public fun derive(seed: ByteArray, longName: String, shortName: String): MeshIdentity {
            require(seed.isNotEmpty()) { "seed must not be empty" }
            // FNV-1a: tiny, dependency-free, and good enough for spreading addresses. This is not
            // a security boundary - identity is proved by the X25519 key, not by the address.
            var hash = 0x811C9DC5L
            for (b in seed) {
                hash = hash xor (b.toLong() and 0xFF)
                hash = (hash * 0x01000193L) and 0xFFFFFFFFL
            }
            if (hash == 0L) hash = 1L // 0 means "unset" on the wire
            return MeshIdentity(hash, longName, shortName)
        }
    }
}
