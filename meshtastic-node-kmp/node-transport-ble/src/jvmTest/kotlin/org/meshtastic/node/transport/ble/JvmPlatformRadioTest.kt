package org.meshtastic.node.transport.ble

import io.kotest.matchers.shouldBe
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlin.test.Test

class JvmPlatformRadioTest {

    @Test
    fun `the JVM has no BLE and says so rather than scanning silently`() = runTest {
        // A node built on this reports the transport through receiveOnlyTransports instead of
        // appearing to listen and finding nothing forever. Linux could have both directions via
        // BlueZ over D-Bus; that is a real implementation, not a shim, and lives elsewhere.
        bleMeshRadio().canTransmit shouldBe false
        bleMeshRadio().advertisements().toList().isEmpty() shouldBe true
    }
}
