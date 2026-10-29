package relay.session

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * What the loading sheet says, derived from one coordinator's load phase and
 * recovery state. One rule for the three ways a session reaches the screen —
 * a switch, the session-name refresh, a reconnect — so they look identical.
 * Port of `Sources/CodeRelayClient/Views/SessionLoadingPresentation.swift`.
 *
 * [expectsSession]: a session is attached or about to be restored. The
 * launch/wake handshake publishes connecting / authenticating / loadingSessions
 * while NO session is attached; with nothing to restore those narrate a
 * server, not a session, and must not raise a modal (a sheet there sat ~54 s
 * against an unreachable host with no Cancel). A switch and recovery always show.
 */
data class SessionLoadingPresentation private constructor(
    val isActive: Boolean,
    val title: String,
    val status: String,
    /** Bytes loaded so far — a literal "0 KB" from the first phase, so the layout never jumps; null only while idle. */
    val detail: String?,
    val subtitle: String?,
    val allowsCancel: Boolean,
    /** The closing step: shown for [SessionLoadingSheetModel.READY_DWELL_MS] after a load that succeeded. */
    val isReady: Boolean,
    val sessionAttached: Boolean,
    val loadFailed: Boolean,
    val recoveryFailed: Boolean,
    internal val isRecoveryPresentation: Boolean,
) {
    constructor(
        loadPhase: SessionLoadPhase?,
        isRecovering: Boolean,
        recoveryPhase: RecoveryPhase,
        expectsSession: Boolean = true,
        sessionAttached: Boolean = true,
        loadFailed: Boolean = false,
        recoveryFailed: Boolean = false,
        sessionName: String?,
        serverName: String?,
    ) : this(
        isActive = sessionBound(loadPhase, expectsSession) || isRecovering,
        title = if (isRecovering) "Reconnecting" else "Loading session",
        // The replay phase is the more specific status once it starts, even mid-recovery.
        status = loadPhase?.label ?: if (isRecovering) recoveryPhase.label else "",
        detail = if (sessionBound(loadPhase, expectsSession) || isRecovering) bytes(loadPhase) else null,
        subtitle = listOfNotNull(sessionName, serverName).filter { it.isNotEmpty() }.joinToString(" · ").ifEmpty { null },
        allowsCancel = isRecovering,
        isReady = false,
        sessionAttached = sessionAttached,
        loadFailed = loadFailed,
        recoveryFailed = recoveryFailed,
        isRecoveryPresentation = isRecovering,
    )

    /** The same sheet, closed out: "Ready" and the final byte count. */
    fun readied(): SessionLoadingPresentation = copy(
        isActive = false, status = "Ready", detail = detail ?: ZERO, allowsCancel = false, isReady = true,
        sessionAttached = true, loadFailed = false, recoveryFailed = false,
    )

    /**
     * Whether a load that just ended (this is the first inactive presentation
     * after [last]) succeeded: a session is on screen, nothing failed, and — if
     * it was a reconnect — the recovery was not cancelled or given up.
     */
    fun endsInReady(last: SessionLoadingPresentation?): Boolean {
        if (isActive || !sessionAttached || loadFailed) return false
        if (last?.isRecoveryPresentation == true && recoveryFailed) return false
        return true
    }

    companion object {
        private const val ZERO = "0 KB"

        private fun sessionBound(phase: SessionLoadPhase?, expectsSession: Boolean): Boolean = when (phase) {
            SessionLoadPhase.Attaching, is SessionLoadPhase.LoadingHistory -> true
            SessionLoadPhase.Connecting, SessionLoadPhase.Authenticating, SessionLoadPhase.LoadingSessions -> expectsSession
            null -> false
        }

        // "0 KB" (not formatBytes(0)'s "<1 KB", which suggests data arrived) until history streams.
        private fun bytes(phase: SessionLoadPhase?): String =
            (phase as? SessionLoadPhase.LoadingHistory)?.let { SessionLoadPhase.formatBytes(it.bytes) } ?: ZERO
    }
}

/**
 * Presents the sheet the instant something loads, holds it at least
 * [MINIMUM_VISIBLE_MS] so an instant switch reads as a response rather than a
 * flicker, closes a successful load with "Ready" for [READY_DWELL_MS], and
 * dismisses when nothing is loading. The terminal blackout follows
 * [isPresented] so sheet and black lift together.
 *
 * It is also the one enforcer of "the sheet never stays up": a presentation
 * unchanged for [STALL_TIMEOUT_MS] (no new phase, no new bytes) lowers the sheet
 * until progress resumes. Port of Swift `SessionLoadingSheetModel`; confined to
 * [scope]'s dispatcher.
 */
class SessionLoadingSheetModel(
    private val scope: CoroutineScope,
    private val sleepMs: suspend (Long) -> Unit = { delay(it) },
) {
    private val _isPresented = MutableStateFlow(false)
    val isPresented: StateFlow<Boolean> = _isPresented.asStateFlow()

    private val _shown = MutableStateFlow<SessionLoadingPresentation?>(null)
    /** The last active presentation, kept while the sheet animates down. */
    val shown: StateFlow<SessionLoadingPresentation?> = _shown.asStateFlow()

    private var active = false
    private var holdElapsed = true
    private var stalled = false
    private var showingReady = false
    private var holdJob: Job? = null
    private var stallJob: Job? = null
    private var readyJob: Job? = null

    fun update(presentation: SessionLoadingPresentation) {
        val changed = presentation != _shown.value
        val wasActive = active
        active = presentation.isActive
        if (presentation.isActive) {
            // A new load (or more bytes) takes over from a Ready in progress.
            readyJob?.cancel(); readyJob = null; showingReady = false
            _shown.value = presentation
        }
        if (wasActive && !active && _isPresented.value && !stalled && presentation.endsInReady(_shown.value)) {
            stallJob?.cancel(); stallJob = null
            showReady()
            return
        }
        if (active && changed) { stalled = false; armStall() }
        if (active && !_isPresented.value && !stalled) {
            _isPresented.value = true
            holdElapsed = false
            holdJob?.cancel()
            holdJob = scope.launch {
                sleepMs(MINIMUM_VISIBLE_MS)
                holdElapsed = true
                settle()
            }
        }
        if (!active) { stallJob?.cancel(); stallJob = null; stalled = false }
        settle()
    }

    private fun armStall() {
        stallJob?.cancel()
        stallJob = scope.launch {
            sleepMs(STALL_TIMEOUT_MS)
            if (!active) return@launch
            stalled = true
            _isPresented.value = false
        }
    }

    private fun showReady() {
        _shown.value = _shown.value?.readied()
        showingReady = true
        readyJob?.cancel()
        readyJob = scope.launch {
            sleepMs(READY_DWELL_MS)
            if (!showingReady || active) return@launch
            showingReady = false
            _isPresented.value = false
        }
    }

    private fun settle() {
        if (_isPresented.value && !active && holdElapsed && !showingReady) _isPresented.value = false
    }

    companion object {
        const val MINIMUM_VISIBLE_MS = 600L
        const val STALL_TIMEOUT_MS = 15_000L
        const val READY_DWELL_MS = 600L
    }
}
