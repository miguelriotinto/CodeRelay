package relay.session

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import java.util.concurrent.atomic.AtomicInteger

/**
 * Behavioral parity harness for ServerStatusChecker, ported from
 * Sources/ClaudeRelayClient/ViewModels/ServerStatusChecker.swift. Uses runTest
 * virtual time + an injected fake probe and sleep so the 15 s interval and 5 s
 * per-probe timeout are exercised deterministically with no real sleeps.
 */
class ServerStatusCheckerTest {

    private fun config(name: String) = ConnectionConfig(name = name, host = "h", port = 9200u)

    // 15 s interval default constant is the Swift default (ServerStatusChecker.swift:18).
    @Test
    fun `default interval is 15 seconds and probe timeout is 5 seconds`() {
        assertEquals(15_000L, ServerStatusChecker.DEFAULT_INTERVAL_MS)
        assertEquals(5_000L, ServerStatusChecker.PROBE_TIMEOUT_MS)
    }

    // checkAll marks LIVE/OFFLINE per probe result, keyed by config id.
    @Test
    fun `checkAll records live and offline keyed by config id`() = runTest {
        val live = config("live")
        val dead = config("dead")
        val checker = ServerStatusChecker(
            scope = this,
            probe = { cfg -> cfg.id == live.id },
            sleepMs = { delay(it) },
        )

        checker.checkAll(listOf(live, dead))

        assertEquals(ServerStatus.LIVE, checker.statuses.value[live.id])
        assertEquals(ServerStatus.OFFLINE, checker.statuses.value[dead.id])
    }

    // A probe that hangs past 5 s is recorded OFFLINE (timeout racer wins).
    @Test
    fun `probe exceeding 5 second timeout is offline`() = runTest {
        val slow = config("slow")
        val checker = ServerStatusChecker(
            scope = this,
            probe = { delay(6_000L); true }, // never resolves before the 5 s cap
            sleepMs = { delay(it) },
        )

        checker.checkAll(listOf(slow))

        assertEquals(ServerStatus.OFFLINE, checker.statuses.value[slow.id])
    }

    // A probe that throws is swallowed to OFFLINE and does not cancel siblings
    // (supervisorScope isolation).
    @Test
    fun `throwing probe is offline and does not cancel siblings`() = runTest {
        val good = config("good")
        val bad = config("bad")
        val checker = ServerStatusChecker(
            scope = this,
            probe = { cfg ->
                if (cfg.id == bad.id) throw RuntimeException("boom")
                true
            },
            sleepMs = { delay(it) },
        )

        checker.checkAll(listOf(good, bad))

        assertEquals(ServerStatus.LIVE, checker.statuses.value[good.id])
        assertEquals(ServerStatus.OFFLINE, checker.statuses.value[bad.id])
    }

    // The poll loop runs checkAll once immediately, then again every interval.
    @Test
    fun `startPolling checks immediately then every interval`() = runTest {
        val c = config("c")
        val checks = AtomicInteger(0)
        val sleeps = mutableListOf<Long>()
        val checker = ServerStatusChecker(
            scope = this,
            probe = { checks.incrementAndGet(); true },
            sleepMs = { ms -> sleeps.add(ms); delay(ms) },
        )

        checker.startPolling(listOf(c))
        runCurrent()
        assertEquals(1, checks.get()) // immediate first check

        advanceTimeBy(15_000L)
        runCurrent()
        assertEquals(2, checks.get()) // one interval later

        advanceTimeBy(15_000L)
        runCurrent()
        assertEquals(3, checks.get())

        checker.stopPolling()
        advanceUntilIdle()
        assertEquals(3, checks.get(), "no further checks after stopPolling")
        assertTrue(sleeps.all { it == 15_000L }, "every inter-poll sleep is the 15 s interval")
    }

    // Empty connection list is a no-op (Swift `guard !connections.isEmpty`).
    @Test
    fun `startPolling with empty list is a no-op`() = runTest {
        val checks = AtomicInteger(0)
        val checker = ServerStatusChecker(
            scope = this,
            probe = { checks.incrementAndGet(); true },
            sleepMs = { delay(it) },
        )

        checker.startPolling(emptyList())
        advanceUntilIdle()

        assertEquals(0, checks.get())
        assertTrue(checker.statuses.value.isEmpty())
    }

    // A config is CHECKING while its probe is in flight, then resolves.
    @Test
    fun `config is checking while probe in flight then resolves`() = runTest {
        val c = config("c")
        val gate = CompletableDeferred<Boolean>()
        val checker = ServerStatusChecker(
            scope = this,
            probe = { gate.await() },
            sleepMs = { delay(it) },
        )

        checker.startPolling(listOf(c))
        runCurrent()
        assertEquals(ServerStatus.CHECKING, checker.statuses.value[c.id])

        gate.complete(true)
        runCurrent()
        assertEquals(ServerStatus.LIVE, checker.statuses.value[c.id])

        checker.stopPolling()
    }
}
