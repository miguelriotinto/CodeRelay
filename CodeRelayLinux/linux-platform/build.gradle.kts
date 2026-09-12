// Linux desktop platform seams: Omarchy theming, desktop notifications,
// and network-link observation.
//
// No Compose, no UI — everything here is headless and unit-testable, which is
// the point: these are the pieces with real platform behaviour, so they must be
// coverable without a running desktop.
//
// External programs used (all present on a stock Omarchy install; declared as
// PKGBUILD depends):
//   notify-send  (libnotify)  — desktop notifications
//   secret-tool  (libsecret)  — used by :linux-storage, not here
//
// Deliberately NOT a JVM D-Bus binding: these tools exist everywhere, add no
// dependency, and cannot break the app when a daemon is missing.

plugins {
    alias(libs.plugins.kotlin.jvm)
}

dependencies {
    api(project(":shared-protocol"))
    // ConnectivitySource lives in :shared-session; LinuxConnectivitySource
    // implements it.
    api(project(":shared-session"))
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(libs.junit5.api)
    testImplementation(libs.junit5.params)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
}
