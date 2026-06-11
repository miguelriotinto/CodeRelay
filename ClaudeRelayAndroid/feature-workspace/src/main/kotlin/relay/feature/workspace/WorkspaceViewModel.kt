package relay.feature.workspace

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import relay.feature.workspace.ui.WorkspaceLogic
import relay.protocol.ClientMessage
import relay.protocol.ConnectionQuality
import relay.session.SessionCoordinator
import java.util.UUID

/**
 * Thin wrapper over [SessionCoordinator] for the workspace screen. The
 * coordinator already exposes every session/recovery/activity [StateFlow] the UI
 * collects; this view model only adds the two reactive surfaces the coordinator
 * does NOT publish:
 *
 *  1. **Connection quality.** [SessionCoordinator.connection] is a
 *     `CoordinatorConnection` interface that does not surface quality, and the
 *     concrete `RelayConnection.connectionQuality` is a plain `var` with no flow.
 *     So we poll a [qualityProvider] on a fixed cadence and republish as a
 *     [StateFlow] for the status-bar dot. The `:app` layer injects
 *     `{ relayConnection.connectionQuality }`; tests inject a fake.
 *
 *  2. **Active-session uptime.** We record a monotonic start instant the first
 *     time a session id becomes active and tick [uptimeSeconds] every second
 *     while it stays active. This avoids depending on the server `createdAt`
 *     reference-date epoch, whose Android conversion is not validated until
 *     Task 9 (see ReferenceDateDoubleSerializer). The Swift status bar uses the
 *     server `createdAt`; the displayed format is identical
 *     (WorkspaceLogic.formatUptime).
 *
 * Owning these as flows keeps the screen purely declarative (collect-only) and
 * the polling lifecycle tied to [viewModelScope].
 *
 * @param coordinator the session orchestrator (constructed by `:app` in Task 11)
 * @param qualityProvider reads the current [ConnectionQuality] from the live
 *   connection; polled, not observed
 * @param sendBinary the relay binary-input sink. Terminal keystrokes are RAW
 *   binary frames (NOT the envelope protocol), and the `CoordinatorConnection`
 *   interface only exposes the envelope `send(...)`, so the concrete
 *   `RelayConnection.sendBinary` is injected here. `:app` wires
 *   `{ bytes -> connection.sendBinary(bytes) }`; tests inject a recorder.
 * @param nowMs monotonic clock for uptime (inject `SystemClock.elapsedRealtime`
 *   from `:app`; defaults to wall-clock for pure-JVM construction)
 */
class WorkspaceViewModel(
    val coordinator: SessionCoordinator,
    private val qualityProvider: () -> ConnectionQuality,
    private val sendBinary: suspend (ByteArray) -> Unit = {},
    private val nowMs: () -> Long = { System.currentTimeMillis() },
) : ViewModel() {

    /**
     * Fire-and-forget terminal input. The screen calls this from the
     * [TerminalHost] / [KeyboardAccessory] onInput callbacks; the bytes go out as
     * a raw binary WebSocket frame on [viewModelScope].
     */
    fun sendInput(bytes: ByteArray) {
        // Prove the socket is alive on user activity. OkHttp's send() returns true
        // for bytes merely enqueued onto a half-open socket, so a keystroke can
        // vanish without tripping onSendFailed; this drives a fast liveness probe +
        // recovery instead of waiting up to ~45 s on the keepalive death detector.
        coordinator.notifyUserActivity()
        viewModelScope.launch { runCatching { sendBinary(bytes) } }
    }

    /**
     * Text-input overload for the speech pipeline. The continuous-listening engine
     * and the push-to-talk engine both deliver a cleaned utterance as a `String`
     * ([relay.speech.ContinuousListeningEngine.onUtteranceReady] /
     * `OnDeviceSpeechEngine.stopAndProcess`), so this UTF-8-encodes the text and
     * routes it through the existing raw-binary terminal-input path — exactly the
     * iOS `vm.sendInput(text)` seam the MicButton calls.
     *
     * Blank/whitespace-only text is dropped (the wiring already blank-skips, but
     * this guards the sink directly too) so a silent utterance never sends an empty
     * frame to the PTY.
     */
    fun sendInput(text: String) {
        val bytes = WorkspaceLogic.utteranceInputBytes(text) ?: return
        sendInput(bytes)
    }

    /**
     * Forwards the terminal's measured grid to the server PTY so its window size
     * matches what is actually on screen. The real VT engine (the termlib
     * `Terminal` in [relay.feature.workspace.ui.TerminalHost]) auto-fits cols×rows
     * to the pane and reports the result through
     * [relay.terminal.RelayTerminalController.reportSize]; the screen wires that
     * here.
     *
     * Faithful port of iOS `TerminalViewModel.sendResize(cols:rows:)`
     * (`TerminalViewModel.swift:235`): suppressed while a recovery pass is in
     * flight (Swift `guard !isSendingSuppressed` → [SessionCoordinator.sendsSuppressed]),
     * then sent as the envelope [ClientMessage.Resize] — NOT a raw binary frame,
     * since resize is a control message. The server applies it to the connection's
     * attached session, so no sessionId is carried (matching iOS + the wire
     * protocol). Non-positive dims are dropped (parity with the controller's own
     * `reportSize` guard).
     */
    fun sendResize(cols: Int, rows: Int) {
        if (cols <= 0 || rows <= 0) return
        viewModelScope.launch {
            // Re-check suppression INSIDE the coroutine (not before launch): the UI
            // and the recovery controller both run on Main, so a resize enqueued
            // while sendsSuppressed was false could otherwise dispatch after
            // recovery flipped it true. Checking here makes the gate atomic with
            // the send (parity intent of iOS `guard !isSendingSuppressed`).
            if (coordinator.sendsSuppressed) return@launch
            runCatching {
                coordinator.connection.send(ClientMessage.Resize(cols.toUShort(), rows.toUShort()))
            }
        }
    }

    private val _connectionQuality = MutableStateFlow(ConnectionQuality.DISCONNECTED)
    val connectionQuality: StateFlow<ConnectionQuality> = _connectionQuality.asStateFlow()

    private val _uptimeSeconds = MutableStateFlow(0L)
    val uptimeSeconds: StateFlow<Long> = _uptimeSeconds.asStateFlow()

    /** Monotonic start instant for the currently-active session id, or null. */
    private var activeSince: Long? = null
    private var trackedActiveId: UUID? = null

    init {
        // Poll connection quality for the status-bar dot.
        viewModelScope.launch {
            while (true) {
                _connectionQuality.value = qualityProvider()
                delay(QUALITY_POLL_MS)
            }
        }
        // Uptime ticker. Re-anchors whenever the active session changes, then
        // ticks once per second while a session is active.
        viewModelScope.launch {
            while (true) {
                val activeId = coordinator.activeSessionId.value
                if (activeId == null) {
                    activeSince = null
                    trackedActiveId = null
                    _uptimeSeconds.value = 0L
                } else {
                    if (activeId != trackedActiveId) {
                        trackedActiveId = activeId
                        activeSince = nowMs()
                    }
                    val since = activeSince ?: nowMs().also { activeSince = it }
                    _uptimeSeconds.value = ((nowMs() - since) / 1000L).coerceAtLeast(0L)
                }
                delay(UPTIME_TICK_MS)
            }
        }
    }

    private companion object {
        const val QUALITY_POLL_MS = 2_000L
        const val UPTIME_TICK_MS = 1_000L
    }
}
