package relay.session

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import relay.net.OptimizeOutcome
import relay.net.OptimizerStrings
import relay.net.PromptOptimizerProtocol
import relay.net.ReplaceOutcome
import java.util.UUID

/** What the relay told us about the optimizer at auth time (spec §7.1, §9). */
enum class OptimizerAvailability {
    /** Not authenticated yet — nothing known. */
    UNKNOWN,
    /** `auth_success.protocolVersion` < 2: the relay predates the feature. */
    SERVER_TOO_OLD,
    /** Protocol ≥ 2 but no `prompt_optimizer` capability: not enabled / no key on the relay. */
    UNCONFIGURED,
    AVAILABLE,
}

enum class OptimizerState { IDLE, OPTIMIZING }

/** The pre-optimize draft, kept for 10 s so Undo can type it back (spec §7.1). */
data class OptimizerUndo(val sessionId: UUID, val original: String)

/**
 * The magic-wand state machine, ported from
 * `SharedSessionCoordinator+Optimizer.swift`. Owned by [SessionCoordinator] the
 * way [RecoveryController] and [ActivityCoordinator] are: every dependency is a
 * lambda, so the transitions are unit-tested with no socket, no controller and
 * no coordinator harness.
 *
 * Rules (Global Constraints of the Plan 3 document):
 *  - *Available* = protocol ≥ [PromptOptimizerProtocol.MIN_PROTOCOL_VERSION]
 *    **and** the [PromptOptimizerProtocol.CAPABILITY] capability. Unavailable is
 *    still *tappable*: the tap shows the hint instead of an RPC.
 *  - *Enabled* = [OptimizerState.IDLE] ∧ ¬recovering ∧ an active session.
 *  - Undo is one-shot, keyed by session, lives [UNDO_WINDOW_MS], and is cleared
 *    **only** by a successful `replace_prompt`, by expiry, or by a later
 *    successful optimize. A failed optimize or a failed undo keeps it, so the
 *    user's original is never discarded on an error (PR #58 finding A1-#1).
 *  - Nothing here logs: the draft, the prompt and the original are user text
 *    (spec §10).
 */
