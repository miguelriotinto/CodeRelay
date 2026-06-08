package relay.app

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import relay.feature.workspace.DeepLinks
import java.util.UUID

private const val TAG = "MainActivity"

/**
 * Single-activity host for the M1 demo. Sets the Compose content to
 * [M1DemoScreen]; there is no nav graph (deferred to M2's Task 11).
 *
 * THROWAWAY UI: Task 11 replaces [M1DemoScreen] with the real nav graph. The
 * deep-link plumbing below (Task 9) is NOT throwaway — it parses
 * `clauderelay://session/<uuid>` links from both a cold start (`onCreate`'s
 * intent) and a warm start (`onNewIntent`, enabled by `launchMode="singleTop"`)
 * and stores the result in [pendingSessionId].
 *
 * `launchMode` is `singleTop` so warm deep links re-deliver to the existing
 * instance via [onNewIntent] instead of stacking a new activity.
 */
class MainActivity : ComponentActivity() {

    /**
     * The most recent session id parsed from a `clauderelay://session/<uuid>`
     * deep link, or null if none is pending.
     *
     * Task 11 consumes [pendingSessionId] on workspace entry — the nav graph
     * collects this, calls `SessionCoordinator.attachRemoteSession(id)`, then
     * clears it via [clearPendingSession]. For M2-G this is parse + store + log
     * only; nothing consumes it yet.
     */
    val pendingSessionId: StateFlow<UUID?> get() = _pendingSessionId.asStateFlow()
    private val _pendingSessionId = MutableStateFlow<UUID?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Cold-start deep link (app launched from the link).
        handleDeepLink(intent)
        setContent {
            M1DemoScreen()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm-start deep link (app already running).
        setIntent(intent)
        handleDeepLink(intent)
    }

    /** Clears the pending session once Task 11's nav graph has consumed it. */
    fun clearPendingSession() {
        _pendingSessionId.value = null
    }

    private fun handleDeepLink(intent: Intent?) {
        val data = intent?.data?.toString() ?: return
        val sessionId = DeepLinks.parseSessionId(data)
        if (sessionId == null) {
            Log.w(TAG, "Ignoring unparseable deep link: $data")
            return
        }
        Log.i(TAG, "Deep link → pending session $sessionId")
        _pendingSessionId.value = sessionId
        // Task 11 consumes pendingSessionId on workspace entry → attachRemoteSession.
    }
}
