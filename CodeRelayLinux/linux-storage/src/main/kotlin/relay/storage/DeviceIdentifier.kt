package relay.storage

import java.io.File
import java.util.UUID

/**
 * A stable per-installation device identifier.
 *
 * The identifier is sent to the server with push registrations and is used to
 * scope per-device preferences. iOS uses `identifierForVendor`; Android has no
 * privacy-safe stable hardware id and so generates and persists a UUID — a
 * divergence its parity audit records as intentional. Linux does the same, for
 * the same reason, so this is a divergence from iOS but **parity with Android**.
 *
 * Deliberately NOT derived from anything real — not the MAC address, not
 * `/etc/machine-id`, not the hostname. `/etc/machine-id` in particular is a
 * stable, system-wide identifier that other applications can also read, so
 * reusing it would let this app's server correlate the user across unrelated
 * software. A random UUID scoped to this app leaks nothing.
 *
 * Persisted in the state dir, so clearing app state resets it — matching
 * Android, where clearing app data does the same.
 */
object DeviceIdentifier {

    private const val FILE_NAME = "device-id"

    @Volatile
    private var cached: String? = null

    /**
     * Returns the identifier, generating and persisting one on first call.
     *
     * If the file cannot be written (read-only home, full disk), a freshly
     * generated id is still returned and cached in memory for the life of the
     * process. That keeps the app working — a device id that resets on restart
     * costs the user only a stale push registration, whereas throwing here would
     * block startup entirely.
     */
    @Synchronized
    fun get(dir: File = XdgPaths.stateDir): String {
        cached?.let { return it }

        val file = File(dir, FILE_NAME)
        val existing = runCatching { file.readText().trim() }.getOrNull()
        if (!existing.isNullOrEmpty() && isWellFormed(existing)) {
            cached = existing
            return existing
        }

        val generated = UUID.randomUUID().toString()
        runCatching { XdgPaths.writeAtomically(file, generated) }
        cached = generated
        return generated
    }

    /** Test seam: forget the cached value so a fresh directory is re-read. */
    @Synchronized
    internal fun resetForTesting() {
        cached = null
    }

    /**
     * Guards against a truncated or hand-edited file. A malformed value is
     * replaced rather than sent to the server, where it would key a push
     * registration that can never be matched again.
     */
    private fun isWellFormed(value: String): Boolean =
        runCatching { UUID.fromString(value).toString() == value.lowercase() }.getOrDefault(false)
}
