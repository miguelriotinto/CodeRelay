// Linux implementations of the `relay.storage` seams.
//
// Presents the SAME public API as ClaudeRelayAndroid's :core-storage in the same
// `relay.storage` package, so :shared-session and the shared feature sources
// compile against it unchanged. Only the constructors differ — there is no
// Android `Context` here, so the stores take files (or nothing).
//
// Backing stores:
//   SavedConnectionStore   → $XDG_CONFIG_HOME/coderelay/servers.json
//   SessionOwnershipStore  → $XDG_STATE_HOME/coderelay/{sessionNames,agentSessions}.json
//   DeviceIdentifier       → $XDG_STATE_HOME/coderelay/device-id
//   TokenStore             → Secret Service (libsecret), never the filesystem

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

val androidRoot: java.io.File by rootProject.extra

// SessionNaming is pure Kotlin (zero Android imports) and is the one file from
// :core-storage that ports verbatim. It cannot simply be added as a shared
// srcDir the way :shared-session does it, because the other four files in that
// directory are the Android stores whose class names collide with ours — and a
// source-set `exclude` pattern matches by path suffix, so excluding
// `**/relay/storage/TokenStore.kt` would drop OUR TokenStore too.
//
// Syncing the single file into a generated dir keeps exactly one copy of the
// truth (the Android file) with no collision. `Sync` rather than `Copy` so a
// rename upstream removes the stale output instead of leaving a duplicate class.
val syncSharedNaming by tasks.registering(Sync::class) {
    from(androidRoot.resolve("core-storage/src/main/kotlin/relay/storage/SessionNaming.kt"))
    into(layout.buildDirectory.dir("shared-src/relay/storage"))
}

// Same for its test, so the shared naming logic keeps its coverage here.
val syncSharedNamingTest by tasks.registering(Sync::class) {
    from(androidRoot.resolve("core-storage/src/test/kotlin/relay/storage/SessionNamingTest.kt")) {
        // Tolerate the file not existing rather than failing configuration.
        include("**/*.kt")
    }
    into(layout.buildDirectory.dir("shared-test-src/relay/storage"))
}

sourceSets {
    main { kotlin.srcDir(syncSharedNaming) }
    test { kotlin.srcDir(syncSharedNamingTest) }
}

dependencies {
    api(project(":shared-protocol"))
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(libs.junit5.api)
    testImplementation(libs.junit5.params)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
}
