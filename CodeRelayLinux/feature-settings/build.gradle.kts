// Settings UI.
//
// `SettingsScreen.kt` (471 lines) is compiled straight from the Android source:
// its only non-portable import is
// `androidx.lifecycle.compose.collectAsStateWithLifecycle`, and Compose
// Multiplatform republishes that under the identical package name.
//
// Replaced locally (not shared):
//   AppSettings.kt          — DataStore-backed on Android; ours is file-backed
//   ShortcutFlags.kt        — android.view.KeyEvent constants (values preserved)
//   KeyCapture.kt           — android.view.KeyEvent capture; desktop equivalent TODO
//   AppSettingsMigrations   — migrates legacy ANDROID keys; no legacy exists here

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.compose.multiplatform)
}

val androidRoot: java.io.File by rootProject.extra

sourceSets {
    main {
        kotlin.srcDirs(
            "src/main/kotlin",
            androidRoot.resolve("feature-settings/src/main/kotlin"),
        )
        // Exclude by ANDROID path prefix, not by filename: a bare
        // `**/AppSettings.kt` pattern would also drop our own replacement, since
        // both live at the same package-relative path.
        kotlin.exclude { it.file.absolutePath.startsWith(androidRoot.absolutePath) &&
            it.name in setOf("AppSettings.kt", "ShortcutFlags.kt", "KeyCapture.kt", "AppSettingsMigrations.kt") }
    }
    test { kotlin.srcDirs("src/test/kotlin") }
}

dependencies {
    api(project(":shared-protocol"))
    api(project(":linux-storage"))
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)

    implementation(compose.runtime)
    implementation(compose.foundation)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation(compose.ui)
    implementation(libs.lifecycle.runtime.compose)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
}
