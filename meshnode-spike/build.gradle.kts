plugins {
    kotlin("jvm") version "2.4.10"
}

kotlin { jvmToolchain(21) }

dependencies {
    // The same Wire-generated KMP models android consumes, so this code is commonMain-ready
    // rather than JVM-only in anything but its crypto provider.
    implementation("org.meshtastic:protobufs:2.8.0")
    testImplementation(kotlin("test"))
}

tasks.test { useJUnitPlatform() }
