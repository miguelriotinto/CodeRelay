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

    /// The button is tappable. Availability is deliberately *not* part of this:
    /// an unavailable wand is drawn dimmed and a tap shows the hint (spec §9).
    public var isWandEnabled: Bool {
        optimizerState == .idle && !isRecovering && activeSessionId != nil
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
        if controller.serverProtocolVersion < 2 {
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
        if optimizerAvailability == .serverTooOld || optimizerAvailability == .unconfigured {
            showOptimizerNotice(wandHint ?? "")
            return
        }

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
                if let original, activeSessionId == sessionId {
                    armOptimizerUndo(OptimizerUndo(sessionId: sessionId, original: original))
                } else {
                    clearOptimizerUndo()
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
    public func undoOptimize() async {
        guard optimizerState == .idle, let undo = optimizerUndo, undo.sessionId == activeSessionId else { return }
        clearOptimizerUndo()
        optimizerState = .optimizing
        defer { optimizerState = .idle }
        do {
            let outcome = try await withAuth { controller in
                try await controller.replacePrompt(sessionId: undo.sessionId, text: undo.original)
            }
            if case .failed(let message) = outcome {
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
