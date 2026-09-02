// Root build for the Linux desktop client.
//
// Plugins are declared `apply false` here and applied per-module, which is the
// standard multi-module arrangement and keeps the root project itself free of a
// Kotlin/Compose toolchain.

plugins {
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.compose.multiplatform) apply false
}

// Every module targets the same JVM. 21 is the floor because the desktop
// distribution is produced with jlink/jpackage; the shared Android sources are
// compiled for JVM 17 in the Android build, and 21 reads those fine.
subprojects {
    plugins.withId("org.jetbrains.kotlin.jvm") {
        extensions.configure<org.gradle.api.plugins.JavaPluginExtension>("java") {
            toolchain { languageVersion.set(JavaLanguageVersion.of(21)) }
        }
        tasks.withType<Test>().configureEach {
            useJUnitPlatform()
            testLogging {
                events("passed", "skipped", "failed")
                exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
            }
        }
    }
}

// Convenience: the path to the Android project, from which all shared source is
// compiled. Declared once so the shared modules do not each re-derive it, and so
// a future relocation is a one-line change.
extra["androidRoot"] = rootProject.projectDir.parentFile.resolve("ClaudeRelayAndroid")
