package relay.storage

import relay.protocol.SessionNamingTheme

/**
 * Utilities for picking session names from a theme.
 *
 * Ports the `SessionNaming` enum from `SessionNaming.swift` (ClaudeRelayClient).
 */
object SessionNaming {

    /**
     * Picks a name from [theme] that isn't already in [usedNames]. Falls back to
     * `"Session <fallbackIndex>"` when every theme name is taken.
     *
     * The pick is **random** among the unused names, matching Swift's
     * `available.randomElement()`. Kotlin's [List.randomOrNull] is the analog of
     * Swift's `Array.randomElement()` — it returns `null` for an empty list, which
     * we map to the fallback label.
     *
     * @param usedNames Names currently in use (case-sensitive).
     * @param theme The theme whose name pool to draw from.
     * @param fallbackIndex Number used in the fallback label when the pool is exhausted.
     */
    fun pickDefaultName(
        usedNames: Set<String>,
        theme: SessionNamingTheme,
        fallbackIndex: Int
    ): String {
        val available = theme.names.filter { it !in usedNames }
        return available.randomOrNull() ?: "Session $fallbackIndex"
    }
}
