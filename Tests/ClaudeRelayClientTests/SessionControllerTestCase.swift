import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

/// Test double for `ConnectionSurface`. `autoRespond` answers a request
/// synchronously inside `send`, exercising the "reply beats the await" path the
/// real code defends against; `deliver` feeds the installed subscribers
/// out-of-band, after the awaiter has parked.
@MainActor
final class FakeConnection: ConnectionSurface {
    var generation: UInt64 = 7

    /// Whether a socket is up. Mutable so a test can model the receive-loop
    /// failure that drops the socket WITHOUT bumping `generation`.
    var isConnected = true

    var sentMessages: [ClientMessage] = []
    var autoRespond: ((ClientMessage) -> ServerMessage?)?

    private var subscribers: [UUID: (ServerMessage) -> Void] = [:]

    func send(_ message: ClientMessage) async throws {
        sentMessages.append(message)
        if let response = autoRespond?(message) { deliver(response) }
    }

    @discardableResult
    func addServerMessageSubscriber(_ handler: @escaping (ServerMessage) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }

    /// Fans `message` out to every installed subscriber (out-of-band delivery).
    func deliver(_ message: ServerMessage) {
        for handler in subscribers.values { handler(message) }
    }

    var sentTypes: [String] { sentMessages.map(\.typeString) }
}

/// Records an RPC's outcome so a test can assert it has NOT resolved yet —
/// a `Task`'s result can only be observed by awaiting it, which would hang.
@MainActor
final class Outcome<T> {
    var value: T?
    var error: Error?

    func capture(_ body: @MainActor () async throws -> T) async {
        do { value = try await body() } catch { self.error = error }
    }
}

/// Shared harness for the `SessionController` correlation suites.
///
/// Extracted from `SessionControllerTests` when that file outgrew SwiftLint's
/// `file_length` ceiling — same move, and same reason, as the server's
/// `SessionRequestHandlers.swift`. The subclasses are split by *topic* rather
/// than by size, so a new correlation rule has an obvious home: this one holds
/// only the doubles and the two timing primitives every subclass needs.
@MainActor
class SessionControllerTestCase: XCTestCase {

    /// Polls until `condition` holds, then returns; fails the test on timeout.
    ///
    /// Deliberately condition-based. An earlier version yielded a fixed number of
    /// times, which is a timing assumption dressed up as a barrier: `Task.yield()`
    /// hands control to whatever is queued on the executor, so once any test in
    /// the suite scheduled timed work, the yields were spent elsewhere and an RPC
    /// that was merely *slow* read as "never sent". It passed alone and failed in
    /// the suite.
    func waitUntil(
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

    /// A bounded quiet period, for asserting something has NOT happened. There is
    /// no sound way to prove a negative here, so this gives pending work a real
    /// chance to run first and is named for what it is. Kept well under the
    /// response timeout so no test trips it accidentally.
    func quiesce() async {
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<20 { await Task.yield() }
    }

    func makeSession(id: UUID) -> SessionInfo {
        SessionInfo(
            id: id,
            name: "on-other-device",
            state: .activeDetached,
            tokenId: "other",
            createdAt: Date(timeIntervalSince1970: 0),
            cols: 80,
            rows: 24
        )
    }
}
