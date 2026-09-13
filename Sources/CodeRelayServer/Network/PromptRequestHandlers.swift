import Foundation
import NIOCore
import CodeRelayKit

/// `optimize_prompt` / `replace_prompt` (spec §5.1, §6, §7).
///
/// Both are RPCs with a dedicated result type, so an unattached request IS
/// answered — `status: "failed"` on `optimize_prompt_result` /
/// `replace_prompt_result` — and never with `.error`. The rule atop
/// `SessionRequestHandlers.swift` is about the reply *type*: an `.error` here
/// would resolve whichever unrelated RPC the client has in flight.
///
/// Logging: byte counts, status and latency only. The draft, the rewritten
/// prompt and the screen never reach a log line (spec §9).
extension RelayMessageHandler {

    /// `replace_prompt.text` cap (spec §6 "Replacement too long").
    static let maxReplaceTextBytes = 16_384

    func handleOptimizePrompt(sessionId: UUID, shareScreen: Bool, context: ChannelHandlerContext) {
        guard let pty = attachedPTY, attachedSessionId == sessionId else {
            sendServerMessage(.optimizePromptResult(status: "failed", message: "Session not attached"), context: context)
            return
        }
        guard let optimizer else {
            sendServerMessage(.optimizePromptResult(status: "unconfigured",
                                                    message: "Optimizer not configured on the relay"), context: context)
            return
        }
        guard !optimizeInFlight else {
            sendServerMessage(.optimizePromptResult(status: "failed", message: "Already optimizing"), context: context)
            return
        }
        optimizeInFlight = true

        // Screen goes to the model only when BOTH the relay config and the device ask for it.
        let includeScreen = shareScreen && optimizer.sharesScreen
        let deadline = optimizeDeadline
        let startedAt = Date()

        bridgeToEventLoop(
            context: context,
            work: { () async throws -> ServerMessage in
                try await Self.withDeadline(deadline) {
                    let promptContext = await pty.promptContext(includeScreen: includeScreen)
                    if promptContext.draft.isEmpty {
                        return .optimizePromptResult(status: "no_draft")
                    }
                    switch try await optimizer.optimize(promptContext) {
                    case .passthrough:
                        return .optimizePromptResult(status: "passthrough")
                    case .optimized(let prompt):
                        // Re-read the draft right before typing: the user may have kept
                        // editing while the model ran, and the replacement must erase
                        // exactly what is on the line now.
                        let current = await pty.promptContext(includeScreen: false)
                        let bytes = DraftReplacer.bytes(replacing: current.draft, with: prompt,
                                                        bracketedPaste: current.bracketedPaste,
                                                        keyboardFlags: current.keyboardFlags)
                        try Task.checkCancellation()   // deadline fired while we were looking
                        await pty.write(bytes)
                        return .optimizePromptResult(status: "ok", original: promptContext.draft, prompt: prompt)
                    }
                }
            },
            onSuccess: { handler, ctx, message in
                handler.optimizeInFlight = false
                if case .optimizePromptResult(let status, let original, let prompt, _) = message {
                    RelayLogger.log(.debug, category: "optimizer",
                        "optimize_prompt \(status) draft=\(original?.utf8.count ?? 0)B prompt=\(prompt?.utf8.count ?? 0)B "
                        + "in \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
                }
                handler.sendServerMessage(message, context: ctx)
            },
            onFailure: { handler, ctx, error in
                handler.optimizeInFlight = false
                let text = (error as? OptimizerError)?.clientMessage ?? OptimizerError.unavailable.clientMessage
                RelayLogger.log(.debug, category: "optimizer",
                    "optimize_prompt failed (\(text)) in \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
                handler.sendServerMessage(.optimizePromptResult(status: "failed", message: text), context: ctx)
            }
        )
    }

    func handleReplacePrompt(sessionId: UUID, text: String, context: ChannelHandlerContext) {
        guard let pty = attachedPTY, attachedSessionId == sessionId else {
            sendServerMessage(.replacePromptResult(status: "failed", message: "Session not attached"), context: context)
            return
        }
        guard text.utf8.count <= Self.maxReplaceTextBytes else {
            sendServerMessage(.replacePromptResult(status: "failed", message: "Replacement too long"), context: context)
            return
        }
        bridgeToEventLoop(
            context: context,
            work: { () async throws -> Void in
                let current = await pty.promptContext(includeScreen: false)
                let bytes = DraftReplacer.bytes(replacing: current.draft, with: text,
                                                bracketedPaste: current.bracketedPaste,
                                                keyboardFlags: current.keyboardFlags)
                await pty.write(bytes)
            },
            onSuccess: { handler, ctx, _ in
                RelayLogger.log(.debug, category: "optimizer", "replace_prompt ok text=\(text.utf8.count)B")
                handler.sendServerMessage(.replacePromptResult(status: "ok"), context: ctx)
            },
            onFailure: { handler, ctx, _ in
                // `work` has no throwing step today; kept so a future PTY error still answers the waiter.
                handler.sendServerMessage(.replacePromptResult(status: "failed", message: "Replacement failed"), context: ctx)
            }
        )
    }

    /// Races `operation` against `deadline`; the loser is cancelled. A timeout
    /// surfaces as `OptimizerError.unavailable` ("Optimizer unavailable, try again").
    static func withDeadline<T: Sendable>(
        _ deadline: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw OptimizerError.unavailable
            }
            guard let first = try await group.next() else { throw OptimizerError.unavailable }
            group.cancelAll()
            return first
        }
    }
}
