import Foundation
import ClaudeRelayKit

/// The connection members `SessionController` actually uses, factored out so the
/// controller's request/response correlation can be tested without a socket.
/// `RelayConnection` satisfies it as-is; the tests substitute a recording fake
/// that answers RPCs synchronously.
///
/// Mirrors Kotlin's `relay.net.ConnectionSurface` member for member, so the two
/// controllers stay portable ports of each other rather than drifting.
@MainActor
public protocol ConnectionSurface: AnyObject {
    /// Bumped every time the socket is replaced. Auth and attachment are
    /// per-socket server-side state, so the stamps are what detect staleness.
    var generation: UInt64 { get }

    /// Cheap, non-suspending "is there a socket right now" read, with no ping
    /// round-trip. A receive-loop failure flips this false WITHOUT bumping
    /// `generation`, so it catches the silently-dead socket stamps cannot.
    var isConnected: Bool { get }

    func send(_ message: ClientMessage) async throws

    @discardableResult
    func addServerMessageSubscriber(_ handler: @escaping (ServerMessage) -> Void) -> UUID
    func removeSubscriber(_ id: UUID)
}

extension RelayConnection: ConnectionSurface {
    public var isConnected: Bool { state == .connected }
}

/// Orchestrates authentication and session lifecycle on top of a `ConnectionSurface`.
@MainActor
public final class SessionController: ObservableObject {

    // MARK: - Types

    public enum SessionError: Error, LocalizedError {
        case authenticationFailed(reason: String)
        case versionIncompatible(clientVersion: Int, serverVersion: Int)
        case unexpectedResponse(String)
        case timeout

        /// This socket has an unaccounted-for request on it (an RPC timed out),
        /// so no further reply on it can be trusted to belong to its sender.
        /// Retriable only by replacing the socket.
        case connectionDesynchronized

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
            case .connectionDesynchronized:
                return "The connection to the server needs to be re-established."
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

    private let connection: any ConnectionSurface

    /// Tail of the RPC chain — the most recently issued request-response RPC.
    /// Each new RPC awaits this one before touching the wire, which is how
    /// "at most one outstanding RPC per connection" is enforced. See
    /// `sendAndWaitForResponse`.
    private var previousRPC: Task<ServerMessage, Error>?

    /// The `connection.generation` of a socket left DESYNCHRONIZED by an RPC
    /// that timed out, i.e. one with a request outstanding that nobody is
    /// waiting for any more.
    ///
    /// Serializing RPCs guarantees one request in flight at a time, but a
    /// timeout retires the waiter while leaving the *request* outstanding
    /// server-side. Its late reply then lands on whichever waiter is installed
    /// when it arrives — and because there are no request ids, that waiter has
    /// no way to reject it. Two consecutive `session_list`s is the worst case
    /// and the original bug verbatim: the launch list times out, a post-create
    /// list follows, and the late pre-create reply resolves it, so the new
    /// session is missing from the sidebar.
    ///
    /// So a timeout poisons the socket rather than just failing one call: every
    /// later RPC on it throws `connectionDesynchronized` until it is replaced.
    /// Keying on the generation makes that self-expiring — any reconnect
    /// (`connect()` or `markConnectionDead()`) bumps it, and a fresh socket
    /// cannot carry the old one's in-flight reply. `SessionHandshake` recovers
    /// without a special case: its catch-all already does `resetAuth()` +
    /// `disconnect()` and retries, which is exactly the required response.
    private var desyncedGeneration: UInt64?

    /// Whether the CURRENT socket is desynchronized — no RPC can run on it and
    /// only replacing it will help. Private, unlike the Kotlin port's public
    /// equivalent: there, the recovery layer has to consult it because its
    /// alive-restore path would otherwise loop on an unusable socket. Swift has
    /// no such path — `restoreSession` is only ever reached after a successful
    /// `forceReconnect()`, whose generation bump has already cleared this — and
    /// the handshake's catch-all cures it by disconnecting and retrying.
    private var isDesynchronized: Bool {
        desyncedGeneration == connection.generation
    }

    /// How long a single RPC waits for its reply. The Kotlin port's
    /// `RESPONSE_TIMEOUT_MS`. Injectable only so tests can exercise the timeout
    /// path without a 10-second wall-clock wait — production always takes the
    /// default.
    private let responseTimeout: Duration

    // MARK: - Init

    public init(connection: any ConnectionSurface, responseTimeout: Duration = .seconds(10)) {
        self.connection = connection
        self.responseTimeout = responseTimeout
    }

    // MARK: - Authentication

