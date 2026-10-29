package relay.session.hub

import relay.protocol.SessionRef
import java.util.UUID

/** Key/value seam so the hub's state persists through each platform's own store (Android SharedPreferences, Linux PreferenceStore). */
interface HubPreferences {
    fun get(key: String): String?
    fun put(key: String, value: String?)
}

/** The hub's own persisted state (spec §9): the active ref, collapsed sections, the one-time migration flag. */
class HubStateStore(private val prefs: HubPreferences, keyPrefix: String) {
    private val activeKey = "$keyPrefix.hub.activeRef"
    private val collapsedKey = "$keyPrefix.hub.collapsedServers"
    private val migratedKey = "$keyPrefix.hub.migrated"

    fun loadActiveRef(): SessionRef? {
        val parts = prefs.get(activeKey)?.split('/') ?: return null
        if (parts.size != 2) return null
        return runCatching { SessionRef(UUID.fromString(parts[0]), UUID.fromString(parts[1])) }.getOrNull()
    }

    fun saveActiveRef(ref: SessionRef?) = prefs.put(activeKey, ref?.let { "${it.serverId}/${it.sessionId}" })

    fun loadCollapsedServers(): Set<UUID> =
        prefs.get(collapsedKey).orEmpty().split(',')
            .mapNotNull { runCatching { UUID.fromString(it) }.getOrNull() }
            .toSet()

    fun saveCollapsedServers(ids: Set<UUID>) = prefs.put(collapsedKey, ids.joinToString(",").ifEmpty { null })

    val isMigrated: Boolean get() = prefs.get(migratedKey) == "true"

    fun markMigrated() = prefs.put(migratedKey, "true")
}
