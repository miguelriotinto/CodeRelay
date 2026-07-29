import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

/// Live end-to-end reproduction of the "empty session pane on relaunch" bug.
///
/// This suite talks to a REAL running relay server, because the bug lives in
/// the connect → authenticate → list handshake and its interaction with the
/// recovery/keepalive machinery — none of which a mock exercises. Five
/// code-reading-only fixes shipped without reproducing it; this harness exists
/// so that never happens again.
///
/// Skipped unless both env vars are set, so `swift test` in CI is unaffected:
///
///     RELAY_LIVE_TOKEN=<raw token>  RELAY_LIVE_HOST=127.0.0.1 \
///       swift test --filter LaunchHandshakeLiveTests
@MainActor
final class LaunchHandshakeLiveTests: XCTestCase {

    private var host: String!
    private var token: String!

    override func setUpWithError() throws {
        guard let token = ProcessInfo.processInfo.environment["RELAY_LIVE_TOKEN"],
              !token.isEmpty else {
            throw XCTSkip("Set RELAY_LIVE_TOKEN (and optionally RELAY_LIVE_HOST) to run live tests.")
        }
        self.token = token
        self.host = ProcessInfo.processInfo.environment["RELAY_LIVE_HOST"] ?? "127.0.0.1"
    }

    private var config: ConnectionConfig {
        ConnectionConfig(name: "live", host: host, port: 9200, useTLS: false)
    }

    /// Builds a coordinator over a brand-new socket — i.e. exactly what a cold
    /// app launch does.
    private func makeLaunchedCoordinator() async throws -> SharedSessionCoordinator {
        let connection = RelayConnection()
        try await connection.connect(config: config, token: token)
        return SharedSessionCoordinator(connection: connection, token: token)
    }

    // MARK: - The reported bug

    /// Phase 1: create two sessions (the user's "I attach one, then another").
    /// Phase 2: tear everything down and cold-launch a fresh coordinator over a
    /// fresh socket (the user's "I kill the app, I relaunch"). The pane MUST
    /// show both sessions with no user interaction.
    func testColdRelaunchShowsSessionsOwnedByThisToken() async throws {
        // ---- Phase 1: first run -------------------------------------------
        let first = try await makeLaunchedCoordinator()
        let firstOK = await first.performHandshake(reason: .launch)
        XCTAssertTrue(firstOK)

        let preexisting = first.activeSessions.count
        await first.createNewSession()
        await first.createNewSession()

        let afterCreate = first.activeSessions.count
        XCTAssertEqual(afterCreate, preexisting + 2,
                       "sanity: two created sessions must be in the pane on the run that created them")
        let expectedIds = Set(first.activeSessions.map(\.id))
        first.tearDown()

        // Give the server a moment to process the detach/disconnect, mimicking
        // the gap between killing the app and relaunching it.
        try await Task.sleep(for: .milliseconds(500))

        // ---- Phase 2: cold relaunch ---------------------------------------
        let relaunched = try await makeLaunchedCoordinator()
        // Exactly what WorkspaceView.task does, including the recovery machinery
        // that races it: `startNetworkRecovery` + the `scenePhase → .active`
        // trigger fire around the handshake, and must not disturb it.
        relaunched.startNetworkRecovery()
        relaunched.triggerUserRecovery()
        let ok = await relaunched.performHandshake(reason: .launch)

        let relaunchedIds = Set(relaunched.activeSessions.map(\.id))
        defer { relaunched.tearDown() }

        XCTAssertTrue(ok, "the launch handshake must report success")
        XCTAssertFalse(
            relaunched.activityCoordinator.showSessionStolen,
            "a cold launch must never report that a session was attached elsewhere"
        )

        XCTAssertEqual(
            relaunchedIds, expectedIds,
            """
            EMPTY PANE ON RELAUNCH. The pane after a cold launch must equal the \
            set of sessions this token owns on the server. \
            expected \(expectedIds.count) session(s), got \(relaunchedIds.count).
            """
        )
    }

    /// Narrower probe: does a freshly-connected socket answer `session_list` at
    /// all? Isolates "the RPC failed" from "the RPC succeeded but the pane
    /// didn't render it".
    func testFreshSocketAnswersSessionListImmediately() async throws {
        let connection = RelayConnection()
        try await connection.connect(config: config, token: token)
        let controller = SessionController(connection: connection)
        try await controller.authenticate(token: token)
        let sessions = try await controller.listSessions()
        connection.disconnect()
        XCTAssertNotNil(controller.tokenId, "auth_success must carry the tokenId")
        print("[live] session_list returned \(sessions.count) session(s) for token \(controller.tokenId ?? "?")")
    }

    /// The launch handshake immediately after `connect()`, with no explicit
    /// `authenticate()` first — the handshake owns authentication, so the app
    /// never has to sequence it by hand.
    func testLaunchHandshakePopulatesPane() async throws {
        let coordinator = try await makeLaunchedCoordinator()
        defer { coordinator.tearDown() }
        let ok = await coordinator.performHandshake(reason: .launch)
        print("[live] pane after launch handshake: \(coordinator.activeSessions.count)")
        XCTAssertTrue(ok, "the handshake must authenticate and list without help")
        XCTAssertFalse(
            coordinator.sessions.isEmpty,
            "launch handshake returned nothing while the server holds sessions for this token"
        )
    }

    /// The handshake must survive the socket being replaced underneath it —
    /// exactly what recovery used to do on cold launch. Here we kill the socket
    /// deliberately, right before handshaking: attempt 1 fails, the retry
    /// reconnects, re-authenticates, and the pane still ends up correct.
    func testHandshakeRecoversFromADeadSocket() async throws {
        let coordinator = try await makeLaunchedCoordinator()
        defer { coordinator.tearDown() }

        // Establish the expected list over a healthy socket first.
        let seeded = await coordinator.performHandshake(reason: .launch)
        XCTAssertTrue(seeded)
        let expected = Set(coordinator.activeSessions.map(\.id))
        try XCTSkipIf(expected.isEmpty, "needs at least one session owned by this token")

        // Now pull the rug out and handshake again.
        coordinator.connection.disconnect()
        let ok = await coordinator.performHandshake(reason: .wake)

        XCTAssertTrue(ok, "the handshake must reconnect and re-authenticate on its own")
        XCTAssertEqual(
            Set(coordinator.activeSessions.map(\.id)), expected,
            "a dead socket must cost a retry, not the contents of the pane"
        )
    }

    /// Single-flight: three simultaneous callers (launch `.task`, foreground
    /// trigger, network-restored) must share ONE pass. Overlapping
    /// `session_list` RPCs can cross-deliver — replies are matched by response
    /// TYPE, the protocol has no request ids.
    func testConcurrentHandshakesShareOnePass() async throws {
        let coordinator = try await makeLaunchedCoordinator()
        defer { coordinator.tearDown() }

        async let a = coordinator.performHandshake(reason: .launch)
        async let b = coordinator.performHandshake(reason: .wake)
        async let c = coordinator.performHandshake(reason: .wake)
        let results = await [a, b, c]

        XCTAssertEqual(results, [true, true, true], "all callers must see the same successful pass")
        XCTAssertFalse(coordinator.isPerformingHandshake, "the gate must clear once")
    }
}
