import XCTest
import Foundation
import ClaudeRelayKit
@testable import ClaudeRelayServer

/// The scenarios of `UnattachedRequestReplyTests` and `ReplayRepaintTests`,
/// driven over the wire by `TestWebSocketClient` (`docs/linux-server-spec.md`
/// AD-8). The rule under test is the server's: a fire-and-forget request that
/// lands while nothing is attached must be DROPPED, not answered with `.error`
/// — see the top of `Sources/ClaudeRelayServer/Network/SessionRequestHandlers.swift`.
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
    /// Authenticated but never attached, both must draw no reply at all.
    func testUnattachedResizeAndRefreshAreDroppedNotErrored() async throws {
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
        try await client.send(.sessionAttach(sessionId: UUID()))
        do {
            try await client.waitFor(["session_attached"])
            XCTFail("attaching a nonexistent session must fail")
        } catch let error as TestWebSocketClient.ReplyError {
            XCTAssertTrue(error.message.contains("Attach failed"), "got: \(error)")
        }
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
