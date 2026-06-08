package relay.feature.servers

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import relay.net.NetworkConfinement
import relay.net.RelayConnection
import relay.net.SessionController
import relay.protocol.ConnectionConfig
import relay.session.ServerStatus
import relay.session.ServerStatusChecker
import relay.storage.SavedConnectionStore
import relay.storage.TokenStore
import java.util.UUID

/**
 * Drives the server-list screen: holds the saved bookmarks plus their live
 * status, and persists add/edit/delete.
 *
 * Ports `ServerListViewModel.swift`. That view model additionally owns the
 * connection lifecycle (`connect`, navigation state); on Android connecting is
 * the nav host's job (Task 11 wires `onConnect` to the workspace), so this view
 * model is scoped to list + status + persistence only. The TLS/cleartext gate
 * that the Swift app enforces implicitly (via ATS) is applied explicitly at the
 * connect call site in [ServersScreen].
 *
 * Dependencies are injected (Hilt is deferred); [create] builds the production
 * graph from a [Context], including a default liveness [probe] assembled from
 * [RelayConnection] + [SessionController] + [TokenStore].
 */
class ServersViewModel(
    private val store: SavedConnectionStore,
    private val tokenStore: TokenStore,
    private val statusChecker: ServerStatusChecker,
) : ViewModel() {

    private val _servers = MutableStateFlow<List<ConnectionConfig>>(emptyList())

    /** Saved bookmarks (Swift `servers`). Refreshed after every mutation. */
    val servers: StateFlow<List<ConnectionConfig>> = _servers.asStateFlow()

    /** Per-server liveness keyed by id (Swift `serverStatuses`). */
    val statuses: StateFlow<Map<UUID, ServerStatus>> = statusChecker.statuses

    init {
        // Load the bookmark list, then start polling (Swift `init` loads +
        // `onAppear` starts polling; we fold both into construction).
        viewModelScope.launch {
            reloadServers()
            statusChecker.startPolling(_servers.value)
        }
    }

    /** Reloads bookmarks from the store and restarts status polling. */
    fun refresh() {
        viewModelScope.launch {
            reloadServers()
            statusChecker.refresh(_servers.value)
        }
    }

    /**
     * Persists [config] (add-or-replace-by-id) plus its [token] when non-null,
     * then refreshes the list and status poll. Ports
     * `AddEditServerViewModel.save()` + `ServerListViewModel.refreshServers()`.
     */
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

    /**
     * Deletes [config] and its saved token, then refreshes. Ports
     * `ServerListViewModel.deleteServer(id:)`.
     */
    fun delete(config: ConnectionConfig) {
        viewModelScope.launch {
            tokenStore.deleteToken(config.id)
            store.delete(config.id)
            reloadServers()
            statusChecker.refresh(_servers.value)
        }
    }

    /** Returns the saved token for [config], or null. Used to prefill the edit sheet. */
    fun tokenFor(config: ConnectionConfig): String? = tokenStore.loadToken(config.id)

    override fun onCleared() {
        statusChecker.stopPolling()
        super.onCleared()
    }

    private suspend fun reloadServers() {
        _servers.value = store.loadAll()
    }

    companion object {
        /**
         * Builds a [ViewModelProvider.Factory] for the production graph from an
         * application [Context]. The status [probe] performs one
         * connect → authenticate → disconnect (in a `try/finally`, so the socket
         * is always torn down), returning true iff auth succeeded — mirroring
         * `ServerStatusChecker.swift`'s probe lifecycle. A connection with no
         * saved token returns false (Swift's early `return ServerStatus()`).
         */
        fun factory(context: Context): ViewModelProvider.Factory {
            val appContext = context.applicationContext
            val store = SavedConnectionStore(appContext)
            val tokenStore = TokenStore(appContext)
            return object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T {
                    val checker = ServerStatusChecker(
                        scope = relayStatusScope(),
                        probe = { config -> probe(config, tokenStore) },
                    )
                    return ServersViewModel(store, tokenStore, checker) as T
                }
            }
        }

        private fun relayStatusScope() = CoroutineScope(NetworkConfinement.dispatcher)

        /** One connect → authenticate → disconnect liveness probe. */
        private suspend fun probe(config: ConnectionConfig, tokenStore: TokenStore): Boolean {
            val token = tokenStore.loadToken(config.id)
            if (token.isNullOrEmpty()) return false
            val connection = RelayConnection()
            return try {
                connection.connect(config, token)
                SessionController(connection).authenticate(token)
                true
            } catch (_: Throwable) {
                false
            } finally {
                connection.disconnect()
            }
        }
    }
}
