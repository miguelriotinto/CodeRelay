// Top-level build file. Plugins are declared here with `apply false` so that
// version resolution is centralized via the version catalog; individual modules
// opt in via `alias(libs.plugins.*)`.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
