import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "relay.speech"
    compileSdk = 34

    defaultConfig {
        minSdk = 28
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Task-1 scope is the pure-logic StreamingAudioBuffer, covered by JVM unit
    // tests (src/test) on the JUnit5 platform — same pattern as :core-session,
    // :core-storage, and :terminal.
    //
    // NO externalNativeBuild { cmake { ... } } block here: CMake is not
    // installed in this environment (NDK 27 is present, but neither the SDK
    // cmake nor a system cmake), so a whisper.cpp/llama.cpp native build would
    // fail with "CMake not found". The JNI native builds are a later, deferred
    // task (M3-C). ONNX Runtime Mobile and Oboe are plain AAR/Maven deps (no
    // CMake) and will be added when their consuming code lands.
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
    // Exposed transitively for shared protocol/value types consumed by the
    // speech pipeline (e.g. utterance text routed into the session layer).
    api(project(":core-protocol"))

    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
}
