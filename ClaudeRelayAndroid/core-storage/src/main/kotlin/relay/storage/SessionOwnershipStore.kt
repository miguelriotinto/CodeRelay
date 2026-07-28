package relay.storage

import android.content.Context
import android.content.SharedPreferences
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import relay.protocol.WireJson
import java.util.UUID

/**
 * SharedPreferences-backed persistence for the three coordinator dictionaries:
 * `names` (user/server-renamed session names), `owned` (session ids this device
 * created or attached), `agents` (last-seen agent per session).
 *
 * Ports `SessionOwnershipStore.swift` (ClaudeRelayClient). iOS/macOS back this
 * with `UserDefaults`; Android has no `UserDefaults`, so the equivalent here is a
 * single private [SharedPreferences] file (`relay.ownership`). As in Swift:
 *
 * - The three persistence flows live behind one API.
 * - Writes are **diff-checked** — `prefs.edit()` is invoked only when the value
 *   actually changed since the last in-memory snapshot.
 * - Key construction is centralized so individual mutators can't drift apart.
 *
 * ## Key layout (matches the 2026-06-08 errata)
 * - `sessionNames`           — UUID→name map (device-independent)
 * - `ownedSessions.$deviceId` — device-scoped owned-id set (per-device scoping so
 *   two devices don't see each other's owned lists)
 * - `agentSessions`          — UUID→agentId map (device-independent)
 *
 * Maps are persisted as JSON `Map<String,String>`; the owned set as a JSON
 * `List<String>`. UUID keys/values are lowercase hyphenated strings (matching
 * the wire UUID rule). Parse failures degrade to empty rather than throwing.
 *
 * The in-memory caches ([names]/[owned]/[agents]) are the single source of truth
 * during a process lifetime; they're loaded once at construction. Construct a new
 * instance to re-read from disk.
 */
class SessionOwnershipStore(
    context: Context,
    @Suppress("UNUSED_PARAMETER") deviceId: String,
) {
    // Ownership is NOT persisted — the server's token-scoped session list is
    // authoritative. This store keeps only the device-independent auxiliary
    // maps (display names, last-seen agent per session) that the UI layers on
    // top of the server list. `deviceId` is retained in the signature for
    // call-site compatibility but no longer namespaces any key.

    /** Key for the UUID→name map (device-independent). */
    val namesKey: String = NAMES_KEY
    /** Key for the UUID→agentId map (device-independent). */
    val agentsKey: String = AGENTS_KEY

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // MARK: - In-memory caches (authoritative for the auxiliary maps; loaded once)

    private val namesCache: MutableMap<UUID, String> = load(namesKey)
    private val agentsCache: MutableMap<UUID, String> = load(agentsKey)

    /** Snapshot of UUID→name. */
    val names: Map<UUID, String> get() = namesCache.toMap()
    /** Snapshot of UUID→agentId. */
    val agents: Map<UUID, String> get() = agentsCache.toMap()

    // MARK: - Mutators (diff-checked)

    /**
     * Sets (or, when [name] is `null`, removes) the display name for [id].
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
     * Sets (or, when [agentId] is `null`, removes) the last-seen agent for [id].
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

    // MARK: - (De)serialization helpers

    /** Decodes a UUID→String map from prefs; empty on missing/parse failure. */
    private fun load(key: String): MutableMap<UUID, String> {
        val json = prefs.getString(key, null) ?: return mutableMapOf()
        val decoded = runCatching {
            WireJson.instance.decodeFromString(MAP_SERIALIZER, json)
        }.getOrNull() ?: return mutableMapOf()
        val result = LinkedHashMap<UUID, String>()
        for ((k, v) in decoded) {
            runCatching { UUID.fromString(k) }.getOrNull()?.let { result[it] = v }
        }
        return result
    }

    /** Encodes [map] (UUID keys → lowercase strings) and writes it to [key]. */
    private fun persist(key: String, map: Map<UUID, String>) {
        val encoded = map.entries.associate { it.key.toString().lowercase() to it.value }
        val json = WireJson.instance.encodeToString(MAP_SERIALIZER, encoded)
        // commit() (synchronous) so a name/agent written right before a
        // force-kill is already on disk.
        prefs.edit().putString(key, json).commit()
    }

    companion object {
        private const val PREFS = "relay.ownership"
        private const val NAMES_KEY = "sessionNames"
        private const val AGENTS_KEY = "agentSessions"

        private val MAP_SERIALIZER =
            MapSerializer(String.serializer(), String.serializer())
    }
}
