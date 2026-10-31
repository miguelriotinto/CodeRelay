package relay.app

import android.content.Context
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel
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
    override val baseline: relay.protocol.SessionBaseline? get() = store.baseline
    override fun setBaseline(b: relay.protocol.SessionBaseline?) { store.setBaseline(b) }
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
 */
class ConnectionSession private constructor(
    val config: ConnectionConfig,
    val coordinator: SessionCoordinator,
    val workspaceViewModel: WorkspaceViewModel,
    val scope: CoroutineScope,
) {
    companion object {
        /**
         * Constructs the coordinator + workspace VM for [config] using [token].
         * [settings] supplies the naming [theme].
         */
        fun create(
            context: Context,
            config: ConnectionConfig,
            token: String,
            settings: AppSettings,
            /** Each server's names/agents live under its own bookmark id (multi-server spec §7.4). */
            ownershipNamespace: String = config.id.toString(),
            /** The naming theme read from disk; falls back to the flow (DEFAULT until DataStore's async read lands). */
            theme: SessionNamingTheme? = null,
        ): ConnectionSession {
            val appContext = context.applicationContext
            // Serial confined scope — the @MainActor analog.
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val nowMs: () -> Long = { SystemClock.elapsedRealtime() }

            val deviceId = DeviceIdentifier.get(appContext)
            val ownership = SessionOwnershipAdapter(SessionOwnershipStore(appContext, deviceId, ownershipNamespace))

            val connection = RelayConnection()
            val coordinator = SessionCoordinator(
                scope = scope,
                connection = connection,
                token = token,
                ownershipStore = ownership,
                config = config,
                theme = theme ?: settings.sessionNamingTheme.value,
                nowMs = nowMs,
            )

            val workspaceViewModel = WorkspaceViewModel(
                coordinator = coordinator,
                qualityProvider = { connection.connectionQuality },
                sendBinary = { bytes -> connection.sendBinary(bytes) },
                nowMs = nowMs,
            )

            return ConnectionSession(config, coordinator, workspaceViewModel, scope)
        }
    }
}

/**
 * One server in the Android hub: its [ConnectionSession] as a hub slot the
 * shared workspace can host. Tearing it down also cancels the session's own
 * scope, so a disabled or removed server leaves nothing running.
 */
class AppServerSlot(val session: ConnectionSession) :
    relay.session.hub.CoordinatorServerSlot(session.config, session.coordinator),
    relay.feature.workspace.hub.WorkspaceSlot {
    override val workspaceViewModel: WorkspaceViewModel get() = session.workspaceViewModel
    override suspend fun tearDown() {
        try {
            super.tearDown()
        } finally {
            session.scope.cancel()
        }
    }
}
