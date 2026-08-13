package relay.feature.workspace

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * Blank-name gating for the two rename dialogs.
 *
 * The dialogs themselves are DEVICE-DEFERRED (Compose UI), so the testable seam
 * is the pure [sanitizedSessionName] function that drives both the `Rename`
 * button's enabled state and what it stores. A whitespace-only entry must read as
 * blank, not as a name made of spaces — that is the case the enabled state and
 * the store would otherwise disagree on.
 */
class SessionNameTest {

    @Test
    fun `a plain name passes through unchanged`() {
        assertEquals("Daenerys", sanitizedSessionName("Daenerys"))
    }

    @Test
    fun `surrounding whitespace is trimmed, matching iOS`() {
        assertEquals("Daenerys", sanitizedSessionName("  Daenerys  "))
    }

    @Test
    fun `interior spaces survive`() {
        assertEquals("Singular RUST", sanitizedSessionName("  Singular RUST "))
    }

    @Test
    fun `an empty entry is not a name`() {
        assertNull(sanitizedSessionName(""))
    }

    @Test
    fun `a whitespace-only entry is not a name`() {
        assertNull(sanitizedSessionName("   "))
        assertNull(sanitizedSessionName("\t"))
    }
}
