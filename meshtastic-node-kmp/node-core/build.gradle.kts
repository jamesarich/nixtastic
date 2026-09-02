plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidKmpLibrary)
}

kotlin {
    jvmToolchain(21)

    // Every public declaration carries an explicit visibility and return type: this is a library,
    // and its API surface should change only on purpose.
    explicitApi()

    // Matches meshtastic-sdk's target set, so an app can depend on both without a target mismatch.
    // There is no platform source set here at all - cryptography-kotlin provides AES and X25519 in
    // common code - so adding a target is a one-line change rather than a porting exercise.
    jvm()
    android {
        namespace = "org.meshtastic.node"
        // 37, not 36: org.meshtastic:protobufs-android is built against it and
        // AAR metadata refuses a consumer compiled against less.
        compileSdk = 37
        // Runs the common suites on Android too, so the shared code is verified against Android's
        // own runtime rather than assumed to behave like the JVM's.
        withHostTest {}
        // startAdvertisingSet, which the BLE transport needs to put a mesh packet on the air,
        // arrived in 26. Nothing here would work on a device that cannot advertise.
        minSdk = 26
    }
    iosArm64()
    iosX64()
    iosSimulatorArm64()
    // macOS is less a shipping target than a test bench: it is the one platform where a BLE scan
    // can run against a real radio from a unit test on a developer machine.
    macosArm64()

    applyDefaultHierarchyTemplate()

    sourceSets {
        commonMain.dependencies {
            api(libs.coroutinesCore)
            api(libs.cryptographyCore)
            api(libs.meshtasticProtobufs)
        }
        // The provider is the one genuinely platform-specific thing here, and the reason is
        // AES-CCM: Meshtastic's PKI layer needs it, and neither the JDK's default JCA provider nor
        // Apple's CryptoKit has it - the JVM fails outright with "Cannot find any provider
        // supporting AES/CCM/NoPadding". openssl3 covers it on native but publishes no JVM
        // artifact, so the JVM uses the JDK provider backed by BouncyCastle. See MeshCrypto.kt.
        // JVM and Android answer the AES-CCM question identically - BouncyCastle runs on both -
        // so the actual is written once in a source set they share rather than duplicated.
        val jvmCommonMain by creating {
            dependsOn(commonMain.get())
            dependencies {
                implementation(libs.cryptographyProviderJdk)
                implementation(libs.bouncyCastle)
            }
        }
        jvmMain.get().dependsOn(jvmCommonMain)
        androidMain.get().dependsOn(jvmCommonMain)
        appleMain.dependencies {
            implementation(libs.cryptographyProviderOpenssl3)
        }
        commonTest.dependencies {
            implementation(libs.kotlinTest)
            implementation(libs.coroutinesTest)
            implementation(libs.turbine)
            implementation(libs.kotestAssertions)
        }
    }
}
