plugins {
    alias(libs.plugins.kotlinMultiplatform)
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
    iosArm64()
    iosX64()
    iosSimulatorArm64()

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
        jvmMain.dependencies {
            implementation(libs.cryptographyProviderJdk)
            implementation(libs.bouncyCastle)
        }
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
