package relay.feature.servers

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import relay.net.RelayConnection
import relay.net.SessionController
import relay.protocol.ConnectionConfig
import relay.session.ServerStatus
import relay.session.ServerStatusChecker
import relay.storage.SavedConnectionStore
import relay.storage.TokenStore
import java.util.UUID

/**
 * Server bookmarks plus per-server liveness.
 *
 * Linux counterpart of the Android `ServersViewModel`. **The class body is a
 * faithful copy** — `ViewModel` and `viewModelScope` are `androidx.lifecycle`
 * types that Compose Multiplatform republishes under identical package names,
 * so nothing in the logic needed changing. Only the companion factory differs:
 * Android's builds the store graph from a `Context`, which does not exist here.
 *
 * That single `Context` reference in the companion is the whole reason this file
 * is duplicated rather than shared. Moving the factory to its own file upstream
 * would let the entire view model be shared by both clients — worth doing when
 * the Android side is next touched.
 */
class ServersViewModel(
    private val store: SavedConnectionStore,
    private val tokenStore: TokenStore,
    private val statusChecker: ServerStatusChecker,
) : ViewModel() {

    private val _servers = MutableStateFlow<List<ConnectionConfig>>(emptyList())

    /** Saved bookmarks. Refreshed after every mutation. */
    val servers: StateFlow<List<ConnectionConfig>> = _servers.asStateFlow()

    /** Per-server liveness keyed by id. */
    val statuses: StateFlow<Map<UUID, ServerStatus>> = statusChecker.statuses

    init {
        viewModelScope.launch {
            reloadServers()
            statusChecker.startPolling(_servers.value)
        }
    }

    /** Reloads bookmarks and restarts status polling. */
    fun refresh() {
        viewModelScope.launch {
            reloadServers()
            statusChecker.refresh(_servers.value)
        }
    }

    /** Persists [config] (add-or-replace by id) plus its [token] when non-null. */
    fun addOrUpdate(config: ConnectionConfig, token: String?) {
        viewModelScope.launch {
            store.add(config)
            if (!token.isNullOrEmpty()) {
                tokenStore.saveToken(token, config.id)
            }
            reloadServers()
            statusChecker.refresh(_servers.value)
        }
    }

    /** Deletes [config] and its saved token. */
    fun delete(config: ConnectionConfig) {
        viewModelScope.launch {
            tokenStore.deleteToken(config.id)
            store.delete(config.id)
            reloadServers()
            statusChecker.refresh(_servers.value)
        }
    }

    /** Returns the saved token for [config], or null. Prefills the edit sheet. */
    fun tokenFor(config: ConnectionConfig): String? =
        runCatching { tokenStore.loadToken(config.id) }.getOrNull()

    /** Used by [PairingViewModel] to persist a config + token through the same path. */
    internal suspend fun addOrUpdateInternal(config: ConnectionConfig, token: String?): List<ConnectionConfig> {
        store.add(config)
        if (!token.isNullOrEmpty()) {
            tokenStore.saveToken(token, config.id)
        }
        reloadServers()
        statusChecker.refresh(_servers.value)
        return _servers.value
    }

    /** Used by [PairingViewModel] to persist a minted token. */
    internal fun saveTokenInternal(token: String, connectionId: UUID) {
        tokenStore.saveToken(token, connectionId)
    }

    override fun onCleared() {
        statusChecker.stopPolling()
        super.onCleared()
    }

    private suspend fun reloadServers() {
        _servers.value = store.loadAll()
    }

    companion object {

        /**
         * Builds the production graph.
         *
         * The liveness probe performs one connect → authenticate → disconnect in
         * a `try/finally` so the socket is always torn down, returning true iff
         * auth succeeded. A bookmark with no saved token probes false without
         * opening a socket at all — there is nothing to authenticate with, and
         * attempting it would show every unconfigured server as "offline" after
         * a needless round trip.
         */
        fun create(
            store: SavedConnectionStore,
            tokenStore: TokenStore,
            scope: kotlinx.coroutines.CoroutineScope,
        ): ServersViewModel {
            val probe: suspend (ConnectionConfig) -> Boolean = { config ->
                val token = runCatching { tokenStore.loadToken(config.id) }.getOrNull()
                if (token.isNullOrEmpty()) {
                    false
                } else {
                    val connection = RelayConnection()
                    val controller = SessionController(connection)
                    try {
                        connection.connect(config, token)
                        controller.authenticate(token)
                        controller.isAuthenticated
                    } catch (e: Exception) {
                        false
                    } finally {
                        runCatching { connection.disconnect() }
                    }
                }
            }
            return ServersViewModel(
                store = store,
                tokenStore = tokenStore,
                statusChecker = ServerStatusChecker(scope = scope, probe = probe),
            )
        }
    }
}
