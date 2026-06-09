package relay.feature.workspace.ui

import relay.protocol.SessionState

/**
 * Pure-logic helpers for the workspace UI, split out from the Composables so they
 * are unit-testable on the JVM without Compose. These mirror small formatting /
 * mapping pieces of the Swift screens (`ActiveTerminalView.swift`,
 * `SessionSidebarView.swift`).
 */
object WorkspaceLogic {

    /**
     * Formats a session uptime in [seconds] into the status-bar string, ported
     * EXACTLY from `ActiveTerminalView.swift:348-358`:
     *  - `%dd %02d:%02d:%02d` when there is at least one whole day,
     *  - `%02d:%02d:%02d` otherwise.
     *
     * Negative inputs clamp to 0 (Swift `max(0, ...)`).
     *
     * Examples: `0 → "00:00:00"`, `65 → "00:01:05"`, `90061 → "1d 01:01:01"`.
     */
    fun formatUptime(seconds: Long): String {
        val total = if (seconds < 0) 0 else seconds
        val days = total / 86_400
        val hours = (total % 86_400) / 3_600
        val minutes = (total % 3_600) / 60
        val secs = total % 60
        return if (days > 0) {
            "%dd %02d:%02d:%02d".format(days, hours, minutes, secs)
        } else {
            "%02d:%02d:%02d".format(hours, minutes, secs)
        }
    }

    /**
     * The three state-badge buckets used by the sidebar row, ported from
     * `SessionSidebarView.swift:174-180`:
     *  - green for `active-attached` / `active-detached`
     *  - yellow for `created` / `starting` / `resuming`
     *  - red for the terminal states (`exited` / `failed` / `terminated` / `expired`)
     */
    enum class BadgeBucket { GREEN, YELLOW, RED }

    fun badgeBucket(state: SessionState): BadgeBucket = when (state) {
        SessionState.ACTIVE_ATTACHED, SessionState.ACTIVE_DETACHED -> BadgeBucket.GREEN
        SessionState.CREATED, SessionState.STARTING, SessionState.RESUMING -> BadgeBucket.YELLOW
        SessionState.EXITED, SessionState.FAILED,
        SessionState.TERMINATED, SessionState.EXPIRED -> BadgeBucket.RED
    }

    /**
     * The blank-skip + UTF-8 encode decision for a speech utterance routed to the
     * terminal, extracted so the `WorkspaceViewModel.sendInput(String)` overload's
     * load-bearing behaviour is unit-testable without a `SessionCoordinator` or a
     * coroutine `viewModelScope`. Returns the bytes to send, or `null` when the
     * text is blank/whitespace-only (emit nothing — mirrors the
     * `onUtteranceReady → if text.isNotBlank → sendInput` wiring + the iOS
     * `if let text, !text.isEmpty` guard in `MicButton.swift`).
     */
    fun utteranceInputBytes(text: String): ByteArray? =
        if (text.isBlank()) null else text.toByteArray(Charsets.UTF_8)
}
