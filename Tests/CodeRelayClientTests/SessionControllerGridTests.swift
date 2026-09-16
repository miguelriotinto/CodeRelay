import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// attach/resume carry the device grid so the server can resize the PTY before
/// it replays and repaints (the session-switch garble fix).
@MainActor
final class SessionControllerGridTests: SessionControllerTestCase {

    func testResumeSendsTheGridItWasGiven() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        let target = UUID()
        let request = Task {
            try await controller.resumeSession(id: target, skipReplay: true, cols: 100, rows: 30)
        }
        await waitUntil("the resume to send") { conn.sentTypes == ["session_resume"] }
        guard case .sessionResume(let id, let skip, let cols, let rows) = conn.sentMessages[0] else {
            XCTFail("expected session_resume"); return
        }
        XCTAssertEqual(id, target)
        XCTAssertTrue(skip)
        XCTAssertEqual(cols, 100)
        XCTAssertEqual(rows, 30)
        conn.deliver(.sessionResumed(sessionId: target))
        _ = try await request.value
    }

    func testAttachSendsTheGridItWasGiven() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        let target = UUID()
        let request = Task { try await controller.attachSession(id: target, cols: 80, rows: 24) }
        await waitUntil("the attach to send") { conn.sentTypes == ["session_attach"] }
        guard case .sessionAttach(let id, let cols, let rows) = conn.sentMessages[0] else {
            XCTFail("expected session_attach"); return
        }
        XCTAssertEqual(id, target)
        XCTAssertEqual(cols, 80)
        XCTAssertEqual(rows, 24)
        conn.deliver(.sessionAttached(sessionId: target, state: "active-attached"))
        _ = try await request.value
    }

    func testAttachWithoutAGridSendsNone() async throws {
        let conn = FakeConnection()
        let controller = SessionController(connection: conn)
        let target = UUID()
        let request = Task { try await controller.attachSession(id: target) }
        await waitUntil("the attach to send") { conn.sentTypes == ["session_attach"] }
        guard case .sessionAttach(_, let cols, let rows) = conn.sentMessages[0] else {
            XCTFail("expected session_attach"); return
        }
        XCTAssertNil(cols)
        XCTAssertNil(rows)
        conn.deliver(.sessionAttached(sessionId: target, state: "active-attached"))
        _ = try await request.value
    }
}
