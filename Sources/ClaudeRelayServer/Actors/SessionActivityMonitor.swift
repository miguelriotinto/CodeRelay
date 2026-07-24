import Foundation
import ClaudeRelayKit

/// Monitors terminal output for a single session and maintains its `ActivityState`.
///
/// Runs inside the owning `PTYSession` actor's isolation domain — NOT a separate actor.
/// This avoids async overhead on the hot path (every output chunk goes through here).
///
/// Detection mechanisms (in priority order):
/// 1. **Foreground process polling**: tcgetpgrp + KERN_PROCARGS2 with parent chain walk
/// 2. **OSC title sequences**: fallback when shell sets title containing an agent keyword
///
/// Exit is debounced: requires two consecutive non-agent signals to prevent false
/// exits during momentary tool-launch process group changes.
public final class SessionActivityMonitor: @unchecked Sendable {

    // MARK: - State

    /// Current activity state. Read from any context; mutated only via `processOutput`/`recordInput`.
    public private(set) var state: ActivityState = .active

    /// The coding agent currently detected as running, or nil.
    public private(set) var activeAgent: CodingAgent?

    /// Fine-grained agent state from screen detection (Phase 2). Nil in Phase 1
    /// — the arbiter that populates it is added in a later task.
    public private(set) var agentState: AgentDetectedState?

    /// Latest window title (OSC 0/2) observed for this session, if any.
    public private(set) var title: String?

    // MARK: - Screen-Detection Arbiter (Phase 2)

    private var agentEnteredAt: Date?
    private var pendingIdleStartedAt: Date?
    private var pendingIdleConfirmations: Int = 0
    private var lastVisibleIdle = false
    private var lastVisibleBlocker = false
    private var lastVisibleWorking = false
    private static let pendingIdleCap: TimeInterval = 0.7
    private static let pendingIdleConfirmationLimit = 3
    private static let startupGrace: TimeInterval = 3.0

    // MARK: - Hook-Authored State Authority (F6)

    /// Timestamp of the most recent state authored by a local agent hook (e.g.
    /// the Claude Code lifecycle hook), or nil if none. While this is *fresh*
    /// (within `hookStateTTL`), the hook is authoritative: screen detection is
    /// treated as fallback and does not overwrite `agentState`. When it goes
    /// stale (hook uninstalled, crashed, or agent that doesn't report), screen
    /// detection silently resumes — no flag, graceful degradation by design.
    /// The hook reports STATE only; agent *identity* stays owned by the
    /// foreground-process poll, so a hook can never evict a running agent.
    private var hookStateAt: Date?
    /// Freshness window for hook-authored state. A well-behaved hook fires on
    /// every lifecycle edge; this bounds how long a single edge suppresses
    /// screen detection if the hook goes silent mid-session.
    private static let hookStateTTL: TimeInterval = 10.0

    /// True when hook-authored state was set within the TTL as of `now`.
    private func hookAuthoritative(now: Date) -> Bool {
        guard let at = hookStateAt else { return false }
        return now.timeIntervalSince(at) < Self.hookStateTTL
    }

    // MARK: - Configuration

    private let silenceThreshold: TimeInterval
    private let agentSilenceThreshold: TimeInterval
    /// Monotonically-increasing change revision. Consumers that marshal callbacks
    /// across isolation boundaries (PTY actor → SessionManager actor) use this
    /// to drop updates that arrived out of order: an older revision must never
    /// overwrite a newer one even if its enqueue-then-await was delayed.
    public private(set) var revision: UInt64 = 0
    private let onChange: @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void

    /// Invoked by the silence timer's Task when the threshold elapses. The
    /// owner (PTYSession) sets this to a closure that re-enters the actor
    /// and calls `applySilenceTimeout()`, ensuring all state mutations
    /// happen on a single isolation domain.
    public var onSilenceTimeout: (@Sendable () -> Void)?

    // MARK: - Internals

    /// Replaces the previous `DispatchWorkItem`+`timerQueue` pair. Using a
    /// cancellable Task lets `cancel()` / `forceExit()` / new-output resets
    /// take effect without a secondary dispatch queue reading actor-guarded
    /// state, closing the `cancelled`/`activeAgent` data race flagged by C-09.
    private var silenceTask: Task<Void, Never>?
    private var cancelled = false

