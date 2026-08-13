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
     * True while output is held to coalesce a repaint burst into a single
     * render. The server wiggles the PTY width after every replay (cols →
     * cols−1 → 150 ms → cols), so a full-screen app repaints TWICE — once at the
     * narrow width, then again at full width. Feeding both frames live flashes
     * the intermediate narrow frame for ~150 ms (the flicker). Holding output for
     * a short quiet window and flushing it as one blob lets the terminal engine
     * apply both reflows in a single display pass, so only the final frame
     * shows. Mirrors Swift `TerminalViewModel.isCoalescingRefresh`.
     */
    private var isCoalescingRefresh = false
    private var refreshCoalesceJob: Job? = null
    private var refreshHardCapJob: Job? = null

    /**
     * True when the in-flight replay must be preceded by a RIS clear because the
     * terminal view is staying put. [terminalReady] normally emits that clear,
     * but it fires only on a view's FIRST layout — a reload in place has no new
     * layout, so the clear has to ride in front of the flush instead. Mirrors
     * Swift `TerminalViewModel.clearOnReplayFlush`.
     */
    private var clearOnReplayFlush = false
    private var reloadBackstopJob: Job? = null

    companion object {
        /** 4 MB. Matches Swift `TerminalViewModel.pendingOutputByteLimit`. */
        const val PENDING_OUTPUT_BYTE_LIMIT: Int = 4 * 1024 * 1024
        /** Flush after output stays quiet this long; must exceed the server's
         *  150 ms width-wiggle gap. Matches Swift `refreshQuietWindow`. */
        const val REFRESH_QUIET_WINDOW_MS: Long = 220
        /** Backstop so a continuously-streaming session still flushes. Matches
         *  Swift `refreshMaxWindow`. */
        const val REFRESH_MAX_WINDOW_MS: Long = 1200
        /** Give a reload's replay this long to arrive before flushing whatever we
         *  have. Generous: the server streams the whole ring buffer in 64 KB
         *  frames. Matches Swift `reloadBackstop`. */
        const val RELOAD_BACKSTOP_MS: Long = 5_000
    }

    /**
     * True from [beginServerReload] until the replay lands (or is cancelled). The
     * coordinator drops a second tap while this holds: two overlapping replays
     * paint the screen twice, the second appended below the first. Mirrors Swift
     * `TerminalViewModel.isReloadingFromServer`.
     */
    val isReloadingFromServer: Boolean get() = clearOnReplayFlush

    /**
     * Tap-to-reload, client half: throws away the locally cached terminal text
     * and buffers whatever arrives next so it can REPLACE the screen instead of
     * appending to it. `SessionCoordinator.reloadTerminalFromServer` owns the
     * other half — the resume that makes the server replay its ring buffer.
     *
     * The RIS clear is deferred to the flush in [endReplay] rather than emitted
     * now: blanking up front would leave the pane empty for the whole round trip,
     * whereas one RIS-prefixed blob swaps old screen for new in a single display
     * pass. Mirrors Swift `TerminalViewModel.beginServerReload`.
     */
    fun beginServerReload() {
        isCoalescingRefresh = false
        refreshCoalesceJob?.cancel(); refreshCoalesceJob = null
        refreshHardCapJob?.cancel(); refreshHardCapJob = null
        // Anything already buffered belongs to the screen we're discarding —
        // keeping it would paint stale bytes after the RIS.
        pendingOutput.clear()
        pendingOutputBytes = 0
        clearOnReplayFlush = true
        beginReplay()
        reloadBackstopJob?.cancel()
        reloadBackstopJob = scope.launch {
            delay(RELOAD_BACKSTOP_MS)
            if (isActive) endReplay()
        }
    }

    /**
     * Aborts a [beginServerReload] whose resume never made it to the server.
     * Drops the pending clear so the pane keeps the copy it already has — a
     * failed reload must not blank the terminal.
     */
    fun cancelServerReload() {
        if (!isReplaying || !clearOnReplayFlush) return
        clearOnReplayFlush = false
        endReplay()
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
            clearOnReplayFlush = false   // this layout emits the clear instead
            onTerminalOutput?.invoke(ReplayProtocol.RIS)
            return
        }
        val completedReplay = replayComplete
        replayComplete = false
        if (completedReplay) clearOnReplayFlush = false
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
        reloadBackstopJob?.cancel(); reloadBackstopJob = null
        if (terminalSized) {
            // RIS was already emitted by [terminalReady] while replaying — except
            // after [beginServerReload], where no layout happened and the clear
            // rides in front of this flush.
            val isReload = clearOnReplayFlush
            clearOnReplayFlush = false
            flushPending(prefix = if (isReload) ReplayProtocol.RIS else ByteArray(0))
            onReplayFlushed?.invoke()
            // The server resize-wiggles after every replay, so a full-screen app
            // is about to repaint TWICE ~150 ms apart. Coalesce that burst too, or
            // the reload ends on a flash of the narrow frame.
            if (isReload) {
                isCoalescingRefresh = true
                armRefreshQuietTimer(hardCap = true)
            }
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
     * Identifies the view currently wired to this vm.
     *
     * This vm is owned by the coordinator's terminal cache, so it OUTLIVES any
     * single composition. A view rebuild therefore means a new owner binds while
     * the old one is still alive and about to tear itself down — and on Android
     * the two overlap in the dangerous order: an Activity recreation (a fold /
     * unfold, which no `configChanges` can suppress) runs the new instance's
     * `onCreate` + composition BEFORE the old instance's `onDestroy`. So the old
     * view's teardown can land AFTER the new view has already wired itself here.
     *
     * [claimOwnership] hands out a fresh token per binder; [releaseOwnership]
     * only tears down when the caller's token is still the current one. Without
     * that check a superseded teardown nulls the LIVE wiring and the terminal
     * goes permanently black: [resetState] clears [terminalSized], but the new
     * controller's one-shot first-size latch is already spent, so nothing can
     * re-fire [terminalReady] and output buffers forever.
     */
    private var ownerToken: Any? = null

    /**
     * Registers the caller as this vm's current view owner and returns its
     * token, to be passed back to [releaseOwnership] on teardown. The previous
     * owner is superseded silently — its later teardown becomes a no-op.
     */
    fun claimOwnership(): Any = Any().also { ownerToken = it }

    /**
     * Tears down the view wiring only if [token] is still the current owner
     * (see [ownerToken]). Returns true when the teardown ran, so a caller can
     * tell whether it was the live owner or a superseded one.
     */
    fun releaseOwnership(token: Any): Boolean {
        if (token !== ownerToken) return false
        ownerToken = null
        resetState()
        return true
    }

    /**
     * Called by the view when switching away from this session. Clears the
     * callbacks (the old terminal view is about to be destroyed) and resets
     * buffering state.
     *
     * Unconditional — this is the COORDINATOR's teardown (a real session switch
     * or an eviction), which outranks any view's claim. View-driven teardown
     * goes through [releaseOwnership] instead so a superseded view can't wipe
     * its replacement's wiring.
     */
    fun prepareForSwitch() {
        ownerToken = null
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
        clearOnReplayFlush = false
        reloadBackstopJob?.cancel()
        reloadBackstopJob = null
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
