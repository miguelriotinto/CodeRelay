import XCTest
@testable import ClaudeRelayClient
@testable import ClaudeRelayKit

/// The one `error` a waiter can prove isn't its own.
///
/// Replies carry no request ids, so `awaitResponse` accepts `error` for every RPC
/// — an `error` produced by a request nobody is awaiting therefore resolves
/// whichever RPC happens to be in flight. `"No session attached"` is the single
/// case where the message itself is proof of misdelivery: server-side only
/// unattached-request handlers emit it, and of those only `detach` has a waiter.
///
/// Kotlin mirror: the three matching cases in core-net `SessionControllerTest`.
/// Both drive the real controller over a fake surface, so a rule that regresses
/// on one client can't quietly pass on the other.
@MainActor
final class SessionControllerForeignErrorTests: SessionControllerTestCase {

    /// A session switch is `detach` then `resume`, and the incoming terminal view
    /// lays out and reports its grid while `resume` is still on the wire — the
    /// coordinator publishes the new selection *before* its RPCs, so this is the
    /// common path, not an edge case. That `resize` is fire-and-forget, and an old
    /// server answers it `error(400, "No session attached")` when it arrives in the
    /// unattached window. With `error` accepted unconditionally, the resume waiter
    /// took it, `resumeSession` threw, and the pane rolled back to the previous
    /// session behind an "Unexpected server response: No session attached" toast.
    ///
    /// Servers from this commit on don't send it at all (see the unattached-request
    /// reply rule atop the server's `SessionRequestHandlers.swift`), but the app
    /// can't assume the server has been rebuilt — so the client must reject it too.
    func testResumeIgnoresANoSessionAttachedErrorMeantForAnotherRequest() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        let target = UUID()

        let outcome = Outcome<Void>()
        let request = Task {
            await outcome.capture { try await controller.resumeSession(id: target, skipReplay: true) }
        }
        await waitUntil("the resume to send and park") { conn.sentTypes == ["session_resume"] }

        // The concurrent fire-and-forget resize's error, from an un-rebuilt server.
        conn.deliver(.error(code: 400, message: "No session attached"))
        await quiesce()
        XCTAssertNil(outcome.error, "resume must not fail on an error addressed to nobody")

        conn.deliver(.sessionResumed(sessionId: target))
        await request.value
        XCTAssertNil(outcome.error)
        XCTAssertEqual(controller.sessionId, target)
    }

    /// The narrowness is the safety property. Only this exact message is ignored,
    /// and only for waiters it cannot belong to — a resume that genuinely failed
    /// answers `"Resume failed: …"` and must still surface, or a real failure turns
    /// into a 10 s timeout that poisons the socket.
    func testResumeStillFailsOnItsOwnError() async {
        let conn = FakeConnection()
        conn.autoRespond = { _ in .error(code: 404, message: "Resume failed: sessionNotFound") }
        let controller = SessionController(connection: conn)

        do {
            try await controller.resumeSession(id: UUID(), skipReplay: false)
            XCTFail("a real resume failure must not be swallowed")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("Resume failed"),
                "expected the server's message, got: \(error)"
            )
        }
    }

    /// `detach` is the ONE request for which "No session attached" is genuinely
    /// addressed — it's a request-response call with a real waiter, and the server
    /// still replies that way when nothing is attached. Filtering it there would
    /// hang the waiter to its timeout, which poisons the socket.
    func testDetachStillFailsOnNoSessionAttached() async {
        let conn = FakeConnection()
        conn.autoRespond = { _ in .error(code: 400, message: "No session attached") }
        let controller = SessionController(connection: conn)

        do {
            try await controller.detach()
            XCTFail("detach must surface its own No-session-attached error")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("No session attached"),
                "expected the server's message, got: \(error)"
            )
        }
    }
}
