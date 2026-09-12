// Session coordinator, recovery state machine, activity coordination, pairing.
//
// 3,216 lines that import NO Android API — verified before this module existed.
// On Android it is an android.library only because it depends on :core-storage;
// here it depends on :linux-storage, which presents the identical public API in
// the same `relay.storage` package.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

val androidRoot: java.io.File by rootProject.extra

sourceSets {
    main { kotlin.setSrcDirs(listOf(androidRoot.resolve("core-session/src/main/kotlin"))) }
    test { kotlin.setSrcDirs(listOf(androidRoot.resolve("core-session/src/test/kotlin"))) }
}

dependencies {
    api(project(":shared-protocol"))
    api(project(":shared-net"))
    api(project(":linux-storage"))
    api(project(":shared-terminal"))
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
}
