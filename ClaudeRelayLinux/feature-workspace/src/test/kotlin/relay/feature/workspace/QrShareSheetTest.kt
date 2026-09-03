package relay.feature.workspace

import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.decoder.Decoder
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID

class QrShareSheetTest {

    private val id = UUID.fromString("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")

    @Test
    fun `encoded modules decode back to the session deep link`() {
        val link = DeepLinks.sessionUri(id)
        val modules = QrModules.encode(link)

        val matrix = BitMatrix(modules.size, modules.size)
        for (y in 0 until modules.size) for (x in 0 until modules.size) {
            if (modules[x, y]) matrix.set(x, y)
        }
        val decoded = Decoder().decode(matrix).text

        assertEquals(link, decoded)
        assertEquals(id, DeepLinks.parseSessionId(decoded))
    }

    @Test
    fun `grid is square with no quiet zone`() {
        val modules = QrModules.encode(DeepLinks.sessionUri(id))
        // Every QR version is 17 + 4n modules per side; the smallest is 21.
        assertTrue(modules.size >= 21 && (modules.size - 17) % 4 == 0, "size=${modules.size}")
        // With MARGIN=0 the finder pattern's outer ring sits on the edge.
        assertTrue(modules[0, 0] && modules[modules.size - 1, 0] && modules[0, modules.size - 1])
    }
}
