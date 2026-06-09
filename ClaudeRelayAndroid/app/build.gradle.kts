import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "relay.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "relay.app"
        minSdk = 28
        targetSdk = 34
        versionCode = 2
        versionName = "0.2-m2"
    }

    buildFeatures {
        compose = true
        // The Settings "About" section reads version/build from BuildConfig.
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // M2 ships the real nav graph (Splash → Servers → Workspace + Settings).
    // No release signing config is wired here yet.
    buildTypes {
        debug {
            isMinifyEnabled = false
        }
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
    // The full stack — this is the module that proves the whole graph links.
    implementation(project(":core-protocol"))
    implementation(project(":core-net"))
    implementation(project(":core-storage"))
    implementation(project(":terminal"))
    // :core-session api-exposes core-net / core-storage / terminal transitively;
    // listed explicitly here too for clarity (the nav graph wires the coordinator).
    implementation(project(":core-session"))

    // The three feature modules the nav graph hosts.
    implementation(project(":feature-servers"))
    implementation(project(":feature-workspace"))
    implementation(project(":feature-settings"))

    // :speech — the SpeechModelStore (splash preload), the ContinuousListeningEngine
    // (foreground service), and the SpeechProcessingOptions snapshot. This is the
    // module that finally packages the ONNX Runtime native libs into the APK (the
    // M3-E concern): :app → :speech → onnxruntime-android AAR → libonnxruntime*.so.
    implementation(project(":speech"))

    implementation(libs.kotlinx.coroutines.android)

    // core-net keeps okhttp `implementation` (not exposed transitively), but
    // RelayConnection's primary constructor has a default-argument of type
    // OkHttpClient — so any caller compiling against it needs okhttp on its
    // compile classpath even when using the no-arg constructor.
    implementation(libs.okhttp)

    // Compose — versions resolved transitively via the BOM platform.
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.activity.compose)

    // Navigation-Compose drives the Splash → Servers → Workspace + Settings graph.
    implementation(libs.androidx.navigation.compose)

    // collectAsStateWithLifecycle() + LifecycleEventEffect (ON_RESUME → recovery).
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
}
