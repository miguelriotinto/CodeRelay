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
