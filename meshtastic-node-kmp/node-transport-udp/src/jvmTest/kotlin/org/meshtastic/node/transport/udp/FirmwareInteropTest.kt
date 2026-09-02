package org.meshtastic.node.transport.udp

import io.kotest.matchers.shouldBe
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.meshtastic.node.ChannelSetUrl
import org.meshtastic.node.MeshEvent
import org.meshtastic.node.MeshIdentity
import org.meshtastic.node.MeshNode
import org.meshtastic.node.MeshKeyPair
import org.meshtastic.node.ProtoPacketCodec
import org.meshtastic.node.RelayPolicy
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.test.Test
import kotlin.test.fail
import kotlin.time.Duration.Companion.seconds

/**
 * The node against a real radio.
 *
 * Every other test here proves the library agrees with itself. This one proves it agrees with the
 * firmware: a device on the same segment with `enabled_protocols` including `UDP_BROADCAST` puts
 * whole encoded `MeshPacket`s on 239.0.0.69:4403, and if our channel key, nonce construction or
 * field numbers are wrong in any detail, nothing decodes and nothing we send is understood.
 *
 * Skipped unless `MESH_INTEROP_CHANNEL_URL` names the radio's channel - it needs hardware, so it
 * cannot be part of the ordinary suite:
 *
 *     MESH_INTEROP_CHANNEL_URL='https://meshtastic.org/e/#...' MESH_INTEROP_PEER='!d1d0dfa1' \
 *         gradle :node-transport-udp:jvmTest --tests '*FirmwareInteropTest*'
 *
 * The URL carries the channel key, so it lives in the environment and never in this file.
 */
class FirmwareInteropTest {

    private companion object {
        /**
         * A fixed identity, and it has to be fixed.
         *
         * A radio pins the first public key it sees for a given node number and answers every later
         * one with "Public Key mismatch, drop NodeInfo" - correct of it, and unforgiving: a test
         * that generated a fresh keypair each run poisoned its own node number on the bench radio
         * after a single run, and no amount of re-running would recover it.
         *
         * The same hazard applies to any node this library builds: persist the address and the
         * keypair together, or become permanently unreachable to every peer that remembers you.
         */
        const val IDENTITY_SEED = "kmp-interop-bench-v2"

        @OptIn(ExperimentalEncodingApi::class)
        val OUR_KEYS = MeshKeyPair(
            privateKey = Base64.Default.decode("gCvf+tn2nqTYErqHML29Hmh8lkantrqR00hMHYBnTFk="),
            publicKey = Base64.Default.decode("grnVMQeWwEjzr7QIYhZEjraBewBFYynD6LqUYBImIxU="),
        )
    }

    private val channelUrl: String? = System.getenv("MESH_INTEROP_CHANNEL_URL")

    private val peerNodeNum: Long? = System.getenv("MESH_INTEROP_PEER")
        ?.let { if (it.startsWith("!")) it.drop(1).toLong(16) else it.toLong() }

    /**
     * The radio's X25519 public key, base64 as `security.public_key` reports it.
     *
     * Optional. Left unset the node waits to learn it from a NodeInfo broadcast, which is the real
     * path but runs on the firmware's own timer - NodeInfo is rate-limited to roughly ten minutes,
     * so a short test will usually miss it. Supplying it is what a user pairing with their own
     * radio does, and it makes the round trip testable in seconds rather than by luck.
     */
    @OptIn(ExperimentalEncodingApi::class)
    private val peerPublicKey: ByteArray? = System.getenv("MESH_INTEROP_PEER_KEY")
        ?.let { Base64.Default.decode(it) }

    private inner class Fixture(url: String, policy: RelayPolicy = RelayPolicy.Island) {
        val provisionedKey = peerPublicKey
        val channels = ChannelSetUrl.decode(url) ?: fail("MESH_INTEROP_CHANNEL_URL did not decode")
        val scope = CoroutineScope(SupervisorJob())
        val node = MeshNode(scope) {
            identity = MeshIdentity.derive(IDENTITY_SEED.encodeToByteArray(), "kmp interop", "KMP")
            this.channels += this@Fixture.channels
            transports += UdpMulticastTransport()
            codec = ProtoPacketCodec()
            relayPolicy = policy
            privateKey = OUR_KEYS.privateKey
            publicKey = OUR_KEYS.publicKey
            peerPublicKey = { provisionedKey }
            clock = { System.currentTimeMillis() }
        }
    }

    private fun withRadio(
        policy: RelayPolicy = RelayPolicy.Island,
        block: suspend (Fixture) -> Unit,
    ) = runBlocking {
        val url = channelUrl ?: return@runBlocking Unit.also {
            println("FirmwareInteropTest skipped: set MESH_INTEROP_CHANNEL_URL to run it against a radio")
        }
        val fixture = Fixture(url, policy)
        try {
            block(fixture)
        } finally {
            fixture.scope.cancel()
        }
    }

