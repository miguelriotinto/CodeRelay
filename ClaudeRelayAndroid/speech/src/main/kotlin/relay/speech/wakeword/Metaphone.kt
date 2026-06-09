package relay.speech.wakeword

/**
 * English Metaphone phonetic encoding (Lawrence Philips, 1990).
 *
 * Faithful port of the `metaphone` / `MetaphoneContext` logic embedded in
 * `Sources/ClaudeRelaySpeech/WakeWordDetector.swift`. Returns a short string
 * representing how a word sounds. Words that sound alike produce the same code
 * ("claude", "cloud", "clod" -> "KLT"). Hand-rolled (not a library) to match
 * the Swift source's output byte-for-byte for the wake-word cases.
 */
object Metaphone {

    private val VOWELS = setOf('a', 'e', 'i', 'o', 'u')

    fun encode(word: String): String {
        val ctx = Context(word)
        if (ctx.chars.isEmpty()) return ""

        val out = StringBuilder()
        var idx = ctx.skipLeadingSilent(out)

        while (idx < ctx.count) {
            val ch = ctx.chars[idx]
            // Skip duplicate consecutive letters, except 'c'.
            if (ch == ctx.get(idx - 1) && ch != 'c') {
                idx += 1
                continue
            }
            ctx.emit(ch, idx, out)
            idx += 1
        }
        return out.toString()
    }

    private class Context(word: String) {
        // Filter to ASCII letters, lowercased.
        val chars: CharArray = buildList {
            for (c in word) {
                when {
                    c in 'a'..'z' -> add(c)
                    c in 'A'..'Z' -> add(c + 32)
                }
            }
        }.toCharArray()

        val count: Int = chars.size

        fun get(idx: Int): Char? = if (idx in 0 until count) chars[idx] else null

        fun isVowel(code: Char?): Boolean = code != null && code in VOWELS

        fun skipLeadingSilent(out: StringBuilder): Int {
            if (count < 2) return 0
            val c0 = chars[0]
            val c1 = chars[1]
            val silentPairs = listOf(
                'k' to 'n', 'g' to 'n', 'p' to 'n',
                'a' to 'e', 'w' to 'r',
            )
            if (silentPairs.any { it.first == c0 && it.second == c1 }) return 1
            if (c0 == 'x') {
                out.append('S')
                return 1
            }
            return 0
        }

        @Suppress("CyclomaticComplexMethod")
        fun emit(ch: Char, idx: Int, out: StringBuilder) {
            val prev = get(idx - 1)
            val next = get(idx + 1)
            val nextNext = get(idx + 2)

            when (ch) {
                'a', 'e', 'i', 'o', 'u' ->
                    if (idx == 0) out.append(ch.uppercaseChar())
                'b' ->
                    if (!(idx == count - 1 && prev == 'm')) out.append('B')
                'c' -> emitC(next, nextNext, out)
                'd' -> emitD(next, nextNext, out)
                'f' -> out.append('F')
                'g' -> emitG(prev, next, idx, out)
                'h' -> emitH(prev, next, out)
                'j' -> out.append('J')
                'k' -> if (prev != 'c') out.append('K')
                'l' -> out.append('L')
                'm' -> out.append('M')
                'n' -> out.append('N')
                'p' -> out.append(if (next == 'h') 'F' else 'P')
                'q' -> out.append('K')
                'r' -> out.append('R')
                's' -> emitS(next, nextNext, out)
                't' -> emitT(next, nextNext, out)
                'v' -> out.append('F')
                'w' -> if (isVowel(next) && !isVowel(prev)) out.append('W')
                'x' -> out.append("KS")
                'y' -> if (isVowel(next)) out.append('Y')
                'z' -> out.append('S')
                else -> Unit
            }
        }

        private fun emitC(next: Char?, nextNext: Char?, out: StringBuilder) {
            when {
                next == 'i' && nextNext == 'a' -> out.append('X')
                next == 'h' -> out.append('X')
                next == 'i' || next == 'e' || next == 'y' -> out.append('S')
                else -> out.append('K')
            }
        }

        private fun emitD(next: Char?, nextNext: Char?, out: StringBuilder) {
            if (next == 'g' && (nextNext == 'e' || nextNext == 'i' || nextNext == 'y')) {
                out.append('J')
            } else {
                out.append('T')
            }
        }

        private fun emitG(prev: Char?, next: Char?, idx: Int, out: StringBuilder) {
            when {
                next == 'h' -> if (!(isVowel(prev) && idx > 0)) out.append('F')
                next == 'n' -> if (idx != count - 2) out.append('K')
                next == 'e' || next == 'i' || next == 'y' -> out.append('J')
                else -> out.append('K')
            }
        }

        private fun emitH(prev: Char?, next: Char?, out: StringBuilder) {
            if (isVowel(prev) && !isVowel(next)) return
            val silentAfter = setOf('c', 's', 'p', 't', 'g')
            if (prev != null && prev in silentAfter) return
            out.append('H')
        }

        private fun emitS(next: Char?, nextNext: Char?, out: StringBuilder) {
            when {
                next == 'h' -> out.append('X')
                next == 'i' && (nextNext == 'a' || nextNext == 'o') -> out.append('X')
                else -> out.append('S')
            }
        }

        private fun emitT(next: Char?, nextNext: Char?, out: StringBuilder) {
            when {
                next == 'h' -> out.append('0')
                next == 'i' && (nextNext == 'a' || nextNext == 'o') -> out.append('X')
                next == 'c' && nextNext == 'h' -> return
                else -> out.append('T')
            }
        }
    }
}
