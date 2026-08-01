package relay.protocol

/**
 * Kotlin mirror of Swift ClaudeRelayKit PairingCode. Crockford Base32.
 *
 * A short, human-transcribable one-time pairing code. Alphabet is Crockford
 * Base32 — the 10 digits plus 22 uppercase letters, excluding `I`, `L`, `O` and
 * `U`. That removes every `0`/`O` and `1`/`I`/`L` confusion when a user reads a
 * code off a screen and types it on a phone.
 *
 * 8 characters over a 32-symbol alphabet is 40 bits of entropy. Combined with
 * the server's per-IP rate limit and a 5-minute TTL, that is far out of reach
 * of online guessing.
 */
object PairingCode {
    const val LENGTH = 8
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private val ALPHABET_SET = ALPHABET.toSet()
    private val CONFUSABLES = mapOf('I' to '1', 'L' to '1', 'O' to '0', 'U' to 'V')
    private const val MAX_INPUT_LENGTH = 64

    /**
     * Canonicalizes user input, or null if it cannot be a valid code.
     * Strips hyphens and whitespace, uppercases, and folds confusable letters.
     */
    fun normalize(input: String): String? {
        if (input.toByteArray(Charsets.UTF_8).size > MAX_INPUT_LENGTH) return null
        val out = StringBuilder(LENGTH)
        for (raw in input.uppercase()) {
            if (raw == '-' || raw.isWhitespace()) continue
            val ch = CONFUSABLES[raw] ?: raw
            if (ch !in ALPHABET_SET) return null
            out.append(ch)
        }
        return if (out.length == LENGTH) out.toString() else null
    }

    /**
     * Renders a code grouped in fours: `K7QP-2M4X`. Presentation only.
     * The hyphen is presentation only; [normalize] strips it.
     */
    fun formatted(code: String): String {
        if (code.length != LENGTH) return code
        val mid = LENGTH / 2
        return "${code.substring(0, mid)}-${code.substring(mid)}"
    }
}
