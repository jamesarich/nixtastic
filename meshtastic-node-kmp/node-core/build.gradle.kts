plugins {
    alias(libs.plugins.kotlin.multiplatform)
}

kotlin {
    // Every public declaration carries an explicit visibility and return type: this is a
    // library, and its API surface should change only on purpose.
    explicitApi()

    jvmToolchain(21)

    // Only the JVM target is wired up so far. The source layout is already
    // commonMain/<platform>Main, and the single platform-specific seam is the AES provider in
    // Crypto.kt, so adding androidTarget() and the apple targets is mechanical rather than a
    // restructure. Deliberately not enabled yet: apple targets need Xcode, and every active Nix
    // shell breaks a real Xcode build (see the workspace CLAUDE.md).
    jvm()

    sourceSets {
        commonMain.dependencies {
            implementation(libs.meshtastic.protobufs)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}
