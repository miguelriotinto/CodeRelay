import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

/// Test double for `ConnectionSurface`. `autoRespond` answers a request
/// synchronously inside `send`, exercising the "reply beats the await" path the
/// real code defends against; `deliver` feeds the installed subscribers
/// out-of-band, after the awaiter has parked.
@MainActor
private final class FakeConnection: ConnectionSurface {
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
private final class Outcome<T> {
    var value: T?
    var error: Error?

    func capture(_ body: @MainActor () async throws -> T) async {
        do { value = try await body() } catch { self.error = error }
    }
}

/// Regression suite for the request/response correlation in `SessionController`
/// — the transport-level defect underneath the "empty pane" family of bugs.
///
/// Kotlin mirror: core-net `SessionControllerTest`. Both drive the real
/// controller over a fake surface, so a correlation rule that regresses on one
/// client can't quietly pass on the other.
@MainActor
final class SessionControllerTests: XCTestCase {

    /// Swift has no virtual clock here, so tests hand control back to the
    /// scheduler a few times to let the RPC tasks reach their next await. Never
    /// long enough to reach the 10 s response timeout — no test relies on it.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func makeSession(id: UUID) -> SessionInfo {
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

    // MARK: - Serialization (the invariant that closes the `error` window)

    /// Type-scoping shrinks the cross-delivery window but cannot close it,
    /// because `error` is a legal reply to EVERY request: two overlapping RPCs
    /// always share at least one possible reply type. The controller therefore
    /// serializes — at most one request-response RPC outstanding per connection.
    ///
    /// Proven structurally rather than by outcome: while the first RPC is parked,
    /// the second must not even have SENT, so there is no second subscriber for a
    /// reply to land in. That is what makes the property hold for `error` too,
    /// which no amount of type-scoping can.
    func testSecondRPCDoesNotStartUntilTheFirstHasAnswered() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        let created = UUID()

        let listOutcome = Outcome<[SessionInfo]>()
        let createOutcome = Outcome<UUID>()

        let first = Task { await listOutcome.capture { try await controller.listSessions() } }
        await settle()
        XCTAssertEqual(conn.sentTypes, ["session_list"], "the first RPC should have sent and parked")

        let second = Task { await createOutcome.capture { try await controller.createSession(name: "queued") } }
        await settle()
        XCTAssertEqual(
            conn.sentTypes, ["session_list"],
            "the second RPC must wait for the first: no overlapping request on the wire"
        )

        // A reply for the QUEUED request arrives while the first is still
        // outstanding. With one waiter installed it cannot be mis-consumed — and,
        // crucially, an `error` here would not resolve the parked list either.
        conn.deliver(.sessionCreated(sessionId: created, cols: 80, rows: 24))
        await settle()
        XCTAssertNil(listOutcome.value, "session_created must not resolve a parked session_list")
        XCTAssertNil(listOutcome.error, "...nor fail it")
        XCTAssertNil(createOutcome.value, "the queued RPC hasn't sent, so it cannot have resolved")

        conn.deliver(.sessionList(sessions: []))
        await first.value
        XCTAssertEqual(listOutcome.value?.count, 0)

        // The queue released: the second RPC now sends and takes its own reply.
        await settle()
        XCTAssertEqual(conn.sentTypes, ["session_list", "session_create"])
        conn.deliver(.sessionCreated(sessionId: created, cols: 80, rows: 24))
        await second.value
        XCTAssertEqual(createOutcome.value, created)
    }

    /// The Swift-specific hazard in that queue: it is a chain of tasks, and each
    /// link awaits its predecessor's `result` — deliberately NOT its `value`.
    /// Awaiting `value` would rethrow a failed predecessor's error into every
    /// request behind it, so one transient error would fail an unbounded run of
    /// unrelated RPCs (the blank-pane failure mode, with a new cause).
    func testAFailedRPCReleasesTheQueueInsteadOfPoisoningIt() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        let created = UUID()

