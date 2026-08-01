package relay.feature.workspace

import java.util.UUID

/**
 * Pure-JVM parser + builder for the `clauderelay://` session deep link, ported
 * to match the iOS URL shape EXACTLY.
 *
 * The canonical iOS link (the only one any client produces or consumes) is built
 * in `QRCodeSheet.swift` / `QRCodeComponents.swift` as:
 *
 *     "clauderelay://session/\(sessionId.uuidString)"
 *
 * and parsed in `ClaudeRelayApp.swift` / `SessionSidebarView.swift` as:
 *
 *     url.scheme == "clauderelay" && url.host == "session"
 *       && UUID(uuidString: url.pathComponents.dropFirst().first)
 *
 * i.e. **scheme = `clauderelay`, host = `session`, single path segment = the
 * UUID**. Swift's `UUID.uuidString` is uppercase, so the QR payloads in the wild
 * are uppercase — but `UUID(uuidString:)` (and `java.util.UUID.fromString`) are
 * case-insensitive, so we parse either case and emit lowercase ourselves.
 *
 * Kept deliberately pure (string parsing, no `android.net.Uri`) so it is covered
 * by fast JVM unit tests rather than an instrumented test.
 */
object DeepLinks {
    /** URL scheme — must match the manifest `<data android:scheme>` and iOS. */
    const val SCHEME = "clauderelay"

    /** Host component — the iOS `url.host`. */
    const val HOST = "session"

    private const val PREFIX = "$SCHEME://$HOST/"

    /**
     * Parse a `clauderelay://session/<uuid>` link to its session [UUID].
     *
     * Returns null on any mismatch — wrong scheme, wrong host, missing or
     * malformed UUID segment, or extra path segments. Case-insensitive on the
     * UUID (so uppercase iOS payloads parse). Robust: never throws.
     */
    fun parseSessionId(uri: String): UUID? {
        val trimmed = uri.trim()
        // Scheme + host check, case-insensitive on the scheme/host shell (schemes
        // and authorities are case-insensitive per RFC 3986; the UUID body is
        // matched by UUID.fromString, which is itself case-insensitive).
        if (!trimmed.regionMatches(0, PREFIX, 0, PREFIX.length, ignoreCase = true)) {
            return null
        }
        // Everything after the host slash is the path. Reject any further segment
        // (or a trailing slash) so `clauderelay://session/<uuid>/extra` is null,
        // matching iOS taking exactly `pathComponents.dropFirst().first`.
        val segment = trimmed.substring(PREFIX.length)
        if (segment.isEmpty() || segment.contains('/')) return null
        // Strip a query/fragment if present, then validate strictly.
        val lastSegment = segment.substringBefore('?').substringBefore('#')
        return runCatching { UUID.fromString(lastSegment) }.getOrNull()
    }

    /**
     * Build the canonical deep link for [id] — lowercase UUID. Round-trips
     * through [parseSessionId].
     */
    fun sessionUri(id: UUID): String = "$PREFIX${id.toString().lowercase()}"

    /**
     * Parse a `clauderelay://pair?host=&port=&tls=&code=` pairing link to a
     * [relay.protocol.PairingURL].
     *
     * Returns null on any mismatch — wrong scheme, wrong host, missing or invalid
     * query parameters. Thin delegate to [relay.protocol.PairingURL.parse] so
     * the feature module has one deep-link entry point while parsing/validation
     * stays in core-protocol (Task 5). Robust: never throws.
     */
    fun parsePairingUrl(uri: String): relay.protocol.PairingURL? =
        relay.protocol.PairingURL.parse(uri)
}
