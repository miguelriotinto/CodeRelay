package relay.speech

/**
 * Result of running a raw transcript through [relay.speech.cleanup.SpeechPostProcessor].
 *
 * Callers use [deliverableText] to get the string to send to the terminal,
 * treating `null` as "emit nothing".
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/ProcessedText.swift` — a sealed
 * type, NOT a bare String, so refusals/empties are distinguishable from real
 * output.
 */
sealed interface ProcessedText {
    data class Passthrough(val text: String) : ProcessedText
    data class Cleaned(val text: String) : ProcessedText
    data class Enhanced(val text: String) : ProcessedText
    data class Refused(val original: String) : ProcessedText
    data object Empty : ProcessedText

    /** The string to deliver to the terminal, or `null` to emit nothing. */
    val deliverableText: String?
        get() = when (this) {
            is Passthrough -> text
            is Cleaned -> text
            is Enhanced -> text
            is Refused -> original
            Empty -> null
        }
}
