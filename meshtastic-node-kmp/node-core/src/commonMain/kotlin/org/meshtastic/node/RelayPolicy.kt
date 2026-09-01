package org.meshtastic.node

/**
 * How far this node's own traffic is allowed to travel.
 *
 * This is the safety lever, and it is enforced by firmware that already ships rather than by client
 * good behaviour: `NextHopRouter::perhapsRebroadcast` relays a packet only when `hop_limit > 0`, so
 * a node that originates frames with `hop_limit = 0` cannot have them flooded onward by any radio
 * that hears it.
 *
 * That matters more than it first looks. A client node is trivially able to inject into the LoRa
 * mesh - any UDP-enabled radio on the same LAN will relay a UDP frame onto the air today, and
 * `UdpMulticastHandler::onReceive` does not require the sender to be in its NodeDB. Meanwhile a
 * radio's NodeDB holds 120 entries (10 on STM32WL), so a room full of phone-nodes can evict every
 * real radio from the tables of anything that hears them. [Island] is therefore the default, and
 * anything wider is a deliberate, named choice.
 */
public sealed interface RelayPolicy {

    /** The hop limit to stamp on packets this node originates. */
    public val hopLimit: Int

    /**
     * Talk only to nodes in direct range; never be relayed. The default.
     */
    public data object Island : RelayPolicy {
        override val hopLimit: Int = 0
    }

    /**
     * Participate in the wider mesh, accepting that traffic reaches the shared - and duty-cycle
     * limited - LoRa channel. Name a hop limit deliberately; the firmware default for a radio is 3.
     */
    public data class Meshed(override val hopLimit: Int) : RelayPolicy {
        init {
            require(hopLimit in 1..HOP_MAX) { "hopLimit must be 1..$HOP_MAX, was $hopLimit" }
        }
    }

    public companion object {
        /** Matches the firmware's HOP_MAX; the wire field is three bits. */
        public const val HOP_MAX: Int = 7
    }
}
