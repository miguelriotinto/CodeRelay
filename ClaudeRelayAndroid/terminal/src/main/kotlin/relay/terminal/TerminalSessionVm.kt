package relay.terminal

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Configures the input-prompt silence detector. Production defaults match the
 * iOS `InputPromptThresholds` struct (`TerminalViewModel.swift:17-26`): 1000 ms
 * normal, 2000 ms while a coding agent is running (longer, so API-call /
 * tool-execution gaps don't trip the detector). Tests pass shorter durations —
 * here, the same defaults under [TestScope] virtual time, so no wall-clock wait.
 *
 * Field names mirror Swift (`normal` / `agentActive`), expressed as
 * milliseconds for the Kotlin [delay] call.
 */
data class InputPromptThresholds(
    val normalMs: Long = 1000L,
    val agentActiveMs: Long = 2000L,
)

/**
 * Manages terminal I/O *buffering* state for a single session.
 *
 * Ported from the iOS `TerminalViewModel` (the part with no SwiftTerm / Combine
 * / RelayConnection dependency). The coordinator pushes output bytes in via
 * [receiveOutput]; this object buffers them until the terminal view reports it
 * has been laid out ([terminalReady]), then flushes and forwards live.
 *
 * ## Lifecycle
 *
 *  1. The terminal view (Termux bridge, added in a later task) installs
 *     [onTerminalOutput] and [onAwaitingInputChanged].
 *  2. On the view's first size callback it calls [terminalReady] to drain any
 *     scrollback that arrived while the view was still laying out.
 *  3. For ring-buffer replay the coordinator calls [prepareForReplay] /
 *     [beginReplay] before attach, then [endReplay] once `replay_complete`
 *     arrives — flushing the whole replay as ONE contiguous frame so the engine
 *     renders the final state in a single pass instead of scrolling history.
 *  4. When switching away it calls [prepareForSwitch] to clear callbacks.
 *
 * Not thread-safe: like the iOS `@MainActor` original, all calls are expected
 * to come from the single UI/coordinator thread.
 *
 * The input-prompt silence detector (the 1000 ms / 2000 ms debounce that drives
 * [awaitingInput]) is implemented here as a faithful port of Swift
 * `detectInputPrompt(_:)`. The Swift original uses `Task` + `Task.sleep`; here we
 * inject a [CoroutineScope] (constructor param) so tests pass a `TestScope` and
 * drive the debounce with virtual time (`advanceTimeBy`) instead of a real timer.
 *
 * @param scope coroutine scope the debounce [Job] launches on. Defaults to a
 *   `Dispatchers.Main` scope to match the iOS `@MainActor` isolation; tests pass
 *   a `TestScope` for virtual-time control.
 * @param promptThresholds silence windows for the input-prompt detector.
 */
class TerminalSessionVm(
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.Main),
    private val promptThresholds: InputPromptThresholds = InputPromptThresholds(),
) {

    /** Installed by the terminal view. Receives live bytes after [terminalReady]. */
    var onTerminalOutput: ((ByteArray) -> Unit)? = null

    /**
     * Installed by the terminal view. Fires when [awaitingInput] transitions
     * (and only on an actual change — see [setAwaitingInput]). Parity with Swift
     * `onAwaitingInputChanged`: a view-level hook, NOT coordinator-wired. The
     * server-driven `sessionsAwaitingInput` set (the tab attention-flash) lives
     * on `ActivityCoordinator` and is a separate signal.
     */
    var onAwaitingInputChanged: ((Boolean) -> Unit)? = null

    /** Fires after replay bytes have reached this terminal's engine. */
    var onReplayFlushed: (() -> Unit)? = null

    /**
     * True when output has been silent long enough that the session is likely
     * waiting for user input. Driven by [detectInputPrompt]. Mirrors Swift's
     * `@Published awaitingInput`.
     */
    var awaitingInput: Boolean = false
        private set

    /**
     * Set by the coordinator when a coding agent is actively running in this
     * session (Swift `isAgentActive`). Selects the silence threshold — a longer
     * window avoids false positives during API-call / tool-execution gaps.
     */
    var isAgentActive: Boolean = false

    /** Pending silence-debounce job; cancelled and replaced on each output chunk. */
    private var promptDebounceJob: Job? = null

    private var terminalSized = false
    private var isReplaying = false
    private var replayComplete = false

    private val pendingOutput = ArrayDeque<ByteArray>()
    private var pendingOutputBytes = 0
    private var didLogPendingCap = false

    /**
     * True while output is held to coalesce a manual refresh into a single
     * render. The server's refresh wiggles the PTY width (cols → cols−1 →
     * 150 ms → cols), so a full-screen app repaints TWICE — once at the narrow
     * width, then again at full width. Feeding both frames live flashes the
     * intermediate narrow frame for ~150 ms (the flicker). Holding output for a
     * short quiet window and flushing it as one blob lets the terminal engine
     * apply both reflows in a single display pass, so only the final frame
     * shows. Mirrors Swift `TerminalViewModel.isCoalescingRefresh`.
     */
    private var isCoalescingRefresh = false
    private var refreshCoalesceJob: Job? = null
    private var refreshHardCapJob: Job? = null

    companion object {
        /** 4 MB. Matches Swift `TerminalViewModel.pendingOutputByteLimit`. */
        const val PENDING_OUTPUT_BYTE_LIMIT: Int = 4 * 1024 * 1024
        /** Flush after output stays quiet this long; must exceed the server's
         *  150 ms width-wiggle gap. Matches Swift `refreshQuietWindow`. */
        const val REFRESH_QUIET_WINDOW_MS: Long = 220
        /** Backstop so a continuously-streaming session still flushes. Matches
         *  Swift `refreshMaxWindow`. */
        const val REFRESH_MAX_WINDOW_MS: Long = 1200
    }

    /**
     * Begins coalescing the manual-refresh repaint burst. Called on the active
     * session's VM right before the `refresh` message is sent. Only meaningful
     * when the view is live (not replaying / not still laying out); otherwise
     * the existing buffering paths already batch output.
     */
    fun beginRefreshCoalesce() {
        if (!terminalSized || isReplaying || onTerminalOutput == null) return
        isCoalescingRefresh = true
        armRefreshQuietTimer(hardCap = true)
    }

    private fun armRefreshQuietTimer(hardCap: Boolean = false) {
        if (!isCoalescingRefresh) return
        refreshCoalesceJob?.cancel()
        refreshCoalesceJob = scope.launch {
            delay(REFRESH_QUIET_WINDOW_MS)
            if (isActive) flushCoalescedRefresh()
        }
        if (hardCap) {
            refreshHardCapJob?.cancel()
            refreshHardCapJob = scope.launch {
                delay(REFRESH_MAX_WINDOW_MS)
                if (isActive) flushCoalescedRefresh()
            }
        }
    }

    private fun flushCoalescedRefresh() {
        if (!isCoalescingRefresh) return
        isCoalescingRefresh = false
        refreshCoalesceJob?.cancel(); refreshCoalesceJob = null
        refreshHardCapJob?.cancel(); refreshHardCapJob = null
        flushPending()
    }

    /** Receives terminal output from the coordinator's I/O routing. */
    fun receiveOutput(data: ByteArray) {
        // While coalescing a manual refresh, hold everything and (re)arm the
        // quiet-window timer so the whole repaint burst flushes as one blob.
        if (isCoalescingRefresh) {
            pendingOutput.addLast(data)
            pendingOutputBytes += data.size
            armRefreshQuietTimer()
            detectInputPrompt(data)
            return
        }
        val handler = onTerminalOutput
        if (!isReplaying && terminalSized && handler != null) {
            handler(data)
        } else {
            pendingOutput.addLast(data)
            pendingOutputBytes += data.size
            if (pendingOutputBytes > PENDING_OUTPUT_BYTE_LIMIT && !didLogPendingCap) {
                // Once-per-session warning flag (parity with Swift's didLogPendingCap).
                didLogPendingCap = true
            }
            // Drop-oldest FIFO until back within cap.
            while (pendingOutputBytes > PENDING_OUTPUT_BYTE_LIMIT && pendingOutput.isNotEmpty()) {
                val dropped = pendingOutput.removeFirst()
                pendingOutputBytes -= dropped.size
            }
        }
        // Swift calls detectInputPrompt unconditionally at the end of
        // receiveOutput — on BOTH the live and buffered paths, and for empty
        // chunks (TerminalViewModel.swift:130). Match that exactly.
        detectInputPrompt(data)
    }

    /**
     * Call once after the terminal view's first size callback. Flushes any
     * scrollback that arrived while the view was laying out, unless a replay is
     * in progress (in which case [endReplay] flushes instead and this only
     * blanks the screen with RIS). Idempotent: subsequent calls are no-ops.
     */
    fun terminalReady() {
        if (terminalSized) return
        terminalSized = true
        didLogPendingCap = false
        if (isReplaying) {
            onTerminalOutput?.invoke(ReplayProtocol.RIS)
            return
        }
        val completedReplay = replayComplete
        replayComplete = false
        flushPending(prefix = if (completedReplay) ReplayProtocol.RIS else ByteArray(0))
        if (completedReplay) onReplayFlushed?.invoke()
    }

    /** Enters replay-buffering mode. All output is held until [endReplay]. */
    fun beginReplay() {
        isReplaying = true
    }

    /**
     * Exits replay-buffering mode and flushes all pending data as a single
     * contiguous blob so the terminal engine renders in one display pass.
     * No-op when no replay is active (guard parity with Swift).
     */
    fun endReplay() {
        if (!isReplaying) return
        isReplaying = false
        if (terminalSized) {
            flushPending()
            onReplayFlushed?.invoke()
        } else {
            replayComplete = true
        }
    }

    /**
     * RIS (Reset to Initial State) clears the terminal before replaying
     * scrollback. Mirrors Swift `resetForReplay`.
     */
    fun resetForReplay() {
        onTerminalOutput?.invoke(ReplayProtocol.RIS)
    }

    /**
     * Called by the view when switching away from this session. Clears the
     * callbacks (the old terminal view is about to be destroyed) and resets
     * buffering state.
     */
    fun prepareForSwitch() {
        resetState()
    }

    /**
     * Resets buffering state in preparation for ring-buffer replay. The RIS
     * (ESC c) is deferred to [terminalReady] so it fires only once the view is
     * wired and can blank the screen immediately. Mirrors Swift
     * `prepareForReplay` (identical body to `prepareForSwitch`).
     */
    fun prepareForReplay() {
        resetState()
    }

    /**
     * Concatenates the whole pending deque into one [ByteArray], emits it once,
     * and clears the buffer. A single feed — no incremental render. An empty
     * buffer emits nothing unless a deferred replay reset supplies [prefix].
     */
    private fun flushPending(prefix: ByteArray = ByteArray(0)) {
        val handler = onTerminalOutput ?: return
        if (pendingOutput.isEmpty() && prefix.isEmpty()) {
            pendingOutputBytes = 0
            return
        }
        val combined = ByteArray(prefix.size + pendingOutputBytes)
        prefix.copyInto(combined)
        var offset = prefix.size
        for (chunk in pendingOutput) {
            chunk.copyInto(combined, offset)
            offset += chunk.size
        }
        pendingOutput.clear()
        pendingOutputBytes = 0
        didLogPendingCap = false
        if (combined.isNotEmpty()) handler(combined)
    }

    private fun resetState() {
        // Swift `prepareForSwitch` / `prepareForReplay` cancel + null the
        // pending debounce (TerminalViewModel.swift:187-188, :204-205) so a
        // stale timer can't flip awaitingInput after the view is gone.
        promptDebounceJob?.cancel()
        promptDebounceJob = null
        onTerminalOutput = null
        onAwaitingInputChanged = null
        onReplayFlushed = null
        terminalSized = false
        isReplaying = false
        replayComplete = false
        isCoalescingRefresh = false
        refreshCoalesceJob?.cancel()
        refreshCoalesceJob = null
        refreshHardCapJob?.cancel()
        refreshHardCapJob = null
        pendingOutput.clear()
        pendingOutputBytes = 0
        didLogPendingCap = false
    }

    // MARK: - Input Prompt Detection

    /**
     * Output-silence detector, ported from Swift `detectInputPrompt(_:)`
     * (TerminalViewModel.swift:245-257). On each output chunk:
     *  1. cancel any pending debounce job,
     *  2. if currently [awaitingInput], clear it ([setAwaitingInput] false) —
     *     fresh output means the session is no longer idle,
     *  3. pick the threshold ([isAgentActive] ? agentActive : normal),
     *  4. launch a new debounce job that [delay]s the threshold then, if not
     *     cancelled, sets [awaitingInput] true.
     *
     * The launched job runs on the injected [scope], so under a `TestScope` the
     * `delay` is virtual and `advanceTimeBy(...)` fires it deterministically.
     * `data` is unused (Swift ignores its contents too — the mere arrival of a
     * chunk, empty or not, resets the silence timer).
     */
    @Suppress("UNUSED_PARAMETER")
    private fun detectInputPrompt(data: ByteArray) {
        promptDebounceJob?.cancel()
        promptDebounceJob = null

        if (awaitingInput) setAwaitingInput(false)

        val threshold = if (isAgentActive) promptThresholds.agentActiveMs else promptThresholds.normalMs
        promptDebounceJob = scope.launch {
            delay(threshold)
            // `isActive` guard == Swift's `guard !Task.isCancelled` — a job
            // cancelled mid-delay must not flip the flag.
            if (isActive) setAwaitingInput(true)
        }
    }

    /**
     * Transitions [awaitingInput] and fires [onAwaitingInputChanged] ONLY on an
     * actual change (Swift dedupes via `guard awaitingInput != value`,
     * TerminalViewModel.swift:259-263).
     */
    private fun setAwaitingInput(value: Boolean) {
        if (awaitingInput == value) return
        awaitingInput = value
        onAwaitingInputChanged?.invoke(value)
    }
}
