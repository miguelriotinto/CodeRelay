import XCTest
import Foundation
import NIO
import NIOPosix
import CodeRelayKit
@testable import CodeRelayServer
@testable import CodeRelayClient

/// Integration coverage for the attach/resume grid (the "garbled after
/// switching sessions" fix): a grid carried on `session_attach` /
/// `session_resume` is applied to the PTY before the ring buffer is read and
/// before the post-replay repaint, and a `resize` that arrives while the
/// connection is unattached is deferred into `pendingGrid` rather than
/// dropped. Split from `ReplayRepaintTests`, which is at its SwiftLint length
/// ceiling. `MockPTYSession` is shared from `SessionManagerTestCase.swift`.
final class AttachGridTests: XCTestCase {

    private struct Fixture {
        let controller: SessionController
        let connection: RelayConnection
        let mockPTY: MockPTYSession
        let sessionId: UUID
        let sessionManager: SessionManager
        let server: WebSocketServer
        let group: MultiThreadedEventLoopGroup
        let tempDir: URL

        /// The same four things `ReplayRepaintTests` does with `defer`.
        @MainActor
        func teardown() {
            connection.disconnect()
            let server = self.server
            Task { try? await server.stop() }
            try? group.syncShutdownGracefully()
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// A running server with one detached mock-PTY session, plus an
    /// authenticated (but unattached) client connection to it.
    @MainActor
    private func makeFixture() async throws -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationAttachGrid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, tokenInfo) = try await tokenStore.create(label: "attach-grid")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let sessionInfo = try await sessionManager.createSession(tokenId: tokenInfo.id, name: "attach-grid-test")
        let (_, pty) = try await sessionManager.attachSession(id: sessionInfo.id, tokenId: tokenInfo.id)
        let mockPTY = try XCTUnwrap(pty as? MockPTYSession)
        try await sessionManager.detachSession(id: sessionInfo.id)

        let server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore,
            pairingStore: PairingCodeStore()
        )
        try await server.start()
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "attach-grid", host: "127.0.0.1", port: config.wsPort)

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)

        return Fixture(
            controller: controller, connection: connection, mockPTY: mockPTY,
            sessionId: sessionInfo.id, sessionManager: sessionManager,
            server: server, group: group, tempDir: tempDir
        )
    }

    /// Attach with a grid: the PTY is resized to it BEFORE the ring buffer is
    /// read and BEFORE the post-replay repaint, so both the replayed bytes'
    /// re-wrap and the SIGWINCH redraw happen at the requesting device's width.
    @MainActor
    func testAttachWithGridResizesBeforeReplayAndRepaint() async throws {
        let f = try await makeFixture()
        defer { f.teardown() }

        try await f.controller.attachSession(id: f.sessionId, cols: 100, rows: 30)
        try? await Task.sleep(for: .milliseconds(200))

        let calls = await f.mockPTY.resizeCalls
        XCTAssertEqual(calls.map { [$0.cols, $0.rows] }, [[100, 30]])
        let readAfter = await f.mockPTY.readBufferSawResize
        XCTAssertTrue(readAfter, "the ring buffer must be read after the resize")
        let repaintAfter = await f.mockPTY.forceRepaintSawResize
        XCTAssertTrue(repaintAfter, "the repaint must fire after the resize, or it redraws at the stale width")
    }

    /// Resume with a grid behaves the same (this is the session-switch path).
    @MainActor
    func testResumeWithGridResizesBeforeReplay() async throws {
        let f = try await makeFixture()
        defer { f.teardown() }

        try await f.controller.resumeSession(id: f.sessionId, skipReplay: true, cols: 90, rows: 40)
        try? await Task.sleep(for: .milliseconds(200))

        let calls = await f.mockPTY.resizeCalls
        XCTAssertEqual(calls.map { [$0.cols, $0.rows] }, [[90, 40]])
        let repaintAfter = await f.mockPTY.forceRepaintSawResize
        XCTAssertTrue(repaintAfter)
    }

    /// A resize that arrives while the connection is unattached (the incoming
    /// terminal view laying out during a switch) is deferred, not dropped: the
    /// next attach/resume without its own grid applies it. Nothing is replied
    /// (no resize_ack, no error) — the unattached-request reply rule.
    @MainActor
    func testResizeWhileUnattachedIsAppliedByTheNextAttach() async throws {
        let f = try await makeFixture()
        defer { f.teardown() }

        try await f.connection.sendResize(cols: 77, rows: 21)
        try? await Task.sleep(for: .milliseconds(100))
        let before = await f.mockPTY.resizeCalls
        XCTAssertTrue(before.isEmpty, "unattached: nothing to resize yet")

        try await f.controller.attachSession(id: f.sessionId)   // no grid on the request
        try? await Task.sleep(for: .milliseconds(200))

        let calls = await f.mockPTY.resizeCalls
        XCTAssertEqual(calls.map { [$0.cols, $0.rows] }, [[77, 21]], "the deferred grid must be applied at attach")
        let readAfter = await f.mockPTY.readBufferSawResize
        XCTAssertTrue(readAfter)
    }

    /// `session_create` ends attached too, so it consumes a deferred grid like
    /// attach/resume do — otherwise a resize that landed while the create was
    /// in flight would sit in `pendingGrid` and be applied stale much later.
    @MainActor
    func testResizeWhileUnattachedIsAppliedByTheNextCreate() async throws {
        let f = try await makeFixture()
        defer { f.teardown() }

        try await f.connection.sendResize(cols: 77, rows: 21)
        try? await Task.sleep(for: .milliseconds(100))

        let newId = try await f.controller.createSession(name: "created", cols: 80, rows: 24)
        try? await Task.sleep(for: .milliseconds(200))

        let createdPTY = await f.sessionManager.ptySession(for: newId)
        let created = try XCTUnwrap(createdPTY as? MockPTYSession)
        let calls = await created.resizeCalls
        XCTAssertEqual(calls.map { [$0.cols, $0.rows] }, [[77, 21]], "create must consume the deferred grid")
        let original = await f.mockPTY.resizeCalls
        XCTAssertTrue(original.isEmpty, "the deferred grid belongs to the connection, not the other session")
    }

    /// The request's own grid wins over a stale deferred one, and the deferred
    /// grid is consumed (not re-applied on a later attach).
    @MainActor
    func testRequestGridBeatsDeferredGridAndConsumesIt() async throws {
        let f = try await makeFixture()
        defer { f.teardown() }

        try await f.connection.sendResize(cols: 77, rows: 21)
        try? await Task.sleep(for: .milliseconds(100))
        try await f.controller.attachSession(id: f.sessionId, cols: 120, rows: 40)
        try? await Task.sleep(for: .milliseconds(200))
        try await f.controller.detach()
        try await f.controller.resumeSession(id: f.sessionId)
        try? await Task.sleep(for: .milliseconds(200))

        let calls = await f.mockPTY.resizeCalls
        XCTAssertEqual(calls.map { [$0.cols, $0.rows] }, [[120, 40]],
                       "only the request grid; the deferred one is neither applied nor replayed later")
    }
}
