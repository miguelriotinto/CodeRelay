import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

/// Regression suite for the launch/wake handshake — the single sequence that
/// populates the session pane (connect → authenticate → list owned sessions →
/// render).
///
/// These tests run WITHOUT a server: the connection has no config and no
/// socket, so every attempt fails. That is deliberate — the properties worth
/// pinning here are the ones that let the "empty pane on relaunch" bug survive
/// five fixes, and all of them are about control flow, not about the happy path:
/// does recovery stay out of the way, does the gate always clear, does a total
/// failure stay visible. The happy path is covered end-to-end against a real
/// server by `LaunchHandshakeLiveTests`.
@MainActor
final class SessionHandshakeTests: XCTestCase {

    private func makeCoordinator() -> SharedSessionCoordinator {
        SharedSessionCoordinator(connection: RelayConnection(), token: "test-token")
    }

    // MARK: - The recovery gate (the #43 root cause, generalised)

    /// The cold-launch bug: `scenePhase → .active` fires while the launch
    /// handshake is mid-flight, recovery calls `forceReconnect()`, and the
    /// in-flight `session_list` dies with the socket. Recovery must refuse to
    /// run while a handshake owns the connection.
    func testUserRecoveryIsBlockedWhileHandshakeInFlight() {
        let coordinator = makeCoordinator()
        coordinator.isPerformingHandshake = true

        coordinator.triggerUserRecovery()

        XCTAssertNil(
            coordinator.recoveryTask,
            "recovery must not be dispatched while the handshake owns the connection"
        )
    }

    func testAutoRecoveryIsBlockedWhileHandshakeInFlight() {
        let coordinator = makeCoordinator()
        coordinator.isPerformingHandshake = true

        coordinator.recoveryController.scheduleAutoRecovery()

        XCTAssertNil(coordinator.recoveryTask, "auto-recovery must not pre-empt a handshake")
    }

    /// The launch race, reproduced: a handshake is running and a foreground
    /// trigger arrives (on a cold launch these are milliseconds apart). The
    /// trigger must be dropped, and the handshake must still be the one holding
    /// the connection when it returns.
    ///
    /// `performHandshake` arms the gate before its first suspension point, so by
    /// the time it has started running there is no window for a trigger to slip
    /// through.
    func testRecoveryTriggerArrivingDuringHandshakeIsIgnored() async {
        let coordinator = makeCoordinator()

        let running = Task { await coordinator.performHandshake(reason: .launch) }
        await Task.yield()      // let the handshake body start
        XCTAssertTrue(coordinator.isPerformingHandshake, "handshake should be in flight")

        coordinator.triggerUserRecovery()

        XCTAssertNil(
            coordinator.recoveryTask,
            "a foreground trigger during the handshake must not dispatch recovery"
        )
        XCTAssertTrue(coordinator.isPerformingHandshake, "the handshake must not have been pre-empted")

        coordinator.tearDown()
        _ = await running.value
    }

    /// Once the handshake finishes — success OR total failure — the gate must
    /// clear, or recovery is dead for the rest of the session.
    func testGateClearsAfterTotalFailure() async {
        let coordinator = makeCoordinator()

        let succeeded = await coordinator.performHandshake(reason: .launch)

        XCTAssertFalse(succeeded, "no server: the handshake cannot succeed")
        XCTAssertFalse(
            coordinator.isPerformingHandshake,
            "the gate must clear on failure — a stuck gate permanently blocks recovery"
        )
    }

    func testTearDownClearsTheGate() {
        let coordinator = makeCoordinator()
        coordinator.isPerformingHandshake = true

        coordinator.tearDown()

        XCTAssertFalse(coordinator.isPerformingHandshake)
    }

    // MARK: - No silent failure

    /// The old launch path caught every error and dropped it, so one transient
    /// RPC failure meant a permanently blank pane with no message and no retry.
    /// A handshake that exhausts its retries must say so.
    func testTotalFailureSurfacesAnErrorInsteadOfFailingSilently() async {
        let coordinator = makeCoordinator()

        await coordinator.performHandshake(reason: .launch)

        XCTAssertTrue(coordinator.showError, "an exhausted handshake must surface an error")
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertTrue(coordinator.recoveryFailed)
        // NOT connectionTimedOut: that dismisses the workspace on iOS, which
        // removes the user's ability to retry. They should stay put and pull to
        // refresh (or foreground again).
        XCTAssertFalse(
            coordinator.connectionTimedOut,
            "a failed list fetch must not tear the workspace down"
        )
    }

    func testHandshakeRetriesMoreThanOnce() {
        // Five attempts, front-loaded: the common failure is a socket replaced
        // microseconds ago, which succeeds on the next try.
        XCTAssertEqual(SessionHandshake.retryDelays.count, 5)
        XCTAssertEqual(SessionHandshake.retryDelays.first, .zero,
                       "the first attempt must not be delayed — launch latency is user-visible")
    }

