import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

@MainActor
final class RecoveryControllerTests: XCTestCase {

    private func makeCoordinatorAndController() -> (SharedSessionCoordinator, RecoveryController) {
        let connection = RelayConnection()
        let coordinator = SharedSessionCoordinator(connection: connection, token: "test-token")
        let controller = coordinator.recoveryController!
        return (coordinator, controller)
    }

    // MARK: - Circuit Breaker

    func testBreakerResetClearsState() {
        let (_, controller) = makeCoordinatorAndController()
        controller._testOnly_setAutoRecoverySuspended(true, failures: 3)

        controller.resetAutoRecoveryBreaker()

        XCTAssertFalse(controller._testOnly_autoRecoverySuspended)
        XCTAssertEqual(controller._testOnly_consecutiveAutoRecoveryFailures, 0)
    }

    func testBreakerResetIsNoOpWhenAlreadyIdle() {
        let (_, controller) = makeCoordinatorAndController()
        XCTAssertFalse(controller._testOnly_autoRecoverySuspended)
        XCTAssertEqual(controller._testOnly_consecutiveAutoRecoveryFailures, 0)

        // Should not crash or change state
        controller.resetAutoRecoveryBreaker()

        XCTAssertFalse(controller._testOnly_autoRecoverySuspended)
    }

    // MARK: - scheduleAutoRecovery gates

    func testScheduleAutoRecoveryBlockedWhenTornDown() {
        let (coordinator, controller) = makeCoordinatorAndController()
        coordinator.tearDown()

        controller.scheduleAutoRecovery()

        XCTAssertNil(coordinator.recoveryTask)
    }

    func testScheduleAutoRecoveryBlockedWhenSuspended() {
        let (coordinator, controller) = makeCoordinatorAndController()
        controller._testOnly_setAutoRecoverySuspended(true, failures: 3)

        controller.scheduleAutoRecovery()

        XCTAssertNil(coordinator.recoveryTask)
    }

    // MARK: - triggerUserRecovery

    func testTriggerUserRecoveryBlockedWhenTornDown() {
        let (coordinator, controller) = makeCoordinatorAndController()
        coordinator.tearDown()

        controller.triggerUserRecovery()

        XCTAssertNil(coordinator.recoveryTask)
    }

    /// Regression: a previous fast-path skipped recovery when
    /// `connection.state == .connected`, but on macOS the WebSocket can be
    /// silently broken by sleep without flipping state. The wake-up
    /// `triggerUserRecovery` call must always dispatch the recovery task —
    /// `handleForegroundTransition` itself short-circuits via a real ping
    /// when the socket is genuinely alive.
    func testTriggerUserRecoveryDispatchesEvenWhenStateAppearsConnected() {
        let (coordinator, controller) = makeCoordinatorAndController()
        // Force-set state to .connected through the test seam to mimic the
        // wake-from-sleep window where state is stale (the socket is dead at
        // the OS level but `state` was never flipped back to .disconnected).
        coordinator.connection._testOnly_setState(.connected)

        controller.triggerUserRecovery()

        XCTAssertNotNil(
            coordinator.recoveryTask,
            "triggerUserRecovery must dispatch recovery on wake even when state appears connected"
        )
    }

    /// Regression (the "empty pane on relaunch" bug): on cold launch `scenePhase`
    /// flips to `.active` right after connect(), firing the foreground
    /// transition. A JUST-established socket must be trusted as alive — the
    /// transition must NOT `forceReconnect` (which tore down the launch
    /// `fetchSessions` mid-flight, leaving the pane empty). It should take the
    /// fresh-connection fast path (fetch, no recovery), so `isRecovering` never
    /// flips true.
    func testForegroundOnFreshConnectionDoesNotReconnect() async {
        let (coordinator, controller) = makeCoordinatorAndController()
        // Mimic a socket opened moments ago (launch): connected + recent stamp.
        coordinator.connection._testOnly_setState(.connected)
        coordinator.connection._testOnly_setLastConnectedAt(Date())

        await controller.handleForegroundTransition(userInitiated: true)

        XCTAssertFalse(
            coordinator.isRecovering,
            "a freshly-connected socket must take the fetch fast path, not reconnect"
        )
    }

    /// Complement: a socket whose `lastConnectedAt` is old (e.g. stale after
    /// macOS sleep) must NOT take the fresh-connection fast path — it goes
    /// through the real ping/reconnect path. (Guards against reintroducing the
    /// removed blind `.connected` fast-path.)
    func testForegroundOnStaleConnectedSocketStillRecovers() async {
        let (coordinator, controller) = makeCoordinatorAndController()
        coordinator.connection._testOnly_setState(.connected)
        // Connected 60s ago — outside the fresh window; the ping will fail (no
        // real socket) and recovery engages.
        coordinator.connection._testOnly_setLastConnectedAt(Date().addingTimeInterval(-60))

        await controller.handleForegroundTransition(userInitiated: true)

        XCTAssertTrue(
            coordinator.recoveryFailed || coordinator.connectionTimedOut,
            "a stale connected socket must go through ping+reconnect, not the fresh fast path"
        )
    }

    // MARK: - cancel

    func testCancelBumpsGenerationAndSuspends() {
        let (coordinator, controller) = makeCoordinatorAndController()
        coordinator.isRecovering = true

        controller.cancel()

        XCTAssertFalse(coordinator.isRecovering)
        XCTAssertTrue(coordinator.recoveryFailed)
        XCTAssertTrue(controller._testOnly_autoRecoverySuspended)
    }

    func testCancelDebouncesPreviousTrigger() {
        let (coordinator, controller) = makeCoordinatorAndController()
        controller.cancel()

        // Immediately try user recovery — should be debounced within 1s
        controller.triggerUserRecovery()
        XCTAssertNil(coordinator.recoveryTask, "Recovery should be debounced within 1s of cancel")
    }

    // MARK: - Auth rejection

    func testScheduleAutoRecoveryBlockedWhenAuthRejected() {
        let (coordinator, controller) = makeCoordinatorAndController()
        controller._testOnly_setAuthRejected(true)

        controller.scheduleAutoRecovery()

        XCTAssertNil(coordinator.recoveryTask)
    }

    func testTriggerUserRecoveryClearsAuthRejected() {
        let (coordinator, controller) = makeCoordinatorAndController()
        _ = coordinator  // retain: controller holds an unowned ref to it
        controller._testOnly_setAuthRejected(true)
        XCTAssertTrue(controller._testOnly_authRejected)

        controller.triggerUserRecovery()

        XCTAssertFalse(controller._testOnly_authRejected)
    }

    func testMarkAuthRejectedArmsGate() {
        let (coordinator, controller) = makeCoordinatorAndController()
        XCTAssertFalse(controller._testOnly_authRejected)

        controller.markAuthRejected()

        XCTAssertTrue(controller._testOnly_authRejected)
        // And the gate now blocks auto-recovery:
        controller.scheduleAutoRecovery()
        XCTAssertNil(coordinator.recoveryTask)
    }
}
