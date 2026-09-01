plugins {
    alias(libs.plugins.kotlin.multiplatform)
}

kotlin {
    jvmToolchain(21)
    jvm()

    sourceSets {
        commonMain.dependencies {
            api(project(":node-core"))
            implementation(libs.meshtastic.protobufs)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}
