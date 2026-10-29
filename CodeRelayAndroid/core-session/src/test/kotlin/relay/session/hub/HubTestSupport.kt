package relay.session.hub

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.test.TestScope
import relay.protocol.ActivityState
import relay.protocol.ConnectionConfig
import relay.protocol.SessionInfo
import relay.protocol.SessionState
import java.util.UUID

fun cfg(name: String, enabled: Boolean = true) = ConnectionConfig(name = name, host = "$name.local", enabled = enabled)

fun session(id: UUID = UUID.randomUUID()) = SessionInfo(
    id = id, name = null, state = SessionState.ACTIVE_DETACHED, tokenId = "t", createdAt = 0.0,
    cols = 80u, rows = 24u, activity = ActivityState.ACTIVE, agent = null,
)

/**
 * A scope on the test's scheduler that `runTest` does not wait for. The hub
 * collects each slot's change stream forever, so it cannot run on the test's
 * own scope; `backgroundScope` would do, but `advanceUntilIdle` does not run
 * background work.
 */
fun TestScope.hubScope(): CoroutineScope = CoroutineScope(coroutineContext + Job())

/** A hub over scripted slots. Pass [hubScope]. */
class HubHarness(
    scope: CoroutineScope,
    configs: List<ConnectionConfig>,
    tokensFor: Set<UUID>? = null,
    maxEnabled: Int = 8,
    hangs: Set<UUID> = emptySet(),
    /** Sessions every slot lists, live, before its start() returns — what a real launch handshake does. */
    liveAtStart: List<relay.protocol.SessionInfo>? = null,
) {
    val sleeps = mutableListOf<Long>()
    val bookmarks = InMemoryBookmarks(configs)
    val tokens = FakeTokens(
        configs.filter { tokensFor == null || it.id in tokensFor }.associate { it.id to "tok-${it.name}" }.toMutableMap(),
    )
    val built = mutableListOf<FakeServerSlot>()
    val state = HubStateStore(MapPreferences(), "test")
    val hub = ServerHub(
        scope = scope,
        bookmarkStore = bookmarks,
        tokens = tokens,
        state = state,
        factory = { c, _ ->
            FakeServerSlot(c).also {
                it.startHangs = c.id in hangs
                if (liveAtStart != null) { it.connected.value = true; it.sessions.value = liveAtStart }
                built += it
            }
        },
        maxEnabled = maxEnabled,
        sleepMs = { sleeps += it },
    )
    fun slot(id: UUID): FakeServerSlot? = hub.slot(id)
}
