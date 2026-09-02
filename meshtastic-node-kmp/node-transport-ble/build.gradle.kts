plugins {
    alias(libs.plugins.kotlinMultiplatform)
}

// Hardware tests report what they saw on the air, and a println that Gradle swallows is worse
// than useless when the question is "did anything arrive at all".
tasks.withType<Test>().configureEach { testLogging { showStandardStreams = true } }

kotlin {
    jvmToolchain(21)
    explicitApi()

    jvm()
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
