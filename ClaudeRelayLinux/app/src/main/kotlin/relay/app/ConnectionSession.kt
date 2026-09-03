package relay.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import relay.feature.settings.AppSettings
import relay.feature.workspace.WorkspaceViewModel
import relay.net.RelayConnection
import relay.protocol.ConnectionConfig
import relay.session.OwnershipStore
import relay.session.SessionCoordinator
import relay.storage.SessionOwnershipStore
import java.util.UUID

/**
 * Adapts the concrete [SessionOwnershipStore] to the coordinator's injected
 * [OwnershipStore] seam — the same indirection the Android app uses, which is
 * what keeps `:shared-session` free of any storage implementation.
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
 * One live connection: its coordinator, workspace view model, and scope.
 *
 * Linux counterpart of the Android `ConnectionSession`, minus the speech
 * engines (out of parity scope). The two obligations the lower layers leave as
 * injected seams are satisfied here exactly as on Android:
 *
 *  - **A serial, confined scope.** `SessionCoordinator` documents itself as the
 *    `@MainActor` analogue: every entry point and callback must run on one
 *    dispatcher. On desktop that is `Dispatchers.Main.immediate`, which
 *    `kotlinx-coroutines-swing` maps to the AWT event thread — the same thread
 *    Compose renders on, so UI state mutations need no further hop.
 *  - **A monotonic clock.** `nowMs` must not jump when the system clock is
 *    adjusted (NTP step, suspend/resume), because the coordinator uses it for
 *    recovery backoff and activity debouncing. `System.nanoTime()` is monotonic;
 *    `currentTimeMillis()` is not, and a backwards step there would make a
 *    debounce window never expire.
 */
class ConnectionSession private constructor(
    /** The bookmark this connection was opened from; the coordinator keeps its copy private. */
    val config: ConnectionConfig,
    val coordinator: SessionCoordinator,
    val workspaceViewModel: WorkspaceViewModel,
    val connection: RelayConnection,
    val scope: CoroutineScope,
) {
    /**
     * Tears the connection down and cancels its scope. Safe to call twice.
     *
     * `tearDown` is a suspend function that must run on the coordinator's own
     * confined dispatcher, so it is launched there rather than blocked on — the
     * caller is the AWT event thread, and blocking it would freeze the UI while
     * the socket closes. The scope is cancelled only after teardown completes,
     * or cancelling would abort the very coroutine doing the cleanup.
     */
    fun close(): Job {
        val job = scope.launch {
            runCatching { coordinator.tearDown() }
        }
        job.invokeOnCompletion {
            runCatching { scope.cancel() }
        }
        return job
    }

    companion object {
        fun create(
            config: ConnectionConfig,
            token: String,
            settings: AppSettings,
            environment: AppEnvironment,
        ): ConnectionSession {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val nowMs: () -> Long = { System.nanoTime() / 1_000_000 }

            val ownership = SessionOwnershipAdapter(environment.ownership)
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

            return ConnectionSession(config, coordinator, workspaceViewModel, connection, scope)
        }
    }
}
