import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// A `SharedSessionCoordinator` driven by a `FakeConnection`, with an isolated
/// defaults suite so its persisted session baseline is the test's own.
///
/// The coordinator's `RelayConnection` is never opened; its state is set to
/// `.connected` so a handshake skips `forceReconnect()` and goes straight to
/// `ensureAuthenticated()`, which uses the controller installed here.
@MainActor
struct ScriptedCoordinator {
    static let keyPrefix = "test.loss"

    let coordinator: SharedSessionCoordinator
    let conn: FakeConnection
    let defaults: UserDefaults
    let controller: SessionController

    /// Every report delivered through `onSessionsLost`, in order.
    let reports: ReportLog

    /// - Parameters:
    ///   - baseline: persisted before the coordinator is built (as a previous run would have left it).
    ///   - authenticated: false leaves the controller unauthenticated, so the
    ///     first `ensureAuthenticated()` sends an `auth_request` the test answers.
    static func make(
        tokenId: String = "me",
        protocolVersion: Int = 4,
        baseline: SessionBaseline? = nil,
        authenticated: Bool = true
    ) async throws -> ScriptedCoordinator {
        let defaults = UserDefaults(suiteName: "test.loss.\(UUID().uuidString)")!
        if let baseline {
            store(defaults).saveBaseline(baseline)
        }
        let coordinator = SharedSessionCoordinator(
            connection: RelayConnection(), token: "tok",
            ownershipKeyPrefix: keyPrefix, defaults: defaults)
        coordinator.connection._testOnly_setState(.connected)
        coordinator.connection._testOnly_sendSink = []
        let conn = FakeConnection()
        let controller = SessionController(connection: conn, responseTimeout: .milliseconds(500))
        if authenticated {
            conn.autoRespond = { message in
                message.typeString == "auth_request"
                    ? .authSuccess(protocolVersion: protocolVersion, tokenId: tokenId)
                    : nil
            }
            try await controller.authenticate(token: "tok")
            conn.autoRespond = nil
            conn.sentMessages.removeAll()
        }
        coordinator.sessionController = controller
        let reports = ReportLog()
        coordinator.onSessionsLost = { reports.items.append($0) }
        return ScriptedCoordinator(coordinator: coordinator, conn: conn, defaults: defaults,
                                   controller: controller, reports: reports)
    }

    static func store(_ defaults: UserDefaults) -> SessionOwnershipStore {
        SessionOwnershipStore(keyPrefix: keyPrefix, deviceId: DeviceIdentifier().currentID, defaults: defaults)
    }

    /// The baseline as persisted right now (read from disk, not a cache).
    var persistedBaseline: SessionBaseline? { Self.store(defaults).loadBaseline() }

    /// Answer `session_list` with `owned` and `session_list_all` with `all`.
    func script(owned: [SessionInfo], all: [SessionInfo] = []) {
        conn.autoRespond = { message in
            switch message.typeString {
            case "session_list": return .sessionList(sessions: owned)
            case "session_list_all": return .sessionListAll(sessions: all)
            default: return nil
            }
        }
    }

    var listAllCount: Int { conn.sentTypes.filter { $0 == "session_list_all" }.count }
    var listCount: Int { conn.sentTypes.filter { $0 == "session_list" }.count }
}

@MainActor
final class ReportLog {
    var items: [SessionLossReport] = []
}

func lossInfo(_ id: UUID, token: String = "me", state: SessionState = .activeDetached) -> SessionInfo {
    SessionInfo(id: id, name: nil, state: state, tokenId: token,
                createdAt: Date(timeIntervalSince1970: 0), cols: 80, rows: 24)
}

/// Polls until `condition` holds; fails the test on timeout.
@MainActor
func pollUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("timed out waiting for \(description)", file: file, line: line)
}

/// A one-shot gate: `wait()` parks until `open()`; `isWaiting` says a caller is parked.
@MainActor
final class TestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    var isWaiting: Bool { !waiters.isEmpty }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume() }
    }
}
