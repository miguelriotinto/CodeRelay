import Foundation
import Combine
import os.log

private let pendingOutputLog = Logger(subsystem: "com.claude.relay.client",
                                       category: "TerminalViewModel")

/// Diagnostic logger for the idle-no-echo bug. Filter Console.app on
/// subsystem com.claude.relay.client and category EchoDiag to see only these.
private let echoDiag = Logger(subsystem: "com.claude.relay.client",
                              category: "EchoDiag")

/// Configures the input-prompt silence detector. Production defaults match the
/// empirically-tuned behavior (1.0 s normal, 2.0 s when Claude is running —
/// longer so API-call/tool-execution gaps don't trip the detector). Tests can
/// pass shorter durations to run quickly.
public struct InputPromptThresholds: Sendable {
    public let normal: Duration
    public let agentActive: Duration

    public init(normal: Duration = .milliseconds(1000),
                agentActive: Duration = .milliseconds(2000)) {
        self.normal = normal
        self.agentActive = agentActive
    }
}

/// Manages terminal I/O state for a single session.
///
/// The `SessionCoordinator` pushes output bytes in via `receiveOutput(_:)`;
/// this view model buffers them until the terminal view reports it has been
/// laid out (`terminalReady()`), then flushes and starts forwarding live.
///
/// ## Lifecycle
///
/// 1. A view creates the VM with `init(sessionId:connection:)`.
/// 2. The terminal view (SwiftTerm bridge) installs `onTerminalOutput`,
///    `onTitleChanged`, `onAwaitingInputChanged`.
/// 3. On the first `sizeChanged` delegate callback, the view calls
///    `terminalReady()` to drain any buffered scrollback.
/// 4. When switching away, the view calls `prepareForSwitch()` to clear
///    callbacks and debounce tasks.
@MainActor
public final class TerminalViewModel: ObservableObject {

    // MARK: - Published State

    @Published public var connectionState: RelayConnection.ConnectionState
    /// Terminal title set by the running process via OSC escape sequences.
    @Published public var terminalTitle: String = ""
    /// True when output has been silent long enough that the session is likely
    /// waiting for user input. Driven by `detectInputPrompt(_:)`.
    @Published public var awaitingInput: Bool = false

    /// Installed by the terminal view. Receives live bytes after `terminalReady()`.
    public var onTerminalOutput: ((Data) -> Void)?
    /// Installed by the terminal view. Fires when the running process sets an OSC title.
    public var onTitleChanged: ((String) -> Void)?
    /// Installed by the terminal view. Fires when `awaitingInput` transitions.
    public var onAwaitingInputChanged: ((Bool) -> Void)?
    /// Installed by the terminal view. Fires after replay bytes have actually
    /// been delivered to that view, so it can re-sync geometry and repaint the
    /// correct session even when `replay_complete` beats view presentation.
    public var onReplayFlushed: (() -> Void)?
    /// Installed by the coordinator. Fires whenever the view reports a new
    /// terminal size, so the coordinator can remember the last-known geometry
    /// to seed the next `session_create`.
    public var onResize: ((UInt16, UInt16) -> Void)?

    private var terminalSized = false
    private var isReplaying = false
    /// Set by `endReplay()` when the server's `replay_complete` arrives before
    /// the terminal view has laid out (`terminalSized == false`). In that race
    /// — common on macOS, where `updateNSView` is scheduled only *after* the
    /// `activeSessionId` publish — we can't flush yet, so we defer: the next
    /// `terminalReady()` emits the RIS clear AND flushes the buffered replay.
    /// Without this the clear was skipped and replayed content painted over the
    /// reused view's stale glyphs (the session-switch garble).
    private var replayComplete = false

