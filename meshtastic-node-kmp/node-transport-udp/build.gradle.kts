plugins {
    alias(libs.plugins.kotlinMultiplatform)
}

kotlin {
    jvmToolchain(21)
    explicitApi()

    // JVM only, and that is a property of the transport rather than an omission: iOS needs the
    // restricted com.apple.developer.networking.multicast entitlement, which is granted per app by
    // Apple rather than by a library, so an iOS multicast transport has to be assembled by the
    // consuming app.
    jvm()

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
