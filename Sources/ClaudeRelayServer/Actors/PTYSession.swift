import Foundation
import CPTYShim
import ClaudeRelayKit

// MARK: - PTYSessionProtocol

public protocol PTYSessionProtocol: Actor {
    var sessionId: UUID { get }
    func startReading()
    func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void)
    func setExitHandler(_ handler: @escaping @Sendable () -> Void)
    func clearOutputHandler()
    func write(_ data: Data)
    func resize(cols: UInt16, rows: UInt16)
    /// Best-effort current working directory of the session's shell process
    /// (the stable workspace anchor). Nil when the process is gone or the
    /// lookup fails. Actor-isolated — callers await.
    func currentWorkingDirectory() -> String?
    /// Set a callback fired from the foreground poll with the session's cwd,
    /// only when it changes. Used to track `cd` for workspace grouping.
    func setWorkingDirHandler(_ handler: @escaping @Sendable (String) -> Void)
    /// Asks the foreground app to repaint by wiggling the PTY width (cols−1,
    /// ~150 ms, restore). Used after a ring-buffer replay and for client
    /// tap-to-redraw: the on-screen bytes can be mis-wrapped/garbled until the
    /// app re-emits its whole screen. A bare same-size SIGWINCH is NOT enough —
    /// Node/Ink apps (Claude Code) re-query TIOCGWINSZ on WINCH and skip the
    /// redraw when the size is unchanged — so we make the size genuinely change
    /// twice, exactly like the keyboard show/hide gesture that provably works.
    func forceRepaint() async
    func readBuffer() -> Data
    func terminate()
    func getActivityState() -> ActivityState
    func getActiveAgent() -> CodingAgent?
    func getAgentState() -> AgentDetectedState?
    func getTitle() -> String?
    /// Activity updates carry a monotonic `revision`. Downstream observers
    /// that cross isolation boundaries drop updates whose revision is older
    /// than what they last recorded — see `SessionManager.reportActivityChange`.
    func setActivityHandler(
        _ handler: @escaping @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void
    )
    func recordInput()
    /// 1.0 for attached (responsive entry detection); 5.0 for detached.
    func setPollCadence(_ seconds: TimeInterval)
}

// MARK: - PTYError

public enum PTYError: Error {
    case forkFailed(Int32)
}

// MARK: - ActivityCallbackBox

/// Thread-safe box that holds an activity-change callback.
/// Used to break the init-time `[weak self]` capture cycle: the monitor's
/// `onChange` closure captures this box (which is created before `self` is
/// fully initialized), and `PTYSession` writes the real handler into it later.
private final class ActivityCallbackBox: @unchecked Sendable {
    var handler: (@Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void)?
}

// MARK: - PTYSession Actor

