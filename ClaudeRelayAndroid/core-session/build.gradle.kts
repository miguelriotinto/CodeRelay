import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "relay.session"
    compileSdk = 34

    defaultConfig {
        minSdk = 28
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The pure-Kotlin logic in this module (coordinators, recovery, cache) is
    // covered by JVM unit tests (src/test) — same pattern as :core-storage and
    // :terminal. Run them on the JUnit5 platform.
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
    // The keystone coordinator binds the real session-layer types, so the
    // module exposes them transitively to :app / feature modules. The
    // dependency-light pure-logic classes (RecoveryController, AuthCoordinator,
    // ActivityCoordinator, TerminalCache) keep their injected seams and do NOT
    // reference these — only SessionCoordinator does.
    api(project(":core-protocol"))
    api(project(":core-net"))
    api(project(":core-storage"))
    api(project(":terminal"))

    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)

    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
