package relay.app

import android.content.Context
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import relay.feature.settings.AppSettings
import relay.protocol.ConnectionConfig

/**
 * Activity-retained holder for the single live [ConnectionSession].
 *
 * ## Why a ViewModel (the fold-survival fix)
 * Previously the live connection lived in a `remember { mutableStateOf<ConnectionSession?>() }`
 * inside `RelayNavGraph`. That state is composition-scoped, so it died whenever the
 * Activity was recreated. On the Huawei Fold, unfolding/folding switches the
 * physical display panel (outer ↔ inner), which forces a full Activity restart even
 * with `android:configChanges` declared — a *display* change is not one of the
 * configs `configChanges` can suppress. The recreated nav graph then found
 * `activeSession == null` and bounced the user back to the Servers list, dropping
 * the terminal session.
 *
 * A [ViewModel] is retained across configuration- and display-driven recreation via
 * the Activity's `ViewModelStore` (`onRetainNonConfigurationInstance`), so the live
 * coordinator + WebSocket survive the fold. The `rememberNavController` back stack
 * already survives via `rememberSaveable`, so on recreation the graph restores to
 * the Workspace route and re-binds to this still-alive session — the user keeps
 * typing in the same terminal.
 *
 * The session is only torn down on explicit disconnect ([teardown]) or when the
 * Activity is truly finishing ([onCleared]) — never on a mere fold.
 */
class ConnectionViewModel : ViewModel() {

    private val _activeSession = MutableStateFlow<ConnectionSession?>(null)
    val activeSession: StateFlow<ConnectionSession?> = _activeSession.asStateFlow()

    private val _connecting = MutableStateFlow(false)
    val connecting: StateFlow<Boolean> = _connecting.asStateFlow()

    /**
     * Builds + connects a session for [config]+[token]. Returns null on success or
     * an error message on failure (the caller surfaces it as a snackbar). Tears down
     * any prior session first. Gated on [connecting] so a double-tap can't open two.
     */
    suspend fun connect(
        context: Context,
        config: ConnectionConfig,
        token: String,
        settings: AppSettings,
    ): String? {
        if (_connecting.value) return null
        _connecting.value = true
        return try {
            teardown()
            val session = ConnectionSession.create(
                context = context,
                config = config,
                token = token,
                settings = settings,
            )
            session.coordinator.connect()
            _activeSession.value = session
            settings.setLastConnectedServerId(config.id.toString())
            // F1 Android push: register this device's FCM token now, and again
            // whenever the OS vends a fresh token while this session is live.
            runCatching { PushSync.sync(context, session.coordinator) }
            FcmTokenBridge.onTokenRefreshed = {
                session.scope.launch { runCatching { PushSync.sync(context, session.coordinator) } }
            }
            null
        } catch (e: Throwable) {
            teardown()
            "Failed to connect: ${e.message ?: "unknown error"}"
        } finally {
            _connecting.value = false
        }
    }

    /** Tears down the current session (cancel recovery, disconnect, cancel scope). */
    suspend fun teardown() {
        _activeSession.value?.let { session ->
            FcmTokenBridge.onTokenRefreshed = null  // don't fire into a dead session
            session.speech.stop()
            session.coordinator.tearDown()
            session.scope.cancel()
        }
        _activeSession.value = null
    }

    override fun onCleared() {
        // The Activity is truly finishing (not a fold/config change) — tear the
        // session down. teardown() is suspend, so it needs a live scope. NOT
        // viewModelScope: AndroidX cancels that inside clear() *before* onCleared()
        // runs, so a coroutine launched here would never start (leaking the mic /
        // foreground microphone service). The session's OWN scope is still alive at
        // this point, so launch the teardown there and cancel it as the final step.
        val session = _activeSession.value
        _activeSession.value = null
        if (session != null) {
            session.scope.launch {
                session.speech.stop()
                session.coordinator.tearDown()
                session.scope.cancel()
            }
        }
        super.onCleared()
    }
}
