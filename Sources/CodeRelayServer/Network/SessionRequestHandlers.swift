import NIO
import NIOCore
import NIOWebSocket
import Foundation
import CodeRelayKit

// Session-lifecycle request handlers live in this file as an extension on
// `RelayMessageHandler`. Moved out of the parent file so the class body fits
// under the SwiftLint `type_body_length` ceiling; the semantics are unchanged.
//
// These methods are called from `handleAuthenticatedMessage` in the parent
// file. They all follow the same discipline: any work that mutates handler
// state does so inside an `onSuccess` / `onFailure` closure handed to
// `bridgeToEventLoop(...)`, which guarantees the callback runs on the
// channel event loop.
//
// UNATTACHED-REQUEST REPLY RULE — a fire-and-forget request must never be
// answered with `.error`.
//
// Replies carry no request ids, so a client waiter can only correlate on the
// response *type* — and `error` is a legal reply to every request, so every
// waiter's match set is `expected ∪ {"error"}` (see
// `SessionController.awaitResponse`). An `.error` produced by a request nobody
// is awaiting therefore resolves whichever RPC happens to be in flight, and
// that waiter has no way to reject it.
//
// `resize`, `refresh` and `paste_image` are all fire-and-forget: the client
// sends them from a `Task` and never reads their acks. When one arrived while
// the handler was unattached, replying `.error(400, "No session attached")`
// handed that error to the concurrent `session_resume` waiter, which failed the
// switch and surfaced iOS's "Unexpected server response: No session attached" —
// then rolled the pane back to the previous session. The race is routine rather
// than exotic: `switchToSession` publishes the new selection *before* its RPCs,
// so the incoming terminal view lays out and reports its grid while
// `session_resume` is still on the wire and `attachedPTY` is briefly nil.
//
// So those handlers never reply (logging at debug), matching
// `handleBinaryFrame`, which has always silently dropped terminal input when
// unattached. `refresh` is dropped outright. An authenticated-but-unattached
// `resize` is **deferred** into `pendingGrid` and applied by the next
// attach/resume/create (still silently) — a *pre-auth* one is still dropped by
// `handleUnauthenticatedMessage` (RelayMessageHandler.swift) before it reaches
// `handleResize`; clients also send their grid on the attach/resume request
// itself, which wins. Note the mirror case: a `resize` that arrives BEFORE the
// client's `detach` lands still takes the attached path and resizes the
// *outgoing* session's PTY — pre-existing, and it self-heals on the next attach,
// which carries its own grid.
//
// Deferral matters because nothing else would ever recover that grid. Two
// plausible-sounding recovery paths do NOT exist: SwiftTerm only fires
// `sizeChanged` when the grid actually *changes*, so a client whose grid is
// already correct never re-sends; and `forceRepaint()` wiggles to
// `currentCols - 1` and back to the PTY's *own* stored `currentCols`, so it
// never learns a value it was not told. Before `pendingGrid`, a resize dropped
// here left the PTY at the previous device's width until the next real layout
// change (rotation, split, font change) — the "garbled after switching" bug.
// What has not changed is the reply: an `.error` here fails an unrelated RPC,
// and a client-side timeout poisons the socket via `desyncedGeneration`. A wrong
// grid is recoverable by the user; a poisoned socket is not.
//
// The rule is about the reply *type*, not about staying silent — a request with
// a dedicated failure reply should still use it (`paste_image` answers
// `.pasteImageResult(success: false)`).
//
// Which handlers may reply `.error`: only those with a real waiter on both
// clients — `attach`, `resume`, `detach`, `create`, `list`. `rename` and
// `terminate` look like request-response but are **fire-and-forget on both
// clients** (bare `connection.send`, no `sendAndWaitForResponse`), so their
// failure paths must not reply `.error` either; they log instead. Before adding
// an `.error` to any handler, check the actual client call site — the shape of
// the server method tells you nothing about whether a waiter exists.

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
        let myStealId = self.stealObserverId
        // Same "request grid wins" rule as attach/resume: a request carrying its
        // own grid discards a stale deferred one; a request without spawns at
        // the deferred size instead of the 80x24 default.
        let grid = takeGrid(cols: cols, rows: rows)
        bridgeToEventLoopWithCtx(
            context: context,
            work: { [weak self] ctx -> (SessionInfo, any PTYSessionProtocol) in
                await self?.autoDetachIfNeeded(ctx: ctx)
                let info = try await mgr.createSession(
                    tokenId: tokenId, cols: grid?.cols ?? 80, rows: grid?.rows ?? 24, name: name)
                // Attach immediately. Exclude our own steal observer so the
                // creating connection isn't told it "stole" the session it just
                // created (attachSession always fires steal notifications).
                let (_, pty) = try await mgr.attachSession(id: info.id, tokenId: tokenId, excludeObserver: myStealId)
                RelayLogger.log(category: "session",
                                "Session created: \(info.id) (name: \(name ?? "nil"))" + RelayMessageHandler.gridSuffix(grid))
                return (info, pty)
            },
            onSuccess: { handler, ctx, pair in
                let (info, pty) = pair
                handler.attachedSessionId = info.id
                handler.attachedPTY = pty
                // A resize that arrived while the create RPC was in flight
                // (after `takeGrid` ran). Create ends attached, so it must
                // consume it like attach/resume do — otherwise it lingers and
                // lands stale on a later attach.
                handler.applyLatePendingGrid(to: pty)
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
            onFailure: { _, _, error in
                // Dropped, NOT answered with `.error` — see the unattached-request
                // reply rule at the top of this file. `renameSession` is
                // fire-and-forget on both clients, so an `.error` here would
                // resolve whichever unrelated RPC is in flight (a rename racing a
                // session switch would fail the switch). The client re-reads names
                // from the next `session_list`, so a failed rename self-corrects.
                RelayLogger.log(.debug, category: "session",
                                "rename of \(sessionId) dropped: \(error)")
            }
        )
    }

    // MARK: - Attach grid

    /// The grid this attach/resume/create should apply: the request's own, else
    /// one deferred by an unattached `resize`. Consumes the deferred grid either
    /// way (for create it is the spawn size, not a resize). A partial request
    /// grid (only one of `cols`/`rows`) is intentionally treated as absent and
    /// falls through to `pendingGrid` — Kit's `encodeIfPresent` can put a half
    /// grid on the wire, but a half grid is never applied.
    /// Event-loop only (it touches `pendingGrid`) — call it *before*
    /// `bridgeToEventLoopWithCtx` so the work closure captures the result.
    private func takeGrid(cols: UInt16?, rows: UInt16?) -> (cols: UInt16, rows: UInt16)? {
        defer { pendingGrid = nil }
        if let cols, let rows { return (cols, rows) }
        return pendingGrid
    }

    /// Applies a `resize` that arrived while the attach/resume/create was in
    /// flight (after `takeGrid` ran, before `attachedPTY` was set). Called from
    /// `onSuccess`, on the event loop, right after `attachedPTY = pty`, by every
    /// handler that ends attached. The
    /// kernel's own SIGWINCH for this resize makes the app redraw at the new
    /// grid, so ordering against the `forceRepaint` Task does not matter.
    private func applyLatePendingGrid(to pty: any PTYSessionProtocol) {
        guard let late = pendingGrid else { return }
        pendingGrid = nil
        Task { await pty.resize(cols: late.cols, rows: late.rows) }
    }

    /// Log-line suffix for an applied grid (cols×rows only — never screen text).
    private static func gridSuffix(_ grid: (cols: UInt16, rows: UInt16)?) -> String {
        grid.map { " grid=\($0.cols)x\($0.rows)" } ?? ""
    }

    // MARK: - Session Attach

    func handleSessionAttach(sessionId: UUID, cols: UInt16?, rows: UInt16?, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let mgr = self.sessionManager
        let myStealId = self.stealObserverId
        let grid = takeGrid(cols: cols, rows: rows)
        bridgeToEventLoopWithCtx(
            context: context,
            work: { [weak self] ctx -> (SessionInfo, any PTYSessionProtocol, Data, ActivitySnapshot) in
                await self?.autoDetachIfNeeded(ctx: ctx)
                let (info, pty) = try await mgr.attachSession(id: sessionId, tokenId: tokenId, excludeObserver: myStealId)
                // Before `readBuffer()`: the replayed bytes re-wrap and the
                // post-replay repaint redraws at *this* device's grid.
                if let grid { await pty.resize(cols: grid.cols, rows: grid.rows) }
                let buffered = await pty.readBuffer()
                let filtered = RelayMessageHandler.filterEscapeResponses(buffered)
                let snapshot = ActivitySnapshot(
                    activity: await pty.getActivityState(),
                    agent: await pty.getActiveAgent(),
                    agentState: await pty.getAgentState(),
                    title: await pty.getTitle()
                )
                RelayLogger.log(category: "session",
                                "Session attached: \(sessionId)" + RelayMessageHandler.gridSuffix(grid))
                return (info, pty, filtered, snapshot)
            },
            onSuccess: { handler, ctx, tuple in
                let (info, pty, filtered, snapshot) = tuple
                handler.attachedSessionId = sessionId
                handler.attachedPTY = pty
                handler.applyLatePendingGrid(to: pty)
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

    func handleSessionResume(sessionId: UUID, skipReplay: Bool, cols: UInt16?, rows: UInt16?, context: ChannelHandlerContext) {
        guard let tokenId = authenticatedTokenId else { return }
        let mgr = self.sessionManager
        let myStealId = self.stealObserverId
        let grid = takeGrid(cols: cols, rows: rows)
        bridgeToEventLoopWithCtx(
            context: context,
            work: { [weak self] ctx -> (any PTYSessionProtocol, Data, ActivitySnapshot) in
                await self?.autoDetachIfNeeded(ctx: ctx)
                let (_, _, pty) = try await mgr.resumeSession(id: sessionId, tokenId: tokenId, excludeObserver: myStealId)
                // Before the buffer read, and even when `skipReplay` is true:
                // the repaint that follows must redraw at this device's grid.
                if let grid { await pty.resize(cols: grid.cols, rows: grid.rows) }
                RelayLogger.log(category: "session",
                                "Session resumed: \(sessionId) (skipReplay=\(skipReplay))"
                                    + RelayMessageHandler.gridSuffix(grid))
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
                handler.applyLatePendingGrid(to: pty)
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
            onFailure: { _, _, error in
                // Dropped, NOT answered with `.error` — see the unattached-request
                // reply rule at the top of this file. Terminate is fire-and-forget
                // (`SharedSessionCoordinator` sends it, then immediately calls
                // `fetchSessions()`), so an `.error` here lands on that
                // `session_list` waiter. The refresh is also the recovery: a
                // terminate that failed leaves the session in the list.
                RelayLogger.log(.debug, category: "session",
                                "terminate of \(sessionId) dropped: \(error)")
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
                // Logged because this is THE answer to "which sessions does this
                // client own" — the question behind every empty-pane report. With
                // no log line, diagnosing one meant guessing from the client side;
                // five fixes shipped that way. tokenId is truncated: it is a
                // credential identifier, and 8 chars is enough to correlate with
                // `claude-relay token list`.
                RelayLogger.log(category: "session",
                                "session_list token=\(tokenId.prefix(8)) → \(sessions.count) session(s)")
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
            // Deferred, not dropped: applied by the next attach/resume (see
            // `pendingGrid`). A resize racing a session switch is routine: the
            // client publishes the new selection before its RPCs, so the
            // incoming terminal lays out (and reports its grid) while
            // `session_resume` is still in flight and we are briefly unattached.
            // Still no reply — resize is fire-and-forget and a `.error` here
            // would resolve whatever RPC is in flight (header). A 0x0 grid was
            // inert before deferral existed; keep it inert rather than spawn or
            // resize a PTY to it.
            guard cols > 0, rows > 0 else { return }
            pendingGrid = (cols, rows)
            RelayLogger.log(.debug, category: "session", "resize \(cols)x\(rows) deferred until attach")
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
            // Dropped, not answered — see the reply rule at the top of this
            // file. Doubly clear here: this request has no ack even on success,
            // so an `.error` was the only reply it could ever produce, and there
            // is no waiter it could legitimately belong to.
            RelayLogger.log(.debug, category: "session", "refresh dropped: no session attached")
            return
        }
        Task {
            await pty.forceRepaint()
        }
    }
}
