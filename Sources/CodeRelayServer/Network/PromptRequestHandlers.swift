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
        optimizeGeneration &+= 1
        let generation = optimizeGeneration

        // Screen goes to the model only when BOTH the relay config and the device ask for it.
        let includeScreen = shareScreen && optimizer.sharesScreen
        let deadline = optimizeDeadline
        let startedAt = Date()

        // Deadline task: cancels work, bumps generation, sends timeout.
        let ctx = UnsafeTransfer(context)
        let deadlineNanos = Int64(deadline.components.seconds) * 1_000_000_000 + deadline.components.attoseconds / 1_000_000_000
        let deadlineTask = context.eventLoop.scheduleTask(in: .nanoseconds(deadlineNanos)) { [weak self] in
            guard let handler = self, handler.optimizeGeneration == generation else { return }
            handler.optimizeWorkTask?.cancel()
            handler.optimizeWorkTask = nil
            handler.optimizeDeadlineTask = nil
            handler.optimizeGeneration &+= 1  // Mark this request resolved
            handler.optimizeInFlight = false
            guard ctx.value.channel.isActive else { return }
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            RelayLogger.log(.debug, category: "optimizer", "optimize_prompt timeout (unavailable) in \(elapsed)ms")
            handler.sendServerMessage(.optimizePromptResult(status: "failed", message: "Optimizer unavailable, try again"), context: ctx.value)
        }
        optimizeDeadlineTask = deadlineTask

        // Work task: model call + PTY write.
        let workTask = Task { [weak self] in
            do {
                let promptContext = await pty.promptContext(includeScreen: includeScreen)
                let trimmed = promptContext.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    try Task.checkCancellation()
                    ctx.value.eventLoop.execute { [weak self] in
                        guard let handler = self, handler.optimizeGeneration == generation else { return }
                        handler.optimizeDeadlineTask?.cancel()
                        handler.optimizeDeadlineTask = nil
                        handler.optimizeWorkTask = nil
                        handler.optimizeGeneration &+= 1
                        handler.optimizeInFlight = false
                        handler.sendServerMessage(.optimizePromptResult(status: "no_draft"), context: ctx.value)
                    }
                    return
                }
                let outcome = try await optimizer.optimize(promptContext)
                try Task.checkCancellation()

                switch outcome {
                case .passthrough:
                    ctx.value.eventLoop.execute { [weak self] in
                        guard let handler = self, handler.optimizeGeneration == generation else { return }
                        handler.optimizeDeadlineTask?.cancel()
                        handler.optimizeDeadlineTask = nil
                        handler.optimizeWorkTask = nil
                        handler.optimizeGeneration &+= 1
                        handler.optimizeInFlight = false
                        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                        RelayLogger.log(.debug, category: "optimizer", "optimize_prompt passthrough in \(elapsed)ms")
                        handler.sendServerMessage(.optimizePromptResult(status: "passthrough"), context: ctx.value)
                    }
                case .optimized(let prompt):
                    // Re-read draft and prepare replacement on the same path.
                    let current = await pty.promptContext(includeScreen: false)
                    let bytes = DraftReplacer.bytes(replacing: current.draft, with: prompt,
                                                    bracketedPaste: current.bracketedPaste,
                                                    keyboardFlags: current.keyboardFlags)
                    try Task.checkCancellation()
                    // Back to event loop: validate attachment, write PTY, then send reply.
                    ctx.value.eventLoop.execute { [weak self] in
                        guard let handler = self, handler.optimizeGeneration == generation else { return }
                        handler.optimizeDeadlineTask?.cancel()
                        handler.optimizeDeadlineTask = nil
                        handler.optimizeWorkTask = nil
                        handler.optimizeGeneration &+= 1
                        handler.optimizeInFlight = false

                        // Re-validate attachment before PTY write.
                        guard handler.attachedSessionId == sessionId, ctx.value.channel.isActive,
                              let pty = handler.attachedPTY else {
                            // Connection detached or closed; write nothing, send nothing.
                            return
                        }
                        // Write PTY first, then send reply to preserve ordering with binary terminal input.
                        Task {
                            await pty.write(bytes)
                            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                            ctx.value.eventLoop.execute { [weak self] in
                                guard let handler = self else { return }
                                RelayLogger.log(.debug, category: "optimizer",
                                    "optimize_prompt ok draft=\(promptContext.draft.utf8.count)B prompt=\(prompt.utf8.count)B in \(elapsed)ms")
                                handler.sendServerMessage(.optimizePromptResult(status: "ok", original: promptContext.draft, prompt: prompt), context: ctx.value)
                            }
                        }
                    }
                }
            } catch {
                ctx.value.eventLoop.execute { [weak self] in
                    guard let handler = self, handler.optimizeGeneration == generation else { return }
                    handler.optimizeDeadlineTask?.cancel()
                    handler.optimizeDeadlineTask = nil
                    handler.optimizeWorkTask = nil
                    handler.optimizeGeneration &+= 1
                    handler.optimizeInFlight = false

                    let errorName: String
                    let clientMessage: String
                    if let optimizerError = error as? OptimizerError {
                        errorName = String(describing: optimizerError).components(separatedBy: "(").first ?? "unknown"
                        clientMessage = optimizerError.clientMessage
                    } else {
                        errorName = "unknown"
                        clientMessage = OptimizerError.unavailable.clientMessage
                    }
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                    RelayLogger.log(.debug, category: "optimizer", "optimize_prompt failed (\(errorName)) in \(elapsed)ms")
                    handler.sendServerMessage(.optimizePromptResult(status: "failed", message: clientMessage), context: ctx.value)
                }
            }
        }
        optimizeWorkTask = workTask
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
            work: { () async throws -> Data in
                let current = await pty.promptContext(includeScreen: false)
                let bytes = DraftReplacer.bytes(replacing: current.draft, with: text,
                                                bracketedPaste: current.bracketedPaste,
                                                keyboardFlags: current.keyboardFlags)
                return bytes
            },
            onSuccess: { handler, ctx, bytes in
                // Re-validate attachment before PTY write.
                guard handler.attachedSessionId == sessionId, ctx.channel.isActive,
                      let pty = handler.attachedPTY else {
                    // Connection detached or closed; write nothing, send nothing.
                    return
                }
                // Write PTY first, then send reply to preserve ordering with binary terminal input.
                Task {
                    await pty.write(bytes)
                    ctx.eventLoop.execute { [weak handler] in
                        guard let handler else { return }
                        RelayLogger.log(.debug, category: "optimizer", "replace_prompt ok text=\(text.utf8.count)B")
                        handler.sendServerMessage(.replacePromptResult(status: "ok"), context: ctx)
                    }
                }
            },
            onFailure: { handler, ctx, _ in
                // `work` has no throwing step today; kept so a future PTY error still answers the waiter.
                handler.sendServerMessage(.replacePromptResult(status: "failed", message: "Replacement failed"), context: ctx)
            }
        )
    }

    /// Cancel optimize state on channel teardown.
    func cleanupOptimizeState() {
        optimizeDeadlineTask?.cancel()
        optimizeWorkTask?.cancel()
        optimizeDeadlineTask = nil
        optimizeWorkTask = nil
        optimizeInFlight = false
    }
}
