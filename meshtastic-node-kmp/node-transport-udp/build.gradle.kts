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

// Publishing. The artifacts are what make this consumable by android, apple and desktop alike;
// without it the library is a directory rather than a dependency.
plugins.apply("maven-publish")

extensions.configure<PublishingExtension> {
    publications.withType<MavenPublication>().configureEach {
        pom {
            name.set("Meshtastic Node :: ${project.name.removePrefix("node-")}")
            description.set(
                "Client-side implementation of the Meshtastic mesh protocol: a node, not a client " +
                    "of one."
            )
            url.set("https://github.com/meshtastic/meshtastic-node-kmp")
            licenses {
                license {
                    name.set("GPL-3.0-or-later")
                    url.set("https://www.gnu.org/licenses/gpl-3.0.html")
                }
            }
        }
    }
}
