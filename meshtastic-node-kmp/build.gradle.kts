plugins {
    alias(libs.plugins.kotlinMultiplatform) apply false
    alias(libs.plugins.androidKmpLibrary) apply false
}

allprojects {
    group = "org.meshtastic"
    version = "0.1.0-SNAPSHOT"
}
