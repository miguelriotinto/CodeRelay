import NIO
import NIOCore
import NIOWebSocket
import Foundation
import ClaudeRelayKit

// Session-lifecycle request handlers live in this file as an extension on
// `RelayMessageHandler`. Moved out of the parent file so the class body fits
// under the SwiftLint `type_body_length` ceiling; the semantics are unchanged.
//
// These methods are called from `handleAuthenticatedMessage` in the parent
// file. They all follow the same discipline: any work that mutates handler
// state does so inside an `onSuccess` / `onFailure` closure handed to
// `bridgeToEventLoop(...)`, which guarantees the callback runs on the
// channel event loop.

extension RelayMessageHandler {

    /// Bundles the activity fields read off a PTY at attach/resume time.
    /// Returning a struct instead of a wide tuple keeps the work-closure
    /// return type under SwiftLint's `large_tuple` threshold.
    struct ActivitySnapshot {
        let activity: ActivityState
        let agent: CodingAgent?
        let agentState: AgentDetectedState?
        let title: String?
    }

    // MARK: - Session Create

    func handleSessionCreate(name: String?, cols: UInt16?, rows: UInt16?, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let mgr = self.sessionManager
        bridgeToEventLoopWithCtx(
            context: context,
            work: { [weak self] ctx -> (SessionInfo, any PTYSessionProtocol) in
                await self?.autoDetachIfNeeded(ctx: ctx)
                let info = try await mgr.createSession(tokenId: tokenId, cols: cols ?? 80, rows: rows ?? 24, name: name)
                // Attach immediately.
                let (_, pty) = try await mgr.attachSession(id: info.id, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session created: \(info.id) (name: \(name ?? "nil"))")
                return (info, pty)
            },
            onSuccess: { handler, ctx, pair in
                let (info, pty) = pair
                handler.attachedSessionId = info.id
                handler.attachedPTY = pty
                handler.sendServerMessage(.sessionCreated(sessionId: info.id, cols: info.cols, rows: info.rows), context: ctx)
                handler.wirePTYOutput(pty: pty, context: ctx)
            },
            onFailure: { handler, ctx, error in
                RelayLogger.log(.error, category: "session", "Session create failed: \(error)")
                handler.sendServerMessage(.error(code: 500, message: "Failed to create session: \(error)"), context: ctx)
            }
        )
    }

    func handleSessionRename(sessionId: UUID, name: String, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let mgr = self.sessionManager
        bridgeToEventLoop(
            context: context,
            work: {
                try await mgr.renameSession(id: sessionId, tokenId: tokenId, name: name)
            },
            onSuccess: { _, _, _ in
                RelayLogger.log(category: "session", "Session renamed: \(sessionId) -> \(name)")
            },
            onFailure: { handler, ctx, error in
                handler.sendServerMessage(.error(code: 404, message: "Rename failed: \(error)"), context: ctx)
            }
        )
    }

    // MARK: - Session Attach

    func handleSessionAttach(sessionId: UUID, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let mgr = self.sessionManager
        let myStealId = self.stealObserverId
        bridgeToEventLoopWithCtx(
            context: context,
            work: { [weak self] ctx -> (SessionInfo, any PTYSessionProtocol, Data, ActivitySnapshot) in
                await self?.autoDetachIfNeeded(ctx: ctx)
                let (info, pty) = try await mgr.attachSession(id: sessionId, tokenId: tokenId, excludeObserver: myStealId)
                let buffered = await pty.readBuffer()
                let filtered = RelayMessageHandler.filterEscapeResponses(buffered)
                let snapshot = ActivitySnapshot(
                    activity: await pty.getActivityState(),
                    agent: await pty.getActiveAgent(),
                    agentState: await pty.getAgentState(),
                    title: await pty.getTitle()
                )
                RelayLogger.log(category: "session", "Session attached: \(sessionId)")
                return (info, pty, filtered, snapshot)
            },
            onSuccess: { handler, ctx, tuple in
                let (info, pty, filtered, snapshot) = tuple
                handler.attachedSessionId = sessionId
                handler.attachedPTY = pty
                handler.sendServerMessage(.sessionAttached(sessionId: sessionId, state: info.state.rawValue), context: ctx)
                if !filtered.isEmpty {
                    handler.sendChunkedBinaryData(filtered, context: ctx)
                }
                handler.sendServerMessage(.replayComplete(sessionId: sessionId), context: ctx)
                handler.sendServerMessage(
                    .sessionActivity(sessionId: sessionId, activity: snapshot.activity, agent: snapshot.agent?.id,
                                     agentState: snapshot.agentState, title: snapshot.title),
                    context: ctx
                )
                // repaintAfter: the replayed ring-buffer bytes were emitted for
                // whatever grid existed when they were generated; a SIGWINCH
                // after the handler is wired makes the foreground app redraw
                // at the current grid, replacing any mis-wrapped replay.
                handler.wirePTYOutput(pty: pty, context: ctx, repaintAfter: true)
            },
            onFailure: { handler, ctx, error in
                RelayLogger.log(.error, category: "session", "Attach failed for \(sessionId): \(error)")
                handler.sendServerMessage(.error(code: 404, message: "Attach failed: \(error)"), context: ctx)
            }
        )
    }

    // MARK: - Session Resume

    func handleSessionResume(sessionId: UUID, skipReplay: Bool, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let mgr = self.sessionManager
        let myStealId = self.stealObserverId
        bridgeToEventLoopWithCtx(
            context: context,
            work: { [weak self] ctx -> (any PTYSessionProtocol, Data, ActivitySnapshot) in
                await self?.autoDetachIfNeeded(ctx: ctx)
                let (_, _, pty) = try await mgr.resumeSession(id: sessionId, tokenId: tokenId, excludeObserver: myStealId)
                RelayLogger.log(category: "session", "Session resumed: \(sessionId) (skipReplay=\(skipReplay))")
                // Read scrollback history to send to client, unless the client
                // already has a live terminal with full scrollback (tab switch).
                let buffered = skipReplay ? Data() : await pty.readBuffer()
                let stripped = RelayMessageHandler.filterEscapeResponses(buffered)
                let filtered = ScrollbackSanitizer.sanitize(stripped)
                let snapshot = ActivitySnapshot(
                    activity: await pty.getActivityState(),
                    agent: await pty.getActiveAgent(),
                    agentState: await pty.getAgentState(),
                    title: await pty.getTitle()
                )
                return (pty, filtered, snapshot)
            },
            onSuccess: { handler, ctx, tuple in
                let (pty, filtered, snapshot) = tuple
                handler.attachedSessionId = sessionId
                handler.attachedPTY = pty
                handler.sendServerMessage(.sessionResumed(sessionId: sessionId), context: ctx)
                if !filtered.isEmpty {
                    handler.sendChunkedBinaryData(filtered, context: ctx)
                }
                handler.sendServerMessage(.replayComplete(sessionId: sessionId), context: ctx)
                handler.sendServerMessage(
                    .sessionActivity(sessionId: sessionId, activity: snapshot.activity, agent: snapshot.agent?.id,
                                     agentState: snapshot.agentState, title: snapshot.title),
                    context: ctx
                )
                // repaintAfter even when skipReplay=true: a tab switch back to
                // a cached terminal can still be stale if the session's grid
                // changed while another device was attached.
                handler.wirePTYOutput(pty: pty, context: ctx, repaintAfter: true)
            },
            onFailure: { handler, ctx, error in
                handler.sendServerMessage(.error(code: 404, message: "Resume failed: \(error)"), context: ctx)
            }
        )
    }

    // MARK: - Session Detach

    func handleSessionDetach(context: ChannelHandlerContext) {
        guard let sessionId = attachedSessionId else {
            sendServerMessage(.error(code: 400, message: "No session attached"), context: context)
            return
        }
        let mgr = self.sessionManager
        bridgeToEventLoop(
            context: context,
            work: {
                try await mgr.detachSession(id: sessionId)
                RelayLogger.log(category: "session", "Session detached: \(sessionId)")
            },
            onSuccess: { handler, ctx, _ in
                handler.attachedSessionId = nil
                handler.attachedPTY = nil
                handler.sendServerMessage(.sessionDetached, context: ctx)
            },
            onFailure: { handler, ctx, error in
                handler.sendServerMessage(.error(code: 500, message: "Detach failed: \(error)"), context: ctx)
            }
        )
    }

    // MARK: - Session Terminate

    func handleSessionTerminate(sessionId: UUID, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let mgr = self.sessionManager
        bridgeToEventLoop(
            context: context,
            work: {
                try await mgr.terminateSession(id: sessionId, tokenId: tokenId)
                RelayLogger.log(category: "session", "Session terminated: \(sessionId)")
            },
            onSuccess: { handler, ctx, _ in
                handler.sendServerMessage(.sessionTerminated(sessionId: sessionId, reason: "client_request"), context: ctx)
                if handler.attachedSessionId == sessionId {
                    handler.attachedSessionId = nil
                    handler.attachedPTY = nil
                }
            },
            onFailure: { handler, ctx, error in
                handler.sendServerMessage(.error(code: 404, message: "Terminate failed: \(error)"), context: ctx)
            }
        )
    }

    // MARK: - Session List

    func handleSessionList(context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let mgr = self.sessionManager
        bridgeToEventLoop(
            context: context,
            work: { await mgr.listSessionsForToken(tokenId: tokenId) },
            onSuccess: { handler, ctx, sessions in
                handler.sendServerMessage(.sessionList(sessions: sessions), context: ctx)
            },
            onFailure: { _, _, _ in /* listSessionsForToken doesn't throw */ }
        )
    }

    func handleSessionListAll(context: ChannelHandlerContext) {
        guard isAuthenticated else { return }
        let mgr = self.sessionManager
        bridgeToEventLoop(
            context: context,
            work: { await mgr.listAllSessions() },
            onSuccess: { handler, ctx, sessions in
                handler.sendServerMessage(.sessionListAll(sessions: sessions), context: ctx)
            },
            onFailure: { _, _, _ in /* listAllSessions doesn't throw */ }
        )
    }

    // MARK: - Resize

    func handleResize(cols: UInt16, rows: UInt16, context: ChannelHandlerContext) {
        guard let pty = attachedPTY else {
            sendServerMessage(.error(code: 400, message: "No session attached"), context: context)
            return
        }
        bridgeToEventLoop(
            context: context,
            work: { await pty.resize(cols: cols, rows: rows) },
            onSuccess: { handler, ctx, _ in
                handler.sendServerMessage(.resizeAck(cols: cols, rows: rows), context: ctx)
            },
            onFailure: { _, _, _ in /* resize doesn't throw */ }
        )
    }

    /// Resize-wiggle the PTY so full-screen apps re-emit their screen. Same
    /// mechanism `wirePTYOutput(repaintAfter:)` uses after a replay; here it's
    /// client-requested (tap-to-redraw). Fire-and-forget — no ack, the repaint
    /// bytes ARE the response.
    func handleRefresh(context: ChannelHandlerContext) {
        guard let pty = attachedPTY else {
            sendServerMessage(.error(code: 400, message: "No session attached"), context: context)
            return
        }
        Task {
            await pty.forceRepaint()
        }
    }
}
