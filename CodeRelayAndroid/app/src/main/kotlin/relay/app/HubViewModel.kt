package relay.app

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import relay.feature.settings.AppSettings
import relay.protocol.ConnectionConfig
import relay.protocol.SessionDeepLink
import relay.session.hub.BookmarkStore
import relay.session.hub.HubMigration
import relay.session.hub.HubPreferences
import relay.session.hub.HubStateStore
import relay.session.hub.PushSettings
import relay.session.hub.ServerHub
import relay.session.hub.ServerSlot
import relay.session.hub.TokenSource
import relay.session.hub.handleDeepLink
import relay.storage.DeviceIdentifier
import relay.storage.SavedConnectionStore
import relay.storage.SessionOwnershipStore
import relay.storage.TokenStore

/** Everything [HubViewModel] needs, injectable so the ownership rules are a JVM test. */
class HubDeps<S : ServerSlot>(
    val scope: CoroutineScope,
    val bookmarks: BookmarkStore,
    val tokens: TokenSource,
    val prefs: HubPreferences,
    val slotFactory: (ConnectionConfig, String) -> S,
    val migration: (suspend (HubStateStore) -> Unit)?,
    val pushSettings: suspend () -> PushSettings?,
)

/**
 * Owns the multi-server hub for the activity (spec §8.4). A retained
 * ViewModel, so a rotation or the Huawei Fold's display switch — which restarts
 * the Activity despite `configChanges` — re-binds to the SAME hub and sockets
 * instead of building a second set; [start] is idempotent for the same reason.
 * The hub runs on its own main-confined scope, not `viewModelScope`: AndroidX
 * cancels that before [onCleared] runs, and the teardown needs a live scope.
 */
class HubViewModel<S : ServerSlot> internal constructor(private val deps: HubDeps<S>) : ViewModel() {

    private val state = HubStateStore(deps.prefs, "relay")

    val hub: ServerHub<S> = ServerHub(
        scope = deps.scope,
        bookmarkStore = deps.bookmarks,
        tokens = deps.tokens,
        state = state,
        factory = deps.slotFactory,
        migration = deps.migration?.let { run -> { run(state) } },
    )

    private var started = false

    /** Builds every enabled server's coordinator once, then registers push on each. */
    fun start() {
        if (started) return
        started = true
        deps.scope.launch {
            hub.start()
            syncPush()
        }
    }

    /** ON_RESUME: every server gets the foreground transition, staggered (D10). */
    fun onForeground() {
        hub.handleForegroundTransition()
        hub.activeSlot.value?.let { (it as? AppServerSlot)?.coordinator?.restoreActiveOnForeground() }
    }

    fun onConnectivityRestored() = hub.handleForegroundTransition()

    /** (Re)registers push on every relay, and remembers it for servers enabled later. */
    fun syncPush() {
        deps.scope.launch { deps.pushSettings()?.let { hub.syncPushRegistration(it) } }
    }

    /** A session link from a notification tap, QR or another app; waits for the first start on a cold launch. */
    fun open(link: SessionDeepLink) {
        deps.scope.launch { hub.handleDeepLink(link) }
    }

    /** Tears every server down and awaits it. */
    suspend fun shutdown() = hub.shutdown()

    override fun onCleared() {
        // The Activity is truly finishing (not a fold or rotation).
        deps.scope.launch {
            shutdown()
            deps.scope.cancel()
        }
        super.onCleared()
    }

    companion object {
        /** The production wiring: DataStore bookmarks, the encrypted token store, per-server ownership. */
        fun factory(app: Application): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                val settings = AppSettings.create(app, scope)
                val bookmarks = AndroidBookmarkStore(SavedConnectionStore(app))
                val deps = HubDeps(
                    scope = scope,
                    bookmarks = bookmarks,
                    tokens = AndroidTokenSource(TokenStore(app)),
                    prefs = SharedPrefsHubPreferences(app),
                    slotFactory = { config, token -> AppServerSlot(ConnectionSession.create(app, config, token, settings)) },
                    migration = { state ->
                        // Spec §9: only the last-connected bookmark stays enabled;
                        // the legacy name/agent maps move under it.
                        HubMigration.run(bookmarks, settings.lastConnectedServerIdNow(), state) { keep ->
                            SessionOwnershipStore(app, DeviceIdentifier.get(app)).moveLegacyInto(keep?.toString())
                        }
                    },
                    pushSettings = { PushSync.settings(app) },
                )
                return HubViewModel(deps) as T
            }
        }
    }
}
