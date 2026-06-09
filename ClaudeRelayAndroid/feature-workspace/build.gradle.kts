import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "relay.feature.workspace"
    compileSdk = 34

    defaultConfig {
        minSdk = 28
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The testable slices are pure logic (atom color/blink mappings, uptime
    // formatting, tab/badge derivation) covered by JVM unit tests (src/test) on
    // the JUnit5 platform. Composables are verified by COMPILE only — runtime
    // rendering / adaptive reflow is DEVICE-DEFERRED.
    testOptions {
        unitTests.all { it.useJUnitPlatform() }
    }
}

// Kotlin 2.0 + AGP 8.5: configure the JVM target via the Kotlin Gradle DSL
// (`compilerOptions`) rather than the deprecated `kotlinOptions { }` block.
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    api(project(":core-protocol"))
    implementation(project(":core-session"))
    implementation(project(":terminal"))

    // :speech — the MicButton observes the PTT / continuous engine state
    // (SpeechEngineState / ContinuousListeningState) and the SpeechModelStore
    // download progress, and routes onUtteranceReady → terminal input. The engines
    // themselves are constructed by :app and handed down to WorkspaceScreen.
    implementation(project(":speech"))

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)

    // BackHandler (suppresses back-dismiss during recovery — the
    // interactiveDismissDisabled analog).
    implementation(libs.androidx.activity.compose)

    // collectAsStateWithLifecycle() for the StateFlow wiring.
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)

    implementation(libs.kotlinx.coroutines.android)

    // QR share: pure-JVM encode → BitMatrix (we rasterize to a Bitmap ourselves).
    implementation(libs.zxing.core)

    // QR scan (DEVICE-DEFERRED): CameraX preview + image analysis → ML Kit detect.
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.mlkit.barcode.scanning)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
}