    private fun diagnosis(what: String): Nothing = fail(
        "$what\nCheck: the radio's network.enabled_protocols has UDP_BROADCAST (bit 0); it is " +
            "associated to the same subnet as this host; this host's firewall allows UDP 4403; and " +
            "both are on one L2 segment - multicast does not cross a router.",
    )

    // runBlocking, not runTest: runTest's virtual clock fires every timeout instantly, so the radio
    // would never get the chance to say anything.
    @Test
    fun `decrypts live traffic from a radio on the same segment`() = withRadio { f ->
        // A radio broadcasts NodeInfo, position and telemetry on its own schedule. Asking for a
        // response makes this deterministic rather than a wait on someone else's timer.
        f.scope.launch {
            repeat(6) {
                f.node.announce(wantResponse = it == 0)
                delay(10.seconds)
            }
        }

        val readable = withTimeoutOrNull(60.seconds) {
            f.node.events.first { it !is MeshEvent.Dropped && it !is MeshEvent.Opaque }
        } ?: diagnosis("Heard nothing decodable in 60s.")

        println("interop: decoded $readable")
    }

    @Test
    fun `a radio acknowledges a direct message from this node`() = withRadio { f ->
        val peer = peerNodeNum ?: return@withRadio println(
            "FirmwareInteropTest round trip skipped: set MESH_INTEROP_PEER to the radio's node number",
        )

        val delivered = f.scope.async {
            withTimeoutOrNull(120.seconds) { f.node.events.first { it is MeshEvent.Delivered } }
        }

        // The exchange in full: we announce so the radio learns our public key, it answers with its
        // own NodeInfo so we learn its key, and only then can either of us encrypt a DM to the
        // other. Neither side was provisioned with anything but the shared channel.
        f.scope.launch {
            var sent = false
            repeat(24) {
                if (!sent) {
                    // The radio needs our public key before it can decrypt anything we send it.
                    f.node.announce(wantResponse = true)
                    sent = f.node.sendText("interop round trip", to = peer, wantAck = true)
                }
                delay(5.seconds)
            }
        }

        // An ack proves the radio parsed our header, matched the channel hash, ran X25519 against a
        // public key it learned over the air, decrypted with AES-CCM and addressed a reply back to a
        // node number it had never seen before.
        delivered.await() ?: diagnosis(
            "Radio did not acknowledge within 120s. Peer key: " +
                "${(peerPublicKey ?: f.node.directory.publicKeyOf(peer))?.size ?: 0} bytes.",
        )
        println("interop: round trip acknowledged by !${peer.toString(16)}")
    }

    /**
     * Reach the LoRa mesh through a bridging radio.
     *
     * The node has no LoRa transport and cannot have one - there is no LoRa radio on a laptop. What
     * is provable is that its packets *reach* LoRa: a UDP-connected radio relays them onto the air
     * like any other traffic it hears.
     *
     * This is the one test that widens [RelayPolicy], and doing so is the entire point. Island mode
     * stamps `hop_limit = 0`, and `NextHopRouter::perhapsRebroadcast` relays only above zero - so
     * an island node is kept off LoRa by shipped firmware rather than by our own restraint. Opting
     * out of that protection is a deliberate act, which is why it is opt-in here too.
     *
     * Verified by observation on a second physical radio: `from` is a plaintext MeshPacket field,
     * so a receiver logs `Lora RX (id=... fr=...)` without holding any key. Set
     * `MESH_INTEROP_LORA_EGRESS=1` to arm it.
     */
    @Test
    fun `a packet this node sends is relayed onto LoRa`() = withRadio(RelayPolicy.Meshed(2)) { f ->
        if (System.getenv("MESH_INTEROP_LORA_EGRESS") == null) {
            println("LoRa egress skipped: set MESH_INTEROP_LORA_EGRESS=1 to put a packet on the air")
            return@withRadio
        }

        // Two hops, not seven: the bridging radio relays once and its neighbours decrement to zero
        // and stop. The smallest footprint that still crosses a LoRa link.
        f.node.relayPolicy.hopLimit shouldBe 2

        // A minute of it. The bridging radio may be mid-reboot or still rejoining WiFi when this
        // starts, and a one-shot send that lands in that window proves nothing either way.
        repeat(20) {
            f.node.announce()
            delay(3.seconds)
        }
        println("interop: sent as !${f.node.identity.nodeNum.toString(16)} - check a second radio for 'Lora RX ... fr='")
    }
}
