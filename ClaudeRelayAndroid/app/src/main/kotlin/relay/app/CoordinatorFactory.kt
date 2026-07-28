package relay.app

import android.content.Context
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import relay.feature.settings.AppSettings
import relay.feature.workspace.WorkspaceViewModel
import relay.net.RelayConnection
import relay.protocol.ConnectionConfig
import relay.protocol.SessionNamingTheme
import relay.session.OwnershipStore
import relay.session.SessionCoordinator
import relay.storage.DeviceIdentifier
import relay.storage.SessionOwnershipStore
import java.util.UUID

/**
 * Wraps a concrete [SessionOwnershipStore] (an Android type needing a `Context`)
 * as the pure-JVM [OwnershipStore] the coordinator expects.
 *
 * The only impedance is the return type: the concrete store's `setName` /
 * `setAgent` return a `Boolean` ("did state change?"), while [OwnershipStore]
 * (via `AgentPersistence`) declares them `Unit`. The adapter forwards and discards
 * the Boolean. The diff-check the Boolean reports still happens inside the store;
 * the coordinator simply does not need the answer.
 */
private class SessionOwnershipAdapter(
    private val store: SessionOwnershipStore,
) : OwnershipStore {
    override val names: Map<UUID, String> get() = store.names
    override val agents: Map<UUID, String> get() = store.agents

    override fun setName(id: UUID, name: String?) { store.setName(id, name) }
    override fun setAgent(id: UUID, agentId: String?) { store.setAgent(id, agentId) }
}

/**
 * Builds the production [SessionCoordinator] + [WorkspaceViewModel] for a
 * connection, satisfying the carry-forward obligations the lower layers left as
 * injected seams:
 *
 *  - **Serial confined scope** `SupervisorJob() + Dispatchers.Main.immediate` —
 *    the `@MainActor` analog the coordinator's docs require (every entry point and
 *    callback runs on the single main dispatcher).
 *  - **Monotonic clock** `SystemClock.elapsedRealtime()` for `nowMs` (the M2-B doc
 *    recommended this over wall-clock for the recovery cooldown/debounce and the
 *    workspace uptime ticker — immune to wall-clock jumps).
 *  - **Ownership adapter** wrapping `SessionOwnershipStore(context, deviceId)`.
 *  - **Connection-quality provider** polling `RelayConnection.connectionQuality`.
 *  - **Binary input sink** `RelayConnection.sendBinary` for raw terminal keystrokes.
 *
 * The factory holds the [connection] so the host can poll quality / send binary
 * and so [SessionCoordinator.tearDown] can disconnect it on leave.
 */
class ConnectionSession private constructor(
    val coordinator: SessionCoordinator,
    val workspaceViewModel: WorkspaceViewModel,
    val scope: CoroutineScope,
    /** Speech engines + model store bound to this connection's scope (Task 11). */
    val speech: SpeechSession,
) {
    companion object {
        /**
         * Constructs the coordinator + workspace VM + [SpeechSession] for [config]
         * using [token]. [settings] supplies the naming [theme] and the speech
         * options snapshot for the engines.
         */
        fun create(
            context: Context,
            config: ConnectionConfig,
            token: String,
            settings: AppSettings,
        ): ConnectionSession {
            val appContext = context.applicationContext
            // Serial confined scope — the @MainActor analog.
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val nowMs: () -> Long = { SystemClock.elapsedRealtime() }

            val deviceId = DeviceIdentifier.get(appContext)
            val ownership = SessionOwnershipAdapter(SessionOwnershipStore(appContext, deviceId))

            val connection = RelayConnection()
            val coordinator = SessionCoordinator(
                scope = scope,
                connection = connection,
                token = token,
                ownershipStore = ownership,
                config = config,
                theme = settings.sessionNamingTheme.value,
                nowMs = nowMs,
            )

            val workspaceViewModel = WorkspaceViewModel(
                coordinator = coordinator,
                qualityProvider = { connection.connectionQuality },
                sendBinary = { bytes -> connection.sendBinary(bytes) },
                nowMs = nowMs,
            )

            val speech = SpeechSession.create(appContext, scope, settings)

            return ConnectionSession(coordinator, workspaceViewModel, scope, speech)
        }
    }
}
