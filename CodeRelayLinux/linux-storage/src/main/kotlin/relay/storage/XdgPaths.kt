package relay.storage

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission

/**
 * XDG Base Directory resolution for everything this client writes.
 *
 * Android's stores hide their locations behind `Context` (DataStore,
 * SharedPreferences); on Linux the locations are ours to choose, and the
 * convention is the XDG spec. Each accessor honours the corresponding
 * environment variable and falls back to the spec's default.
 *
 * The split matters and is not cosmetic:
 *  - [configDir] (`~/.config`) holds things a user might reasonably edit or
 *    put under version control — the server bookmark list.
 *  - [stateDir] (`~/.local/state`) holds things the app owns and the user
 *    should not hand-edit — the device id, session display names, agent map.
 *
 * Secrets live in neither; they go to the Secret Service (see [TokenStore]).
 */
object XdgPaths {

    private const val APP = "coderelay"

    /**
     * Environment lookup, injectable for tests. Production reads the real
     * environment; the JVM offers no supported way to mutate it in-process, so
     * the seam is the only way to cover the spec's rules (§ "relative paths are
     * invalid and must be ignored") without spawning a subprocess per case.
     */
    internal var envLookup: (String) -> String? = System::getenv

    /** Home directory, injectable alongside [envLookup] for the same reason. */
    internal var homeLookup: () -> String = { System.getProperty("user.home") }

    /** `$XDG_CONFIG_HOME/coderelay`, else `~/.config/coderelay`. */
    val configDir: File get() = resolve("XDG_CONFIG_HOME", ".config")

    /** `$XDG_STATE_HOME/coderelay`, else `~/.local/state/coderelay`. */
    val stateDir: File get() = resolve("XDG_STATE_HOME", ".local/state")

    /** `$XDG_DATA_HOME/coderelay`, else `~/.local/share/coderelay`. */
    val dataDir: File get() = resolve("XDG_DATA_HOME", ".local/share")

    internal fun resolve(envVar: String, fallbackRelative: String): File {
        // The spec says a relative value is invalid and must be ignored, which
        // is why this checks isAbsolute rather than merely non-blank.
        val fromEnv = envLookup(envVar)?.takeIf { it.isNotBlank() }?.let(::File)
        val base = if (fromEnv != null && fromEnv.isAbsolute) {
            fromEnv
        } else {
            File(homeLookup(), fallbackRelative)
        }
        return File(base, APP)
    }

    /**
     * Ensures [dir] exists and is owner-only (0700).
     *
     * Bookmarks name hosts and ports of machines the user can reach, and the
     * state dir names their sessions; neither belongs to other local users even
     * though neither is a credential.
     */
    fun ensureDir(dir: File) {
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) {
            throw IOException("Cannot create directory: $dir")
        }
        runCatching {
            Files.setPosixFilePermissions(
                dir.toPath(),
                setOf(
                    PosixFilePermission.OWNER_READ,
                    PosixFilePermission.OWNER_WRITE,
                    PosixFilePermission.OWNER_EXECUTE,
                ),
            )
        }
    }

    /**
     * Writes [content] to [target] atomically: a sibling temp file, fsync'd and
     * chmod 0600, then an atomic rename over the target.
     *
     * This mirrors the guarantee the Android stores get for free —
     * `SharedPreferences.commit()` and DataStore both write-then-rename — and
     * that the server's own `TokenStore.save` takes care to provide
     * (`Data.write(options: .atomic)`). Without it, a crash mid-write leaves a
     * truncated JSON file, and every one of these stores treats a parse failure
     * as "empty", so a torn write would silently erase the user's bookmarks.
     */
    fun writeAtomically(target: File, content: String) {
        ensureDir(target.parentFile)
        val tmp = File.createTempFile(target.name, ".tmp", target.parentFile)
        try {
            runCatching {
                Files.setPosixFilePermissions(
                    tmp.toPath(),
                    setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
                )
            }
            tmp.outputStream().use { out ->
                out.write(content.toByteArray(Charsets.UTF_8))
                out.flush()
                // Durability before the rename: an atomic rename over a file
                // whose bytes are still in the page cache is not atomic in the
                // way that matters after a power loss.
                out.fd.sync()
            }
            if (!tmp.renameTo(target)) {
                throw IOException("Atomic rename failed: $tmp -> $target")
            }
        } finally {
            // No-op on the success path (the rename consumed it).
            tmp.delete()
        }
    }
}
