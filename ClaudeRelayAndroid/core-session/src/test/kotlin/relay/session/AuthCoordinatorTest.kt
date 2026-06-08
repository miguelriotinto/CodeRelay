package relay.session

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
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
        var valid = false
        val coordinator = AuthCoordinator(
            authenticate = { authCalls.incrementAndGet(); valid = true },
            isAuthValid = { valid },
        )

        val bodyCalls = AtomicInteger(0)
        val result = coordinator.withAuth {
            val n = bodyCalls.incrementAndGet()
            if (n == 1) throw NotAuthenticatedException()
            "ok"
        }

        assertEquals("ok", result)
        assertEquals(2, bodyCalls.get()) // first throws, retry succeeds
        // One auth for the initial ensureAuthenticated, one for the retry.
        assertEquals(2, authCalls.get())
    }

    @Test
    fun `withAuth re-authenticates before the retry`() = runTest {
        // After the first NotAuthenticated, the local auth bit must be cleared
        // and re-authenticated so the retry runs against fresh auth rather than
        // short-circuiting on a stale valid flag (AuthCoordinator.swift:97-98).
        var valid = false
        val authCalls = AtomicInteger(0)
        val coordinator = AuthCoordinator(
            authenticate = { authCalls.incrementAndGet(); valid = true },
            isAuthValid = { valid },
        )
        coordinator.withAuth {
            if (authCalls.get() < 2) throw NotAuthenticatedException()
            Unit
        }
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