public actor PTYSession: PTYSessionProtocol {
    /// Poll cadence used while a client is attached — fast enough for responsive
    /// agent entry/exit detection.
    public static let attachedPollCadence: TimeInterval = 1.0
    /// Poll cadence used while detached — slow enough that many-session deployments
    /// don't pay 1 Hz of per-session walker cost, but fast enough that background
    /// iOS tabs still reflect agent state changes within a few seconds.
    public static let detachedPollCadence: TimeInterval = 5.0

    public let sessionId: UUID

    private let masterFD: Int32
    private let childPID: Int32
    /// Start time of `childPID`, captured right after `forkpty`. Used by
    /// `terminate()` to detect PID reuse before sending SIGKILL (C-10). In
    /// microseconds-since-epoch so sub-second restarts are distinguishable;
    /// `-1` means the lookup failed at init and SIGKILL will skip the check.
    private let childStartTime: Int64
    private var ringBuffer: RingBuffer
    private var readSource: DispatchSourceRead?
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var exitHandler: (@Sendable () -> Void)?
    private let activityMonitor: SessionActivityMonitor
    private let screenModel: TerminalScreenModel
    private let stateDetector: AgentStateDetector
    /// Shared box to bridge the monitor's synchronous onChange callback into the actor.
    /// The monitor captures this box (not `self`) so the closure doesn't require `self` to be fully initialized.
    private let activityCallbackBox = ActivityCallbackBox()
    private var activityHandler: (@Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void)?
    /// Callback for working-directory changes, fired from the foreground poll.
    private var workingDirHandler: (@Sendable (String) -> Void)?
    /// Last cwd we reported, to fire the handler only on change.
    private var lastReportedWorkingDir: String?
    private var terminated: Bool = false
    private var foregroundPollTimer: DispatchSourceTimer?
    /// Last size applied via init/`resize()`. `forceRepaint()` restores to
    /// these values after its wiggle; because reads happen inside the actor,
    /// a client resize that lands mid-wiggle wins and the restore uses the
    /// newest size instead of stomping it.
    private var currentCols: UInt16
    private var currentRows: UInt16

    // MARK: - Write Queue

    /// Bytes that could not be flushed immediately because the PTY master FD
    /// returned EAGAIN. Drained by `writeSource` when the FD is writable.
    /// Each entry tracks `offset` so partial writes advance in-place instead
    /// of copying the tail via `subdata(in:)` — keeps drain O(n) under
    /// sustained backpressure.
    private struct QueuedWrite {
        var data: Data
        var offset: Int
        var remaining: Int { data.count - offset }
    }
    private var writeQueue: [QueuedWrite] = []
    private var writeQueueBytes = 0
    /// Hard cap on buffered write bytes before we drop oldest. 4 MB matches
    /// the client's terminal-output cap; shell input >4 MB is almost certainly
    /// a runaway loop.
    private static let maxWriteQueueBytes = 4 * 1024 * 1024
    private var writeSource: DispatchSourceWrite?
    /// One-shot flag so we only log the overflow warning once per session
    /// (the stream of dropped chunks is all one operational event).
    private var didLogWriteOverflow = false

    // MARK: - Initialization

    /// Initialize: forkpty with given terminal size, spawn command in child.
    public init(
        sessionId: UUID,
        cols: UInt16,
        rows: UInt16,
        scrollbackSize: Int,
        command: String = "/opt/homebrew/bin/claude"
    ) throws {
        self.sessionId = sessionId
        self.ringBuffer = RingBuffer(capacity: scrollbackSize)
        self.currentCols = cols
        self.currentRows = rows

        var fd: Int32 = 0
        var ws = winsize()
        ws.ws_col = cols
        ws.ws_row = rows
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0

        // Resolve home directory BEFORE fork — NSHomeDirectory() and other
        // ObjC/Foundation calls are NOT safe in a forked child process.
        let homeDir = strdup(NSHomeDirectory())

        let pid = relay_forkpty(&fd, &ws)

        if pid < 0 {
            free(homeDir)
            throw PTYError.forkFailed(errno)
        }

        if pid == 0 {
            // Child process — only use POSIX/C calls here (no ObjC/Foundation).
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1)
            if let homeDir = homeDir {
                chdir(homeDir)
            }

            // Use login -f to spawn shell with proper user context and permissions
            let username = getenv("USER") ?? getpwuid(getuid()).pointee.pw_name
            let usernameStr = strdup(username)
            let argv0 = strdup("login")
            let argv1 = strdup("-fp")
            let cArgs: [UnsafeMutablePointer<CChar>?] = [argv0, argv1, usernameStr, nil]
            _ = cArgs.withUnsafeBufferPointer { buf in
                execv("/usr/bin/login", buf.baseAddress)
            }

            // Fallback to direct zsh if login fails
            let fallbackArgv0 = strdup("-zsh")
            let fallbackArgs: [UnsafeMutablePointer<CChar>?] = [fallbackArgv0, nil]
            _ = fallbackArgs.withUnsafeBufferPointer { buf in
                execv("/bin/zsh", buf.baseAddress)
            }
            _exit(1)
        }

        free(homeDir)

        // Parent process
        self.masterFD = fd
        self.childPID = pid
        // Capture the child's start time immediately so `terminate()` can
        // detect PID reuse before sending SIGKILL (C-10). sysctl is
        // best-effort; if it fails we store -1 and skip the check at kill
        // time, accepting the residual reuse risk.
        self.childStartTime = relay_get_process_start_time(pid)
        // Put the master FD into non-blocking mode so write() never pins the
        // actor. write(2) returns EAGAIN when the shell's input buffer is full;
        // we buffer the remainder in writeQueue and drain from a DispatchSource.
        let existingFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, existingFlags | O_NONBLOCK)
        let box = self.activityCallbackBox
        self.activityMonitor = SessionActivityMonitor(
            silenceThreshold: 1.0,
            agentSilenceThreshold: 2.0,
            onChange: { newState, agent, agentState, title, revision in
                box.handler?(newState, agent, agentState, title, revision)
            }
        )
        self.screenModel = TerminalScreenModel(cols: cols, rows: rows)
        self.stateDetector = AgentStateDetector(manifests: AgentStateDetector.loadBundled())
    }

    /// Activate the dispatch source that reads PTY output.
    /// Must be called after init to avoid actor-initializer isolation warning (Swift 6).
    public func startReading() {
        guard readSource == nil else { return }
        let readSrc = Self.makeReadSource(fd: masterFD, session: self)
        self.readSource = readSrc

        activityMonitor.onSilenceTimeout = { [weak self] in
            Task {
                guard let session = self else { return }
                await session.handleSilenceTimeout()
            }
        }

        startForegroundPoll()
    }

    /// Re-enters actor isolation for the silence timer so state mutations are
    /// serialized with processOutput/updateForegroundProcess.
    private func handleSilenceTimeout() {
        activityMonitor.applySilenceTimeout()
    }

    /// Re-enters actor isolation for the foreground process poll result.
    private func handleForegroundPollResult(agent: CodingAgent?) {
        guard !terminated else { return }
        activityMonitor.updateForegroundProcess(agent: agent)
        // Screen detection only runs while an agent is active. Snapshot the
        // emulated grid and evaluate the agent's manifest, then arbitrate.
        if let agent = activityMonitor.activeAgent {
            let snapshot = screenModel.snapshot()
            let detection = stateDetector.detect(agentId: agent.id, snapshot: snapshot)
            activityMonitor.updateScreenDetection(detection, now: Date())
        }
        // Track cwd changes (e.g. `cd`) even without an activity change.
        if let handler = workingDirHandler, let cwd = currentWorkingDirectory(),
           cwd != lastReportedWorkingDir {
            lastReportedWorkingDir = cwd
            handler(cwd)
        }
    }

    // MARK: - Foreground Process Polling

    /// Polls tcgetpgrp + KERN_PROCARGS2 to detect a coding agent as the foreground process
    /// or as an ancestor (up to 4 levels) of the foreground process.
    ///
    /// Parent chain walk is essential: when agents launch tools (git, npm, node),
    /// those tools become the foreground process group leader while the agent remains
    /// their ancestor. Without the walk, every tool execution briefly appears as
    /// "agent exited", causing UI flicker.
    ///
    /// Poll interval: 1s, first fire immediately on attach for responsive entry detection.
    /// Exit debouncing in SessionActivityMonitor prevents flicker.
    private func startForegroundPoll() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        let fd = masterFD
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            let pgid = relay_get_foreground_pgid(fd)
            guard pgid > 0 else { return }

            let agent = Self.detectAgentInProcessChain(startingPid: pgid)
            Task {
                guard let session = self else { return }
                await session.handleForegroundPollResult(agent: agent)
            }
        }
        timer.resume()
        foregroundPollTimer = timer
    }

    /// Adjust the foreground-process polling interval. Attached sessions use
    /// `attachedPollCadence` (1.0 s) for responsive agent-entry detection;
    /// detached sessions use `detachedPollCadence` (5.0 s) so many-session
    /// deployments don't pay the full poll cost per second.
    public func setPollCadence(_ seconds: TimeInterval) {
        guard let timer = foregroundPollTimer else { return }
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
    }

    /// Walks the process tree from `startingPid` up through parents (max 5 hops)
    /// looking for a known coding agent.
    ///
    /// For each PID we check two names:
    /// 1. The executable basename (e.g. `claude`, `node`).
    /// 2. `argv[1]` basename — the script path when the process is a script
    ///    interpreter. This is what catches Node/Python/Ruby-based agents
    ///    like `codex` whose binary is actually `node`.
    private static func detectAgentInProcessChain(startingPid: Int32) -> CodingAgent? {
        let ownPid = getpid()
        var pid = startingPid
        for _ in 0..<5 {
            // Stop at init or at our own PID. The server binary is named
            // `claude-relay-server`, which matches `claude-` via the prefix rule —
            // without this guard every fresh PTY would look like Claude is running
            // from the moment the shell starts (login → zsh → claude-relay-server).
            guard pid > 1, pid != ownPid else { return nil }

            var execBuf = [CChar](repeating: 0, count: 256)
            if relay_get_process_name(pid, &execBuf, 256) == 0 {
                let execName = String(cString: execBuf)
                if let agent = CodingAgent.matching(processName: execName) {
                    return agent
                }
            }

            var scriptBuf = [CChar](repeating: 0, count: 256)
            if relay_get_process_script_name(pid, &scriptBuf, 256) == 0 {
                let scriptName = String(cString: scriptBuf)
                if let agent = CodingAgent.matching(processName: scriptName) {
                    return agent
                }
            }

            let ppid = relay_get_parent_pid(pid)
            if ppid <= 1 || ppid == pid { return nil }
            pid = ppid
        }
        return nil
    }

    // MARK: - Read Source Setup

    /// Creates and activates a DispatchSourceRead for the master file descriptor.
    /// Bridges GCD callbacks into the actor context via unstructured Tasks.
    private static func makeReadSource(fd: Int32, session: PTYSession) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())

        // Persistent read buffer — reused across callbacks to avoid per-read allocation.
        var readBuffer = [UInt8](repeating: 0, count: 8192)

        source.setEventHandler { [weak source, session] in
            let estimated = max(Int(source?.data ?? 0), 256)
            if estimated > readBuffer.count {
                readBuffer = [UInt8](repeating: 0, count: min(estimated, 65536))
            }
            let bytesRead = read(fd, &readBuffer, readBuffer.count)

            if bytesRead > 0 {
                let data = Data(readBuffer[0..<bytesRead])
                Task {
                    await session.handleOutput(data)
                }
            } else {
                // EOF or error — cancel source to stop firing and close FD
                source?.cancel()
                Task {
                    await session.handleExit()
                }
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        return source
    }

    // MARK: - Internal Handlers

    /// Called from the read source when output data is available.
    /// Always writes to the ring buffer (for resume history) and
    /// additionally forwards to the live output handler if attached.
    private func handleOutput(_ data: Data) {
        ringBuffer.write(data)
        screenModel.feed(data)
        activityMonitor.processOutput(data)
        outputHandler?(data)
    }

    /// Called from the read source on EOF (child exited).
    private func handleExit() {
        foregroundPollTimer?.cancel()
        foregroundPollTimer = nil
        activityMonitor.forceExit()
        exitHandler?()
    }

    // MARK: - Activity Monitoring

    /// Returns the current activity state of this session.
    public func getActivityState() -> ActivityState {
        activityMonitor.state
    }

    /// Returns the coding agent currently running in this session, if any.
    public func getActiveAgent() -> CodingAgent? {
        activityMonitor.activeAgent
    }

    /// Returns the fine-grained agent state detected from the screen, if any.
    public func getAgentState() -> AgentDetectedState? {
        activityMonitor.agentState
    }

    /// Returns the current window title (OSC 0/2), if any.
    public func getTitle() -> String? {
        activityMonitor.title
    }

    /// Set callback for activity state changes. The monitor emits a monotonic
    /// `revision` with every change so downstream observers can drop out-of-order
    /// updates that cross isolation boundaries.
    public func setActivityHandler(
        _ handler: @escaping @Sendable (ActivityState, CodingAgent?, AgentDetectedState?, String?, UInt64) -> Void
    ) {
        self.activityHandler = handler
        self.activityCallbackBox.handler = handler
    }

    /// Set a callback invoked (on the foreground poll) with the session's
    /// current working directory. Fires only when the cwd is readable and has
    /// changed since the last poll, so `cd` is tracked even without an activity
    /// state change. The handler resolves the git root and reports upward.
    public func setWorkingDirHandler(_ handler: @escaping @Sendable (String) -> Void) {
        self.workingDirHandler = handler
    }

    /// Record that input was sent to this session.
    public func recordInput() {
        activityMonitor.recordInput()
    }

    // MARK: - Public API

    /// Set callback for PTY output (when client is attached).
    public func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        self.outputHandler = handler
    }

    /// Set callback for process exit.
    public func setExitHandler(_ handler: @escaping @Sendable () -> Void) {
        self.exitHandler = handler
    }

    /// Clear output handler (when client detaches -- output goes to ring buffer).
    public func clearOutputHandler() {
        self.outputHandler = nil
    }

    /// Write data to PTY (terminal input from client). Non-blocking: on EAGAIN
    /// the remainder is buffered and a DispatchSourceWrite is scheduled to
    /// drain the queue when the FD becomes writable.
    public func write(_ data: Data) {
        guard !terminated else { return }
        guard !data.isEmpty else { return }
        writeQueue.append(QueuedWrite(data: data, offset: 0))
        writeQueueBytes += data.count
        capWriteQueue()
        drainWriteQueue()
    }

    /// Drop oldest chunks while the queue exceeds the byte cap. Logs once per
    /// session's lifetime so a runaway-input bug is diagnosable without
    /// spamming the log.
    private func capWriteQueue() {
        guard writeQueueBytes > Self.maxWriteQueueBytes else { return }
        let overshoot = writeQueueBytes
        while writeQueueBytes > Self.maxWriteQueueBytes, !writeQueue.isEmpty {
            let dropped = writeQueue.removeFirst()
            writeQueueBytes -= dropped.remaining
        }
        if !didLogWriteOverflow {
            RelayLogger.log(.error, category: "session",
                "PTYSession \(sessionId) write queue overflow: dropped \(overshoot - writeQueueBytes) bytes (cap = \(Self.maxWriteQueueBytes))")
            didLogWriteOverflow = true
        }
    }

    /// Flush as many bytes as the kernel will take right now. On EAGAIN schedule
    /// (or keep alive) a write source that will call us back.
    private func drainWriteQueue() {
        while let head = writeQueue.first {
            let remaining = head.remaining
            let written = head.data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Foundation.write(masterFD, base.advanced(by: head.offset), remaining)
            }
            if written >= remaining {
                writeQueue.removeFirst()
                writeQueueBytes -= remaining
                continue
            }
            if written > 0 {
                writeQueue[0].offset += written
                writeQueueBytes -= written
                continue
            }
            // written == -1
            let err = errno
            if err == EAGAIN || err == EINTR {
                startWriteSourceIfNeeded()
                return
            }
            RelayLogger.log(.error, category: "session",
                "PTYSession \(sessionId) write error: errno \(err)")
            writeQueue.removeAll()
            writeQueueBytes = 0
            writeSource?.cancel()
            writeSource = nil
            return
        }
        // Queue drained successfully. Reset the overflow log gate so a later
        // overflow episode gets its own log line instead of being swallowed.
        didLogWriteOverflow = false
        writeSource?.cancel()
        writeSource = nil
    }

    /// Lazy-create a write dispatch source that kicks drainWriteQueue whenever
    /// the FD becomes writable. No-op if one is already live.
    private func startWriteSourceIfNeeded() {
        guard writeSource == nil else { return }
        let sessionActor = self
        let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            Task { await sessionActor.drainWriteQueue() }
        }
        source.resume()
        writeSource = source
    }

    /// Resize the terminal.
    public func resize(cols: UInt16, rows: UInt16) {
        guard !terminated else { return }
        currentCols = cols
        currentRows = rows
        screenModel.resize(cols: cols, rows: rows)
        _ = relay_set_winsize(masterFD, rows, cols)
    }

    /// Best-effort cwd of the session's shell (the stable workspace anchor).
    ///
    /// `childPID` is the setuid `login` process, whose vnode path info is not
    /// readable by this non-root server (EPERM on sugid processes). So we
    /// descend to the first readable child — the real interactive shell — and
    /// return its cwd. Nil when nothing in the subtree is readable.
    public func currentWorkingDirectory() -> String? {
        guard !terminated else { return nil }
        var buf = [CChar](repeating: 0, count: 1024)   // paths well under PATH_MAX
        guard relay_proc_cwd_descendant(childPID, &buf, Int32(buf.count)) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Forces the foreground app to re-emit its whole screen by genuinely
    /// changing the PTY width and restoring it (cols−1 → 150 ms → cols).
    ///
    /// A bare SIGWINCH at unchanged size does NOT work for Node/Ink apps
    /// (Claude Code): Node's WINCH handler re-reads TIOCGWINSZ and only fires
    /// the `resize` event when the dimensions differ from its cache — measured
    /// 0 repaint bytes from `claude` on same-size WINCH vs a full repaint on a
    /// 1-column change. The gap is required too: the foreground process must
    /// handle the first WINCH *while the intermediate size is still current*,
    /// or it observes only the restored size and skips the redraw (25 ms was
    /// the measured minimum for `claude` on an idle machine; a busy process
    /// needs more, and the keyboard gesture this mimics has a human-scale
    /// gap). Cols is wiggled rather than rows because a rows-grow was observed
    /// to produce no repaint. TIOCSWINSZ auto-delivers WINCH on each real
    /// change, so no explicit kill() is needed.
    public func forceRepaint() async {
        guard !terminated, currentCols > 1 else { return }
        _ = relay_set_winsize(masterFD, currentRows, currentCols - 1)
        try? await Task.sleep(nanoseconds: 150_000_000)
        // Re-read after the await: a client resize() that landed mid-wiggle
        // has updated currentCols/currentRows, and restoring to those is
        // correct (never stomp a legitimate resize with a stale size).
        guard !terminated else { return }
        _ = relay_set_winsize(masterFD, currentRows, currentCols)
    }

    /// Read the ring buffer contents (for resume, send scrollback history to client).
    /// Does not clear — new output continues to accumulate for subsequent resumes.
    public func readBuffer() -> Data {
        return ringBuffer.read()
    }

    /// Clean up: kill child process, close fd.
    public func terminate() {
        guard !terminated else { return }
        terminated = true
        activityMonitor.cancel()
        foregroundPollTimer?.cancel()
        foregroundPollTimer = nil

        // Cancel the read source (this also closes the fd via the cancel handler)
        readSource?.cancel()
        readSource = nil

        writeSource?.cancel()
        writeSource = nil
        writeQueue.removeAll()
        writeQueueBytes = 0

        // Send SIGTERM to the child. SIGCHLD is set to SIG_IGN in main.swift,
        // so the kernel auto-reaps — no waitpid needed.
        let pid = childPID
        let sid = sessionId
        let startTime = childStartTime
        if kill(pid, SIGTERM) != 0 {
            RelayLogger.log(.error, category: "session", "PTYSession \(sid) SIGTERM failed for pid \(pid): errno \(errno)")
        }

        // Schedule SIGKILL after 2 s if the process hasn't exited. zsh exits
        // within ~100 ms of SIGTERM in practice, so 2 s is a generous safety
        // margin.
        //
        // Before firing SIGKILL, verify the PID still belongs to our child
        // by comparing its start time to what we captured at fork. If macOS
        // has recycled the PID for an unrelated process in the last 2 s, the
        // start times won't match and we skip the kill (C-10).
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            // Check if process is still alive (kill with signal 0)
            if kill(pid, 0) == 0 {
                // Start-time check: skip SIGKILL if the PID was recycled.
                // `startTime == -1` means the init-time lookup failed, in
                // which case we accept the residual reuse risk and proceed.
                if startTime != -1 {
                    let current = relay_get_process_start_time(pid)
                    if current != -1 && current != startTime {
                        RelayLogger.log(.error, category: "session",
                            "PTYSession \(sid) PID \(pid) was recycled (start \(startTime) → \(current)); skipping SIGKILL")
                        return
                    }
                }
                if kill(pid, SIGKILL) != 0 {
                    RelayLogger.log(.error, category: "session", "PTYSession \(sid) SIGKILL failed for pid \(pid): errno \(errno)")
                }
            }
        }
    }
}
