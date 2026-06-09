import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "relay.speech"
    compileSdk = 35

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
    // task (M3-C). ONNX Runtime Mobile is a plain AAR/Maven dep (no CMake) and is
    // now present (see dependencies) to back the gated M3-E detectors; Oboe will
    // be added when its consuming code lands.
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

    // CloudPromptEnhancer: AWS Bedrock Converse REST call (OkHttp) + JSON
    // request/response shaping (kotlinx-serialization, the codebase JSON standard;
    // avoids Android's unit-test `org.json` stub so the pure helpers are testable).
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)

    // ONNX Runtime Mobile (AAR) — backs the GATED M3-E SileroVoiceActivityDetector
    // + SmartTurnTurnEndDetector. These detectors compile against this API now but
    // are NOT wired into ContinuousListeningEngine.makeDefault (which keeps the
    // energy VAD + HeuristicTurnEndDetector). M4 wires them in once
    // ml/validate_parity.py converts the CoreML models to ONNX and the parity gate
    // passes. Plain Maven AAR — no CMake/NDK native build required.
    implementation(libs.onnxruntime.android)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
}
