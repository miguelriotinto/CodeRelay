import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// Release signing is driven from a NON-COMMITTED `keystore.properties` at the
// Android project root (gitignored — see .gitignore + RELEASE.md). When the file
// is present (a human ran the keytool setup) we wire a real `release` signing
// config from it. When it's absent (headless dev / CI without the upload key) we
// fall back to debug signing in the release buildType so `assembleRelease` still
// produces an installable — if debug-signed — artifact and never fails on a
// missing key. The fallback APK/AAB is NOT upload-eligible; it only proves R8 +
// the keep rules link cleanly.
val keystorePropsFile = rootProject.file("keystore.properties")
val hasReleaseKeystore = keystorePropsFile.exists()
val keystoreProps = Properties().apply {
    if (hasReleaseKeystore) keystorePropsFile.inputStream().use { load(it) }
}

android {
    namespace = "relay.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "relay.app"
        minSdk = 28
        targetSdk = 34
        // M26 version. Milestone naming ("0.3-m26") chosen over a bare "1.0"
        // so the version string stays honest about the pre-1.0 milestone cadence;
        // the App "About" section reads this via BuildConfig (buildConfig = true).
        versionCode = 25
        versionName = "0.3-m26"
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

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            // R8 full-mode: shrink + obfuscate code and shrink resources. The
            // keep rules in proguard-rules.pro protect everything reflection- or
            // JNI-based (kotlinx.serialization, ONNX Runtime, ML Kit, OkHttp,
            // coroutines) from being stripped. proguard-android-optimize.txt is
            // AGP's optimized default ruleset.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig =
                if (hasReleaseKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    // Headless/CI fallback: debug-signed so the build still
                    // assembles. NOT eligible for Play upload.
                    signingConfigs.getByName("debug")
                }
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
