package relay.terminal

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
 * NOTE: the input-prompt silence detector (the 1000 ms / 2000 ms debounce that
 * drives `awaitingInput`) is M4 Task 3 and is intentionally NOT implemented
 * here. [onAwaitingInputChanged] is declared so the later milestone can wire
 * it without changing this type's surface.
 */
class TerminalSessionVm {

    /** Installed by the terminal view. Receives live bytes after [terminalReady]. */
    var onTerminalOutput: ((ByteArray) -> Unit)? = null

    /** Installed by the terminal view. Fires when `awaitingInput` transitions (M4). */
    var onAwaitingInputChanged: ((Boolean) -> Unit)? = null

    private var terminalSized = false
    private var isReplaying = false

    private val pendingOutput = ArrayDeque<ByteArray>()
    private var pendingOutputBytes = 0
    private var didLogPendingCap = false

    companion object {
        /** 4 MB. Matches Swift `TerminalViewModel.pendingOutputByteLimit`. */
        const val PENDING_OUTPUT_BYTE_LIMIT: Int = 4 * 1024 * 1024
    }

    /** Receives terminal output from the coordinator's I/O routing. */
    fun receiveOutput(data: ByteArray) {
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
        // detectInputPrompt(data) — M4 Task 3, deliberately omitted.
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
        flushPending()
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
     * and clears the buffer. A single feed — no incremental render. Empty
     * buffers emit nothing (parity with Swift's `if !combined.isEmpty`).
     */
    private fun flushPending() {
        val handler = onTerminalOutput ?: return
        if (pendingOutput.isEmpty()) {
            pendingOutputBytes = 0
            return
        }
        val combined = ByteArray(pendingOutputBytes)
        var offset = 0
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
        onTerminalOutput = null
        onAwaitingInputChanged = null
        terminalSized = false
        isReplaying = false
        pendingOutput.clear()
        pendingOutputBytes = 0
        didLogPendingCap = false
    }
}
