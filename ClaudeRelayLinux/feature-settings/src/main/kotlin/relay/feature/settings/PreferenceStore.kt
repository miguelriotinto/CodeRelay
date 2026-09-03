package relay.feature.settings

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import relay.storage.XdgPaths
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * A small JSON-file key-value store with hot [StateFlow] mirrors.
 *
 * Stands in for Jetpack DataStore, which `AppSettings` uses on Android. The
 * surface is deliberately narrow — typed getters returning `StateFlow`, and
 * `put` — because that is all `AppSettings` needs, and a faithful DataStore
 * clone would be far more machinery than 14 preferences justify.
 *
 * Semantics chosen to match DataStore where it matters:
 *  - Reads are served from an in-memory map loaded once at construction, so a
 *    settings screen binding 14 flows does not touch the disk 14 times.
 *  - Writes update the flow immediately and persist asynchronously. The UI must
 *    never block on a disk write when a user flips a switch.
 *  - Values are stored as strings and parsed on read; a malformed value falls
 *    back to the default rather than throwing, so a hand-edited file cannot
 *    prevent the app from starting.
 *
 * Everything is stored in one file. Per-key files would avoid rewriting the
 * whole map on each change, but 14 keys is small enough that a single atomic
 * write is both simpler and safer — there is no window where two keys disagree.
 */
class PreferenceStore(
    private val file: File = File(XdgPaths.configDir, FILE_NAME),
    private val scope: CoroutineScope,
) {

    private val values = ConcurrentHashMap<String, String>()

    /**
     * Typed mirrors per key, each with its own updater. A write walks the list
     * for that key and pushes the newly-parsed value in SYNCHRONOUSLY.
     *
     * The obvious alternative — one raw `MutableStateFlow<String?>` per key plus
     * `scope.launch { collect { ... } }` per derived flow — was tried and is
     * wrong twice over: it leaks one live coroutine per preference for the life
     * of the app, and the derived value only lands once the dispatcher runs, so
     * a toggle does not reflect until the next dispatch. On a busy default
     * dispatcher the switch visibly lags the tap. Nothing here needs to be
     * asynchronous: parsing a string is not I/O.
     */
    private val mirrors = ConcurrentHashMap<String, MutableList<Mirror<*>>>()

    private class Mirror<T>(
        val flow: MutableStateFlow<T>,
        val transform: (String?) -> T,
    ) {
        fun refresh(raw: String?) {
            flow.value = transform(raw)
        }
    }

    init {
        load()
    }

    fun stringFlow(key: String, default: String): StateFlow<String> =
        mapped(key) { it ?: default }

    fun boolFlow(key: String, default: Boolean): StateFlow<Boolean> =
        mapped(key) { it?.toBooleanStrictOrNull() ?: default }

    fun intFlow(key: String, default: Int): StateFlow<Int> =
        mapped(key) { it?.toIntOrNull() ?: default }

    fun doubleFlow(key: String, default: Double): StateFlow<Double> =
        mapped(key) { it?.toDoubleOrNull() ?: default }

    /** True when the key has ever been written — the analogue of `Preferences.contains`. */
    fun contains(key: String): Boolean = values.containsKey(key)

    fun put(key: String, value: String) {
        values[key] = value
        notifyMirrors(key, value)
        persistAsync()
    }

    fun put(key: String, value: Boolean) = put(key, value.toString())
    fun put(key: String, value: Int) = put(key, value.toString())
    fun put(key: String, value: Double) = put(key, value.toString())

    fun remove(key: String) {
        values.remove(key)
        notifyMirrors(key, null)
        persistAsync()
    }

    /**
     * Returns a hot, typed mirror of [key].
     *
     * The initial value is computed eagerly from the stored string, so a freshly
     * composed settings screen renders the persisted value on its first frame
     * rather than flashing the default. Subsequent writes are pushed in by
     * [notifyMirrors], synchronously, on the writing thread.
     */
    internal fun <T> mapped(key: String, transform: (String?) -> T): StateFlow<T> {
        val mirror = Mirror(MutableStateFlow(transform(values[key])), transform)
        mirrors.getOrPut(key) { java.util.Collections.synchronizedList(mutableListOf()) }.add(mirror)
        return mirror.flow
    }

    private fun notifyMirrors(key: String, raw: String?) {
        val list = mirrors[key] ?: return
        synchronized(list) { list.forEach { it.refresh(raw) } }
    }

    private fun load() {
        if (!file.isFile) return
        val text = runCatching { file.readText() }.getOrNull() ?: return
        if (text.isBlank()) return
        val decoded = runCatching { JSON.decodeFromString(SERIALIZER, text) }.getOrNull() ?: return
        values.putAll(decoded)
    }

    private fun persistAsync() {
        scope.launch(Dispatchers.IO) {
            // Snapshot first: the map can change while we encode.
            val snapshot = HashMap(values)
            runCatching {
                XdgPaths.writeAtomically(file, JSON.encodeToString(SERIALIZER, snapshot))
            }
        }
    }

    companion object {
        const val FILE_NAME = "settings.json"

        private val JSON = Json { prettyPrint = true }
        private val SERIALIZER = MapSerializer(String.serializer(), String.serializer())
    }
}
