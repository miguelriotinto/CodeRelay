pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
        // Compose Multiplatform's plugin marker and its dev builds.
        maven("https://maven.pkg.jetbrains.space/public/p/compose/dev")
        google()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
        maven("https://maven.pkg.jetbrains.space/public/p/compose/dev")
        // Compose Multiplatform's desktop artifacts still pull a few genuine
        // androidx.* dependencies (savedstate, annotation, collection) that are
        // published only to Google's Maven, not Central. Without this the build
        // fails resolving androidx.savedstate on any Compose module.
        google()
    }
}

rootProject.name = "ClaudeRelayLinux"

// ---------------------------------------------------------------------------
// Shared modules — these compile source that PHYSICALLY LIVES under
// ClaudeRelayAndroid/. There is exactly one copy of each shared file on disk;
// see docs/linux-client-spec.md AD-2 for why we share rather than copy, and
// why we do not convert the Android modules to Kotlin Multiplatform in place.
//
// The wiring is in each module's build.gradle.kts via sourceSets srcDirs.
// Nothing under ClaudeRelayAndroid/ is modified by this build.
// ---------------------------------------------------------------------------
include(":shared-protocol")
include(":shared-net")
include(":shared-session")
include(":shared-terminal")

// Linux platform implementations of the seams the shared modules call.
include(":linux-storage")
include(":linux-platform")
include(":linux-terminal")

// Feature UI. Each compiles the shared Android sources plus a small set of
// Linux replacements; see each module's build file for the exclusion list.
include(":feature-servers")
include(":feature-workspace")
include(":feature-settings")

// The desktop application.
include(":app")
