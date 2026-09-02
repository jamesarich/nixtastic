plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidKmpLibrary)
}

// Hardware tests report what they saw on the air, and a println that Gradle swallows is worse
// than useless when the question is "did anything arrive at all".
tasks.withType<Test>().configureEach { testLogging { showStandardStreams = true } }

kotlin {
    jvmToolchain(21)
    explicitApi()

    jvm()
    android {
        namespace = "org.meshtastic.node.transport.ble"
        // 37, not 36: org.meshtastic:protobufs-android is built against it and
        // AAR metadata refuses a consumer compiled against less.
        compileSdk = 37
        // Runs the common suites on Android too, so the shared code is verified against Android's
        // own runtime rather than assumed to behave like the JVM's.
        withHostTest {}
        // startAdvertisingSet, the only API that puts more than 31 bytes on the air, is API 26.
        minSdk = 26
    }
    iosArm64()
    iosX64()
    iosSimulatorArm64()
    macosArm64()

    applyDefaultHierarchyTemplate()

    sourceSets {
        commonMain.dependencies {
            api(project(":node-core"))
            api(libs.coroutinesCore)
        }
        commonTest.dependencies {
            implementation(libs.kotlinTest)
            implementation(libs.coroutinesTest)
            implementation(libs.turbine)
            implementation(libs.kotestAssertions)
        }
    }
}
