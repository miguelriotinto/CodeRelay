package relay.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import relay.feature.settings.PreferenceStore
import relay.feature.workspace.WorkspaceViewModel
import relay.feature.workspace.hub.WorkspaceSlot
import relay.protocol.ConnectionConfig
import relay.session.hub.BookmarkStore
import relay.session.hub.CoordinatorServerSlot
import relay.session.hub.HubMigration
import relay.session.hub.HubPreferences
import relay.session.hub.HubStateStore
import relay.session.hub.ServerHub
import relay.session.hub.TokenSource
import relay.storage.SavedConnectionStore
import relay.storage.TokenStore
import relay.storage.XdgPaths
import java.io.File
import java.util.UUID

/** The hub's bookmark list over `servers.json`. */
class LinuxBookmarkStore(private val store: SavedConnectionStore) : BookmarkStore {
    override suspend fun loadAll(): List<ConnectionConfig> = store.loadAll()
    override suspend fun saveAll(list: List<ConnectionConfig>) = store.saveAll(list)
    override suspend fun add(c: ConnectionConfig) { store.add(c) }
    override suspend fun delete(id: UUID) { store.delete(id) }
}

/**
 * Relay tokens from the Secret Service. A locked keyring makes `secret-tool`
 * fail; that reads as "no token", so the section shows authFailed with Re-pair
 * instead of the app crashing (Review Focus 5).
 */
class LinuxTokenSource(private val store: TokenStore) : TokenSource {
    override fun loadToken(id: UUID): String? = runCatching { store.loadToken(id) }.getOrNull()
    override fun deleteToken(id: UUID) { runCatching { store.deleteToken(id) } }
}

/**
 * The hub's own small state in its OWN file: two [PreferenceStore]s on one file
 * would each rewrite the whole map and drop the other's keys.
 */
class PreferenceStoreHubPreferences(private val store: PreferenceStore) : HubPreferences {
    override fun get(key: String): String? = if (store.contains(key)) store.stringFlow(key, "").value else null
    override fun put(key: String, value: String?) { if (value == null) store.remove(key) else store.put(key, value) }
}

/** One server in the Linux hub: its [ConnectionSession] as a slot the shared workspace hosts. */
class LinuxServerSlot(val session: ConnectionSession) :
    CoordinatorServerSlot(session.config, session.coordinator),
    WorkspaceSlot {
    override val workspaceViewModel: WorkspaceViewModel get() = session.workspaceViewModel
    /** [ConnectionSession.close] tears the coordinator down on its own scope, then cancels that scope. */
    override suspend fun tearDown() {
        session.close().join()
    }
}

/**
 * Builds the process's one hub (multi-server spec §8.5): a coordinator per
 * enabled bookmark, each with its own ownership namespace, on the AWT event
 * thread like every coordinator. The one-time migration keeps only the
 * last-connected bookmark enabled and moves the legacy name/agent files under it.
 */
fun createLinuxHub(environment: AppEnvironment): ServerHub<LinuxServerSlot> {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val settings = environment.settings
    val bookmarks = LinuxBookmarkStore(environment.connections)
    val state = HubStateStore(
        PreferenceStoreHubPreferences(PreferenceStore(File(XdgPaths.configDir, "hub.json"), environment.scope)),
        "relay",
    )
    return ServerHub(
        scope = scope,
        bookmarkStore = bookmarks,
        tokens = LinuxTokenSource(environment.tokens),
        state = state,
        factory = { config, token -> LinuxServerSlot(ConnectionSession.create(config, token, settings, environment)) },
        migration = {
            HubMigration.run(bookmarks, settings.lastConnectedServerId.value, state) { keep ->
                environment.ownership.moveLegacyInto(keep?.toString())
            }
        },
    )
}
