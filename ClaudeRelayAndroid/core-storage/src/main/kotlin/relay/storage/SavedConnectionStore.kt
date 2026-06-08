package relay.storage

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first
import kotlinx.serialization.builtins.ListSerializer
import relay.protocol.ConnectionConfig
import relay.protocol.WireJson
import java.util.UUID

/**
 * Persists a user's list of server connection bookmarks.
 *
 * Ports `SavedConnectionStore.swift` (ClaudeRelayClient). On iOS/macOS bookmarks
 * live in `UserDefaults` under a platform-scoped key as JSON-encoded
 * `[ConnectionConfig]`. On Android there is no `UserDefaults`, so we use a
 * Preferences [DataStore] (`saved_connections`) holding the list as a single JSON
 * string, encoded via [WireJson] + `ListSerializer(ConnectionConfig.serializer())`.
 *
 * ## Legacy-key migration (best-effort hook)
 *
 * Swift migrates from an older `UserDefaults` key when the current key is empty,
 * copying it forward while **leaving the legacy entry intact** so a downgrade
 * still sees bookmarks (SavedConnectionStore.swift `loadAll()`).
 *
 * On Android there has never been a prior storage location, so there is no real
 * iOS legacy store to read from — `UserDefaults` is not shared with an Android
 * process. We therefore implement the migration as a faithful **hook** keyed by
 * the corrected legacy constant [LEGACY_KEY] (`com.coderemote.savedConnections`):
 * when [CURRENT_KEY] is empty we read [LEGACY_KEY] from the *same* DataStore,
 * copy any value forward, and leave the legacy entry intact for downgrade safety.
 * With no legacy Android data present this is a clean no-op — we deliberately do
 * NOT fabricate a migration from a store that never existed on Android.
 */
class SavedConnectionStore(private val context: Context) {

    private val dataStore: DataStore<Preferences> get() = context.savedConnectionsDataStore

    private val listSerializer = ListSerializer(ConnectionConfig.serializer())

    /**
     * Loads all saved connections. When the current key is empty, transparently
     * migrates any value stored under the legacy key (see class docs), copying it
     * forward and leaving the legacy entry intact.
     */
    suspend fun loadAll(): List<ConnectionConfig> {
        val prefs = dataStore.data.first()

        prefs[CURRENT_KEY]?.let { json ->
            decode(json)?.let { return it }
        }

        // Legacy-key migration hook (best-effort; no-op when no legacy data exists).
        prefs[LEGACY_KEY]?.let { legacyJson ->
            decode(legacyJson)?.let { migrated ->
                // Copy forward into the current key; leave LEGACY_KEY untouched so
                // a downgrade still finds its bookmarks.
                dataStore.edit { it[CURRENT_KEY] = legacyJson }
                return migrated
            }
        }

        return emptyList()
    }

    /** Replaces the persisted list with [connections]. */
    suspend fun saveAll(connections: List<ConnectionConfig>) {
        val json = WireJson.instance.encodeToString(listSerializer, connections)
        dataStore.edit { it[CURRENT_KEY] = json }
    }

    /** Adds or replaces (by [ConnectionConfig.id]) a connection; returns the updated list. */
    suspend fun add(connection: ConnectionConfig): List<ConnectionConfig> {
        val all = loadAll().toMutableList()
        val index = all.indexOfFirst { it.id == connection.id }
        if (index >= 0) all[index] = connection else all.add(connection)
        saveAll(all)
        return all
    }

    /** Removes a connection by [id]; returns the updated list. */
    suspend fun delete(id: UUID): List<ConnectionConfig> {
        val all = loadAll().filterNot { it.id == id }
        saveAll(all)
        return all
    }

    private fun decode(json: String): List<ConnectionConfig>? =
        runCatching { WireJson.instance.decodeFromString(listSerializer, json) }.getOrNull()

    companion object {
        /** Current DataStore key for the JSON-encoded bookmark list. */
        val CURRENT_KEY = stringPreferencesKey("saved_connections")

        /**
         * Legacy migration key. Matches the iOS legacy `UserDefaults` key
         * (SavedConnectionStore.swift documents migration from older keys; the
         * corrected legacy key per the 2026-06-08 errata is
         * `com.coderemote.savedConnections`). Read-only and never deleted, so a
         * downgrade keeps working.
         */
        val LEGACY_KEY = stringPreferencesKey("com.coderemote.savedConnections")
    }
}

/** Single process-wide DataStore instance backing [SavedConnectionStore]. */
private val Context.savedConnectionsDataStore: DataStore<Preferences> by
    preferencesDataStore(name = "saved_connections")
