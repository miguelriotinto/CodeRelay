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

// The freshly built libvterm/JNI bridge, and where it is staged for packaging.
//
// **It has to be on `java.library.path` before the JVM starts.** termlib's own
// `TerminalNative` companion runs `System.loadLibrary("jni_cb_term")` in its
// static initializer, and `loadLibrary` searches `java.library.path` and nothing
// else. `NativeLibraryLoader` extracting the .so from the jar and `System.load`ing
// it by absolute path cannot satisfy that: the JVM keys loaded libraries by path,
// never by name, so the later `loadLibrary` still throws
// `no jni_cb_term in java.library.path`. Both entry points below therefore put a
// real directory containing the .so on that path.
val nativeTerminalLibs = project(":linux-terminal").layout.buildDirectory.dir("native-libs")

/**
 * Stages the .so under the app-resources layout jpackage copies into
 * `$APPDIR/resources` (the plugin's own `linux-x64` platform directory).
 */
val stageNativeTerminal by tasks.registering(Sync::class) {
    from(project(":linux-terminal").tasks.named("buildNativeTerminal"))
    into(layout.buildDirectory.dir("app-resources/linux-x64"))
}

compose.desktop {
    application {
        mainClass = "relay.app.CodeRelay"

        // jpackage substitutes $APPDIR at launch; `appResourcesRootDir` below is
        // what puts libjni_cb_term.so in the directory this names.
        jvmArgs += "-Djava.library.path=\$APPDIR/resources"

        // Let AWT decide the display scale, not Skia.
        //
        // `configureSwingGlobalsForCompose` — which every `application {}` entry
        // point calls — turns on `skiko.linux.autodpi`, and Skia's Linux
        // auto-DPI reads the X `Xft.dpi` resource. Under Hyprland with
        // `xwayland:force_zero_scaling = true` nothing publishes that resource,
        // so it concludes 1.0 and pins `sun.java2d.uiScale=1` — on a 2x panel
        // the entire UI then renders at half size, one device pixel per dp.
        // Measured: a 56.dp FAB came out 56 px, and the terminal grid inherited
        // the same halving. AWT gets it right on the same box (it honours
        // GDK_SCALE and Xft.dpi both), so defer to it: density went 1.0 → 2.0
        // with this single flag. On a 1x display AWT reports 1.0, so this stays
        // correct rather than trading one hard-coded scale for another.
        jvmArgs += "-Dskiko.linux.autodpi=false"

        nativeDistributions {
            appResourcesRootDir.set(layout.buildDirectory.dir("app-resources"))
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

// `prepareAppResources` is the single consumer of appResourcesRootDir, and
// nothing tells Gradle that this project writes into it — without the explicit
// edge the two run in either order, and when prepare wins it packages an image
// with an empty `resources/` and a java.library.path pointing at it.
tasks.matching { it.name == "prepareAppResources" }.configureEach {
    dependsOn(stageNativeTerminal)
}

// `./gradlew :app:run` launches a plain JVM with no jpackage layout, so $APPDIR
// means nothing here — point the path at the build output instead. Replaces the
// packaged value rather than appending, since the JVM honours the last -D wins.
// This module's live tests drive the real emulator (LiveTerminalRenderTest), so
// the test JVM needs the same library path the app gets — see the comment on
// `nativeTerminalLibs` for why it must be set at JVM start.
tasks.test {
    dependsOn(project(":linux-terminal").tasks.named("buildNativeTerminal"))
    doFirst {
        systemProperty("java.library.path", nativeTerminalLibs.get().asFile.absolutePath)
    }
}

// `matching`, not `named`: the Compose plugin registers `run` after this script
// is evaluated, so looking it up eagerly fails the build.
tasks.withType<JavaExec>().matching { it.name == "run" }.configureEach {
    dependsOn(project(":linux-terminal").tasks.named("buildNativeTerminal"))
    doFirst {
        jvmArgs = jvmArgs.orEmpty().filterNot { it.startsWith("-Djava.library.path=") } +
            "-Djava.library.path=${nativeTerminalLibs.get().asFile.absolutePath}"
    }
}

// Dev helper: prints the runtime classpath so the app can be launched directly
// with `java -cp`, which is how the WM-class JVM flag was verified.
tasks.register("printRuntimeClasspath") {
    val cp = sourceSets["main"].runtimeClasspath
    doLast { println(cp.asPath) }
}