        // The list fails at the protocol level; the create gets no canned reply
        // and so parks until we deliver one out-of-band.
        conn.autoRespond = { message in
            message.typeString == "session_list" ? .error(code: 500, message: "boom") : nil
        }

        let listOutcome = Outcome<[SessionInfo]>()
        let createOutcome = Outcome<UUID>()

        let first = Task { await listOutcome.capture { try await controller.listSessions() } }
        await settle()
        let second = Task {
            await createOutcome.capture { try await controller.createSession(name: "behind a failure") }
        }
        await first.value
        await settle()

        XCTAssertNotNil(listOutcome.error, "an `error` reply must fail the list")
        XCTAssertEqual(
            conn.sentTypes, ["session_list", "session_create"],
            "a predecessor that threw must release the queue, not fail what's behind it"
        )
        conn.deliver(.sessionCreated(sessionId: created, cols: 80, rows: 24))
        await second.value
        XCTAssertEqual(createOutcome.value, created)
        XCTAssertNil(createOutcome.error, "the successor must not inherit its predecessor's error")
    }

    // MARK: - Type scoping (the second half of the correlation story)

    /// Regression: cross-device "No Sessions Available". A parallel
    /// `fetchSessions` (`session_list`) and this `listAllSessions`
    /// (`session_list_all`) ran at once; both waiters accepted BOTH reply types,
    /// so `listAllSessions` grabbed the `session_list_result`, failed its type
    /// check and returned empty. Even with the queue in place, a *pushed* message
    /// or a late reply from an RPC that already timed out can still land here —
    /// so the waiter must match only its own type.
    func testListAllSessionsIgnoresAStraySessionListResult() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        let wanted = makeSession(id: UUID())

        let outcome = Outcome<[SessionInfo]>()
        let request = Task { await outcome.capture { try await controller.listAllSessions() } }
        await settle()

        conn.deliver(.sessionList(sessions: []))
        await settle()
        XCTAssertNil(outcome.value, "listAllSessions must not resolve on session_list_result")
        XCTAssertNil(outcome.error, "...nor fail its type check on it")

        conn.deliver(.sessionListAll(sessions: [wanted]))
        await request.value
        XCTAssertEqual(outcome.value?.map(\.id), [wanted.id])
    }

    /// A redundant auth on an already-authenticated socket draws
    /// `error(400, "Already authenticated")`. That is a client/server auth-state
    /// desync, not a failure — the controller must adopt the authenticated state
    /// or session creation stays blocked ("Unexpected server response: error").
    func testAuthenticateTreats400AlreadyAuthenticatedAsSuccess() async throws {
        let conn = FakeConnection()
        conn.autoRespond = { _ in .error(code: 400, message: "Already authenticated") }
        let controller = SessionController(connection: conn)

        try await controller.authenticate(token: "tok")

        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertEqual(controller.authenticatedGeneration, conn.generation)
    }

    /// Any other error (rate-limit 429, auth timeout 401, server 500) is a real
    /// failure — the server's actual message must surface, not the type string.
    func testAuthenticateSurfacesRealMessageOnNon400Error() async {
        let conn = FakeConnection()
        conn.autoRespond = { _ in .error(code: 429, message: "Too many failed attempts") }
        let controller = SessionController(connection: conn)

        do {
            try await controller.authenticate(token: "tok")
            XCTFail("a 429 must not be treated as success")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("Too many failed attempts"),
                "expected the server's message, got: \(error)"
            )
        }
        XCTAssertFalse(controller.isAuthenticated)
    }

    // MARK: - Auth validity

    /// A receive-loop failure nils the socket but does NOT bump the generation,
    /// so a generation-only `isAuthValid` reported "authenticated" over a socket
    /// that was already gone. The RPC then threw `notConnected` — which
    /// `withAuth` does not retry — a silent dead end that showed up as a blank
    /// session pane. Auth validity must require a live socket so the handshake
    /// reconnects first.
    func testAuthValidityRequiresALiveSocketNotJustAMatchingGeneration() async throws {
        let conn = FakeConnection()
        conn.autoRespond = { _ in .authSuccess(protocolVersion: 1, tokenId: "tok") }
        let controller = SessionController(connection: conn)

        XCTAssertFalse(controller.isAuthValid, "never authenticated → invalid")

        try await controller.authenticate(token: "tok")
        XCTAssertTrue(controller.isAuthValid, "authenticated on the current, live connection")

        conn.isConnected = false
        XCTAssertEqual(controller.authenticatedGeneration, conn.generation, "generation still matches")
        XCTAssertFalse(controller.isAuthValid, "no live socket → invalid regardless of generation")
    }

    // MARK: - State, error classification and descriptions
    //
    // (Moved here from RelayConnectionTests.swift, which had grown a second
    // suite; the controller now has a file of its own.)

    // MARK: - Auth State

    func testIsAuthValidInitiallyFalse() {
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        XCTAssertFalse(controller.isAuthValid)
    }

    func testResetAuthClearsState() {
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        controller.resetAuth()
        XCTAssertFalse(controller.isAuthenticated)
        XCTAssertNil(controller.sessionId)
    }

    func testIsAuthValidFalseAfterReset() {
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        controller.resetAuth()
        XCTAssertFalse(controller.isAuthValid)
    }

    // MARK: - Error Classification

    func testSessionErrorIsNotAuthenticatedDetection() {
        let notAuth = SessionController.SessionError.unexpectedResponse("Not authenticated")
        XCTAssertTrue(notAuth.isNotAuthenticated)

        let notAuthCase = SessionController.SessionError.unexpectedResponse("not authenticated yet")
        XCTAssertTrue(notAuthCase.isNotAuthenticated)

        let other = SessionController.SessionError.unexpectedResponse("Session not found")
        XCTAssertFalse(other.isNotAuthenticated)

        let authFailed = SessionController.SessionError.authenticationFailed(reason: "bad token")
        XCTAssertFalse(authFailed.isNotAuthenticated)

        let timeout = SessionController.SessionError.timeout
        XCTAssertFalse(timeout.isNotAuthenticated)
    }

    // MARK: - Error Descriptions

    func testSessionErrorDescriptions() {
        let authFailed = SessionController.SessionError.authenticationFailed(reason: "invalid token")
        XCTAssertNotNil(authFailed.errorDescription)
        XCTAssertTrue(authFailed.errorDescription!.contains("invalid token"))

        let versionMismatch = SessionController.SessionError.versionIncompatible(clientVersion: 1, serverVersion: 0)
        XCTAssertNotNil(versionMismatch.errorDescription)
        XCTAssertTrue(versionMismatch.errorDescription!.contains("not compatible"))

        let unexpected = SessionController.SessionError.unexpectedResponse("weird_type")
        XCTAssertNotNil(unexpected.errorDescription)
        XCTAssertTrue(unexpected.errorDescription!.contains("weird_type"))

        let timeout = SessionController.SessionError.timeout
        XCTAssertNotNil(timeout.errorDescription)
        XCTAssertTrue(timeout.errorDescription!.contains("timed out"))
    }

    // MARK: - Generation Staleness

    func testAuthenticatedGenerationTracksConnectionGeneration() {
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        XCTAssertEqual(controller.authenticatedGeneration, 0)
        XCTAssertEqual(connection.generation, 0)
    }

    // MARK: - Authenticate Error Paths

    /// Authenticating before the transport is connected must throw and leave
    /// the controller unauthenticated — never silently "succeed" against a
    /// missing socket.
    func testAuthenticateThrowsWhenNotConnected() async {
        let connection = RelayConnection()
        let controller = SessionController(connection: connection)

        do {
            try await controller.authenticate(token: "any-token")
            XCTFail("Expected an error when authenticating before connect()")
        } catch {
            // Any thrown error is acceptable here — the contract is that the
            // call must not return normally. We additionally guarantee the
            // controller stays unauthenticated.
            XCTAssertFalse(controller.isAuthenticated,
                           "Controller should remain unauthenticated after failed send")
            XCTAssertFalse(controller.isAuthValid)
        }
    }
}
