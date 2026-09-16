import XCTest
import Foundation
import CodeRelayKit
@testable import CodeRelayServer

/// The scenarios of `UnattachedRequestReplyTests`, `ReplayRepaintTests` and
/// `AttachGridTests`, driven over the wire by `TestWebSocketClient`
/// (`docs/linux-server-spec.md` AD-8). The rule under test is the server's: a
/// fire-and-forget request that lands while nothing is attached must go
/// UNANSWERED — `refresh` is dropped, `resize` is deferred into `pendingGrid`
/// and applied by the next attach/resume/create — and never be answered with
/// `.error`. See the top of
/// `Sources/CodeRelayServer/Network/SessionRequestHandlers.swift`.
/// Asserting on raw frames pins the SERVER's behaviour, which a client-side
/// `isForeignError` filter could otherwise mask.
final class WireRequestReplyTests: XCTestCase {

    private func typeStrings(_ events: [TestWebSocketClient.Event]) -> [String] {
        events.map { event in
            switch event {
            case .binary: return "binary"
            case .message(let message): return message.typeString
            case .closed: return "closed"
            }
        }
    }

    /// `resize` and `refresh` have no waiter; an `.error` addressed to nobody
    /// would resolve whichever RPC is in flight (the session-switch rollback bug).
    /// Authenticated but never attached, both must draw no reply at all — the
    /// `refresh` is dropped, the `resize` is deferred (see the next test).
    func testUnattachedResizeAndRefreshAreUnansweredNotErrored() async throws {
        let fixture = try WireTestServer()
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "unattached")
        let client = try await fixture.authenticatedClient(token: token)

        try await client.send(.resize(cols: 120, rows: 40))
        try await client.send(.refresh)

        // Give a reply real time to arrive; asserting a negative needs it.
        let received = typeStrings(await client.drain(idle: .milliseconds(300)))
        XCTAssertTrue(received.isEmpty, "unattached resize/refresh must draw no reply at all, got: \(received)")

