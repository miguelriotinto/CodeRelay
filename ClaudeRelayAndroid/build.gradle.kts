// Top-level build file. Plugins are declared here with `apply false` so that
// version resolution is centralized via the version catalog; individual modules
// opt in via `alias(libs.plugins.*)`.

// Override AGP 8.7.3's bundled R8 with a Kotlin-2.3-aware build. AGP picks up an
// `com.android.tools:r8` entry on the buildscript classpath and uses it in place
// of the bundled shrinker. Kotlin 2.3.21 emits metadata that the bundled R8 can't
// parse (harmless warnings, but the release shrinker should understand the code it
// shrinks); 8.13.19 is the minimum R8 documented to support Kotlin 2.3.x.
buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath(libs.android.r8)
    }
}

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
