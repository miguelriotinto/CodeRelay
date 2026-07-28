import Foundation
import ClaudeRelayKit

/// Orchestrates authentication and session lifecycle on top of a `RelayConnection`.
@MainActor
public final class SessionController: ObservableObject {

    // MARK: - Types

    public enum SessionError: Error, LocalizedError {
        case authenticationFailed(reason: String)
        case versionIncompatible(clientVersion: Int, serverVersion: Int)
        case unexpectedResponse(String)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .authenticationFailed(let reason):
                return "Authentication failed: \(reason)"
            case .versionIncompatible:
                return "This app is not compatible with the server version running on the backend."
            case .unexpectedResponse(let detail):
                return "Unexpected server response: \(detail)"
            case .timeout:
                return "The operation timed out."
            }
        }

        var isNotAuthenticated: Bool {
            if case .unexpectedResponse(let msg) = self {
                return msg.localizedCaseInsensitiveContains("not authenticated")
            }
            return false
        }
    }

    // MARK: - Published State

    @Published public private(set) var sessionId: UUID?
    @Published public private(set) var isAuthenticated = false

    /// The authenticated token's server-side id, delivered in `auth_success`.
    /// `nil` against older servers that don't send it (the reconcile logic
    /// falls back to a strictly-safe "retain if still on the server" rule when
    /// this is unknown). Used to tell "my session, transiently missing from the
    /// token-scoped list" from "genuinely moved to another token".
    @Published public private(set) var tokenId: String?

    /// The connection generation when auth was established. Used to detect stale auth
    /// after the WebSocket reconnects (server sees a fresh unauthenticated handler).
    public private(set) var authenticatedGeneration: UInt64 = 0

    // MARK: - Private

    private let connection: RelayConnection

    // MARK: - Init

    public init(connection: RelayConnection) {
        self.connection = connection
    }

    // MARK: - Authentication

    /// Whether the controller is authenticated on the **current** connection.
    /// Returns false if the WebSocket has been replaced since auth was established.
    public var isAuthValid: Bool {
        isAuthenticated && authenticatedGeneration == connection.generation
    }

    /// Resets authentication state so the next operation will re-authenticate.
    /// Call this after the underlying connection has been re-established.
    public func resetAuth() {
        isAuthenticated = false
        sessionId = nil
    }

    /// Sends an authentication request and waits for the server response.
    /// Includes the client's protocol version; checks the server's version on success.
    public func authenticate(token: String) async throws {
        let response = try await sendAndWaitForResponse(
            .authRequest(token: token, protocolVersion: ClaudeRelayKit.protocolVersion),
            expected: ["auth_success", "auth_failure"]
        )

        switch response {
        case .authSuccess(let serverProtocolVersion, let serverTokenId):
            let serverVersion = serverProtocolVersion ?? 0
            if serverVersion < ClaudeRelayKit.minProtocolVersion {
                isAuthenticated = false
                throw SessionError.versionIncompatible(
                    clientVersion: ClaudeRelayKit.protocolVersion,
                    serverVersion: serverVersion
                )
            }
            isAuthenticated = true
            authenticatedGeneration = connection.generation
            // nil against older servers; the coordinator's reconcile falls back
            // to a safe "retain if still on the server" rule when unknown.
            if let serverTokenId { tokenId = serverTokenId }
        case .authFailure(let reason):
            isAuthenticated = false
            throw SessionError.authenticationFailed(reason: reason)
        case .error(let code, let message):
            // The server can reply with `.error` on the auth path. A 400
            // "Already authenticated" means this socket is ALREADY authenticated
            // server-side (a client/server auth-state desync — e.g. a redundant
            // auth after a reconnect where the server still held the socket
            // authenticated). That's not a failure: adopt the authenticated
            // state so session creation proceeds. Without this, the reply fell
            // through to `default` and threw `unexpectedResponse("error")` (the
            // detail is `ServerMessage.error`'s type string, "error"), which
            // surfaced on iOS as "Unexpected server response: error" and blocked
            // session creation. Every other error (rate-limit 429, auth timeout
            // 401, server 500) is a real failure — surface its actual message.
            if code == 400 {
                isAuthenticated = true
                authenticatedGeneration = connection.generation
            } else {
                isAuthenticated = false
                throw SessionError.unexpectedResponse(message)
            }
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    // MARK: - Session Lifecycle

    /// Creates a new terminal session on the server. Returns the session UUID.
    @discardableResult
    public func createSession(name: String? = nil, cols: UInt16? = nil, rows: UInt16? = nil) async throws -> UUID {
        let response = try await sendAndWaitForResponse(
            .sessionCreate(name: name, cols: cols, rows: rows),
            expected: ["session_created"]
        )

        switch response {
        case .sessionCreated(let id, _, _):
            sessionId = id
            return id
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    /// Attaches to a session that may still be active on another connection.
    /// Unlike resume, this does not require the session to be detached first.
    public func attachSession(id: UUID) async throws {
        let response = try await sendAndWaitForResponse(
            .sessionAttach(sessionId: id),
            expected: ["session_attached"]
        )

        switch response {
        case .sessionAttached(let attachedId, _):
            sessionId = attachedId
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    /// Resumes an existing session by its identifier.
    /// - Parameter skipReplay: When true, the server skips the ring-buffer
    ///   replay. Use this when the client is swapping between locally-cached
    ///   terminals and already has the full scrollback on screen.
    public func resumeSession(id: UUID, skipReplay: Bool = false) async throws {
        let response = try await sendAndWaitForResponse(
            .sessionResume(sessionId: id, skipReplay: skipReplay),
            expected: ["session_resumed"]
        )

        switch response {
        case .sessionResumed(let resumedId):
            sessionId = resumedId
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    /// Lists all sessions owned by the authenticated token.
    public func listSessions() async throws -> [SessionInfo] {
        let response = try await sendAndWaitForResponse(.sessionList, expected: ["session_list_result"])

        switch response {
        case .sessionList(let sessions):
            return sessions
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    /// Lists all sessions across all tokens. Used for cross-device attach.
    public func listAllSessions() async throws -> [SessionInfo] {
        let response = try await sendAndWaitForResponse(.sessionListAll, expected: ["session_list_all_result"])

        switch response {
        case .sessionListAll(let sessions):
            return sessions
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    /// Renames a session. Fire-and-forget — the server broadcasts the rename
    /// to all connections via `sessionRenamed`. No response expected.
    public func renameSession(id: UUID, name: String) async throws {
        try await connection.send(.sessionRename(sessionId: id, name: name))
    }

    /// Detaches from the current session without terminating it.
    public func detach() async throws {
        let response = try await sendAndWaitForResponse(
            .sessionDetach,
            expected: ["session_detached"]
        )

        switch response {
        case .sessionDetached:
            sessionId = nil
        case .error(_, let message):
            throw SessionError.unexpectedResponse(message)
        default:
            throw SessionError.unexpectedResponse(response.typeString)
        }
    }

    // MARK: - Internal Helpers

    /// Full set of command-reply types. Used only as a defensive fallback for a
    /// caller that doesn't pass an explicit `expected:` set — every real caller
    /// now scopes its own reply type (see the cross-delivery note below), so a
    /// waiter never matches an unrelated reply like a concurrent `auth_success`.
    private static let responseTypes: Set<String> = [
        "auth_success", "auth_failure",
        "session_created", "session_attached", "session_resumed", "session_detached",
        "session_list_result", "session_list_all_result",
        "error"
    ]

    /// Installs a response subscription synchronously on MainActor, then sends.
    /// The subscriber resumes the continuation if available, or stores the
    /// value for the synchronous check after send.
    ///
    /// Uses `addServerMessageSubscriber` + `removeSubscriber` rather than the
    /// old save-restore pattern on `onServerMessage`. The subscriber list
    /// composes multiple concurrent waiters correctly — if a caller like the
    /// coordinator is also subscribed, both still receive every message, and
    /// two overlapping `withAuth { ... }` retry flows no longer risk
    /// restoring a stale handler in defer order.
    private func sendAndWaitForResponse(
        _ message: ClientMessage,
        expected: Set<String>? = nil
    ) async throws -> ServerMessage {
        let guard_ = ResumeGuard()

        // Match only the caller's expected reply type(s), always including
        // "error". The wire protocol has no request ids, so a waiter matching
        // EVERY response type can capture a reply meant for a concurrent
        // request — e.g. `listAllSessions` (awaiting `session_list_all_result`)
        // grabbing the `session_list_result` from a parallel `fetchSessions`,
        // then failing the type check and returning empty. Scoping each waiter
        // to its own reply type prevents that cross-delivery. Defaults to the
        // full set for callers that don't specify.
        let matchTypes = expected.map { $0.union(["error"]) } ?? Self.responseTypes

        // 1) Install subscription SYNCHRONOUSLY on MainActor — guaranteed in
        //    place before any suspension point. The subscriber either
        //    resumes the continuation (if we're waiting) or stores the
        //    value (if the response beats the await).
        let subscriptionId = connection.addServerMessageSubscriber { serverMessage in
            guard matchTypes.contains(serverMessage.typeString) else { return }
            if guard_.continuation != nil {
                guard_.resume(returning: serverMessage)
            } else {
                guard_.pendingValue = serverMessage
            }
        }
        defer { connection.removeSubscriber(subscriptionId) }

        // 2) Send the message.
        try await connection.send(message)

        // 3) If the response already arrived during send, return it.
        if let value = guard_.pendingValue {
            return value
        }

        // 4) Otherwise wait for it with a timeout.
        return try await withCheckedThrowingContinuation { continuation in
            guard_.continuation = continuation

            // Check again — response may have arrived between step 3 and here.
            if let value = guard_.pendingValue {
                guard_.resume(returning: value)
                return
            }

            guard_.timeoutTask = Task { @MainActor [guard_] in
                try? await Task.sleep(for: .seconds(10))
                guard_.resume(throwing: SessionError.timeout)
            }
        }
    }
}

// MARK: - Resume Guard

/// Ensures a `CheckedContinuation` is resumed exactly once.
/// All access must be on `@MainActor`.
@MainActor
private final class ResumeGuard {
    var continuation: CheckedContinuation<ServerMessage, Error>?
    var pendingValue: ServerMessage?
    var timeoutTask: Task<Void, Never>?
    private var resumed = false

    func resume(returning value: ServerMessage) {
        guard !resumed else { return }
        resumed = true
        timeoutTask?.cancel()
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        guard !resumed else { return }
        resumed = true
        timeoutTask?.cancel()
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
