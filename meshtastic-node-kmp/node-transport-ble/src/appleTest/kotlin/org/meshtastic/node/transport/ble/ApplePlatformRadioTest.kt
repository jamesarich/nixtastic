package org.meshtastic.node.transport.ble

import io.kotest.matchers.shouldBe
import kotlin.test.Test

class ApplePlatformRadioTest {

    @Test
    fun `an Apple radio can listen and never speak`() {
        // Not a limitation of this implementation and not one a different library could lift:
        // CBPeripheralManager.startAdvertising accepts only CBAdvertisementDataLocalNameKey and
        // CBAdvertisementDataServiceUUIDsKey, so a MeshPacket is not expressible as an Apple
        // advertisement at all.
        bleMeshRadio().canTransmit shouldBe false
        BleMeshTransport().canTransmit shouldBe false
    }
}
