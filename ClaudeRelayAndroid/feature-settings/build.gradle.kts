import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "relay.feature.settings"
    compileSdk = 35

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

    // Pure-logic helpers (the two AppSettings migration decisions) are covered by
    // JVM unit tests (src/test). The DataStore round-trip + Compose UI are
    // verified by COMPILE only — runtime is DEVICE-DEFERRED. Run on JUnit5.
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
    implementation(project(":core-storage"))

    // :speech — currentSpeechOptions() returns a SpeechProcessingOptions snapshot
    // for the PTT / continuous engines, so the type is part of this module's API.
    api(project(":speech"))

    // DataStore backs the 14 typed settings keys.
    implementation(libs.datastore.preferences)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)

    // viewModel() + collectAsStateWithLifecycle() for the screen wiring.
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)

    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
}