    /// True while output is being held to coalesce a repaint burst into a single
    /// render. The server wiggles the PTY width after every replay
    /// (cols → cols−1 → 150 ms → cols), which makes a full-screen app repaint
    /// TWICE: once reflowed to the narrow width, then again at full width.
    /// Feeding both frames live shows the intermediate (narrow) frame for
    /// ~150 ms — the flicker. Holding output for a short quiet window and
    /// flushing it as one blob lets SwiftTerm apply both reflows in a single
    /// display pass, so only the final frame is ever seen.
    private var isCoalescingRefresh = false
    private var refreshCoalesceTask: Task<Void, Never>?
    /// True from `beginServerReload()` until that reload's replay lands (or is
    /// cancelled) — i.e. exactly when the in-flight replay must be preceded by a
    /// RIS clear because the terminal view is staying put. `terminalReady()`
    /// normally emits that clear, but it fires only on a view's FIRST layout, and
    /// a reload in place has no new layout, so the clear rides in front of the
    /// flush instead.
    ///
    /// Two readers outside this type:
    /// - the coordinator drops a second tap while this holds (two overlapping
    ///   replays paint the screen twice, the second appended below the first);
    /// - the views hold their fade-through-black cover up while it holds, so the
    ///   black lifts on the repaint rather than on a fixed timer.
    @Published public private(set) var isReloadingFromServer = false
    /// Backstop for `beginServerReload()`: a lost `replay_complete` (or a socket
    /// that dies mid-replay) must not leave output buffered forever.
    private var reloadBackstopTask: Task<Void, Never>?
    /// Flush once output stays quiet for this long. Must exceed the server's
    /// 150 ms width-wiggle gap so the two repaint frames land in one batch.
    private static let refreshQuietWindow: Duration = .milliseconds(220)
    /// Hard cap so a continuously-streaming session (refreshed mid-output)
    /// can't buffer forever — flush no later than this after the tap.
    private static let refreshMaxWindow: Duration = .milliseconds(1200)
    /// Give the replay this long to arrive before flushing whatever we have.
    /// Generous: the server streams the whole ring buffer in 64 KB frames.
    private static let reloadBackstop: Duration = .seconds(5)

    // MARK: - Dependencies

    public let sessionId: UUID
    public var isSendingSuppressed = false
    private let connection: RelayConnection
    private var pendingOutput: [Data] = []
    private var pendingOutputBytes: Int = 0
    private var didLogPendingCap = false
    private static let pendingOutputByteLimit: Int = 4 * 1024 * 1024 // 4 MB

    // MARK: - Input Detection

    /// Set by the coordinator when a coding agent is actively running in this session.
    /// Controls the silence threshold used for input-awaiting detection — a
    /// longer window avoids false positives during API-call/tool-execution gaps.
    public var isAgentActive = false
    private var promptDebounceTask: Task<Void, Never>?
    private let promptThresholds: InputPromptThresholds

    // MARK: - Init

    public init(
        sessionId: UUID,
        connection: RelayConnection,
        promptThresholds: InputPromptThresholds = InputPromptThresholds()
    ) {
        self.sessionId = sessionId
        self.connection = connection
        self.promptThresholds = promptThresholds
        self.connectionState = connection.state

        connection.$state
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .assign(to: &$connectionState)
    }

    // MARK: - Output

    /// Receives terminal output from the coordinator's I/O routing.
    public func receiveOutput(_ data: Data) {
        // While coalescing a manual refresh, hold everything and (re)arm the
        // quiet-window timer so the whole repaint burst flushes as one blob.
        if isCoalescingRefresh {
            pendingOutput.append(data)
            pendingOutputBytes += data.count
            armRefreshQuietTimer()
            detectInputPrompt(data)
            return
        }
        if !isReplaying && terminalSized, let handler = onTerminalOutput {
            handler(data)
        } else {
            // EchoDiag: log only the FIRST time we buffer a chunk (rate-limited
            // by the existing didLogPendingCap flag would over-fire; use a
            // dedicated short-lived flag so a single buffering episode produces
            // exactly one log line).
            if pendingOutput.isEmpty {
                echoDiag.info(
                    "buffer-path entered session=\(self.sessionId.uuidString.prefix(8), privacy: .public) isReplaying=\(self.isReplaying, privacy: .public) terminalSized=\(self.terminalSized, privacy: .public) onTerminalOutput=\(self.onTerminalOutput != nil, privacy: .public) bytes=\(data.count, privacy: .public)"
                )
            }
            pendingOutput.append(data)
            pendingOutputBytes += data.count
            if pendingOutputBytes > Self.pendingOutputByteLimit, !didLogPendingCap {
                pendingOutputLog.warning(
                    "Terminal pending buffer hit \(Self.pendingOutputByteLimit / 1024 / 1024, privacy: .public) MB cap for session \(self.sessionId.uuidString.prefix(8), privacy: .public) — dropping oldest chunks")
                didLogPendingCap = true
            }
            while pendingOutputBytes > Self.pendingOutputByteLimit, !pendingOutput.isEmpty {
                let dropped = pendingOutput.removeFirst()
                pendingOutputBytes -= dropped.count
            }
        }
        detectInputPrompt(data)
    }

