import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// Tests for `AuthCoordinator` — single-flight semantics and state lifecycle.
/// End-to-end auth against a real WebSocketServer is covered by
/// `WebSocketIntegrationTests`; these tests focus on the parts that don't
/// need a live server.
@MainActor
final class AuthCoordinatorTests: XCTestCase {

    // MARK: - Initial state

    func testInitialStateHasNoController() {
        let connection = RelayConnection()
        let auth = AuthCoordinator(connection: connection, token: "t")
        XCTAssertNil(auth.sessionController)
        XCTAssertFalse(auth.isAuthValid)
    }

    // MARK: - resetAuth / invalidate / cancelInFlight

    func testResetAuthPreservesControllerButClearsAuthValid() {
        let connection = RelayConnection()
        let auth = AuthCoordinator(connection: connection, token: "t")
        let controller = SessionController(connection: connection)
        auth.sessionController = controller

        auth.resetAuth()

        XCTAssertNotNil(auth.sessionController,
            "resetAuth must preserve the controller instance")
        XCTAssertFalse(auth.isAuthValid,
            "controller should report not valid after resetAuth")
    }

    func testInvalidateDropsController() {
        let connection = RelayConnection()
        let auth = AuthCoordinator(connection: connection, token: "t")
        auth.sessionController = SessionController(connection: connection)
        auth.invalidate()
        XCTAssertNil(auth.sessionController)
    }

    func testCancelInFlightKeepsController() {
        let connection = RelayConnection()
        let auth = AuthCoordinator(connection: connection, token: "t")
        let controller = SessionController(connection: connection)
        auth.sessionController = controller
        auth.cancelInFlight()
        XCTAssertTrue(auth.sessionController === controller,
            "cancelInFlight must not drop the controller")
    }

    // MARK: - onAuthenticated hook

    func testOnAuthenticatedNotFiredOnInit() {
        final class Flag: @unchecked Sendable {
            var called = false
            private let lock = NSLock()
            func fire() { lock.lock(); called = true; lock.unlock() }
            func read() -> Bool { lock.lock(); defer { lock.unlock() }; return called }
        }
        let flag = Flag()
        let connection = RelayConnection()
        let auth = AuthCoordinator(connection: connection, token: "t")
        auth.onAuthenticated = { flag.fire() }
        XCTAssertFalse(flag.read(),
            "onAuthenticated must not fire before a successful authenticate call")
    }

    // MARK: - ensureAuthenticated without transport

    /// Without a live transport, `SessionController.authenticate` throws.
    /// `ensureAuthenticated` must propagate the throw and leave the
    /// coordinator unauthenticated — no cached success from a prior call.
    func testEnsureAuthenticatedThrowsWhenNotConnected() async {
        let connection = RelayConnection()
        let auth = AuthCoordinator(connection: connection, token: "t")
        do {
            _ = try await auth.ensureAuthenticated()
            XCTFail("Expected a throw when connection is not established")
        } catch {
            // expected
            XCTAssertFalse(auth.isAuthValid)
        }
    }
}
