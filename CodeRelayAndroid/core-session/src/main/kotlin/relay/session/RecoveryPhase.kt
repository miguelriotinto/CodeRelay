package relay.session

/**
 * Recovery progress surfaced to the UI, ported from the Swift
 * `SharedSessionCoordinator.RecoveryPhase` enum
 * (SharedSessionCoordinator.swift:58-59 — `case reconnecting, authenticating,
 * resuming`).
 */
enum class RecoveryPhase {
    RECONNECTING, AUTHENTICATING, RESUMING;

    /** The loading sheet's status line during a reconnect — the Swift `RecoveryPhase.label`, verbatim. */
    val label: String
        get() = when (this) {
            RECONNECTING -> "Reconnecting to server…"
            AUTHENTICATING -> "Authenticating…"
            RESUMING -> "Restoring session…"
        }
}