    /// Call once after the terminal view's first `sizeChanged` callback.
    /// Flushes any scrollback that arrived while the view was still laying out,
    /// unless a replay is still in progress (endReplay will flush instead).
    public func terminalReady() {
        guard !terminalSized else { return }
        terminalSized = true
        didLogPendingCap = false
        echoDiag.info(
            "terminalReady session=\(self.sessionId.uuidString.prefix(8), privacy: .public) isReplaying=\(self.isReplaying, privacy: .public) replayComplete=\(self.replayComplete, privacy: .public) pendingBytes=\(self.pendingOutputBytes, privacy: .public)"
        )
        guard let handler = onTerminalOutput else { return }
        // Replay still streaming in: clear the reused view now so old glyphs are
        // gone before the buffered scrollback flushes in `endReplay()`.
        if isReplaying {
            isReloadingFromServer = false   // this layout emits the clear instead
            handler(Data([0x1B, 0x63]))
            return
        }
        // Replay already finished before we laid out (macOS race): the clear was
        // deferred to here. Emit RIS first, then flush the buffered replay as one
        // blob so SwiftTerm renders the reset + fresh content in a single pass —
        // this is the fix for the session-switch garble.
        var combined = Data()
        let completedReplay = replayComplete
        if completedReplay {
            replayComplete = false
            isReloadingFromServer = false
            combined.append(contentsOf: [0x1B, 0x63])
        }
        combined.append(contentsOf: pendingOutput.reduce(into: Data()) { $0.append($1) })
        pendingOutput.removeAll()
        pendingOutputBytes = 0
        if !combined.isEmpty { handler(combined) }
        if completedReplay { onReplayFlushed?() }
    }

    /// Enters replay-buffering mode. All output is held until `endReplay()`.
    public func beginReplay() {
        echoDiag.info("beginReplay session=\(self.sessionId.uuidString.prefix(8), privacy: .public)")
        isReplaying = true
    }

    /// Exits replay-buffering mode and flushes all pending data as a single
    /// contiguous blob so SwiftTerm renders in one display pass.
    public func endReplay() {
        guard isReplaying else { return }
        isReplaying = false
        reloadBackstopTask?.cancel()
        reloadBackstopTask = nil
        echoDiag.info(
            "endReplay session=\(self.sessionId.uuidString.prefix(8), privacy: .public) terminalSized=\(self.terminalSized, privacy: .public) onTerminalOutput=\(self.onTerminalOutput != nil, privacy: .public) pendingBytes=\(self.pendingOutputBytes, privacy: .public)"
        )
        if terminalSized, let handler = onTerminalOutput {
            // View already laid out → RIS was emitted by `terminalReady()` while
            // replaying; just flush the buffered scrollback. The exception is a
            // reload in place (`beginServerReload`), where no layout happened and
            // the clear rides in front of this flush.
            let isReload = isReloadingFromServer
            isReloadingFromServer = false
            var combined = isReload ? Data([0x1B, 0x63]) : Data()
            combined.append(contentsOf: pendingOutput.reduce(into: Data()) { $0.append($1) })
            pendingOutput.removeAll()
            pendingOutputBytes = 0
            didLogPendingCap = false
            if !combined.isEmpty { handler(combined) }
            onReplayFlushed?()
            // The server resize-wiggles after every replay (`repaintAfter`), so a
            // full-screen app is about to repaint TWICE ~150 ms apart. Coalesce
            // that burst too, or the reload ends on a flash of the narrow frame.
            if isReload {
                isCoalescingRefresh = true
                armRefreshQuietTimer(hardCap: true)
            }
        } else {
            // View not laid out yet (macOS: `updateNSView` runs after the
            // `activeSessionId` publish, so `replay_complete` wins the race).
            // Defer the RIS clear + flush to the next `terminalReady()`; keep the
            // buffered scrollback intact so nothing is lost.
            replayComplete = true
        }
    }

    /// RIS (Reset to Initial State) clears terminal before replaying scrollback
    public func resetForReplay() {
        onTerminalOutput?(Data([0x1B, 0x63]))
    }

    /// Called by the view when switching away from this session. Clears the
    /// callbacks (the old terminal view is about to be destroyed) and any
    /// pending debounce task.
    public func prepareForSwitch() {
        echoDiag.info("prepareForSwitch session=\(self.sessionId.uuidString.prefix(8), privacy: .public)")
        promptDebounceTask?.cancel()
        promptDebounceTask = nil
        onTerminalOutput = nil
        onTitleChanged = nil
        onAwaitingInputChanged = nil
        onReplayFlushed = nil
        terminalSized = false
        isReplaying = false
        replayComplete = false
        isCoalescingRefresh = false
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = nil
        isReloadingFromServer = false
        reloadBackstopTask?.cancel()
        reloadBackstopTask = nil
        pendingOutput.removeAll()
        pendingOutputBytes = 0
        didLogPendingCap = false
    }

