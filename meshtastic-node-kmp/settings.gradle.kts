rootProject.name = "meshtastic-node-kmp"

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}

include(":node-core")
include(":node-transport-udp")
// include(":node-transport-ble-adv")   // Android + Linux; connectionless extended advertising
// include(":node-transport-ble-gatt")  // Apple, and an Android fallback
// include(":node-android")             // foreground service, runtime permissions, Doze
// include(":node-bom")
