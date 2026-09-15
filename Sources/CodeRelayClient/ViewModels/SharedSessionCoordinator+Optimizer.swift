import Foundation
import CodeRelayKit

/// Whether the wand may be used against the connected relay (spec §7.1).
public enum OptimizerAvailability: Equatable, Sendable {
    /// Not authenticated yet.
    case unknown
    /// `protocolVersion < 2`: the relay predates the optimizer RPCs.
    case serverTooOld
    /// Relay speaks v2 but did not advertise `prompt_optimizer`.
    case unconfigured
    case available
}

public enum OptimizerState: Equatable, Sendable {
    case idle
    case optimizing
}

/// What Undo will put back, and at which session.
public struct OptimizerUndo: Equatable, Sendable {
    public let sessionId: UUID
    public let original: String

    public init(sessionId: UUID, original: String) {
        self.sessionId = sessionId
        self.original = original
    }
}

extension SharedSessionCoordinator {

    /// The first relay protocol version that carries `optimize_prompt` /
    /// `replace_prompt` (spec §7.1). Deliberately NOT `CodeRelayKit.protocolVersion`:
    /// that is the version *this client* speaks and will move; the gate must not.
    public static let optimizerMinimumProtocolVersion = 2

    /// The button is tappable. Availability is deliberately *not* part of this:
    /// an unavailable wand is drawn dimmed and a tap shows the hint (spec §9).
    ///
    /// `!isTornDown` is defence in depth: the button dies with the view, but a
    /// programmatic tap (the keyboard-shortcut notification) on a coordinator
    /// that has already been torn down would otherwise reach
    /// `ensureAuthenticated()` and open a fresh `auth_request` on an
    /// invalidated coordinator.
    public var isWandEnabled: Bool {
        optimizerState == .idle && !isRecovering && !isTornDown && activeSessionId != nil
    }

    public var isOptimizerAvailable: Bool { optimizerAvailability == .available }

    /// Tooltip / footer for a dimmed wand; nil when available or unknown.
    public var wandHint: String? {
        switch optimizerAvailability {
        case .available, .unknown: return nil
        case .serverTooOld: return OptimizerStrings.updateRelayHint
        case .unconfigured: return OptimizerStrings.configHint
        }
    }

    /// Re-derive availability from the current controller. Called after every
    /// authentication and before every optimize.
    public func refreshOptimizerAvailability() {
        guard let controller = sessionController, controller.isAuthenticated else {
            optimizerAvailability = .unknown
            return
        }
        if controller.serverProtocolVersion < Self.optimizerMinimumProtocolVersion {
            optimizerAvailability = .serverTooOld
        } else if controller.serverCapabilities.contains(CodeRelayKit.promptOptimizerCapability) {
            optimizerAvailability = .available
        } else {
            optimizerAvailability = .unconfigured
        }
    }