    /// Resets buffering state in preparation for ring-buffer replay. The RIS
    /// (ESC c) is deferred to `terminalReady()` so it fires only once the view
    /// is wired and can blank the screen immediately.
    public func prepareForReplay() {
        echoDiag.info("prepareForReplay session=\(self.sessionId.uuidString.prefix(8), privacy: .public)")
        promptDebounceTask?.cancel()
        promptDebounceTask = nil
        onTerminalOutput = nil
        onTitleChanged = nil
        onAwaitingInputChanged = nil
        onReplayFlushed = nil
        terminalSized = false
        isReplaying = false
        replayComplete = false
        isCoalescingRefresh = false
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = nil
        isReloadingFromServer = false
        reloadBackstopTask?.cancel()
        reloadBackstopTask = nil
        pendingOutput.removeAll()
        pendingOutputBytes = 0
        didLogPendingCap = false
    }

    // MARK: - Input

    public func sendInput(_ data: Data) {
        guard !isSendingSuppressed else { return }
        if awaitingInput { setAwaitingInput(false) }
        Task { try? await connection.sendBinary(data) }
    }

    public func sendInput(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    public func sendPasteImage(_ imageData: Data) {
        guard !isSendingSuppressed else { return }
        let base64 = imageData.base64EncodedString()
        Task { try? await connection.sendPasteImage(base64Data: base64) }
    }

    public func sendResize(cols: UInt16, rows: UInt16) {
        onResize?(cols, rows)
        guard !isSendingSuppressed else { return }
        Task { try? await connection.sendResize(cols: cols, rows: rows) }
    }

    /// Tap-to-reload, client half: throws away the locally cached terminal text
    /// and buffers whatever arrives next so it can REPLACE the screen instead of
    /// appending to it. `SharedSessionCoordinator.reloadTerminalFromServer` owns
    /// the other half — the resume that makes the server replay its ring buffer.
    ///
    /// The RIS clear is deferred to the flush in `endReplay()` rather than
    /// emitted now: blanking up front would leave the pane empty for the whole
    /// round trip, whereas one RIS-prefixed blob swaps old screen for new in a
    /// single display pass.
    public func beginServerReload() {
        isCoalescingRefresh = false
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = nil
        // Anything already buffered belongs to the screen we're discarding —
        // keeping it would paint stale bytes after the RIS.
        pendingOutput.removeAll()
        pendingOutputBytes = 0
        isReloadingFromServer = true
        beginReplay()
        reloadBackstopTask?.cancel()
        reloadBackstopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reloadBackstop)
            guard !Task.isCancelled else { return }
            self?.endReplay()
        }
    }

    /// Aborts a `beginServerReload()` whose resume never made it to the server.
    /// Drops the pending clear so the pane keeps the copy it already has — a
    /// failed reload must not blank the terminal.
    public func cancelServerReload() {
        guard isReplaying, isReloadingFromServer else { return }
        isReloadingFromServer = false
        endReplay()
    }

    /// (Re)arms the quiet-window timer that ends refresh coalescing. Each new
    /// output chunk pushes the flush out by `refreshQuietWindow`; `hardCap`
    /// (set once at `sendRefresh`) also schedules a `refreshMaxWindow` backstop
    /// so a continuously-streaming session still flushes.
    private func armRefreshQuietTimer(hardCap: Bool = false) {
        guard isCoalescingRefresh else { return }
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshQuietWindow)
            guard !Task.isCancelled else { return }
            self?.flushCoalescedRefresh()
        }
        if hardCap {
            Task { [weak self] in
                try? await Task.sleep(for: Self.refreshMaxWindow)
                guard !Task.isCancelled else { return }
                self?.flushCoalescedRefresh()
            }
        }
    }

    /// Ends coalescing and delivers the held repaint burst as one contiguous
    /// blob so SwiftTerm renders the final frame in a single display pass.
    private func flushCoalescedRefresh() {
        guard isCoalescingRefresh else { return }
        isCoalescingRefresh = false
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = nil
        guard terminalSized, let handler = onTerminalOutput else {
            pendingOutput.removeAll(); pendingOutputBytes = 0; return
        }
        let combined = pendingOutput.reduce(into: Data()) { $0.append($1) }
        pendingOutput.removeAll()
        pendingOutputBytes = 0
        if !combined.isEmpty { handler(combined) }
    }

    // MARK: - Input Prompt Detection

    /// Output-silence detector: if no output has arrived for `threshold`
    /// after the last chunk, mark the session as awaiting input. The coordinator
    /// decides whether to surface this in the UI (e.g. attention-flash a tab).
    private func detectInputPrompt(_ data: Data) {
        promptDebounceTask?.cancel()
        promptDebounceTask = nil

        if awaitingInput { setAwaitingInput(false) }

        let threshold = isAgentActive ? promptThresholds.agentActive : promptThresholds.normal
        promptDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: threshold)
            guard !Task.isCancelled else { return }
            self?.setAwaitingInput(true)
        }
    }

    private func setAwaitingInput(_ value: Bool) {
        guard awaitingInput != value else { return }
        awaitingInput = value
        onAwaitingInputChanged?(value)
    }
}
