package relay.session

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flow

/**
 * Platform connectivity source the [NetworkObserver] consumes.
 *
 * The Swift original (`NetworkMonitor.swift`) wraps `NWPathMonitor`; on Android
 * the equivalent is `ConnectivityManager.registerNetworkCallback`. To keep
 * `:core-session` pure-JVM (so the edge-detection logic stays headless-testable
 * and the ActivityCoordinator/Recovery/Auth tests need no emulator), the Android
 * `ConnectivityManager` wiring is implemented in `:app` against this interface
 * instead of imported here. A test supplies a fake emitting a controlled
 * sequence of booleans.
 *
 * [isOnline] must emit `true` when the device has a validated, internet-capable
 * network and `false` otherwise (the analogue of `NWPath.status == .satisfied`).
 */
interface ConnectivitySource {
    /** Current connectivity, hot. `true` == online. */
    val isOnline: StateFlow<Boolean>
}

/**
 * Emits a "connectivity restored" signal on every offline→online transition,
 * ported from Sources/ClaudeRelayClient/Helpers/NetworkMonitor.swift.
 *
 * The Swift monitor tracks a `wasDisconnected` flag and posts the
 * `connectivityRestored` notification **only** on the disconnected→connected
 * edge (NetworkMonitor.swift:21-29) — never on the initial "already online"
 * state and never twice for one outage. The coordinator wires that notification
 * to `triggerUserRecovery`. This observer reproduces exactly that edge semantic:
 *
 *  - It starts in the "have not yet seen offline" state, so an initial `true`
 *    (app launches online) does NOT fire.
 *  - It fires once when `true` follows a `false` (the network came back).
 *  - Consecutive `true`s (redundant updates) do not re-fire.
 *
 * Pure logic — the edge detector ([edges]) is a stateless transform over a
 * boolean [Flow], so it is unit-tested directly without Android. The Android
 * `ConnectivityManager`/`NetworkCallback` glue lives in `:app` and merely feeds
 * a [ConnectivitySource] into this observer.
 */
class NetworkObserver(
    private val connectivity: ConnectivitySource,
) {
    /** Live connectivity (passthrough of the injected source). */
    val isOnline: StateFlow<Boolean> get() = connectivity.isOnline

    /**
     * Fires `Unit` on each offline→online transition. Collect this and call the
     * coordinator's user-recovery trigger. Cold — restarts its edge state per
     * collector, matching the Swift monitor's single live consumer.
     */
    val connectivityRestored: Flow<Unit> = edges(connectivity.isOnline)

    companion object {
        /**
         * Stateless offline→online edge detector. Emits `Unit` for each `false`→
         * `true` transition in [source], and never for the initial value or for
         * redundant repeats (those are collapsed by [distinctUntilChanged]).
         *
         * Mirrors `NetworkMonitor`'s `wasDisconnected` flip-flop
         * (NetworkMonitor.swift:14, :22-28): only a `true` that *follows* a
         * `false` counts as "restored". Exposed (and pure) so it can be
         * unit-tested headless.
         */
        fun edges(source: Flow<Boolean>): Flow<Unit> = flow {
            // Null = "no prior state seen" (Swift starts wasDisconnected=false and
            // never fires on the first satisfied path; we likewise suppress the
            // initial value, whatever it is).
            var wasDisconnected = false
            var seenFirst = false
            source.distinctUntilChanged().collect { online ->
                if (!seenFirst) {
                    seenFirst = true
                    if (!online) wasDisconnected = true
                    return@collect
                }
                if (!online) {
                    wasDisconnected = true
                } else if (wasDisconnected) {
                    wasDisconnected = false
                    emit(Unit)
                }
            }
        }
    }
}
