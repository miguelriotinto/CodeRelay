// The real VT100/xterm terminal for the Linux desktop.
//
// Android renders with `org.connectbot:termlib` — libvterm behind JNI plus a
// Compose renderer — published as an Android AAR with Android-ABI `.so` files.
// The ARTIFACT does not work off-Android. The SOURCE does, and upstream already
// supports it: `lib/src/main/cpp/CMakeLists.txt` carries a non-Android branch
//
//     else()
//         find_package(JNI REQUIRED)
//         target_include_directories(jni_cb_term PRIVATE ${JNI_INCLUDE_DIRS})
//         target_link_libraries(jni_cb_term vterm)
//     endif()
//
// and `Terminal.cpp` guards its logging behind `#ifdef __ANDROID__`. JNI is a
// standard JVM feature, not an Android one, so we build the same C++ for
// x86_64-linux and `TerminalNative.kt`'s 12 `external fun` declarations load
// against it unchanged.
//
// This is why we did NOT bind libvterm via Panama/FFM: doing so would mean
// reimplementing the 49 KB of C++ in Terminal.cpp that does cell-run batching,
// palette handling and the callback bridge — all of which already exists and is
// already exercised by a shipping Android app.
//
// Requires on the build host: cmake, a C++17 toolchain, and a JDK (for jni.h).

import org.gradle.internal.os.OperatingSystem
import org.gradle.process.ExecOperations
import javax.inject.Inject

plugins {
    alias(libs.plugins.kotlin.jvm)
    // Six of the synced termlib files import `androidx.compose.runtime.*` and
    // `androidx.compose.ui.graphics.Color`. Compose Multiplatform republishes
    // those exact package names for the desktop JVM, so they compile unchanged —
    // but the module therefore needs the Compose compiler plugin.
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.compose.multiplatform)
}

// Pinned by COMMIT, not tag or branch: termlib publishes no desktop artifact, so
// we track source, and an unpinned `main` would let an upstream change alter our
// terminal without review. Bumping this is a deliberate, reviewed edit.
val termlibCommit = "735c6dc646a845099f34083a15bd295be145a6ce"
val termlibRepo = "https://github.com/connectbot/termlib.git"

/**
 * Clones termlib at the pinned commit. A shallow fetch of the single commit
 * keeps this cheap; the task is up-to-date once the checked-out HEAD matches.
 */
// `Project.exec {}` inside a task action is deprecated in Gradle 8.14 and gone
// in 9. The supported form is an injected ExecOperations service, so these tasks
// are declared as typed tasks that take one.
abstract class GitCheckoutTask : DefaultTask() {
    @get:Inject abstract val execOps: ExecOperations

    @get:Input abstract val repoUrl: Property<String>
    @get:Input abstract val commit: Property<String>
    @get:OutputDirectory abstract val destination: DirectoryProperty

    @TaskAction
    fun checkout() {
        val dir = destination.get().asFile
        if (!dir.resolve(".git").isDirectory) {
            dir.deleteRecursively()
            dir.mkdirs()
            execOps.exec { commandLine("git", "init", "--quiet", dir.absolutePath) }
            execOps.exec {
                workingDir = dir
                commandLine("git", "remote", "add", "origin", repoUrl.get())
            }
        }
        // Shallow single-commit fetch: we need one tree, not the history.
        execOps.exec {
            workingDir = dir
            commandLine("git", "fetch", "--quiet", "--depth", "1", "origin", commit.get())
        }
        execOps.exec {
            workingDir = dir
            commandLine("git", "checkout", "--quiet", "--force", commit.get())
        }
    }
}

val fetchTermlib by tasks.registering(GitCheckoutTask::class) {
    repoUrl.set(termlibRepo)
    commit.set(termlibCommit)
    destination.set(layout.buildDirectory.dir("termlib-src"))
}

/**
 * Adds mouse dispatch to the checkout. termlib exposes keyboard input only —
 * `CLAUDE.md` records the consequence ("Android's termlib engine ... has no
 * mouse path at all"), which is why an agent's transcript cannot be scrolled
 * there. libvterm itself has `vterm_mouse_move`/`vterm_mouse_button` and owns
 * the encoding, so this is a small addition, documented in
 * patches/0001-mouse-dispatch.md and intended for upstreaming.
 *
 * The script is idempotent, so re-running over a patched tree is a no-op.
 */
abstract class PatchTermlibTask : DefaultTask() {
    @get:Inject abstract val execOps: ExecOperations

