package relay.storage

import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import relay.protocol.WireJson
import java.io.File
import java.util.UUID

/**
 * Device-local auxiliary maps the UI layers on top of the server's session list:
 * per-session display names and the last-seen coding agent.
 *
 * Linux counterpart of the Android `SessionOwnershipStore`. Same public surface
 * (`names` / `agents` snapshots, diff-checked `setName` / `setAgent` returning
 * whether anything changed), same JSON encoding (`Map<String,String>` with
 * lowercase hyphenated UUID keys via [WireJson]), same degrade-to-empty on a
 * parse failure. Only the backing store differs: two JSON files under
 * `$XDG_STATE_HOME/coderelay/` instead of SharedPreferences.
 *
 * As on Android, **ownership itself is not persisted** — the server's
 * token-scoped session list is authoritative. [deviceId] is accepted for
 * call-site parity with the Android constructor and namespaces nothing.
 *
 * Caches are loaded once at construction; construct a new instance to re-read.
 * Not thread-safe, matching the original: callers confine mutation to the main
 * dispatcher.
 */
class SessionOwnershipStore(
    private val dir: File = XdgPaths.stateDir,
    @Suppress("UNUSED_PARAMETER") deviceId: String = "",
) {

    /** Key (and filename stem) for the UUID→name map. */
    val namesKey: String = NAMES_KEY

    /** Key (and filename stem) for the UUID→agentId map. */
    val agentsKey: String = AGENTS_KEY

    private val namesCache: MutableMap<UUID, String> = load(namesKey)
    private val agentsCache: MutableMap<UUID, String> = load(agentsKey)

    /** Snapshot of UUID→name. */
    val names: Map<UUID, String> get() = namesCache.toMap()

    /** Snapshot of UUID→agentId. */
    val agents: Map<UUID, String> get() = agentsCache.toMap()

    /**
     * Sets (or, when [name] is null, removes) the display name for [id].
     * Persists only when the stored value actually changed.
     */
    fun setName(id: UUID, name: String?): Boolean {
        val changed = if (name == null) {
            namesCache.remove(id) != null
        } else {
            namesCache.put(id, name) != name
        }
        if (changed) persist(namesKey, namesCache)
        return changed
    }

    /**
     * Sets (or, when [agentId] is null, removes) the last-seen agent for [id].
     * Persists only when the stored value actually changed.
     */
    fun setAgent(id: UUID, agentId: String?): Boolean {
        val changed = if (agentId == null) {
            agentsCache.remove(id) != null
        } else {
            agentsCache.put(id, agentId) != agentId
        }
        if (changed) persist(agentsKey, agentsCache)
        return changed
    }

    // ---- (de)serialization ----

    private fun fileFor(key: String) = File(dir, "$key.json")

    /** Decodes a UUID→String map; empty on missing file, unreadable file, or bad JSON. */
    private fun load(key: String): MutableMap<UUID, String> {
        val f = fileFor(key)
        if (!f.isFile) return mutableMapOf()
        val json = runCatching { f.readText() }.getOrNull() ?: return mutableMapOf()
        val decoded = runCatching {
            WireJson.instance.decodeFromString(MAP_SERIALIZER, json)
        }.getOrNull() ?: return mutableMapOf()
        val result = LinkedHashMap<UUID, String>()
        for ((k, v) in decoded) {
            // Skip unparseable keys rather than failing the whole map — one bad
            // entry must not cost the user every session name they have set.
            runCatching { UUID.fromString(k) }.getOrNull()?.let { result[it] = v }
        }
        return result
    }

    /**
     * Encodes and writes atomically. The Android original uses
     * `SharedPreferences.commit()` (synchronous) specifically so a rename made
     * just before a force-kill is already on disk; [XdgPaths.writeAtomically]
     * fsyncs before renaming for the same reason.
     */
    private fun persist(key: String, map: Map<UUID, String>) {
        val encoded = map.entries.associate { it.key.toString().lowercase() to it.value }
        val json = WireJson.instance.encodeToString(MAP_SERIALIZER, encoded)
        runCatching { XdgPaths.writeAtomically(fileFor(key), json) }
    }

    companion object {
        private const val NAMES_KEY = "sessionNames"
        private const val AGENTS_KEY = "agentSessions"

        private val MAP_SERIALIZER =
            MapSerializer(String.serializer(), String.serializer())
    }
}
