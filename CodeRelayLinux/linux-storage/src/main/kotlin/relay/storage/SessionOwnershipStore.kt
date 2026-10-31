package relay.storage

import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import relay.protocol.SessionBaseline
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
    /**
     * Multi-server: each server's coordinator gets its own files, keyed by its
     * bookmark id (spec §7.4), so a session UUID on one relay can never pick up
     * another relay's name. Empty is the legacy, single-server file set.
     */
    namespace: String = "",
) {

    /** Key (and filename stem) for the UUID→name map. */
    val namesKey: String = if (namespace.isEmpty()) NAMES_KEY else "$namespace.$NAMES_KEY"

    /** Key (and filename stem) for the UUID→agentId map. */
    val agentsKey: String = if (namespace.isEmpty()) AGENTS_KEY else "$namespace.$AGENTS_KEY"

    private val namesCache: MutableMap<UUID, String> = load(namesKey)
    private val agentsCache: MutableMap<UUID, String> = load(agentsKey)

    /** Key (and filename stem) for the diff baseline. */
    val baselineKey: String = if (namespace.isEmpty()) BASELINE_KEY else "$namespace.$BASELINE_KEY"

    private var baselineCache: SessionBaseline? = loadBaseline()

    /** The sessions this server's pane last showed. A diff baseline only. */
    val baseline: SessionBaseline? get() = baselineCache

    /**
     * Persists [b]; null removes the file. Writes only when the value changed.
     */
    fun setBaseline(b: SessionBaseline?) {
        if (b == baselineCache) return
        baselineCache = b
        if (b == null) {
            runCatching { fileFor(baselineKey).delete() }
        } else {
            val json = WireJson.instance.encodeToString(SessionBaseline.serializer(), b)
            runCatching { XdgPaths.writeAtomically(fileFor(baselineKey), json) }
        }
    }

    private fun loadBaseline(): SessionBaseline? {
        val f = fileFor(baselineKey)
        if (!f.isFile) return null
        val json = runCatching { f.readText() }.getOrNull() ?: return null
        return runCatching {
            WireJson.instance.decodeFromString(SessionBaseline.serializer(), json)
        }.getOrNull()
    }

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

    /**
     * One-time multi-server migration (spec §9): copies this store's maps into
     * [namespace] (the server that stays enabled) and clears them here; with a
     * null [namespace] the maps are only dropped, never guessed onto a server.
     */
    fun moveLegacyInto(namespace: String?) {
        if (namespace != null) {
            val target = SessionOwnershipStore(dir, namespace = namespace)
            names.forEach { (id, n) -> target.setName(id, n) }
            agents.forEach { (id, a) -> target.setAgent(id, a) }
        }
        names.keys.forEach { setName(it, null) }
        agents.keys.forEach { setAgent(it, null) }
    }

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
        private const val BASELINE_KEY = "sessionBaseline"

        private val MAP_SERIALIZER =
            MapSerializer(String.serializer(), String.serializer())
    }
}