    /// Whether the controller is authenticated on the **current, live**
    /// connection. False if the WebSocket has been replaced since auth was
    /// established, or if there is no live socket at all.
    ///
    /// The `isConnected` term matters: `RelayConnection` bumps its
    /// generation in `markConnectionDead()` but NOT in `handleReceiveFailure()`,
    /// which merely nils the task and flips `state` to `.disconnected`. Without
    /// the liveness check, auth stayed "valid" over a socket that no longer
    /// exists, so `ensureAuthenticated()` handed back a dead controller and the
    /// RPC threw `ConnectionError.notConnected` — an error `withAuth` does not
    /// retry. Requiring a live socket makes the handshake reconnect instead.
    public var isAuthValid: Bool {
        isAuthenticated
            && authenticatedGeneration == connection.generation
            && connection.isConnected
            // A desynchronized socket can't carry an RPC, so auth over it is of
            // no use to a caller — report invalid and let the handshake replace it.
            && !isDesynchronized
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

    /// Serializes request-response RPCs: **at most one may be outstanding on a
    /// connection at a time.**
    ///
    /// This is a protocol constraint, not an optimization. Replies carry no
    /// request id, so the only thing a waiter can match on is the response TYPE
    /// — and `error` is a legal reply to *every* request. Two overlapping RPCs
    /// therefore always share at least one possible reply type, and whichever
    /// reply lands first resolves BOTH waiters:
    ///
    /// - a `session_list` from a pane refresh and one from a handshake: both
    ///   resolve on the first `session_list_result`, so the later request (the
    ///   one issued *after* a create) renders a pre-create list and the new
    ///   session vanishes from the sidebar;
    /// - an `error` for a failing `session_create` also completes a concurrent
    ///   `session_list` waiter, so the handshake concludes ITS list failed,
    ///   drops the socket and retries — tearing the transport out from under
    ///   the create.
    ///
    /// Scoping each waiter to its own reply type (`expected`, below) shrinks the
    /// window but cannot close it, because of `error`. Serializing does close it.
    ///
    /// There is no async mutex on `@MainActor`, so the queue is a chain: each
    /// RPC awaits its predecessor's `result` — deliberately `result`, not
    /// `value`, so a predecessor that throws or times out RELEASES the queue
    /// instead of poisoning everything behind it. Worst-case wait for a queued
    /// RPC is one response timeout; that is strictly better than the
    /// cross-delivery it replaces, which corrupted state silently.
    ///
    /// **Constraint for future code: never issue an RPC from inside another
    /// RPC's await window** — the chain is not reentrant and that self-deadlocks.
    /// Today's paths are all sequential: `withAuth` completes
    /// `ensureAuthenticated()` (one RPC) before running its body (the next), and
    /// inbound push handlers dispatch onto their own tasks rather than calling
    /// back in.
    private func sendAndWaitForResponse(
        _ message: ClientMessage,
        expected: Set<String>
    ) async throws -> ServerMessage {
        let predecessor = previousRPC
        let rpc = Task { @MainActor [self] in
            _ = await predecessor?.result
            return try await awaitResponse(message, expected: expected)
        }
        previousRPC = rpc
        defer {
            // Only the tail drops itself, so a queued successor still has
            // something to wait on. Clearing it keeps a finished chain from
            // retaining `self` (and the messages) indefinitely.
            if previousRPC == rpc { previousRPC = nil }
        }
        return try await rpc.value
    }

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
    ///
    /// `expected` is deliberately required, with no permissive default. It is
    /// the second half of the correlation story: the chain guarantees only one
    /// RPC is outstanding, and the type scope guarantees that even a stray
    /// *pushed* message (or a late reply from an RPC that already timed out)
    /// can't resolve this one. A waiter matching every response type produced
    /// the cross-device "No Sessions Available" bug: `listAllSessions` (awaiting
    /// `session_list_all_result`) grabbed the `session_list_result` from a
    /// parallel `fetchSessions`, failed its type check and returned empty.
    /// Every call site names its own reply type, so a new one cannot silently
    /// inherit the hazard.
    /// The server's reply to a request that arrived while nothing was attached.
    /// Matched as data because that is all the wire carries — see
    /// `isForeignError`.
    private static let noSessionAttachedMessage = "no session attached"

    /// True when this `.error` provably belongs to some *other* request, so this
    /// waiter must ignore it rather than fail on it.
    ///
    /// Only one such proof is available, and it is narrow by design. `error`
    /// carries no request id (nothing does), so a waiter normally cannot tell an
    /// error meant for it from one meant for a request nobody is awaiting — which
    /// is why `matchTypes` accepts `error` unconditionally in the first place.
    ///
    /// `"No session attached"` is the exception: server-side it is emitted only by
    /// handlers for requests that arrive while unattached, and of those, only
    /// `detach` has a waiter. Every other handler that *does* have a waiter fails
    /// with its own prefix instead (`"Attach failed: …"`, `"Resume failed: …"`,
    /// `"Terminate failed: …"`). So this error reaching an attach/resume/list
    /// waiter means a fire-and-forget request produced it — the resize/refresh
    /// race that made an iOS session switch report "Unexpected server response:
    /// No session attached" and roll the pane back to the previous session.
    ///
    /// Servers from this commit on don't send it for those requests at all (see
    /// the unattached-request reply rule atop the server's
    /// `SessionRequestHandlers.swift`). This check is what protects a client
    /// talking to an OLDER server, which the app cannot assume has been rebuilt.
    /// Both layers are wanted: the server stops manufacturing an unaddressed
    /// error, and the client stops accepting the one kind it can identify.
    ///
    /// Deliberately NOT generalized into "ignore errors that don't look like
    /// mine". Any unrecognized message shape would then be dropped and the
    /// waiter would hang to its timeout — and a timeout poisons the socket
    /// (`desyncedGeneration`), which is far worse than surfacing one wrong error.
    /// Matching a single known string fails safe: an unmatched error still
    /// resolves the waiter exactly as before.
    private static func isForeignError(_ message: ServerMessage, expected: Set<String>) -> Bool {
        // A detach waiter is the one place this error is legitimately addressed.
        guard !expected.contains("session_detached") else { return false }
        guard case .error(_, let detail) = message else { return false }
        return detail.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(noSessionAttachedMessage) == .orderedSame
    }

    private func awaitResponse(
        _ message: ClientMessage,
        expected: Set<String>
    ) async throws -> ServerMessage {
        // A previous RPC on this socket timed out, so it still owes a reply that
        // this waiter would happily accept. Refuse until the socket is replaced.
        guard !isDesynchronized else {
            throw SessionError.connectionDesynchronized
        }

        let guard_ = ResumeGuard()

        // "error" is always accepted — the server answers any request with it.
        let matchTypes = expected.union(["error"])

        // 1) Install subscription SYNCHRONOUSLY on MainActor — guaranteed in
        //    place before any suspension point. The subscriber either
        //    resumes the continuation (if we're waiting) or stores the
        //    value (if the response beats the await).
        let subscriptionId = connection.addServerMessageSubscriber { serverMessage in
            guard matchTypes.contains(serverMessage.typeString) else { return }
            if Self.isForeignError(serverMessage, expected: expected) { return }
            if guard_.continuation != nil {
                guard_.resume(returning: serverMessage)
            } else {
                guard_.pendingValue = serverMessage
            }
        }
        defer { connection.removeSubscriber(subscriptionId) }

        // 2) Send the message.
        try await connection.send(message)

        // The generation the request actually went out on. The timeout below must
        // poison THIS socket, not whichever one is current when the timer fires:
        // if a reconnect intervenes, the request died with the old socket and the
        // fresh one can never receive its reply. Poisoning the fresh socket would
        // refuse every RPC on a perfectly good connection until yet another
        // reconnect — and if none is forthcoming, permanently. Read after the send
        // rather than before, so a send that threw (no request outstanding) never
        // reaches it.
        let sentGeneration = connection.generation

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

            let timeout = responseTimeout
            guard_.timeoutTask = Task { @MainActor [weak self, guard_] in
                // `try await`, NOT `try?`: `ResumeGuard.resume` cancels this task
                // when the reply lands, and a cancelled `Task.sleep` throws
                // immediately. Swallowing that would run the rest of this body on
                // every SUCCESSFUL RPC — which used to be harmless (a second
                // `resume` is a no-op) but now marks the socket desynchronized,
                // failing every subsequent request on a healthy connection.
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return   // cancelled: the reply arrived, nothing is outstanding
                }
                // The request stays outstanding server-side even though nobody
                // waits for it any more — mark the socket unusable BEFORE
                // resuming, so the caller's error handling (which may issue
                // another RPC immediately) already sees it.
                //
                // This also covers CANCELLATION, by a route the Kotlin port can't
                // use. This task is unstructured, so a cancelled caller does not
                // cancel it: it still fires and still poisons the socket the
                // abandoned request went out on. (The caller stays parked until
                // then — `withCheckedThrowingContinuation` has no cancellation
                // handler — which is slow but safe.) Kotlin's `withTimeoutOrNull`
                // lets a `CancellationException` escape instead, so it poisons in
                // a `finally` covering both paths. Same invariant, different
                // mechanics; don't "align" one to the other without re-checking.
                if let self { desyncedGeneration = sentGeneration }
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