        // The rule is about unaddressed errors, not about silence in general: an
        // attach that genuinely fails still has a waiter the error belongs to.
        // This also exercises "a failed attach consumes the deferred grid":
        // `takeGrid` runs before the attach is attempted, so the 120x40 deferred
        // above is gone whether or not the attach succeeds.
        try await client.send(.sessionAttach(sessionId: UUID()))
        do {
            try await client.waitFor(["session_attached"])
            XCTFail("attaching a nonexistent session must fail")
        } catch let error as TestWebSocketClient.ReplyError {
            XCTAssertTrue(error.message.contains("Attach failed"), "got: \(error)")
        }
        await client.close()
    }

    /// The deferral half of the rule, observable on both platforms: an
    /// unattached `resize` is not lost. A `session_create` WITHOUT its own grid
    /// spawns at the deferred size (reported back in `session_created`), and
    /// the deferred grid is consumed rather than applied again as a resize.
    func testUnattachedResizeBecomesTheNextGridlessCreatesSpawnSize() async throws {
        let fixture = try WireTestServer()
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "deferred-grid-create")
        let client = try await fixture.authenticatedClient(token: token)

        try await client.send(.resize(cols: 57, rows: 21))
        let received = typeStrings(await client.drain(idle: .milliseconds(300)))
        XCTAssertTrue(received.isEmpty, "the deferred resize must draw no reply, got: \(received)")

        try await client.send(.sessionCreate(name: "deferred-grid"))   // no cols/rows on the request
        guard case .sessionCreated(let id, let cols, let rows) = try await client.waitFor(["session_created"]) else {
            return XCTFail("waitFor returned a non-matching message")
        }
        XCTAssertEqual([cols, rows], [57, 21], "a gridless create must spawn at the deferred grid, not 80x24")

        let pty = await fixture.sessionManager.ptySession(for: id)
        let mock = try XCTUnwrap(pty as? MockPTYSession)
        XCTAssertEqual([mock.spawnGrid.cols, mock.spawnGrid.rows], [57, 21])
        let resizes = await mock.resizeCalls
        XCTAssertTrue(resizes.isEmpty, "consumed at spawn — the deferred grid must not land again as a resize")
        await client.close()
    }

    /// The grid carried on `session_attach` itself is applied to the PTY (and
    /// wins over any deferred one — none here). `SessionInfo` keeps the spawn
    /// size, so the resize is observed on the mock PTY, as `AttachGridTests` does.
    func testAttachWithGridResizesThePTY() async throws {
        let fixture = try WireTestServer()
        let (token, tokenInfo) = try await fixture.mintToken(label: "attach-grid")
        let sessionInfo = try await fixture.sessionManager.createSession(tokenId: tokenInfo.id, name: "attach-grid")
        let (_, pty) = try await fixture.sessionManager.attachSession(id: sessionInfo.id, tokenId: tokenInfo.id)
        let mockPTY = try XCTUnwrap(pty as? MockPTYSession)
        try await fixture.sessionManager.detachSession(id: sessionInfo.id)

        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let client = try await fixture.authenticatedClient(token: token)

        try await client.send(.sessionAttach(sessionId: sessionInfo.id, cols: 61, rows: 23))
        try await client.waitFor(["replay_complete"])

        // The resize happens in the attach work closure, before `session_attached`
        // is sent, so by `replay_complete` it has been recorded. Poll anyway
        // rather than sleep: the assertion is on the actor's state.
        var calls = await mockPTY.resizeCalls
        var polls = 0
        while calls.isEmpty, polls < 20 {
            polls += 1
            try? await Task.sleep(for: .milliseconds(50))
            calls = await mockPTY.resizeCalls
        }
        XCTAssertEqual(calls.map { [$0.cols, $0.rows] }, [[61, 23]], "the attach request's grid must be applied")
        let readAfter = await mockPTY.readBufferSawResize
        XCTAssertTrue(readAfter, "the ring buffer must be read after the resize")
        await client.close()
    }

    /// `paste_image` is fire-and-forget too, but it has a dedicated failure
    /// reply, so it must answer `paste_image_result{success:false}` rather than
    /// either `.error` or silence.
    func testUnattachedPasteImageRepliesWithFailureResultNotError() async throws {
        let fixture = try WireTestServer()
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "unattached-paste")
        let client = try await fixture.authenticatedClient(token: token)

        // A 1x1 transparent PNG — valid base64, but nothing is attached.
        try await client.send(.pasteImage(
            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="))

        let received = await client.drain(idle: .milliseconds(300))
        XCTAssertEqual(typeStrings(received), ["paste_image_result"],
            "unattached paste_image must answer with its own failure reply, got: \(typeStrings(received))")
        guard case .message(.pasteImageResult(let success))? = received.first else {
            return XCTFail("expected a paste_image_result, got: \(typeStrings(received))")
        }
        XCTAssertFalse(success, "an unattached paste cannot have succeeded")
        await client.close()
    }

    /// `rename` and `terminate` look like request-response but are fire-and-forget
    /// on every client, so a failure (unknown session) must be dropped rather than
    /// answered with `.error`.
    func testUnknownSessionRenameAndTerminateAreDroppedNotErrored() async throws {
        let fixture = try WireTestServer()
        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let (token, _) = try await fixture.mintToken(label: "unattached-rename")
        let client = try await fixture.authenticatedClient(token: token)

        // Neither session exists, so both hit their `onFailure` path.
        try await client.send(.sessionRename(sessionId: UUID(), name: "ghost"))
        try await client.send(.sessionTerminate(sessionId: UUID()))

        let received = typeStrings(await client.drain(idle: .milliseconds(300)))
        XCTAssertTrue(received.isEmpty, "a failed rename/terminate must draw no reply at all, got: \(received)")
        await client.close()
    }

    /// After a replay (attach or resume), the server must ask the PTY's
    /// foreground app to repaint, and only after the live output handler is
    /// wired — otherwise the redraw bytes go to the ring buffer alone and never
    /// reach this client.
    func testAttachAndResumeForceRepaintAfterOutputIsWired() async throws {
        let fixture = try WireTestServer()
        let (token, tokenInfo) = try await fixture.mintToken(label: "repaint")

        let sessionInfo = try await fixture.sessionManager.createSession(tokenId: tokenInfo.id, name: "repaint-test")
        let (_, pty) = try await fixture.sessionManager.attachSession(id: sessionInfo.id, tokenId: tokenInfo.id)
        let mockPTY = try XCTUnwrap(pty as? MockPTYSession)
        try await fixture.sessionManager.detachSession(id: sessionInfo.id)

        try await fixture.start()
        defer { Task { await fixture.stop() } }
        let client = try await fixture.authenticatedClient(token: token)

        try await client.attach(sessionInfo.id)
        try await client.waitFor(["replay_complete"])
        try? await Task.sleep(for: .milliseconds(200))

        let afterAttach = await mockPTY.forceRepaintCallCount
        XCTAssertEqual(afterAttach, 1, "attach must request exactly one repaint")
        let wiredAtRepaint = await mockPTY.forceRepaintSawOutputHandler
        XCTAssertTrue(wiredAtRepaint,
                      "repaint must fire after the output handler is wired, or the redraw never reaches the client")

        // Detach and resume — the resume replay path must repaint too.
        try await client.detach()
        try await client.resume(sessionInfo.id)
        try await client.waitFor(["replay_complete"])
        try? await Task.sleep(for: .milliseconds(200))

        let afterResume = await mockPTY.forceRepaintCallCount
        XCTAssertEqual(afterResume, 2, "resume must request a repaint as well")
        await client.close()
    }
}
