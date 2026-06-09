plugins {
    alias(libs.plugins.kotlin.jvm)
}

dependencies {
    api(project(":core-protocol"))
    implementation(libs.okhttp)
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
    testImplementation(libs.okhttp.mockwebserver)
}

tasks.test { useJUnitPlatform() }

java { toolchain { languageVersion.set(JavaLanguageVersion.of(17)) } }
