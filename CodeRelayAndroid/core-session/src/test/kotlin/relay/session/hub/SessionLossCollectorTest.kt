package relay.session.hub

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID

/** Port of Swift `SessionLossCollectorTests`, on `TestScope` virtual time. */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionLossCollectorTest {

    private val server = UUID.randomUUID()
    private val flushes = mutableListOf<Pair<List<SessionLossItem>, List<SessionLossItem>>>()
    private val requestedSleeps = mutableListOf<Long>()

    private fun TestScope.collector() = SessionLossCollector(
        scope = hubScope(),
        nowMs = { testScheduler.currentTime },
        sleepMs = { requestedSleeps += it; delay(it) },
    ).also { c -> c.onFlush = { taken, ended -> flushes += taken to ended } }

    private fun item(name: String, id: UUID = UUID.randomUUID(), server: UUID = this.server) =
        SessionLossItem(serverId = server, serverName = "Mac", session = LostSession(id, name))

    @Test fun twoLiveReportsWithin1sFlushOnce() = runTest {
        val c = collector()
        val a = item("api"); val b = item("web")
        c.report(listOf(a), SessionLossKind.TAKEN)
        advanceTimeBy(900); runCurrent()
        c.report(listOf(b), SessionLossKind.TAKEN)
        advanceTimeBy(950); runCurrent()
        assertTrue(flushes.isEmpty(), "the second report restarts the 1 s debounce")
        advanceTimeBy(100); runCurrent()
        assertEquals(1, flushes.size)
        assertEquals(listOf(a, b), flushes[0].first)
        assertEquals(emptyList<SessionLossItem>(), flushes[0].second)
        assertTrue(requestedSleeps.all { it == 1_000L })
    }

    @Test fun repeatWithin120sIsSuppressed() = runTest {
        val c = collector()
        val id = UUID.randomUUID()
        c.report(listOf(item("api", id)), SessionLossKind.TAKEN)
        advanceUntilIdle()
        assertEquals(1, flushes.size)

        advanceTimeBy(119_000); runCurrent()
        c.report(listOf(item("api", id)), SessionLossKind.TAKEN)
        c.report(listOf(item("api", id)), SessionLossKind.ENDED)
        advanceUntilIdle()
        assertEquals(1, flushes.size, "a repeat inside 120 s of the announcement is dropped")

        advanceTimeBy(2_000); runCurrent() // 121 s after the announcement
        c.report(listOf(item("api", id)), SessionLossKind.TAKEN)
        advanceUntilIdle()
        assertEquals(2, flushes.size, "allowed again once the window has passed")
    }

    @Test fun holdDefersFlushUntilEndHold() = runTest {
        val c = collector()
        val a = item("api"); val b = item("web"); val d = item("db")
        c.beginHold()
        c.beginHold() // nested (start + foreground overlap)
        c.report(listOf(a), SessionLossKind.TAKEN)
        c.report(listOf(b), SessionLossKind.ENDED)
        advanceUntilIdle()
        assertTrue(flushes.isEmpty(), "nothing flushes while a hold is open")
        c.endHold()
        advanceUntilIdle()
        assertTrue(flushes.isEmpty(), "the inner endHold does not flush")
        c.report(listOf(d), SessionLossKind.TAKEN)
        c.endHold()
        assertEquals(1, flushes.size, "the outermost endHold flushes at once")
        assertEquals(listOf(a, d), flushes[0].first)
        assertEquals(listOf(b), flushes[0].second)
        advanceUntilIdle()
        assertEquals(1, flushes.size, "no stray debounce flush after the hold")
    }

    @Test fun duplicateInBatchCollapses() = runTest {
        val c = collector()
        val id = UUID.randomUUID(); val other = UUID.randomUUID()
        c.report(listOf(item("api", id), item("api", id)), SessionLossKind.TAKEN)
        c.report(listOf(item("api", id)), SessionLossKind.ENDED)
        c.report(listOf(item("api", id, server = other)), SessionLossKind.TAKEN)
        advanceUntilIdle()
        assertEquals(1, flushes.size)
        assertEquals(listOf(id, id), flushes[0].first.map { it.session.id }, "same session id on another server is distinct")
        assertEquals(listOf(server, other), flushes[0].first.map { it.serverId })
        assertEquals(emptyList<SessionLossItem>(), flushes[0].second)
    }

    @Test fun resetDropsPendingAndALateEndHoldIsANoOp() = runTest {
        val c = collector()
        val stale = c.beginHold()
        c.report(listOf(item("api")), SessionLossKind.TAKEN)
        c.reset()
        c.endHold(stale) // the old hold's cap fires late
        assertFalse(c.isHolding)
        assertTrue(flushes.isEmpty(), "pending items were dropped, no flush")

        val fresh = c.beginHold()
        c.report(listOf(item("web")), SessionLossKind.TAKEN)
        c.endHold(stale)
        assertTrue(c.isHolding, "a pre-reset hold cannot close a new one")
        c.endHold(fresh)
        assertEquals(listOf(listOf("web")), flushes.map { f -> f.first.map { it.session.name } })

        c.report(listOf(item("db")), SessionLossKind.TAKEN)
        c.reset()
        advanceUntilIdle()
        assertEquals(1, flushes.size, "reset cancels a pending debounce")
    }
}