    @get:InputFile abstract val script: RegularFileProperty
    @get:Internal abstract val checkout: DirectoryProperty

    /**
     * The files the script edits, declared as outputs so Gradle's file-system
     * watching learns they changed. Without this the edit is invisible to the
     * downstream Sync (the python process is not a Gradle task output), which
     * then reports itself up-to-date and compiles a stale TerminalNative.kt —
     * the symptom is "Unresolved reference: dispatchPasteStart" right after a
     * build that printed "paste patch: ... TerminalNative.kt".
     */
    @get:OutputFiles
    val patched: Provider<List<File>>
        get() = checkout.map { dir ->
            listOf(
                dir.file("lib/src/main/cpp/Terminal.h").asFile,
                dir.file("lib/src/main/cpp/Terminal.cpp").asFile,
                dir.file("lib/src/main/java/org/connectbot/terminal/TerminalNative.kt").asFile,
            )
        }

    @TaskAction
    fun apply() {
        execOps.exec {
            commandLine("python3", script.get().asFile.absolutePath, checkout.get().asFile.absolutePath)
        }
    }
}

val patchTermlibMouse by tasks.registering(PatchTermlibTask::class) {
    dependsOn(fetchTermlib)
    script.set(layout.projectDirectory.file("patches/apply-mouse-patch.py"))
    checkout.set(layout.buildDirectory.dir("termlib-src"))
}

/**
 * Bracketed paste (`vterm_keyboard_start_paste` / `end_paste`), which termlib
 * likewise never exposed. Applied after the mouse patch because its Kotlin
 * anchor is the mouse wrapper. See patches/0002-bracketed-paste.md.
 */
val patchTermlibPaste by tasks.registering(PatchTermlibTask::class) {
    dependsOn(patchTermlibMouse)
    script.set(layout.projectDirectory.file("patches/apply-paste-patch.py"))
    checkout.set(layout.buildDirectory.dir("termlib-src"))
}

/**
 * Builds `libjni_cb_term.so` through upstream's own CMake, taking the `else()`
 * (non-Android) branch. We pass no `-DANDROID`, so `find_package(JNI)` resolves
 * against the Gradle toolchain's JDK.
 */
abstract class BuildNativeTerminalTask : DefaultTask() {
    @get:Inject abstract val execOps: ExecOperations

    @get:InputDirectory abstract val cppSource: DirectoryProperty
    @get:Internal abstract val cmakeBuildDir: DirectoryProperty
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun build() {
        require(OperatingSystem.current().isLinux) {
            "The native terminal is only built for Linux; this client targets Linux desktops."
        }
        val cpp = cppSource.get().asFile
        require(cpp.resolve("CMakeLists.txt").isFile) {
            "termlib sources missing at $cpp - did the fetch task run?"
        }

        // jni.h must come from the SAME JDK this module compiles against, or the
        // built library could disagree with the runtime about JNI ABI details.
        val javaHome = System.getProperty("java.home")
        val buildDir = cmakeBuildDir.get().asFile.apply { mkdirs() }

        // No -DANDROID, so upstream's CMakeLists takes its else() branch:
        //   find_package(JNI REQUIRED) + link only vterm.
        execOps.exec {
            commandLine(
                "cmake",
                "-S", cpp.absolutePath,
                "-B", buildDir.absolutePath,
                "-DCMAKE_BUILD_TYPE=Release",
                "-DJAVA_HOME=$javaHome",
            )
        }
        execOps.exec { commandLine("cmake", "--build", buildDir.absolutePath, "--parallel") }

        val out = outputDir.get().asFile.apply { mkdirs() }
        val built = buildDir.walkTopDown().firstOrNull { it.name == "libjni_cb_term.so" }
            ?: error("CMake succeeded but libjni_cb_term.so was not produced under $buildDir")
        built.copyTo(out.resolve(built.name), overwrite = true)
    }
}

val buildNativeTerminal by tasks.registering(BuildNativeTerminalTask::class) {
    dependsOn(patchTermlibPaste)
    cppSource.set(layout.buildDirectory.dir("termlib-src/lib/src/main/cpp"))
    cmakeBuildDir.set(layout.buildDirectory.dir("native"))
    outputDir.set(layout.buildDirectory.dir("native-libs"))
}