    /// Exit debounce: counts consecutive non-agent foreground-process polls.
    /// Exit is owned by the poll alone (kernel process-tree ground truth) — the
    /// OSC-title path drives entry only and never contributes here, so agents
    /// that churn their terminal title while working can't self-evict. Any
    /// agent-positive poll resets the counter to 0.
    private var consecutiveNoAgentPolls = 0
    private static let exitDebounceThreshold = 2

    /// Comprehensive ANSI/VT escape sequence stripper.
    private static let ansiEscapePattern = #/\x1B(?:\[[\x20-\x3F]*[\x40-\x7E]|\][^\x07\x1B]*(?:\x07|\x1B\\)|\([A-B0-2]|[=>])/#

    // MARK: - Init

    public init(
        silenceThreshold: TimeInterval = 1.0,
        agentSilenceThreshold: TimeInterval = 2.0,
        onChange: @escaping @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void
    ) {
        self.silenceThreshold = silenceThreshold
        self.agentSilenceThreshold = agentSilenceThreshold
        self.onChange = onChange
    }

    // MARK: - Process Output

    /// Analyze a chunk of PTY output. Called from `PTYSession.handleOutput()`.
    public func processOutput(_ data: Data) {
        guard !cancelled else { return }

        // Always scan for OSC title so agent-entry detection still works.
        detectTitleChange(in: data)

        // Fast path: when no agent is running, *any* output is activity. We
        // don't need UTF-8 decoding or ANSI stripping — that work is only
        // needed to distinguish meaningful output from ink/React redraws
        // while an agent is running.
        if activeAgent == nil {
            transition(to: .active)
            resetSilenceTimer()
            return
        }

        // Agent path: only count visible content (skip pure escape-sequence
        // redraws). Decode + ANSI-strip only in this branch.
        var hasVisibleContent = true
        if let raw = String(data: data, encoding: .utf8) {
            let clean = raw.replacing(Self.ansiEscapePattern, with: "")
            hasVisibleContent = !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasVisibleContent {
            transition(to: .agentActive)
            resetSilenceTimer()
        }
    }

    /// Called when the client sends input to this session.
    public func recordInput() {
        guard !cancelled else { return }
        let activeState: ActivityState = activeAgent != nil ? .agentActive : .active
        transition(to: activeState)
        resetSilenceTimer()
    }

    /// Force agent exit and transition to idle. Called when the PTY process exits —
    /// regardless of what the monitor thinks, an agent cannot be running if the shell is dead.
    /// Emits a final state change so clients see the definitive "not running" state.
    public func forceExit() {
        guard !cancelled else { return }
        silenceTask?.cancel()
        silenceTask = nil
        if activeAgent != nil {
            activeAgent = nil
            consecutiveNoAgentPolls = 0
        }
        agentState = .idle          // process gone: definitively idle
        agentEnteredAt = nil
        pendingIdleStartedAt = nil
        pendingIdleConfirmations = 0
        transition(to: .idle)
    }

    /// Stop monitoring. Called on session termination.
    public func cancel() {
        cancelled = true
        silenceTask?.cancel()
        silenceTask = nil
    }

    // MARK: - Foreground Process Detection

    /// Called by PTYSession's foreground poll timer with the detected agent
    /// (or nil if no agent was found in the process chain).
    ///
    /// Entry is immediate (single poll confirms). Exit is debounced: requires
    /// `exitDebounceThreshold` consecutive non-agent signals (counted across
    /// this poll path and the OSC title path combined) to guard against
    /// momentary process group changes during tool launches.
    public func updateForegroundProcess(agent: CodingAgent?, now: Date = Date()) {
        guard !cancelled else { return }
        if let agent {
            consecutiveNoAgentPolls = 0
            if activeAgent?.id != agent.id {
                activeAgent = agent
                agentEnteredAt = now
                agentState = nil            // clear stale detection on agent change
                pendingIdleStartedAt = nil
                pendingIdleConfirmations = 0
                // Hook authority is scoped to the agent it was reported for.
                // A new agent must be classified by screen detection from
                // scratch — the previous agent's fresh hook timestamp must not
                // suppress it for the rest of the TTL.
                hookStateAt = nil
                transition(to: .agentActive)
                resetSilenceTimer()
            }
        } else if activeAgent != nil {
            consecutiveNoAgentPolls += 1
            if consecutiveNoAgentPolls >= Self.exitDebounceThreshold {
                exitAgent()
            }
        }
    }

    /// Apply a screen-detection result with herdr's anti-flap arbitration.
    /// Called from PTYSession on each foreground-poll tick with the detector's
    /// output for the active agent (nil when no agent / no manifest).
    public func updateScreenDetection(_ detection: AgentDetection?, now: Date) {
        guard !cancelled, activeAgent != nil, let detection else { return }

        // Hook authority (F6): while a local hook is freshly reporting this
        // session's state, it wins — screen detection becomes a no-op so its
        // anti-flap lag and misdetections don't override the authoritative
        // lifecycle signal. Falls through to screen detection once the hook
        // state goes stale.
        if hookAuthoritative(now: now) { return }

        // Overlay (transcript viewer, model picker): freeze current state.
        if detection.skipStateUpdate { return }

        // Startup grace: ignore a spurious idle right after agent entry.
        if let enteredAt = agentEnteredAt,
           detection.state == .idle, !detection.visibleIdle,
           now.timeIntervalSince(enteredAt) < Self.startupGrace {
            return
        }

        let previousState = agentState
        let next = detection.state

        // Pending-idle hold: only Working→plain-idle, not a visible idle/blocker.
        let isWorkingToPlainIdle = previousState == .working
            && next == .idle && !detection.visibleIdle && !detection.visibleBlocker
        if isWorkingToPlainIdle {
            if shouldHoldPlainIdle(now: now) { return }
        } else {
            pendingIdleStartedAt = nil
            pendingIdleConfirmations = 0
        }

        let changed = next != previousState
            || detection.visibleIdle != lastVisibleIdle
            || detection.visibleBlocker != lastVisibleBlocker
            || detection.visibleWorking != lastVisibleWorking
        guard changed else { return }

        lastVisibleIdle = detection.visibleIdle
        lastVisibleBlocker = detection.visibleBlocker
        lastVisibleWorking = detection.visibleWorking
        agentState = next
        revision &+= 1
        onChange(state, activeAgent, agentState, title, revision)
    }

    /// Apply an authoritative agent state reported by a local lifecycle hook
    /// (F6). Refreshes the hook-authority window and, if the state changed,
    /// publishes it immediately — bypassing screen-detection anti-flap, since
    /// the hook signal is already authoritative. Reports STATE only: `activeAgent`
    /// is untouched, so this never asserts or evicts an agent. No-op if the
    /// session is cancelled or no agent is currently active (a hook for a
    /// session with no detected agent is ignored rather than fabricating one).
    public func applyHookState(_ hookState: AgentDetectedState, now: Date) {
        guard !cancelled, activeAgent != nil else { return }
        hookStateAt = now
        // Any pending screen-driven idle hold is moot once the hook speaks.
        pendingIdleStartedAt = nil
        pendingIdleConfirmations = 0
        guard hookState != agentState else { return }
        agentState = hookState
        revision &+= 1
        onChange(state, activeAgent, agentState, title, revision)
    }

    /// Returns true while a Working→plain-idle transition should be withheld.
    /// Publishes (returns false) once 700ms elapse or 3 confirmations accrue.
    private func shouldHoldPlainIdle(now: Date) -> Bool {
        guard let startedAt = pendingIdleStartedAt else {
            pendingIdleStartedAt = now
            pendingIdleConfirmations = 0
            return true
        }
        if now.timeIntervalSince(startedAt) >= Self.pendingIdleCap {
            pendingIdleStartedAt = nil
            pendingIdleConfirmations = 0
            return false
        }
        pendingIdleConfirmations += 1
        if pendingIdleConfirmations >= Self.pendingIdleConfirmationLimit {
            pendingIdleStartedAt = nil
            pendingIdleConfirmations = 0
            return false
        }
        return true
    }

    // MARK: - Detection Logic

    /// Scan for OSC title set sequences: ESC ] 0 ; <title> BEL (or ESC ] 2 ; <title> BEL)
    private func detectTitleChange(in data: Data) {
        // Hot path: PTY output chunks that contain no ESC byte can never
        // carry an OSC title sequence. Short-circuit using Data's memchr-
        // backed `firstIndex(of:)` before materialising `[UInt8](data)`
        // or running the index-by-index scan.
        guard data.firstIndex(of: 0x1B) != nil else { return }
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count - 4 {
            if bytes[i] == 0x1B, bytes[i + 1] == 0x5D {
                let paramStart = i + 2
                if paramStart < bytes.count,
                   bytes[paramStart] == 0x30 || bytes[paramStart] == 0x32,
                   paramStart + 1 < bytes.count, bytes[paramStart + 1] == 0x3B {
                    let titleStart = paramStart + 2
                    var titleEnd = titleStart
                    while titleEnd < bytes.count && bytes[titleEnd] != 0x07 {
                        if bytes[titleEnd] == 0x1B, titleEnd + 1 < bytes.count, bytes[titleEnd + 1] == 0x5C {
                            break
                        }
                        titleEnd += 1
                    }
                    if titleEnd > titleStart, let title = String(bytes: bytes[titleStart..<titleEnd], encoding: .utf8) {
                        handleTitle(title)
                    }
                    i = titleEnd + 1
                    continue
                }
            }
            i += 1
        }
    }

    private func handleTitle(_ title: String) {
        self.title = title
        // The OSC-title path drives agent *entry* only. Exit is owned solely by
        // the foreground-process poll (`updateForegroundProcess`), which has
        // kernel process-tree ground truth. A non-agent title must NOT count
        // toward exit: agents like Claude Code continuously rewrite their
        // terminal title to non-keyword strings ("Previewly", "esc to
        // interrupt", …) while working, and treating those as no-agent signals
        // falsely evicts a still-running agent — the client then flickers the
        // agent name/state cluster and tab color every few seconds.
        if let agent = CodingAgent.matching(title: title) {
            consecutiveNoAgentPolls = 0
            if activeAgent?.id != agent.id {
                activeAgent = agent
                transition(to: .agentActive)
                resetSilenceTimer()
            }
        }
    }

    private func exitAgent() {
        activeAgent = nil
        consecutiveNoAgentPolls = 0
        agentState = nil
        agentEnteredAt = nil
        pendingIdleStartedAt = nil
        hookStateAt = nil   // hook authority does not outlive the agent it tracked
        transition(to: .active)
        resetSilenceTimer()
    }

    /// Heuristic: does this ANSI-stripped line look like a shell prompt?
    public static func looksLikeShellPrompt(_ line: String) -> Bool {
        guard line.count >= 2, line.count <= 120 else { return false }
        guard line.hasSuffix("$") || line.hasSuffix("%") || line.hasSuffix("#") else { return false }
        if line.hasPrefix("  ") || line.hasPrefix("\t") { return false }
        return true
    }

    // MARK: - Silence Timer

    /// Called from the owning actor when the silence timer fires. Computes the
    /// idle state using the current `activeAgent` flag — safe because the
    /// actor serializes this call with all other state mutations.
    public func applySilenceTimeout() {
        guard !cancelled else { return }
        let idleState: ActivityState = activeAgent != nil ? .agentIdle : .idle
        transition(to: idleState)
    }

    private func resetSilenceTimer() {
        silenceTask?.cancel()
        let threshold = activeAgent != nil ? agentSilenceThreshold : silenceThreshold
        // Capture the callback once up-front. `onSilenceTimeout` is the
        // owning actor's re-entrancy hook (`PTYSession.handleSilenceTimeout`)
        // which awaits back into actor isolation before calling
        // `applySilenceTimeout()`. If no owner installed a callback we fall
        // back to transitioning directly — used only by tests that construct
        // the monitor without a PTY around it.
        let callback = onSilenceTimeout
        silenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(threshold))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, !self.cancelled else { return }
            if let callback {
                callback()
            } else {
                let idleState: ActivityState = self.activeAgent != nil ? .agentIdle : .idle
                self.transition(to: idleState)
            }
        }
    }

    // MARK: - State Transition

    private func transition(to newState: ActivityState) {
        guard newState != state else { return }
        let oldState = state
        state = newState
        revision &+= 1
        RelayLogger.log(.debug, category: "activity",
            "State: \(oldState.rawValue) → \(newState.rawValue) (rev=\(revision))")
        onChange(newState, activeAgent, agentState, title, revision)
    }
}
