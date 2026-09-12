// Top-level build file. Plugins are declared here with `apply false` so that
// version resolution is centralized via the version catalog; individual modules
// opt in via `alias(libs.plugins.*)`.
//
// NOTE: AGP 8.13.2 bundles a Kotlin-2.3-aware R8, so the previous standalone
// `com.android.tools:r8` buildscript pin (an AGP-8.7.3-era workaround for Kotlin
// 2.3.21 metadata) has been removed. See gradle/libs.versions.toml [versions] agp.

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
    // FCM (F1 Android push): applied in :app, declared here for centralized
    // version resolution.
    alias(libs.plugins.google.services) apply false
}