    /// Wand tap. Never throws: every outcome becomes state or a toast.
    public func optimizePrompt(shareScreen: Bool) async {
        guard isWandEnabled, let sessionId = activeSessionId else { return }

        // Fast path: show hint immediately for known-unavailable relays without
        // entering .optimizing or making any network call.
        if let hint = wandHint {
            showOptimizerNotice(hint)
            return
        }

        // A notice from the *previous* tap lives on its own 4 s timer. Leaving it
        // up would render a stale failure toast beside this attempt's result —
        // e.g. `Optimizer unavailable, try again` next to `Optimized · Undo`.
        dismissOptimizerNotice()
        optimizerState = .optimizing
        defer { optimizerState = .idle }

        do {
            _ = try await ensureAuthenticated()
            refreshOptimizerAvailability()
            switch optimizerAvailability {
            case .serverTooOld:
                showOptimizerNotice(OptimizerStrings.updateRelayHint)
                return
            case .unconfigured:
                showOptimizerNotice(OptimizerStrings.configHint)
                return
            case .unknown, .available:
                break
            }

            let outcome = try await withAuth { controller in
                try await controller.optimizePrompt(sessionId: sessionId, shareScreen: shareScreen)
            }
            switch outcome {
            case .ok(let original):
                if activeSessionId != sessionId {
                    // Session switched mid-optimize: the reply belongs to a
                    // session the user is no longer looking at. No undo, and no
                    // toast either — it would read as this session's result.
                    clearOptimizerUndo()
                } else if let original {
                    armOptimizerUndo(OptimizerUndo(sessionId: sessionId, original: original))
                } else {
                    // The relay rewrote the draft but was not tracking what it
                    // replaced, so there is nothing to put back. Confirm the
                    // rewrite anyway (spec §7.1) — without an Undo affordance.
                    clearOptimizerUndo()
                    showOptimizerNotice(OptimizerStrings.optimized)
                }
            case .noDraft:
                showOptimizerNotice(OptimizerStrings.noDraft)
            case .passthrough:
                showOptimizerNotice(OptimizerStrings.passthrough)
            case .unconfigured:
                optimizerAvailability = .unconfigured
                showOptimizerNotice(OptimizerStrings.configHint)
            case .failed(let message):
                showOptimizerNotice(message)
            }
        } catch {
            showOptimizerNotice(optimizerMessage(for: error))
        }
    }

    /// Undo chip tap: put the original back. One-shot.
    ///
    /// The undo is cleared **only on success.** After a successful optimize the
    /// terminal's input line holds the rewrite and `optimizerUndo` is the only
    /// copy of what the user actually typed; clearing it before the RPC would
    /// destroy that draft whenever the replace failed (spec §9 lists two such
    /// rows, plus timeout and a mid-flight disconnect). This matches the
    /// deliberate choice on the sibling path — a failed *re-optimize* keeps the
    /// existing undo too. One-shot-ness does not depend on the early clear: the
    /// `isWandEnabled` guard plus `optimizerState = .optimizing` already block a
    /// double tap, and not clearing leaves the 10 s expiry task running, so the
    /// chip still disappears on its original schedule.
    public func undoOptimize() async {
        guard isWandEnabled, let undo = optimizerUndo, undo.sessionId == activeSessionId else { return }
        optimizerState = .optimizing
        defer { optimizerState = .idle }
        do {
            let outcome = try await withAuth { controller in
                try await controller.replacePrompt(sessionId: undo.sessionId, text: undo.original)
            }
            switch outcome {
            case .ok:
                clearOptimizerUndo()
            case .failed(let message):
                showOptimizerNotice(message)
            }
        } catch {
            showOptimizerNotice(optimizerMessage(for: error))
        }
    }

    public func dismissOptimizerNotice() {
        optimizerNoticeTask?.cancel()
        optimizerNoticeTask = nil
        optimizerNotice = nil
    }

    // MARK: - Internals

    func showOptimizerNotice(_ text: String) {
        optimizerNoticeTask?.cancel()
        optimizerNotice = text
        let duration = optimizerNoticeDuration
        optimizerNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.optimizerNotice = nil
        }
    }

    func armOptimizerUndo(_ undo: OptimizerUndo) {
        optimizerUndoTask?.cancel()
        optimizerUndo = undo
        let window = optimizerUndoWindow
        optimizerUndoTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.optimizerUndo = nil
        }
    }

    func clearOptimizerUndo() {
        optimizerUndoTask?.cancel()
        optimizerUndoTask = nil
        optimizerUndo = nil
    }

    /// `.error` replies carry the relay's message (e.g. "Session not attached");
    /// anything else (timeout, dead socket) gets the generic fallback. Never
    /// includes draft/prompt text.
    private func optimizerMessage(for error: Error) -> String {
        if case SessionController.SessionError.unexpectedResponse(let message) = error, !message.isEmpty {
            return message
        }
        return OptimizerStrings.couldNotRewrite
    }
}
