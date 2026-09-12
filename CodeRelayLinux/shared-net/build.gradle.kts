// WebSocket transport + session RPC, shared verbatim with the Android client.
// Pure JVM already on Android (OkHttp), so this needs no adaptation at all.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

val androidRoot: java.io.File by rootProject.extra

sourceSets {
    main { kotlin.setSrcDirs(listOf(androidRoot.resolve("core-net/src/main/kotlin"))) }
    test { kotlin.setSrcDirs(listOf(androidRoot.resolve("core-net/src/test/kotlin"))) }
}

dependencies {
    api(project(":shared-protocol"))
    api(libs.okhttp)
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
