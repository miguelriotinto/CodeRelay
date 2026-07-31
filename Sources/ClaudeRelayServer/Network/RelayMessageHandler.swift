import NIO
import NIOCore
import NIOWebSocket
import Foundation
import ClaudeRelayKit

final class RelayMessageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    let sessionManager: SessionManager
    private let tokenStore: TokenStore
    private let rateLimiter: RateLimiter
    private let clipboardService: ClipboardService
    var isAuthenticated = false
    var authenticatedTokenId: String?
    var attachedSessionId: UUID?
    var attachedPTY: (any PTYSessionProtocol)?
    private var context: ChannelHandlerContext?
    private var authTimeout: Scheduled<Void>?
    private var authAttempts = 0
    /// Captured at `channelActive`. Used as the rate-limit key and as the
    /// logged remote address on auth events. Prefer `ipAddress` over
    /// `description` so repeated reconnects from the same host share a bucket
    /// regardless of ephemeral source port.
    private(set) var remoteIP: String = "unknown"
    private var activityObserverId: UUID?
    var stealObserverId: UUID?
    private var renameObserverId: UUID?
    /// Set to true once `cleanupSession()` has run. Used to detect the race where
    /// observer registration completes after the channel has already gone inactive,
    /// so the late-arriving observer IDs can be unregistered instead of leaked.
    private var isCleanedUp = false
    private static let maxAuthAttempts = 3
    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()
    private static let maxTextFrameSize = 10_000_000   // 10MB (images are base64 in JSON)
    private static let maxBinaryFrameSize = 10_000_000 // 10MB

    /// Bytes currently in-flight on the WebSocket write pipe. When this exceeds
    /// `maxInflightOutputBytes` we skip frames; the server's ring buffer holds
    /// the authoritative copy so the client replays on resume.
    private var inflightOutputBytes = 0
    private static let maxInflightOutputBytes = 2 * 1024 * 1024  // 2 MB

    let pushStore: PushRegistrationStore
    /// Per-connection registration-mutation counter, reset each auth. Bounds
    /// abuse of the push-token endpoint (Codex plan: rate-limit registrations).
    private var pushMutations = 0
    private let maxPushMutations = 20

    private let pairingStore: PairingCodeStore
    /// Bad pairing codes on this connection. Mirrors `authAttempts`.
    private(set) var pairAttempts = 0
    private static let maxPairAttempts = 3

    init(sessionManager: SessionManager, tokenStore: TokenStore, rateLimiter: RateLimiter,
         clipboardService: ClipboardService,
         pushStore: PushRegistrationStore = PushRegistrationStore(directory: RelayConfig.configDirectory),
         pairingStore: PairingCodeStore) {
        self.sessionManager = sessionManager
        self.tokenStore = tokenStore
        self.rateLimiter = rateLimiter
        self.clipboardService = clipboardService
        self.pushStore = pushStore
        self.pairingStore = pairingStore
    }

    /// This handler is installed by the WebSocket upgrade after the channel
    /// is already active, so NIO does NOT call `channelActive` on us. We use
    /// `handlerAdded` instead to capture the remote address, log the connect,
    /// and arm the auth timer + rate-limit gate.
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        // Prefer the bare IP as the rate-limit key so repeated reconnects from
        // the same host share a bucket regardless of ephemeral source port.
        // Fall back to `description` (which includes :port) only if IP is
        // unavailable — still better than "unknown".
        let remote = context.remoteAddress?.ipAddress
            ?? context.remoteAddress?.description
            ?? "unknown"
        self.remoteIP = remote
        RelayLogger.log(category: "connection", "WebSocket connected from \(remote)")

        // Rate-limit check has to run on the limiter actor. Dispatch a task
        // that checks first, then installs the auth timer on the event loop.
        // If blocked, close the channel with 429 before arming the timer.
        let limiter = rateLimiter
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            let blocked = await limiter.isBlocked(ip: remote)
            ctx.value.eventLoop.execute {
                guard let self = self else { return }
                if blocked {
                    RelayLogger.log(.error, category: "auth",
                        "Connection from \(remote) rejected: rate-limited")
                    self.sendServerMessage(.error(code: 429, message: "Too many failed attempts"), context: ctx.value)
                    ctx.value.close(promise: nil)
                    return
                }
                // Start 10-second auth timer
                self.authTimeout = ctx.value.eventLoop.scheduleTask(in: .seconds(10)) { [weak self] in
                    guard let self = self, !self.isAuthenticated else { return }
                    RelayLogger.log(.error, category: "auth", "Auth timeout for \(remote)")
                    self.sendServerMessage(.error(code: 401, message: "Authentication timeout"), context: ctx.value)
                    ctx.value.close(promise: nil)
                }
            }
        }
    }

    /// Retained for channels where the handler is added pre-activation (not
    /// the typical WebSocket upgrade path). `handlerAdded` sets `remoteIP`
    /// eagerly; guard against double-initialization.
    func channelActive(context: ChannelHandlerContext) {
        if self.context == nil {
            handlerAdded(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let remote = context.remoteAddress?.description ?? "unknown"
        RelayLogger.log(category: "connection", "WebSocket disconnected from \(remote)")
        authTimeout?.cancel()
        cleanupSession()
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            handleTextFrame(frame, context: context)
        case .binary:
            handleBinaryFrame(frame, context: context)
        case .connectionClose:
            cleanupSession()
            context.close(promise: nil)
        case .ping:
            let frameData = frame.data
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        cleanupSession()
        context.close(promise: nil)
    }

    // MARK: - Text Frame Handling

    private func handleTextFrame(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        let data = frame.unmaskedData
        let readable = data.readableBytes
        guard readable > 0 else { return }
        if readable > Self.maxTextFrameSize {
            sendServerMessage(.error(code: 413, message: "Message too large"), context: context)
            context.close(promise: nil)
            return
        }
        let jsonData = data.withUnsafeReadableBytes { Data($0) }

        let envelope: MessageEnvelope
        do {
            envelope = try Self.jsonDecoder.decode(MessageEnvelope.self, from: jsonData)
        } catch {
            sendServerMessage(.error(code: 400, message: "Invalid message format"), context: context)
            return
        }

        guard case .client(let clientMessage) = envelope else {
            sendServerMessage(.error(code: 400, message: "Expected client message"), context: context)
            return
        }

        if !isAuthenticated {
            handleUnauthenticatedMessage(clientMessage, context: context)
        } else {
            handleAuthenticatedMessage(clientMessage, context: context)
        }
    }

    private func handleUnauthenticatedMessage(_ message: ClientMessage, context: ChannelHandlerContext) {
        switch message {
        case .authRequest(let token, let protocolVersion):
            handleAuth(token: token, clientProtocolVersion: protocolVersion, context: context)
        case .pairRequest(let code, let deviceName, let platform):
            handlePairRequest(code: code, deviceName: deviceName, platform: platform, context: context)
        case .ping:
            sendServerMessage(.pong, context: context)
        default:
            sendServerMessage(.error(code: 401, message: "Not authenticated"), context: context)
        }
    }

    private func handleAuthenticatedMessage(_ message: ClientMessage, context: ChannelHandlerContext) {
        switch message {
        case .authRequest:
            sendServerMessage(.error(code: 400, message: "Already authenticated"), context: context)
        case .pairRequest:
            sendServerMessage(.error(code: 400, message: "Already authenticated"), context: context)
        case .sessionCreate(let name, let cols, let rows):
            handleSessionCreate(name: name, cols: cols, rows: rows, context: context)
        case .sessionAttach(let sessionId):
            handleSessionAttach(sessionId: sessionId, context: context)
        case .sessionResume(let sessionId, let skipReplay):
            handleSessionResume(sessionId: sessionId, skipReplay: skipReplay, context: context)
        case .sessionDetach:
            handleSessionDetach(context: context)
        case .sessionTerminate(let sessionId):
            handleSessionTerminate(sessionId: sessionId, context: context)
        case .sessionList:
            handleSessionList(context: context)
        case .sessionListAll:
            handleSessionListAll(context: context)
        case .sessionRename(let sessionId, let name):
            handleSessionRename(sessionId: sessionId, name: name, context: context)
        case .resize(let cols, let rows):
            handleResize(cols: cols, rows: rows, context: context)
        case .refresh:
            handleRefresh(context: context)
        case .pasteImage(let data):
            handlePasteImage(base64Data: data, context: context)
        case .ping:
            sendServerMessage(.pong, context: context)
        case .registerPushToken(let platform, let token, let deviceId, let enabled, let notifyOnFinished, let topic):
            handleRegisterPushToken(platform: platform, token: token, deviceId: deviceId,
                                    enabled: enabled, notifyOnFinished: notifyOnFinished,
                                    topic: topic, context: context)
        case .unregisterPushToken(let deviceId):
            handleUnregisterPushToken(deviceId: deviceId, context: context)
        }
    }

    private func handleRegisterPushToken(platform: PushPlatform, token: String, deviceId: String,
                                         enabled: Bool, notifyOnFinished: Bool, topic: String?,
                                         context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else {
            sendServerMessage(.pushTokenAck(accepted: false), context: context); return
        }
        let registration = PushRegistration(platform: platform, token: token, deviceId: deviceId,
                                            enabled: enabled, notifyOnFinished: notifyOnFinished,
                                            updatedAt: Date(), topic: topic)
        pushMutations += 1
        guard registration.isValid, pushMutations <= maxPushMutations else {
            sendServerMessage(.pushTokenAck(accepted: false), context: context); return
        }
        let transferCtx = UnsafeTransfer(context)
        Task { [pushStore] in
            await pushStore.upsert(registration, forTokenId: tokenId)
            transferCtx.value.eventLoop.execute {
                self.sendServerMessage(.pushTokenAck(accepted: true), context: transferCtx.value)
            }
        }
    }

    private func handleUnregisterPushToken(deviceId: String, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else {
            sendServerMessage(.pushTokenAck(accepted: false), context: context); return
        }
        pushMutations += 1
        // Bound deviceId (same 128-char limit as registration) and enforce the
        // per-connection mutation cap — a malicious client must not be able to
        // spam atomic rewrites of push-tokens.json with unbounded input.
        guard !deviceId.isEmpty, deviceId.count <= 128, pushMutations <= maxPushMutations else {
            sendServerMessage(.pushTokenAck(accepted: false), context: context); return
        }
        let transferCtx = UnsafeTransfer(context)
        Task { [pushStore] in
            await pushStore.remove(deviceId: deviceId, forTokenId: tokenId)
            transferCtx.value.eventLoop.execute {
                self.sendServerMessage(.pushTokenAck(accepted: true), context: transferCtx.value)
            }
        }
    }

    // MARK: - Binary Frame Handling

    private func handleBinaryFrame(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        guard isAuthenticated, let pty = attachedPTY else { return }
        let data = frame.unmaskedData
        if data.readableBytes > Self.maxBinaryFrameSize {
            sendServerMessage(.error(code: 413, message: "Binary frame too large"), context: context)
            return
        }
        let inputData = data.withUnsafeReadableBytes { Data($0) }
        Task {
            await pty.write(inputData)
            await pty.recordInput()
        }
    }

    // MARK: - Auth

    /// Distinguishes the three failure modes so `onFailure` can replicate the
    /// original code paths (invalid token → attempt counter + rate-limit +
    /// close-after-max; version mismatch → reject + close; unexpected error
    /// → 500 + close).
    private enum AuthFailure: Error {
        case invalidToken
        case versionMismatch(clientVersion: Int)
    }

    /// Bag of state produced by the async `work` phase and consumed by
    /// `onSuccess` on the event loop. Observer ids must be captured here
    /// (not on `self`) so we can unregister them if the channel was torn
    /// down mid-registration.
    private struct AuthSuccessPayload {
        let tokenId: String
        let clientVersion: Int
        let activityObserverId: UUID
        let stealObserverId: UUID
        let renameObserverId: UUID
    }

    private func handleAuth(token: String, clientProtocolVersion: Int?, context: ChannelHandlerContext) {
        let tokenStore = self.tokenStore
        let manager = self.sessionManager
        let observerCtx = UnsafeTransfer(context)
        let clientVersion = clientProtocolVersion ?? 0

        bridgeToEventLoop(
            context: context,
            work: {
                guard let info = await tokenStore.validate(token: token) else {
                    throw AuthFailure.invalidToken
                }
                // Check protocol compatibility *after* auth, so unauthenticated
                // clients cannot probe the server version.
                guard clientVersion >= ClaudeRelayKit.minProtocolVersion else {
                    throw AuthFailure.versionMismatch(clientVersion: clientVersion)
                }

                // Register observers BEFORE we signal success. This closes the
                // race where `auth_success` was visible to the client while
                // the server's activity/steal/rename observers were not yet
                // installed — a concurrent steal from another device in that
                // window would never reach this handler.
                //
                // The channel can still go inactive while these three actor
                // calls are in flight; the `isCleanedUp` check in `onSuccess`
                // covers that case by unregistering what we just installed.
                let activityId = await manager.addActivityObserver(tokenId: info.id) {
                    [weak self] sessionId, activity, agent, agentState, title, workingDir in
                    observerCtx.value.eventLoop.execute {
                        self?.sendServerMessage(
                            .sessionActivity(sessionId: sessionId, activity: activity, agent: agent,
                                             agentState: agentState, title: title, workingDir: workingDir),
                            context: observerCtx.value
                        )
                    }
                }
                let stealId = await manager.addStealObserver(tokenId: info.id) { [weak self] sessionId in
                    observerCtx.value.eventLoop.execute {
                        guard let self else { return }
                        // Always forward the stolen notification so the client
                        // removes the session from its sidebar. If it happens to
                        // be the actively-attached session, also clear local state.
                        if self.attachedSessionId == sessionId {
                            self.attachedSessionId = nil
                            self.attachedPTY = nil
                        }
                        self.sendServerMessage(.sessionStolen(sessionId: sessionId), context: observerCtx.value)
                    }
                }
                let renameId = await manager.addRenameObserver(tokenId: info.id) { [weak self] sessionId, name in
                    observerCtx.value.eventLoop.execute {
                        self?.sendServerMessage(.sessionRenamed(sessionId: sessionId, name: name), context: observerCtx.value)
                    }
                }
                return AuthSuccessPayload(
                    tokenId: info.id,
                    clientVersion: clientVersion,
                    activityObserverId: activityId,
                    stealObserverId: stealId,
                    renameObserverId: renameId
                )
            },
            onSuccess: { handler, ctx, payload in
                // Late-arrival guard: if the channel tore down while we were
                // registering observers, unregister them to avoid a leak
                // inside SessionManager.
                guard !handler.isCleanedUp else {
                    Task {
                        await manager.removeActivityObserver(id: payload.activityObserverId)
                        await manager.removeStealObserver(id: payload.stealObserverId)
                        await manager.removeRenameObserver(id: payload.renameObserverId)
                    }
                    return
                }
                handler.activityObserverId = payload.activityObserverId
                handler.stealObserverId = payload.stealObserverId
                handler.renameObserverId = payload.renameObserverId
                handler.isAuthenticated = true
                handler.authenticatedTokenId = payload.tokenId
                handler.authTimeout?.cancel()
                handler.authTimeout = nil
                RelayLogger.log(category: "auth",
                    "Auth success for token \(payload.tokenId) (protocol v\(payload.clientVersion))")
                handler.sendServerMessage(
                    .authSuccess(protocolVersion: ClaudeRelayKit.protocolVersion, tokenId: payload.tokenId),
                    context: ctx
                )
            },
            onFailure: { handler, ctx, error in
                switch error {
                case AuthFailure.versionMismatch(let clientVersion):
                    let remote = ctx.remoteAddress?.description ?? "unknown"
                    RelayLogger.log(.error, category: "auth",
                        "Version mismatch from \(remote): client protocol v\(clientVersion), server requires >= v\(ClaudeRelayKit.minProtocolVersion)")
                    handler.sendServerMessage(.authFailure(
                        reason: "This app is not compatible with the server version running on the backend. "
                            + "Client protocol: v\(clientVersion), server requires: v\(ClaudeRelayKit.minProtocolVersion)+."
                    ), context: ctx)
                    ctx.close(promise: nil)

                case AuthFailure.invalidToken:
                    handler.authAttempts += 1
                    let remote = handler.remoteIP
                    RelayLogger.log(.error, category: "auth",
                        "Auth failed — invalid token (attempt \(handler.authAttempts)/\(Self.maxAuthAttempts)) from \(remote)")
                    // Record this failure against the shared rate limiter so
                    // repeated reconnect-and-retry from the same IP eventually
                    // hits the cross-connection cap (not just the per-connection
                    // `maxAuthAttempts`).
                    let limiter = handler.rateLimiter
                    Task { await limiter.recordFailure(ip: remote) }
                    handler.sendServerMessage(.authFailure(reason: "Invalid token"), context: ctx)
                    if handler.authAttempts >= Self.maxAuthAttempts {
                        RelayLogger.log(.error, category: "auth",
                            "Max auth attempts reached, closing connection from \(remote)")
                        ctx.close(promise: nil)
                    }

                default:
                    // Any other error from validate/register is unexpected;
                    // treat it like a server-side failure and close.
                    RelayLogger.log(.error, category: "auth",
                        "Auth error: \(error.localizedDescription)")
                    handler.sendServerMessage(.error(code: 500, message: "Auth error"), context: ctx)
                    ctx.close(promise: nil)
                }
            }
        )
    }

    // MARK: - Pairing

    private enum PairFailure: Error {
        case invalidCode
    }

    private struct PairSuccessPayload: Sendable {
        let token: String
        let tokenId: String
        let label: String
    }

    /// Redeem a one-time pairing code for a freshly minted per-device token.
    ///
    /// Runs **pre-auth**, so it is bounded by the same 10 s auth timer armed in
    /// `handlerAdded`: the client must follow `pair_success` with an
    /// `auth_request` inside that window. Pairing deliberately does NOT set
    /// `isAuthenticated` — the client authenticates with the token it just
    /// received, which keeps exactly one code path for becoming authenticated.
    private func handlePairRequest(code: String, deviceName: String, platform: String,
                                   context: ChannelHandlerContext) {
        let pairingStore = self.pairingStore
        let tokenStore = self.tokenStore

        // Label the token after the device so it is identifiable and
        // individually revocable in `claude-relay token list`.
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmedName.isEmpty ? platform : trimmedName
        // Strip control characters (attacker-controlled deviceName/platform can
        // embed \n to forge log lines or ANSI escapes to corrupt terminals).
        let allowedChars = CharacterSet.controlCharacters.union(.newlines).inverted
        let stripped = sanitized.unicodeScalars.filter { allowedChars.contains($0) }
        let safeName = String(String.UnicodeScalarView(stripped).prefix(60))
        let label = "\(safeName) (paired)"

        bridgeToEventLoop(
            context: context,
            work: {
                guard await pairingStore.redeem(code) != nil else {
                    throw PairFailure.invalidCode
                }
                let (plaintext, info) = try await tokenStore.create(label: label)
                return PairSuccessPayload(token: plaintext, tokenId: info.id, label: label)
            },
            onSuccess: { handler, ctx, payload in
                RelayLogger.log(category: "auth",
                    "Pairing succeeded for \(payload.label) — minted token \(payload.tokenId)")
                handler.sendServerMessage(
                    .pairSuccess(token: payload.token, tokenId: payload.tokenId, label: payload.label),
                    context: ctx
                )
            },
            onFailure: { handler, ctx, error in
                switch error {
                case PairFailure.invalidCode:
                    handler.pairAttempts += 1
                    let remote = handler.remoteIP
                    RelayLogger.log(.error, category: "auth",
                        "Pairing failed — invalid code (attempt \(handler.pairAttempts)/\(Self.maxPairAttempts)) from \(remote)")
                    let limiter = handler.rateLimiter
                    Task { await limiter.recordFailure(ip: remote) }
                    handler.sendServerMessage(
                        .error(code: 401, message: "Invalid or expired pairing code"), context: ctx)
                    if handler.pairAttempts >= Self.maxPairAttempts {
                        ctx.close(promise: nil)
                    }

                default:
                    // Any other error from redeem/create is a server-side fault,
                    // not a failed pairing attempt. Do not increment pairAttempts
                    // or penalize the rate limiter.
                    RelayLogger.log(.error, category: "auth",
                        "Pairing error: \(error.localizedDescription)")
                    handler.sendServerMessage(.error(code: 500, message: "Pairing error"), context: ctx)
                }
            }
        )
    }

    // MARK: - Session Request Handlers
    //
    // The session-lifecycle request handlers (`handleSessionCreate`,
    // `handleSessionAttach`, `handleSessionResume`, `handleSessionDetach`,
    // `handleSessionTerminate`, `handleSessionList`, `handleSessionListAll`,
    // `handleSessionRename`, `handleResize`) live in
    // `SessionRequestHandlers.swift` as an extension on this class. The
    // split keeps this file under the SwiftLint `type_body_length` ceiling.

    // MARK: - Auto-Detach

    /// Detaches the currently attached session (if any) before attaching a new one.
    ///
    /// Reads and writes to `attachedSessionId`/`attachedPTY` must happen on
    /// the channel's event loop — this handler is `@unchecked Sendable` and
    /// the compiler does not enforce isolation for us. Callers from a Task
    /// context must pass their `ctx` so we can hop back to the event loop
    /// for both the snapshot and the cleanup writeback.
    func autoDetachIfNeeded(ctx: UnsafeTransfer<ChannelHandlerContext>) async {
        // Snapshot on the event loop.
        let captured: (UUID, (any PTYSessionProtocol)?)? = await withCheckedContinuation { cont in
            ctx.value.eventLoop.execute {
                if let id = self.attachedSessionId {
                    cont.resume(returning: (id, self.attachedPTY))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
        guard let (sessionId, pty) = captured else { return }

        if let pty = pty {
            await pty.clearOutputHandler()
        }
        try? await sessionManager.detachSession(id: sessionId)

        // Writeback on the event loop, guarded against a concurrent caller
        // having already overwritten `attachedSessionId` with a different id.
        ctx.value.eventLoop.execute {
            if self.attachedSessionId == sessionId {
                self.attachedSessionId = nil
                self.attachedPTY = nil
            }
        }
    }

    // MARK: - PTY Output Wiring

    /// Installs the live output handler. With `repaintAfter`, also runs the
    /// PTY's resize-wiggle (`forceRepaint()`) once the handler is in place, so
    /// full-screen apps re-emit their screen at the current grid. Used after a
    /// ring-buffer replay: replayed bytes reflect the grid they were emitted
    /// for. The ordering is load-bearing — repainting before the handler is
    /// wired would send the redraw bytes to the ring buffer only, never to
    /// this client.
    func wirePTYOutput(pty: any PTYSessionProtocol, context: ChannelHandlerContext, repaintAfter: Bool = false) {
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            let sessionId = await pty.sessionId
            await pty.setOutputHandler { [weak self] data in
                ctx.value.eventLoop.execute {
                    self?.sendBinaryData(data, context: ctx.value)
                }
            }
            // F11: mirror OSC 52 clipboard writes from the terminal to the
            // client's device clipboard.
            await pty.setClipboardHandler { [weak self] text in
                ctx.value.eventLoop.execute {
                    self?.sendServerMessage(.clipboardUpdate(sessionId: sessionId, text: text),
                                            context: ctx.value)
                }
            }
            if repaintAfter {
                await pty.forceRepaint()
            }
        }
    }

    // MARK: - Cleanup

    private func cleanupSession() {
        isCleanedUp = true
        let obsActivity = activityObserverId
        let obsSteal = stealObserverId
        let obsRename = renameObserverId
        let sessionId = attachedSessionId
        let pty = attachedPTY
        let manager = sessionManager

        activityObserverId = nil
        stealObserverId = nil
        renameObserverId = nil
        attachedSessionId = nil
        attachedPTY = nil

        Task {
            if let id = obsActivity { await manager.removeActivityObserver(id: id) }
            if let id = obsSteal { await manager.removeStealObserver(id: id) }
            if let id = obsRename { await manager.removeRenameObserver(id: id) }
            if let pty { await pty.clearOutputHandler() }
            if let sessionId { try? await manager.detachSession(id: sessionId) }
        }
    }

    // MARK: - Paste Image

    /// Handles an image paste from the iOS client.
    /// Decodes the base64 PNG, writes it to the macOS pasteboard, then sends
    /// an empty bracketed-paste sequence to the PTY so Claude Code inspects
    /// the clipboard (see the inline note below for why a keystroke is wrong).
    private func handlePasteImage(base64Data: String, context: ChannelHandlerContext) {
        guard let pty = attachedPTY else {
            sendServerMessage(.error(code: 400, message: "No session attached"), context: context)
            return
        }

        guard let imageData = Data(base64Encoded: base64Data) else {
            sendServerMessage(.pasteImageResult(success: false), context: context)
            return
        }

        guard clipboardService.pasteImage(imageData) else {
            sendServerMessage(.pasteImageResult(success: false), context: context)
            return
        }

        // Trigger Claude Code to read the clipboard. Terminal emulators
        // (iTerm2, Terminal.app) send an empty bracketed paste when the
        // clipboard contains only image data — the empty text body tells
        // the TUI "a paste happened" and it then inspects NSPasteboard
        // for image content. Sending non-empty text (e.g. "\n") causes
        // Claude Code to process that text instead of checking the clipboard.
        let bracketedPasteStart = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~
        let bracketedPasteEnd = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])   // ESC[201~

        let ctx = UnsafeTransfer(context)
        Task {
            await pty.write(bracketedPasteStart + bracketedPasteEnd)
            ctx.value.eventLoop.execute { [weak self] in
                self?.sendServerMessage(.pasteImageResult(success: true), context: ctx.value)
            }
        }
    }

    // MARK: - Send Helpers

    func sendServerMessage(_ message: ServerMessage, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        let envelope = MessageEnvelope.server(message)
        do {
            let data = try Self.jsonEncoder.encode(envelope)
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            let promise = context.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenFailure { error in
                RelayLogger.log(.error, category: "connection", "Write failed: \(error)")
            }
            context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
        } catch {
            RelayLogger.log(.error, category: "connection", "JSON encode failed for \(message): \(error)")
        }
    }

    /// Chunk size for ring-buffer replays. Mobile WebSocket stacks (URLSession
    /// on iOS in particular) drop large single frames — at ~1.7 MB we observed
    /// consistent I/O-on-closed-channel failures. 64 KB frames sit well inside
    /// every platform's buffers and still keep overhead low.
    private static let replayChunkSize = 64 * 1024

    /// Send a potentially-large binary payload as a series of small frames.
    /// Uses `write` (no flush) on each chunk and a single `flush` at the end
    /// so NIO can coalesce where possible. A promise is attached ONLY to the
    /// final flush — per-chunk failures propagate through the channel's
    /// `errorCaught` path, and a closed channel drops into the
    /// `isActive` guard on the next call. (The previous implementation
    /// called `flushPromise.succeed(())` unconditionally, which meant the
    /// `whenFailure` block was unreachable.)
    func sendChunkedBinaryData(_ data: Data, context: ChannelHandlerContext) {
        guard !data.isEmpty else { return }
        guard context.channel.isActive else { return }
        let totalBytes = data.count
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + Self.replayChunkSize, data.endIndex)
            let slice = data[offset..<end]
            var buffer = context.channel.allocator.buffer(capacity: slice.count)
            buffer.writeBytes(slice)
            let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
            let isLast = end == data.endIndex
            if isLast {
                // Real promise on the final frame so flush failures reach the log.
                let promise = context.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenFailure { error in
                    RelayLogger.log(.error, category: "connection",
                        "Chunked binary write failed (\(totalBytes) bytes): \(error)")
                }
                context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
            } else {
                context.write(wrapOutboundOut(frame), promise: nil)
            }
            offset = end
        }
    }

    private func sendBinaryData(_ data: Data, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        // Backpressure: if the client is slow (mobile backgrounded, bad network)
        // skip frames. The server's ring buffer holds the authoritative copy;
        // the client replays from there on resume.
        if inflightOutputBytes > Self.maxInflightOutputBytes {
            return
        }
        let byteCount = data.count
        inflightOutputBytes += byteCount
        var buffer = context.channel.allocator.buffer(capacity: byteCount)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak self] result in
            // inflight counter must decrement whether the write succeeded or
            // failed — otherwise a persistent failure would drain the budget.
            self?.inflightOutputBytes -= byteCount
            if case .failure(let error) = result {
                RelayLogger.log(.error, category: "connection",
                    "Binary write failed (\(byteCount) bytes): \(error)")
            }
        }
        context.writeAndFlush(wrapOutboundOut(frame), promise: promise)
    }

    // MARK: - Escape Sequence Filtering
    //
    // The implementation lives in `EscapeResponseFilter` (sibling file).
    // This wrapper keeps the existing `Self.filterEscapeResponses(...)` call
    // sites unchanged.
    static func filterEscapeResponses(_ data: Data) -> Data {
        EscapeResponseFilter.filter(data)
    }

    // MARK: - Event-loop bridge
    //
    // The handler is `@unchecked Sendable`; every read/write of mutable
    // instance state must happen on the channel's event loop. Most request
    // handlers follow the same shape — await something on an actor, then hop
    // back to mutate handler state and send a response. `bridgeToEventLoop`
    // names the pattern so call sites can express the intent in one place
    // instead of copy-pasting the `Task { [weak self] … eventLoop.execute {
    // … } }` scaffolding.
    //
    // Semantics:
    // - `work` runs on the Swift concurrency executor (suspension allowed).
    // - `onSuccess` and `onFailure` are guaranteed to run on the channel
    //   event loop; they may safely mutate handler state.
    // - `self` is captured weakly in both hops. If the handler has been
    //   torn down by the time a callback runs, it silently no-ops.

    func bridgeToEventLoop<T: Sendable>(
        context: ChannelHandlerContext,
        work: @Sendable @escaping () async throws -> T,
        onSuccess: @escaping (_ handler: RelayMessageHandler, _ ctx: ChannelHandlerContext, _ value: T) -> Void,
        onFailure: @escaping (_ handler: RelayMessageHandler, _ ctx: ChannelHandlerContext, _ error: Error) -> Void
    ) {
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            do {
                let value = try await work()
                ctx.value.eventLoop.execute { [weak self] in
                    guard let self else { return }
                    onSuccess(self, ctx.value, value)
                }
            } catch {
                ctx.value.eventLoop.execute { [weak self] in
                    guard let self else { return }
                    onFailure(self, ctx.value, error)
                }
            }
        }
    }

    /// Variant of `bridgeToEventLoop` that hands the `UnsafeTransfer<ChannelHandlerContext>`
    /// to the work closure. Needed by handlers that call helpers like
    /// `autoDetachIfNeeded(ctx:)` which themselves hop back to the event
    /// loop for a snapshot/writeback.
    func bridgeToEventLoopWithCtx<T: Sendable>(
        context: ChannelHandlerContext,
        work: @Sendable @escaping (UnsafeTransfer<ChannelHandlerContext>) async throws -> T,
        onSuccess: @escaping (_ handler: RelayMessageHandler, _ ctx: ChannelHandlerContext, _ value: T) -> Void,
        onFailure: @escaping (_ handler: RelayMessageHandler, _ ctx: ChannelHandlerContext, _ error: Error) -> Void
    ) {
        let ctx = UnsafeTransfer(context)
        Task { [weak self] in
            do {
                let value = try await work(ctx)
                ctx.value.eventLoop.execute { [weak self] in
                    guard let self else { return }
                    onSuccess(self, ctx.value, value)
                }
            } catch {
                ctx.value.eventLoop.execute { [weak self] in
                    guard let self else { return }
                    onFailure(self, ctx.value, error)
                }
            }
        }
    }
}
