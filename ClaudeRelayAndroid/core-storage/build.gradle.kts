import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "relay.storage"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The pure-Kotlin logic in this module (SessionNaming) is covered by JVM
    // unit tests (src/test). Run them on the JUnit5 platform.
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
    implementation(libs.security.crypto)
    implementation(libs.datastore.preferences)
    implementation(libs.kotlinx.coroutines.android)
    // core-protocol exposes WireJson (Json) and uses kotlinx-serialization
    // internally; this module touches Json + ListSerializer directly, so it
    // needs the serialization runtime on its own classpath.
    implementation(libs.kotlinx.serialization.json)

    // Pure-Kotlin JVM unit tests (src/test) — SessionNaming picker.
    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)

    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
