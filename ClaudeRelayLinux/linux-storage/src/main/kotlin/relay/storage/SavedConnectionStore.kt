package relay.storage

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import relay.protocol.ConnectionConfig
import relay.protocol.WireJson
import java.io.File
import java.util.UUID

/**
 * Persists the user's list of server connection bookmarks.
 *
 * Linux counterpart of the Android `SavedConnectionStore`
 * (`ClaudeRelayAndroid/core-storage/.../SavedConnectionStore.kt`), which stores
 * the list in a Preferences DataStore. **The public API is identical on
 * purpose** — `loadAll` / `saveAll` / `add` / `delete`, all `suspend`, all
 * returning the same types — so call sites shared with Android compile against
 * either implementation. Only the constructor differs: there is no `Context`
 * here, so this takes a file.
 *
 * The payload is byte-for-byte what Android writes: `WireJson` +
 * `ListSerializer(ConnectionConfig.serializer())`. That is deliberate. It means
 * the JSON blob Android holds inside its DataStore can be copied into this file
 * verbatim (and vice versa) if a user ever moves bookmarks between devices, and
 * it means a wire-format change cannot break one client without breaking the
 * other loudly.
 *
 * **Tokens are NOT stored here.** `ConnectionConfig` carries no secret; the
 * bearer token for each connection lives in [TokenStore], keyed by the same
 * connection id. This file is plaintext and readable by the user.
 */
class SavedConnectionStore(
    private val file: File = File(XdgPaths.configDir, FILE_NAME),
) {

    private val listSerializer = ListSerializer(ConnectionConfig.serializer())

    // Serialises read-modify-write pairs. `add` and `delete` are each a
    // loadAll-then-saveAll, and two concurrent calls would otherwise interleave
    // so that the second overwrites the first's change with a stale list. The
    // Android original is safe here only because DataStore's `edit` is itself
    // transactional; a plain file is not, so the mutual exclusion is explicit.
    private val mutex = Mutex()

    /** Loads all saved connections. Missing or corrupt file → empty list. */
    suspend fun loadAll(): List<ConnectionConfig> = withContext(Dispatchers.IO) {
        readUnlocked()
    }

    /** Replaces the persisted list with [connections]. */
    suspend fun saveAll(connections: List<ConnectionConfig>) = withContext(Dispatchers.IO) {
        mutex.withLock { writeUnlocked(connections) }
    }

    /** Adds or replaces (by [ConnectionConfig.id]) a connection; returns the updated list. */
    suspend fun add(connection: ConnectionConfig): List<ConnectionConfig> =
        withContext(Dispatchers.IO) {
            mutex.withLock {
                val all = readUnlocked().toMutableList()
                val index = all.indexOfFirst { it.id == connection.id }
                if (index >= 0) all[index] = connection else all.add(connection)
                writeUnlocked(all)
                all
            }
        }

    /** Removes a connection by [id]; returns the updated list. */
    suspend fun delete(id: UUID): List<ConnectionConfig> = withContext(Dispatchers.IO) {
        mutex.withLock {
            val all = readUnlocked().filterNot { it.id == id }
            writeUnlocked(all)
            all
        }
    }

    // ---- internals (callers hold the mutex where mutation is involved) ----

    /**
     * A parse failure degrades to an empty list rather than throwing, matching
     * the Android store's `runCatching { … }.getOrNull()`. The file is then
     * overwritten on the next write. This is the right trade for bookmarks —
     * losing them is recoverable and re-addable, whereas a crash loop on a
     * corrupt file locks the user out of the app entirely.
     */
    private fun readUnlocked(): List<ConnectionConfig> {
        if (!file.isFile) return emptyList()
        val json = runCatching { file.readText() }.getOrNull() ?: return emptyList()
        if (json.isBlank()) return emptyList()
        return runCatching { WireJson.instance.decodeFromString(listSerializer, json) }
            .getOrElse { emptyList() }
    }

    private fun writeUnlocked(connections: List<ConnectionConfig>) {
        val json = WireJson.instance.encodeToString(listSerializer, connections)
        XdgPaths.writeAtomically(file, json)
    }

    companion object {
        /** Bookmark list filename under `$XDG_CONFIG_HOME/coderelay/`. */
        const val FILE_NAME = "servers.json"
    }
}
