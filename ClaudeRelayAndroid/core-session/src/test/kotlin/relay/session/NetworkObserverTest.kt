package relay.session

import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Pure-logic tests for the NetworkObserver offline→online edge detector, ported
 * from Sources/ClaudeRelayClient/Helpers/NetworkMonitor.swift. The Android
 * `ConnectivityManager` glue is `:app`-side and device-deferred; this verifies
 * the only load-bearing logic — that "connectivity restored" fires exactly on a
 * `false`→`true` transition and never on the initial value or redundant repeats
 * (NetworkMonitor.swift:14, :22-28).
 */
class NetworkObserverTest {

    private suspend fun edges(vararg states: Boolean): List<Unit> =
        NetworkObserver.edges(flowOf(*states.toTypedArray())).toList()

    // Initial "already online" must NOT fire (Swift never posts on the first satisfied path).
    @Test
    fun `initial online does not fire`() = runTest {
        assertEquals(0, edges(true).size)
    }

    // offline→online fires exactly once.
    @Test
    fun `offline then online fires once`() = runTest {
        assertEquals(1, edges(false, true).size)
    }

    // Starting online, going offline, then back online fires once on the return.
    @Test
    fun `online offline online fires once on return`() = runTest {
        assertEquals(1, edges(true, false, true).size)
    }

    // Redundant repeats collapse — no double fire.
    @Test
    fun `redundant online repeats do not refire`() = runTest {
        // distinctUntilChanged collapses true,true; only the false→true edge fires.
        assertEquals(1, edges(false, true, true, true).size)
    }

    // Two separate outages → two restored signals.
    @Test
    fun `two outages fire twice`() = runTest {
        assertEquals(2, edges(true, false, true, false, true).size)
    }

    // Initial offline alone (never restored) does not fire.
    @Test
    fun `initial offline alone does not fire`() = runTest {
        assertEquals(0, edges(false).size)
    }
}