    // MARK: - Launch is silent, wake announces

    /// `.wake` announces a session that another device took while we were away
    /// (we missed its live `session_stolen` push because the socket was down).
    func testFirstLostSessionIsTheOneMissingFromTheServerList() {
        let kept = UUID()
        let taken = UUID()
        let before = [(id: kept, name: "Arya"), (id: taken, name: "Bran")]

        let lost = SessionHandshake.firstLostSession(before: before, stillOwned: [kept])

        XCTAssertEqual(lost?.id, taken)
        XCTAssertEqual(lost?.name, "Bran", "the name must come from the pre-fetch snapshot")
    }

    /// Nothing to announce when the server still lists everything we had.
    func testNoLostSessionWhenServerListMatches() {
        let a = UUID(), b = UUID()
        let before = [(id: a, name: "Arya"), (id: b, name: "Bran")]

        XCTAssertNil(SessionHandshake.firstLostSession(before: before, stillOwned: [a, b]))
    }

    /// The launch case, by construction: an empty pane before the fetch means
    /// there is no "before" to diff, so nothing is ever announced on launch —
    /// which is the product requirement (don't report sessions taken while the
    /// app was closed).
    func testNothingIsAnnouncedWhenThereWasNoPriorPane() {
        XCTAssertNil(SessionHandshake.firstLostSession(before: [], stillOwned: []))
        XCTAssertNil(SessionHandshake.firstLostSession(before: [], stillOwned: [UUID()]))
    }

    /// A `.launch` handshake must never raise the "attached from another device"
    /// alert, even if the pane somehow already had rows (e.g. a deep-link attach
    /// ran first). The reason flag — not just the empty-pane coincidence — is
    /// what guarantees it.
    func testLaunchNeverRaisesTheStolenAlert() async {
        let coordinator = makeCoordinator()
        coordinator.sessions = [
            SessionInfo(id: UUID(), name: "Ghost", state: .activeAttached,
                        tokenId: "t", createdAt: Date(), cols: 80, rows: 24)
        ]

        await coordinator.performHandshake(reason: .launch)

        XCTAssertFalse(
            coordinator.activityCoordinator.showSessionStolen,
            "launch must stay silent about sessions lost while the app was closed"
        )
    }

    // MARK: - Auth validity requires a live socket

    /// `handleReceiveFailure()` flips `state` to `.disconnected` WITHOUT bumping
    /// the connection generation, so a generation-only `isAuthValid` reported
    /// "authenticated" over a socket that no longer existed. The RPC then threw
    /// `ConnectionError.notConnected`, which `withAuth` does not retry — a
    /// silent dead end. Auth validity must require a live socket so the
    /// handshake reconnects instead.
    func testAuthIsInvalidWithoutALiveSocket() async {
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)

        connection._testOnly_setState(.connected)
        XCTAssertFalse(controller.isAuthValid, "never authenticated → invalid")

        connection._testOnly_setState(.disconnected)
        XCTAssertFalse(controller.isAuthValid, "no live socket → invalid regardless of generation")
    }

    // MARK: - Desynchronized sockets are a TRANSPORT condition

    /// A desynchronized socket (an earlier RPC timed out and still owes a reply)
    /// must classify as transport-level, not application-level. App-level means
    /// "the server rejected this request": the recovery path responds by evicting
    /// the active terminal and clearing the user's session. Doing that over a
    /// socket that merely needs replacing would destroy live work.
    ///
    /// Swift gets this right by construction — the classification switches over
    /// an exhaustive enum, so adding `connectionDesynchronized` forced the
    /// decision at compile time. The Kotlin port classifies by matching the error
    /// *message*, where the same addition silently fell through to the app-level
    /// default; it now carries an explicit `isDesynchronized` flag. This test
    /// pins the Swift half of that parity so a later "simplification" of the
    /// switch can't quietly reintroduce it.
    func testDesynchronizedIsTransportLevelNotApplicationLevel() {
        XCTAssertFalse(
            SharedSessionCoordinator.isApplicationLevelError(
                SessionController.SessionError.connectionDesynchronized
            ),
            "a socket that needs replacing must not be reported as the server rejecting the request"
        )
        // The neighbouring cases, so the assertion above is meaningful rather
        // than passing because everything returns false.
        XCTAssertFalse(SharedSessionCoordinator.isApplicationLevelError(
            SessionController.SessionError.timeout
        ))
        XCTAssertTrue(SharedSessionCoordinator.isApplicationLevelError(
            SessionController.SessionError.unexpectedResponse("session_not_found")
        ))
    }
}
