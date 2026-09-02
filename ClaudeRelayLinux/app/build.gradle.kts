// The CodeRelay desktop application for Linux.
//
// Produces a jpackage image bundling a trimmed JRE, so the AUR package imposes
// no system JDK on the user.

import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.compose.multiplatform)
}

dependencies {
    // The shared stack — protocol, transport, session coordination — compiled
    // from ClaudeRelayAndroid's own sources. :shared-session api-exposes
    // :shared-net and :linux-storage transitively; listed explicitly for clarity.
    implementation(project(":shared-protocol"))
    implementation(project(":shared-net"))
    implementation(project(":shared-session"))
    implementation(project(":shared-terminal"))

    implementation(project(":linux-storage"))
    implementation(project(":linux-platform"))
    implementation(project(":linux-terminal"))

    implementation(project(":feature-servers"))
    implementation(project(":feature-workspace"))
    implementation(project(":feature-settings"))

    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation(compose.components.resources)

    // Compose Desktop dispatches on the AWT event thread; this gives coroutines
    // a Main dispatcher that lands there.
    implementation(libs.kotlinx.coroutines.swing)
    implementation(libs.kotlinx.coroutines.core)

    // CMP ports of the AndroidX libraries the shared UI sources use. Different
    // coordinates (org.jetbrains.androidx.*), identical package names in source,
    // which is what lets those files compile unchanged.
    implementation(libs.navigation.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)

    // QR encode for the session-share sheet (pure JVM; scanning is not ported).
    implementation(libs.zxing.core)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
}

compose.desktop {
    application {
        mainClass = "relay.app.CodeRelay"

        nativeDistributions {
            targetFormats(TargetFormat.AppImage, TargetFormat.Deb)
            packageName = "coderelay"
            packageVersion = "0.1.0"
            description = "Remote terminal relay client for coding agents"
            vendor = "CodeRelay"

            linux {
                // Must match StartupWMClass in the .desktop entry so Hyprland
                // window rules can match the window.
                packageName = "coderelay"
                appCategory = "Development"
                menuGroup = "Development"
            }

            // Trim the bundled runtime. These are the modules actually reached:
            // java.base plus desktop (AWT/Swing, which Compose Desktop needs),
            // net.http (OkHttp), naming/management for the JDK internals Skia
            // and the logger touch.
            modules("java.base", "java.desktop", "java.net.http", "java.naming", "java.management")
        }
    }
}

// Dev helper: prints the runtime classpath so the app can be launched directly
// with `java -cp`, which is how the WM-class JVM flag was verified.
tasks.register("printRuntimeClasspath") {
    val cp = sourceSets["main"].runtimeClasspath
    doLast { println(cp.asPath) }
}