class PromptOptimizerController(
    private val scope: CoroutineScope,
    private val ensureAuthenticated: suspend () -> Unit,
    private val withAuth: suspend (suspend () -> Unit) -> Unit,
    private val isAuthenticated: () -> Boolean,
    private val serverProtocolVersion: () -> Int,
    private val serverCapabilities: () -> Set<String>,
    private val activeSessionId: () -> UUID?,
    private val isRecovering: () -> Boolean,
    private val optimize: suspend (sessionId: UUID, shareScreen: Boolean) -> OptimizeOutcome,
    private val replace: suspend (sessionId: UUID, text: String) -> ReplaceOutcome,
) {
    private val _availability = MutableStateFlow(OptimizerAvailability.UNKNOWN)
    val availability: StateFlow<OptimizerAvailability> = _availability.asStateFlow()

    private val _state = MutableStateFlow(OptimizerState.IDLE)
    val state: StateFlow<OptimizerState> = _state.asStateFlow()

    private val _undo = MutableStateFlow<OptimizerUndo?>(null)
    val undo: StateFlow<OptimizerUndo?> = _undo.asStateFlow()

    private val _notice = MutableStateFlow<String?>(null)
    /** The 4 s toast text, or null. */
    val notice: StateFlow<String?> = _notice.asStateFlow()

    private var undoExpiry: Job? = null
    private var noticeExpiry: Job? = null
    private var cancelled = false

    /** Tappable: not mid-RPC, not recovering, and there is a session to optimize. */
    val isWandEnabled: Boolean
        get() = _state.value == OptimizerState.IDLE && !isRecovering() && activeSessionId() != null

    val isAvailable: Boolean
        get() = _availability.value == OptimizerAvailability.AVAILABLE

    /** The toast for an unavailable wand, or null when available / unknown. */
    val wandHint: String?
        get() = when (_availability.value) {
            OptimizerAvailability.SERVER_TOO_OLD -> OptimizerStrings.UPDATE_RELAY_HINT
            OptimizerAvailability.UNCONFIGURED -> OptimizerStrings.CONFIG_HINT
            OptimizerAvailability.UNKNOWN, OptimizerAvailability.AVAILABLE -> null
        }

    /** Re-derives [availability] from the controller's `auth_success` facts. Call after every authenticate. */
    fun refreshAvailability() {
        _availability.value = when {
            !isAuthenticated() -> OptimizerAvailability.UNKNOWN
            serverProtocolVersion() < PromptOptimizerProtocol.MIN_PROTOCOL_VERSION -> OptimizerAvailability.SERVER_TOO_OLD
            PromptOptimizerProtocol.CAPABILITY in serverCapabilities() -> OptimizerAvailability.AVAILABLE
            else -> OptimizerAvailability.UNCONFIGURED
        }
    }

    /**
     * The wand tap. Fast-paths the hint when the cached availability already says
     * no; otherwise authenticates, re-derives availability (a reconnect may have
     * landed on a different relay), and runs the RPC.
     */
    suspend fun optimizePrompt(shareScreen: Boolean) {
        if (!isWandEnabled) return
        val sessionId = activeSessionId() ?: return
        wandHint?.let { showNotice(it); return }

        dismissNotice()
        _state.value = OptimizerState.OPTIMIZING
        try {
            ensureAuthenticated()
            if (cancelled) return
            refreshAvailability()
            wandHint?.let { showNotice(it); return }

            var outcome: OptimizeOutcome? = null
            withAuth { outcome = optimize(sessionId, shareScreen) }
            if (cancelled) return
            when (val result = outcome) {
                is OptimizeOutcome.Ok -> {
                    val original = result.original
                    if (original != null) {
                        armUndo(OptimizerUndo(sessionId, original))
                    } else {
                        clearUndo()
                        showNotice(OptimizerStrings.OPTIMIZED)
                    }
                }
                OptimizeOutcome.NoDraft -> showNotice(OptimizerStrings.NO_DRAFT)
                OptimizeOutcome.Passthrough -> showNotice(OptimizerStrings.PASSTHROUGH)
                OptimizeOutcome.Unconfigured -> {
                    _availability.value = OptimizerAvailability.UNCONFIGURED
                    showNotice(OptimizerStrings.CONFIG_HINT)
                }
                is OptimizeOutcome.Failed -> showNotice(result.message)
                null -> showNotice(OptimizerStrings.COULD_NOT_REWRITE)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            showNotice(messageFor(e))
        } finally {
            _state.value = OptimizerState.IDLE
        }
    }

    /** Undo: one-shot `replace_prompt(original)`; the chip survives a failure so the user can retry. */
    suspend fun undoOptimize() {
        if (!isWandEnabled) return
        val armed = _undo.value ?: return
        if (armed.sessionId != activeSessionId()) return

        dismissNotice()
        _state.value = OptimizerState.OPTIMIZING
        try {
            var outcome: ReplaceOutcome? = null
            withAuth { outcome = replace(armed.sessionId, armed.original) }
            if (cancelled) return
            when (val result = outcome) {
                ReplaceOutcome.Ok -> clearUndo()
                is ReplaceOutcome.Failed -> showNotice(result.message)
                null -> showNotice(OptimizerStrings.COULD_NOT_REWRITE)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            showNotice(messageFor(e))
        } finally {
            _state.value = OptimizerState.IDLE
        }
    }

    fun dismissNotice() {
        noticeExpiry?.cancel()
        noticeExpiry = null
        _notice.value = null
    }

    /** Teardown: drop the chip and the toast and stop their timers. */
    fun cancel() {
        cancelled = true
        clearUndo()
        dismissNotice()
    }

    private fun showNotice(text: String) {
        if (cancelled) return
        noticeExpiry?.cancel()
        _notice.value = text
        noticeExpiry = scope.launch {
            delay(NOTICE_WINDOW_MS)
            _notice.value = null
        }
    }

    private fun armUndo(undo: OptimizerUndo) {
        if (cancelled) return
        undoExpiry?.cancel()
        _undo.value = undo
        undoExpiry = scope.launch {
            delay(UNDO_WINDOW_MS)
            _undo.value = null
        }
    }

    private fun clearUndo() {
        undoExpiry?.cancel()
        undoExpiry = null
        _undo.value = null
    }

    private fun messageFor(e: Exception): String =
        e.message?.takeIf { it.isNotEmpty() } ?: OptimizerStrings.COULD_NOT_REWRITE

    companion object {
        /** How long the "Optimized · Undo" chip stays (spec §7.1). */
        const val UNDO_WINDOW_MS = 10_000L
        /** How long a toast stays (spec §7.1). */
        const val NOTICE_WINDOW_MS = 4_000L
    }
}