/**
 * Syncs from termlib exactly the Kotlin files that are portable, measured
 * import-by-import against upstream rather than assumed:
 *
 *   ZERO Android imports (verbatim):
 *     TerminalNative, TerminalCallbacks, CellRun, ScrollController, UrlDetection
 *
 *   ONLY `androidx.compose.*` imports (verbatim — Compose Multiplatform
 *   republishes those exact package names for the desktop JVM, which is the
 *   whole reason this works):
 *     ColorCache, TerminalSnapshot, TerminalLine, SemanticType, SelectionManager
 *
 *   NOT synced despite having only Compose imports:
 *     TerminalScreenState — its rememberTerminalScreenState() binds
 *     TerminalEmulatorImpl, the Android emulator we replace, so it cannot
 *     compile without it. Our renderer collects LinuxTerminalEmulator.grid
 *     directly instead.
 *
 * DELIBERATELY NOT SYNCED — see LinuxTerminalEmulator in this module:
 *   TerminalEmulator.kt (1,518 lines) is genuinely Android-coupled:
 *     android.os.Handler/Looper  → posts off the native mutex
 *     android.view.Choreographer → frame-synced damage coalescing
 *     android.icu.lang.UCharacter/UProperty → Unicode width queries
 *     android.util.Log
 *   Terminal.kt (2,506 lines) is the composable — IME, accessibility, Android
 *   key and pointer events — and is rewritten for Compose Desktop in :app.
 */
val syncTermlibKotlin by tasks.registering(Sync::class) {
    // The patches add the mouse and paste declarations to TerminalNative.kt, so
    // they must run before the sync copies that file out.
    dependsOn(patchTermlibPaste)
    from(layout.buildDirectory.dir("termlib-src/lib/src/main/java/org/connectbot/terminal")) {
        include(
            "TerminalNative.kt",
            "TerminalCallbacks.kt",
            "CellRun.kt",
            "ColorCache.kt",
            "TerminalSnapshot.kt",
            "TerminalLine.kt",
            "ScrollController.kt",
            "SelectionManager.kt",
            "SemanticType.kt",
            "UrlDetection.kt",
        )
    }
    into(layout.buildDirectory.dir("termlib-kotlin/org/connectbot/terminal"))
}

sourceSets {
    main {
        kotlin.srcDir(syncTermlibKotlin)
        // The .so is deliberately NOT a jar resource. It used to be, extracted at
        // startup by NativeLibraryLoader — which cannot help: termlib's own
        // static initializer resolves the library by NAME against
        // java.library.path, so a copy loaded from a temp path is ignored. The
        // library reaches the app through :app's `stageNativeTerminal` (into
        // `$APPDIR/resources`) and through the run/test tasks' java.library.path.
    }
}

// termlib's own `TerminalNative` companion calls `System.loadLibrary("jni_cb_term")`
// in its static initializer, which searches java.library.path only. That runs
// before any loader of ours can intervene (the failure shows up as
// ExceptionInInitializerError), so the test JVM must be pointed at the freshly
// built library rather than relying on extraction.
//
// The packaged app does not need this: jpackage places the .so beside the
// binary, and NativeLibraryLoader's resource-extraction path covers a fat jar.
tasks.test {
    dependsOn(buildNativeTerminal)
    doFirst {
        systemProperty(
            "java.library.path",
            layout.buildDirectory.dir("native-libs").get().asFile.absolutePath,
        )
    }
}

dependencies {
    api(project(":shared-terminal"))
    implementation(libs.kotlinx.coroutines.core)

    // Compose runtime + graphics only — no UI here. The synced termlib model
    // classes use @Immutable/@Stable, mutableStateOf, and Color.
    implementation(compose.runtime)
    implementation(compose.foundation)
    implementation(compose.ui)

    // Replaces android.icu.lang.UCharacter/UProperty in the ported emulator.
    // Android's `android.icu` IS ICU4J, so this is an import swap rather than a
    // reimplementation — the class and method names are identical.
    implementation("com.ibm.icu:icu4j:78.3")

    // Skia's NATIVE library, for the tests that measure real font metrics
    // (TerminalCellMetricsTest). `compose.ui` brings the skiko *bindings*; the
    // platform runtime jar that carries libskiko-linux-x64.so arrives with
    // `compose.desktop.currentOs`, which only :app depends on. Without it every
    // Skia call in a test JVM dies in a static initializer.
    testImplementation(compose.desktop.currentOs)
    testImplementation(libs.junit5.api)
    testRuntimeOnly(libs.junit5.engine)
    testImplementation(libs.kotlinx.coroutines.test)
}
