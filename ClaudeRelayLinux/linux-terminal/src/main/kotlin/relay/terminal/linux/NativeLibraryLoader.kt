package relay.terminal.linux

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Loads `libjni_cb_term.so` — the libvterm + JNI bridge built from termlib's
 * upstream CMake, taking its non-Android branch.
 *
 * `System.loadLibrary` searches `java.library.path`, which does not include the
 * inside of a jar, so the packaged `.so` is extracted to a temp file and loaded
 * by absolute path. A jpackage/jlink distribution can instead place the library
 * on `java.library.path`; that path is tried first, so the packaged build does
 * no extraction at all.
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

        // 1. Packaged distribution: already on java.library.path.
        runCatching {
            System.loadLibrary(LIBRARY_NAME)
            loaded = true
        }.onSuccess { return }

        // 2. Development / fat-jar: extract from resources.
        val stream = NativeLibraryLoader::class.java.classLoader
            ?.getResourceAsStream(FILE_NAME)
            ?: throw NativeLoadException(
                "$FILE_NAME is neither on java.library.path nor packaged in resources. " +
                    "Run `./gradlew :linux-terminal:buildNativeTerminal` (needs cmake, a C++17 " +
                    "compiler, and a JDK for jni.h).",
            )

        val extracted = try {
            // Not deleteOnExit: the JVM may be killed, and a stale 0-byte file
            // from a previous crash would then be loaded instead of a real one.
            // A unique name per process avoids that entirely.
            val dir = Files.createTempDirectory("coderelay-native").toFile()
            dir.deleteOnExit()
            val target = File(dir, FILE_NAME)
            stream.use { input ->
                Files.copy(input, target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
            target.deleteOnExit()
            target
        } catch (e: Exception) {
            throw NativeLoadException("Could not unpack $FILE_NAME", e)
        }

        try {
            System.load(extracted.absolutePath)
        } catch (e: UnsatisfiedLinkError) {
            throw NativeLoadException(
                "Failed to load $FILE_NAME from ${extracted.absolutePath}. " +
                    "It may have been built for a different architecture " +
                    "(this JVM: ${System.getProperty("os.arch")}).",
                e,
            )
        }
        loaded = true
    }
}
