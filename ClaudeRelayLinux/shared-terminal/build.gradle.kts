// The TerminalEngine seam and the pure-logic controller/view-model that drive it.
//
// KeyboardAccessory.kt is EXCLUDED: it is the on-screen modifier-key bar for a
// soft keyboard (35 Compose imports, the only Compose in the module) and has no
// desktop meaning — a physical keyboard sends Ctrl/Alt/Esc directly. Excluding
// it leaves this module pure JVM with no Compose dependency at all.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

val androidRoot: java.io.File by rootProject.extra

sourceSets {
    main {
        kotlin.setSrcDirs(listOf(androidRoot.resolve("terminal/src/main/kotlin")))
        kotlin.exclude("**/KeyboardAccessory.kt")
    }
    test { kotlin.setSrcDirs(listOf(androidRoot.resolve("terminal/src/test/kotlin"))) }
}

dependencies {
    api(project(":shared-protocol"))
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
}
