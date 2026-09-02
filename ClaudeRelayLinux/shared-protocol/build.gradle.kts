// Wire protocol, shared verbatim with the Android client.
//
// Compiles ClaudeRelayAndroid/core-protocol's sources — one copy on disk, two
// builds. See docs/linux-client-spec.md AD-2.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

val androidRoot: java.io.File by rootProject.extra

sourceSets {
    main { kotlin.setSrcDirs(listOf(androidRoot.resolve("core-protocol/src/main/kotlin"))) }
    test {
        kotlin.setSrcDirs(listOf(androidRoot.resolve("core-protocol/src/test/kotlin")))
        // LiveFrameContractTest loads a captured live server frame from test
        // resources; without this the fixture is absent and the test NPEs on a
        // null stream rather than failing meaningfully.
        resources.setSrcDirs(listOf(androidRoot.resolve("core-protocol/src/test/resources")))
    }
}

dependencies {
    api(libs.kotlinx.serialization.json)
    testImplementation(libs.junit5.api)
    testImplementation(libs.junit5.params)
    testRuntimeOnly(libs.junit5.engine)
}
