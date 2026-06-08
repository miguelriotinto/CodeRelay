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
        versionCode = 1
        versionName = "0.1-m1"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // M1 ships a debug-only throwaway demo (replaced by the real nav graph in
    // M2). No release signing config is wired here.
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
    // The full M1 stack — this is the module that proves the whole graph links.
    implementation(project(":core-protocol"))
    implementation(project(":core-net"))
    implementation(project(":core-storage"))
    implementation(project(":terminal"))
    // :core-session api-exposes core-net / core-storage / terminal transitively;
    // listed explicitly here too for clarity (M2 nav graph wires the coordinator).
    implementation(project(":core-session"))

    // feature-workspace owns DeepLinks (the clauderelay://session parser) consumed
    // by MainActivity's intent handling, plus the QR sheet/scanner the nav graph
    // wires in Task 11.
    implementation(project(":feature-workspace"))

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
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.activity.compose)
}
