import XCTest
import Foundation
import NIO
import NIOPosix
import ClaudeRelayKit
@testable import ClaudeRelayServer
@testable import ClaudeRelayClient

/// The server half of the unattached-request reply rule: a fire-and-forget
/// request that lands while nothing is attached must be DROPPED, not answered
/// with `.error`. See the rule at the top of
/// `Sources/ClaudeRelayServer/Network/SessionRequestHandlers.swift`.
///
/// Split out of `WebSocketIntegrationTests`, which was already over SwiftLint's
/// `file_length` and `type_body_length` ceilings; a topical file also gives the
/// next unattached-handler case an obvious home.
final class UnattachedRequestReplyTests: XCTestCase {

    /// Regression: a fire-and-forget request that arrives while nothing is
    /// attached must be DROPPED, not answered with `.error`.
    ///
    /// `resize` has no waiter — the client sends it from a `Task` and never reads a
    /// reply. Replies carry no request ids, so `SessionController.awaitResponse`
    /// accepts `error` for every RPC; an `.error` addressed to nobody therefore
    /// resolves whichever RPC is in flight. That is how a session switch failed:
    /// the coordinator publishes the new selection before its RPCs, so the incoming
    /// terminal lays out and reports its grid while `session_resume` is still on the
    /// wire and the handler is briefly unattached. The resize drew
    /// `error(400, "No session attached")`, the resume waiter took it, and the pane
    /// rolled back behind an "Unexpected server response: No session attached"
    /// toast.
    ///
    /// Asserted on the raw server-message stream rather than through an RPC, so it
    /// pins the SERVER's behaviour and cannot be satisfied by the client-side
    /// `isForeignError` filter that backstops it for un-rebuilt servers.
    @MainActor
    func testUnattachedResizeAndRefreshAreDroppedNotErrored() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationUnattached-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 19_000..<20_000)
        config.adminPort = UInt16.random(in: 20_000..<21_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "unattached")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore,
            pairingStore: PairingCodeStore()
        )
        try await server.start()
        defer { Task { try? await server.stop() } }
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "unattached", host: "127.0.0.1", port: config.wsPort)

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)

        // Subscribe AFTER auth so `auth_success` isn't in the recording, and
        // before the sends so nothing can slip past.
        var received: [ServerMessage] = []
        connection.addServerMessageSubscriber { received.append($0) }

        // Authenticated, but never attached — the same handler state a resize hits
        // when it races a session switch.
        try await connection.sendResize(cols: 120, rows: 40)
        try await connection.sendRefresh()

        // Give a reply real time to arrive; asserting a negative needs it.
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(
            received.isEmpty,
            "unattached resize/refresh must draw no reply at all, got: \(received.map(\.typeString))"
        )

        // The rule is about unaddressed errors, not about silence in general: an
        // attach that genuinely fails still has a waiter the error belongs to.
        do {
            try await controller.attachSession(id: UUID())
            XCTFail("attaching a nonexistent session must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("Attach failed"), "got: \(error)")
        }

        connection.disconnect()
    }

    /// The other half of the rule: `paste_image` is fire-and-forget too, but it has
    /// a dedicated failure reply, so it must answer `.pasteImageResult(success:
    /// false)` rather than either `.error` or silence.
    ///
    /// Worth its own test because it is the one handler whose reply *type* changed.
    /// The resize/refresh cases above assert an absence, which a revert to `.error`
    /// would break loudly; a revert here swaps one present reply for another, and
    /// nothing else in the suite would notice.
    @MainActor
    func testUnattachedPasteImageRepliesWithFailureResultNotError() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationPaste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 21_000..<22_000)
        config.adminPort = UInt16.random(in: 22_000..<23_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "unattached-paste")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore,
            pairingStore: PairingCodeStore()
        )
        try await server.start()
        defer { Task { try? await server.stop() } }
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "unattached-paste", host: "127.0.0.1", port: config.wsPort)

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)

        var received: [ServerMessage] = []
        connection.addServerMessageSubscriber { received.append($0) }

        // A 1x1 transparent PNG — valid base64, but nothing is attached.
        try await connection.sendPasteImage(
            base64Data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
        )
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(
            received.map(\.typeString), ["paste_image_result"],
            "unattached paste_image must answer with its own failure reply, got: \(received.map(\.typeString))"
        )
        guard case .pasteImageResult(let success)? = received.first else {
            return XCTFail("expected a paste_image_result, got: \(received.map(\.typeString))")
        }
        XCTAssertFalse(success, "an unattached paste cannot have succeeded")

        connection.disconnect()
    }

    /// `rename` and `terminate` LOOK like request-response but are fire-and-forget
    /// on both clients (bare `connection.send`, no `sendAndWaitForResponse`), so a
    /// failure must be dropped rather than answered with `.error`.
    ///
    /// Both failure paths are reachable in production: a stale sidebar row targets a
    /// session that was purged or stolen, giving `.notFound` / `.ownershipViolation`.
    /// Terminate is the sharper case — `SharedSessionCoordinator` sends it and then
    /// immediately calls `fetchSessions()`, putting a `session_list` waiter in flight
    /// exactly when the error would land. Neither message could be filtered
    /// client-side either: `"Rename failed: …"` is indistinguishable from a
    /// legitimate reply, so unlike the resize race there is no second layer here.
    @MainActor
    func testUnknownSessionRenameAndTerminateAreDroppedNotErrored() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSIntegrationRenameTerm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var config = RelayConfig.default
        config.wsPort = UInt16.random(in: 23_000..<24_000)
        config.adminPort = UInt16.random(in: 24_000..<25_000)

        let tokenStore = TokenStore(directory: tempDir)
        let (plaintext, _) = try await tokenStore.create(label: "unattached-rename")

        let sessionManager = SessionManager(
            config: config,
            tokenStore: tokenStore,
            ptyFactory: { id, cols, rows, scrollback in
                MockPTYSession(sessionId: id, cols: cols, rows: rows, scrollbackSize: scrollback)
            }
        )

        let server = WebSocketServer(
            group: group, config: config,
            sessionManager: sessionManager, tokenStore: tokenStore,
            pairingStore: PairingCodeStore()
        )
        try await server.start()
        defer { Task { try? await server.stop() } }
        try? await Task.sleep(for: .milliseconds(100))

        let connection = RelayConnection()
        let controller = SessionController(connection: connection)
        let clientConfig = ConnectionConfig(name: "unattached-rename", host: "127.0.0.1", port: config.wsPort)

        try await connection.connect(config: clientConfig, token: plaintext)
        try await controller.authenticate(token: plaintext)

        var received: [ServerMessage] = []
        connection.addServerMessageSubscriber { received.append($0) }

        // Neither session exists, so both hit their `onFailure` path.
        try await connection.send(.sessionRename(sessionId: UUID(), name: "ghost"))
        try await connection.send(.sessionTerminate(sessionId: UUID()))
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(
            received.isEmpty,
            "a failed rename/terminate must draw no reply at all, got: \(received.map(\.typeString))"
        )

        connection.disconnect()
    }
}
