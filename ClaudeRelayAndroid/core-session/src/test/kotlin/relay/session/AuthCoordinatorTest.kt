package relay.session

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * Verifies the single-flight + retry-once semantics ported from
 * Sources/ClaudeRelayClient/AuthCoordinator.swift:
 *   - concurrent ensureAuthenticated callers share one in-flight auth
 *     (AuthCoordinator.swift:73-87)
 *   - withAuth retries the body exactly once on a NotAuthenticated error,
 *     re-authenticating before the retry (AuthCoordinator.swift:92-101)
 */
class AuthCoordinatorTest {

    @Test
    fun `concurrent ensureAuthenticated dedupes to a single auth call`() = runTest {
        val authCalls = AtomicInteger(0)
        val gate = CompletableDeferred<Unit>()
        var valid = false
        val coordinator = AuthCoordinator(
            authenticate = {
                authCalls.incrementAndGet()
                gate.await() // hold all callers in the same in-flight task
                valid = true
            },
            isAuthValid = { valid },
        )

        // Launch several concurrent callers BEFORE releasing the gate so they
        // all observe the same in-flight task.
        val jobs = List(5) { async { coordinator.ensureAuthenticated() } }
        gate.complete(Unit)
        jobs.awaitAll()

        assertEquals(1, authCalls.get())
    }

    @Test
    fun `ensureAuthenticated short-circuits when already valid`() = runTest {
        val authCalls = AtomicInteger(0)
        var valid = true
        val coordinator = AuthCoordinator(
            authenticate = { authCalls.incrementAndGet(); valid = true },
            isAuthValid = { valid },
        )
        coordinator.ensureAuthenticated()
        coordinator.ensureAuthenticated()
        assertEquals(0, authCalls.get())
    }

    @Test
    fun `withAuth retries body exactly once on NotAuthenticated`() = runTest {
        val authCalls = AtomicInteger(0)
        val resetCalls = AtomicInteger(0)
        var valid = false
        val coordinator = AuthCoordinator(
            authenticate = { authCalls.incrementAndGet(); valid = true },
            isAuthValid = { valid },
            resetAuth = { resetCalls.incrementAndGet(); valid = false },
        )

        val bodyCalls = AtomicInteger(0)
        val result = coordinator.withAuth {
            val n = bodyCalls.incrementAndGet()
            if (n == 1) throw NotAuthenticatedException()
            "ok"
        }

        assertEquals("ok", result)
        assertEquals(2, bodyCalls.get()) // first throws, retry succeeds
        // One auth for the initial ensureAuthenticated, one for the retry. The
        // retry now routes through resetAuth()+ensureAuthenticated() (Swift
        // parity), so assert on the COUNT — it must still be exactly 2.
        assertEquals(2, authCalls.get())
        assertEquals(1, resetCalls.get(), "resetAuth invoked once before the retry")
    }

    @Test
    fun `withAuth re-authenticates before the retry`() = runTest {
        // After the first NotAuthenticated, resetAuth() must clear the local auth
        // bit BEFORE ensureAuthenticated() runs, so the retry re-authenticates
        // against fresh auth rather than short-circuiting on a stale valid flag
        // (AuthCoordinator.swift:97-98). We capture the ordering explicitly.
        var valid = false
        val authCalls = AtomicInteger(0)
        val order = mutableListOf<String>()
        val coordinator = AuthCoordinator(
            authenticate = { authCalls.incrementAndGet(); valid = true; order.add("auth") },
            isAuthValid = { valid },
            resetAuth = { valid = false; order.add("reset") },
        )
        coordinator.withAuth {
            if (authCalls.get() < 2) throw NotAuthenticatedException()
            Unit
        }
        assertEquals(2, authCalls.get())
        // Ordering must match Swift: resetAuth() THEN ensureAuthenticated()->auth.
        assertEquals(listOf("auth", "reset", "auth"), order)
    }

