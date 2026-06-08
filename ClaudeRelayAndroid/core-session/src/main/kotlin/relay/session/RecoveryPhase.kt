package relay.session

/**
 * Recovery progress surfaced to the UI, ported from the Swift
 * `SharedSessionCoordinator.RecoveryPhase` enum
 * (SharedSessionCoordinator.swift:58-59 — `case reconnecting, authenticating,
 * resuming`).
 */
enum class RecoveryPhase { RECONNECTING, AUTHENTICATING, RESUMING }
