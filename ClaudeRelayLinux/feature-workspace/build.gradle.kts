// The workspace: sidebar, session tabs, terminal host, status bar.
//
// The bulk is shared verbatim from Android — SessionSidebar (579),
// SessionTabs (284), AttachSessionSheet (289), ActivityDot, AgentStatePill,
// AgentColorPalette, AgentSparkleIcon, ConnectionQualityDot, WorkspaceLogic,
// DeepLinks, SessionName — none of which import an Android API.
//
// WorkspaceScreen.kt (816) and WorkspaceViewModel.kt (185) are ALSO shared,
// which was not obvious: the screen's single Android dependency is one
// `BackHandler` call (shimmed as a desktop no-op in
// src/main/kotlin/androidx/activity/compose/), and the view model imports only
// androidx.lifecycle.ViewModel/viewModelScope, which CMP republishes under
// identical package names. Forking either would have meant ~1,000 lines of
// duplicate UI drifting from the Android original.
//
// Replaced or dropped locally:
//   TerminalHost.kt          — LocalView + WindowInsets, i.e. showing the soft
//                              keyboard; a desktop has none, and the host must
//                              bind our libvterm engine rather than termlib
//   TermlibTerminalEngine.kt — the ANDROID termlib binding; ours is :linux-terminal
//   Haptics.kt               — no desktop equivalent
//   QrScannerScreen.kt       — CameraX + ML Kit; pairing uses a typed code instead
//   QrShareSheet.kt          — Android Bitmap; desktop QR render TODO
//   MicButton.kt             — speech is out of parity scope (spec §1.1)

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.compose.multiplatform)
}

val androidRoot: java.io.File by rootProject.extra

sourceSets {
    main {
        kotlin.srcDirs("src/main/kotlin", androidRoot.resolve("feature-workspace/src/main/kotlin"))
        kotlin.exclude {
            it.file.absolutePath.startsWith(androidRoot.absolutePath) &&
                it.name in setOf(
                    "TerminalHost.kt",
                    "TermlibTerminalEngine.kt", "Haptics.kt", "QrScannerScreen.kt",
                    "QrShareSheet.kt", "MicButton.kt",
                )
        }
    }
    test {
        kotlin.srcDirs("src/test/kotlin", androidRoot.resolve("feature-workspace/src/test/kotlin"))
        // Cover excluded Android screens.
        kotlin.exclude {
            it.file.absolutePath.startsWith(androidRoot.absolutePath) &&
                it.name in setOf(
                    "SessionTabsLogicTest.kt",
                    "MicButtonStateTest.kt",
                    // Tests the Android vibrator-backed HapticController; ours is
                    // a no-op with no `vibrator` to inject.
                    "HapticsTest.kt",
                )
        }
    }
}

dependencies {
    api(project(":shared-protocol"))
    api(project(":shared-session"))
    api(project(":shared-terminal"))
    api(project(":linux-terminal"))
    api(project(":linux-storage"))
    implementation(libs.kotlinx.coroutines.core)

    implementation(compose.runtime)
    implementation(compose.foundation)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation(compose.ui)
    // Shared UI files carry @Preview; CMP publishes
    // androidx.compose.ui.tooling.preview.Preview via this artifact.
    implementation(compose.components.uiToolingPreview)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
}
