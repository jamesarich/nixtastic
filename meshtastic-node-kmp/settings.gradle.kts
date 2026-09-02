pluginManagement {
    repositories {
        // AGP is published to Google's maven, not the plugin portal.
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

rootProject.name = "meshtastic-node-kmp"


dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}

include(":node-core")
include(":node-transport-udp")
include(":node-transport-ble")
// include(":node-transport-ble-gatt")  // Apple, and an Android fallback
// include(":node-android")             // foreground service, runtime permissions, Doze
// include(":node-bom")
