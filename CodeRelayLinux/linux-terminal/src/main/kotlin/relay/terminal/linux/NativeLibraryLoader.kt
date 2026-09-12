package relay.terminal.linux

/**
 * Loads `libjni_cb_term.so` — the libvterm + JNI bridge built from termlib's
 * upstream CMake, taking its non-Android branch.
 *
 * **There is deliberately no extract-from-jar fallback, because one cannot
 * work.** termlib's own `TerminalNative` companion calls
 * `System.loadLibrary("jni_cb_term")` from its static initializer, and
 * `loadLibrary` resolves a *name* against `java.library.path` only. The JVM keys
 * already-loaded libraries by absolute path, so extracting the .so to a temp
 * file and `System.load`ing it here would succeed and still leave that later
 * `loadLibrary` throwing `no jni_cb_term in java.library.path`. This module
 * shipped exactly that fallback for a while: it made the loader look safe while
 * every GUI build failed the moment a session opened a terminal.
 *
 * So the library must be on `java.library.path` when the JVM starts, which
 * `:app`'s build script arranges for both entry points — `$APPDIR/resources` for
 * the jpackage image, `linux-terminal/build/native-libs` for `./gradlew :app:run`
 * — and `:linux-terminal`'s own test task does the same for tests.
 *
 * Calling this before touching `TerminalNative` turns the failure into a message
 * that names the cause instead of the raw JVM one.
 */
object NativeLibraryLoader {

    private const val LIBRARY_NAME = "jni_cb_term"
    private const val FILE_NAME = "lib$LIBRARY_NAME.so"

    @Volatile
    private var loaded = false

    /** Thrown when the terminal engine cannot be loaded. Fatal — there is no fallback renderer. */
    class NativeLoadException(message: String, cause: Throwable? = null) :
        RuntimeException(message, cause)

    /**
     * Loads the library once per process. Safe to call repeatedly.
     *
     * Deliberately has **no fallback**. Android once shipped a text-fallback
     * engine that rendered raw ANSI control codes as literal glyphs; it looked
     * like a working terminal while being useless. Failing loudly here is far
     * better than presenting a broken one.
     */
    @Synchronized
    fun ensureLoaded() {
        if (loaded) return

        try {
            System.loadLibrary(LIBRARY_NAME)
        } catch (e: UnsatisfiedLinkError) {
            throw NativeLoadException(
                "$FILE_NAME is not on java.library.path " +
                    "(${System.getProperty("java.library.path")}), so the terminal engine " +
                    "cannot start. Build it with `./gradlew :linux-terminal:buildNativeTerminal` " +
                    "(needs cmake, a C++17 compiler, and a JDK for jni.h); it must then be " +
                    "launched with that directory on java.library.path — `./gradlew :app:run` " +
                    "and the packaged app both set it. This JVM: ${System.getProperty("os.arch")}.",
                e,
            )
        }
        loaded = true
    }
}
