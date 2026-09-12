package relay.protocol

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull

class PairingCodeTest {
    @Test fun `normalize strips hyphen and uppercases`() {
        assertEquals("K7QP2M4X", PairingCode.normalize("k7qp-2m4x"))
    }

    @Test fun `normalize folds confusables I L O U`() {
        // I,L -> 1 ; O -> 0 ; U -> V
        // Port of Swift: "OI2345L7" -> "01234517"
        assertEquals("01234517", PairingCode.normalize("OI2345L7"))
    }

    @Test fun `normalize rejects wrong length`() {
        assertNull(PairingCode.normalize("K7QP"))
        assertNull(PairingCode.normalize("K7QP2M4X9"))
    }

    @Test fun `normalize rejects out-of-alphabet chars`() {
        assertNull(PairingCode.normalize("K7QP2M4!"))
    }

    @Test fun `normalize rejects overlong input`() {
        assertNull(PairingCode.normalize("A".repeat(65)))
    }

    @Test fun `formatted groups in fours with a hyphen`() {
        assertEquals("K7QP-2M4X", PairingCode.formatted("K7QP2M4X"))
    }
}