    @Test
    fun `concurrent withAuth retries dedupe through single-flight to two auth calls`() = runTest {
        // The real bug (I1): two concurrent withAuth bodies BOTH throwing
        // NotAuthenticated on their first call (the post-reconnect mass-
        // invalidation case). The retries must dedupe through the shared in-flight
        // auth slot — total authenticate() calls == 2 (one shared initial auth +
        // one shared retry auth), NOT 3 (which is what a direct authenticate() in
        // the catch block produced, racing two competing auth_requests).
        val authCalls = AtomicInteger(0)
        var valid = false
        // One gate per authentication round (round 1 = initial, round 2 = retry),
        // pre-created so there is no racy reassignment between rounds. authenticate
        // awaits the gate for its round, holding the single in-flight slot open
        // long enough for the concurrent peer to join it.
        val gates = listOf(CompletableDeferred<Unit>(), CompletableDeferred<Unit>())
        val coordinator = AuthCoordinator(
            authenticate = {
                val round = authCalls.getAndIncrement() // 0 = initial, 1 = retry
                gates[round].await()
                valid = true
            },
            isAuthValid = { valid },
            resetAuth = { valid = false },
        )

        // Each body throws NotAuthenticated on ITS first call, then succeeds.
        val bodyCalls = IntArray(2)
        val jobs = List(2) { idx ->
            async {
                coordinator.withAuth {
                    bodyCalls[idx] += 1
                    if (bodyCalls[idx] == 1) throw NotAuthenticatedException()
                    "ok-$idx"
                }
            }
        }

        // Round 1: both ensureAuthenticated calls join the single in-flight auth.
        runCurrent()
        assertEquals(1, authCalls.get(), "initial ensureAuthenticated is single-flighted to 1")
        gates[0].complete(Unit) // release round-1 auth; both bodies run and throw

        // Round 2: both catch blocks resetAuth()+ensureAuthenticated(); they must
        // again dedupe through ONE in-flight auth rather than firing two.
        runCurrent()
        assertEquals(2, authCalls.get(), "concurrent retries dedupe to a single retry auth")
        gates[1].complete(Unit)

        val results = jobs.awaitAll()
        assertEquals(listOf("ok-0", "ok-1"), results)
        assertEquals(2, bodyCalls[0])
        assertEquals(2, bodyCalls[1])
        // The load-bearing assertion: 2, not 3. With the OLD direct-authenticate()
        // retry, this would be 3 (each retry fires its own auth_request).
        assertEquals(2, authCalls.get())
    }

    @Test
    fun `withAuth propagates a second NotAuthenticated without a third attempt`() = runTest {
        // Swift only catches the FIRST NotAuthenticated; a second one escapes.
        var valid = false
        val authCalls = AtomicInteger(0)
        val coordinator = AuthCoordinator(
            authenticate = { authCalls.incrementAndGet(); valid = true },
            isAuthValid = { valid },
        )
        val bodyCalls = AtomicInteger(0)
        assertThrows(NotAuthenticatedException::class.java) {
            kotlinx.coroutines.runBlocking {
                coordinator.withAuth<Unit> {
                    bodyCalls.incrementAndGet()
                    throw NotAuthenticatedException()
                }
            }
        }
        assertEquals(2, bodyCalls.get()) // initial + one retry, then it escapes
    }

    @Test
    fun `withAuth propagates non-auth errors immediately`() = runTest {
        var valid = false
        val coordinator = AuthCoordinator(
            authenticate = { valid = true },
            isAuthValid = { valid },
        )
        val bodyCalls = AtomicInteger(0)
        assertThrows(IllegalStateException::class.java) {
            kotlinx.coroutines.runBlocking {
                coordinator.withAuth<Unit> {
                    bodyCalls.incrementAndGet()
                    throw IllegalStateException("boom")
                }
            }
        }
        assertEquals(1, bodyCalls.get()) // no retry on a non-auth error
    }
}
