package relay.app

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import relay.protocol.ConnectionConfig
import relay.session.hub.BookmarkStore
import relay.session.hub.HubPreferences
import relay.session.hub.TokenSource
import relay.storage.SavedConnectionStore
import relay.storage.TokenStore
import java.util.UUID

/** The hub's bookmark list over the DataStore-backed [SavedConnectionStore]. */
class AndroidBookmarkStore(private val store: SavedConnectionStore) : BookmarkStore {
    override suspend fun loadAll(): List<ConnectionConfig> = store.loadAll()
    override suspend fun saveAll(list: List<ConnectionConfig>) = store.saveAll(list)
    override suspend fun add(c: ConnectionConfig) { store.add(c) }
    override suspend fun delete(id: UUID) { store.delete(id) }
}

/** Per-bookmark relay tokens from the encrypted [TokenStore], read off the main thread. */
class AndroidTokenSource(private val store: TokenStore) : TokenSource {
    override suspend fun loadToken(id: UUID): String? = withContext(Dispatchers.IO) { store.loadToken(id) }
    override fun deleteToken(id: UUID) { store.deleteToken(id) }
}

/** The hub's own small state (active ref, collapsed sections, migration flag) in SharedPreferences "relay.hub". */
class SharedPrefsHubPreferences(context: Context) : HubPreferences {
    private val prefs = context.applicationContext.getSharedPreferences("relay.hub", Context.MODE_PRIVATE)
    override fun get(key: String): String? = prefs.getString(key, null)
    override fun put(key: String, value: String?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }
}
