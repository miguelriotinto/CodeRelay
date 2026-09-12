// Server list, add/edit, and pairing UI.
//
// Shared verbatim from Android: ServersScreen (412), AddEditServerSheet (226),
// PairWithHostSheet (146), ServerFormLogic (96). ServersScreen's only
// non-portable import is collectAsStateWithLifecycle, which CMP supplies under
// the identical package name.
//
// Replaced locally:
//   ServersViewModel.kt  — constructs Context-backed stores
//   PairingViewModel.kt  — uses android.os.Build for the device name

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.compose.multiplatform)
}

val androidRoot: java.io.File by rootProject.extra

sourceSets {
    main {
        kotlin.srcDirs("src/main/kotlin", androidRoot.resolve("feature-servers/src/main/kotlin"))
        // Exclude by ANDROID path prefix, not by filename alone: a bare
        // `**/ServersViewModel.kt` pattern would also drop our replacement,
        // since both sit at the same package-relative path.
        kotlin.exclude {
            it.file.absolutePath.startsWith(androidRoot.absolutePath) &&
                it.name in setOf("ServersViewModel.kt", "PairingViewModel.kt")
        }
    }
    test {
        kotlin.srcDirs("src/test/kotlin", androidRoot.resolve("feature-servers/src/test/kotlin"))
        // Covers PairingViewModel, which is excluded above.
        kotlin.exclude {
            it.file.absolutePath.startsWith(androidRoot.absolutePath) &&
                it.name in setOf("PairingViewModelTest.kt")
        }
    }
}

dependencies {
    api(project(":shared-protocol"))
    api(project(":shared-session"))
    api(project(":linux-storage"))
    implementation(libs.kotlinx.coroutines.core)

    implementation(compose.runtime)
    implementation(compose.foundation)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation(compose.ui)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
}
