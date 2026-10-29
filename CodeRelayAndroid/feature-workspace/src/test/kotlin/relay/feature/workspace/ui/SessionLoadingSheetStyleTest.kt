package relay.feature.workspace.ui

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class SessionLoadingSheetStyleTest {
    @Test fun bytesAreTheLargestTextOnTheSheet() =
        assertTrue(
            SessionLoadingSheetStyle.BYTES_SP > SessionLoadingSheetStyle.STATUS_SP,
            "the counter is the one line that proves progress is real; it must not be a caption",
        )

    @Test fun blackoutCurvesMatchTheAppleApps() {
        assertEquals(160, SessionLoadingSheetStyle.COVER_OUT_MS)
        assertEquals(220, SessionLoadingSheetStyle.COVER_IN_MS)
    }

    @Test fun sheetWidthMatchesTheAppleApps() = assertEquals(340, SessionLoadingSheetStyle.MAX_WIDTH_DP)

    @Test fun phonesSpanTheScreenLikeTheIphoneSheet() {
        // The iPhone sheet spans the screen; only tablet-class and desktop
        // windows get the fixed 340 dp card (the iPad / Mac width).
        assertEquals(null, SessionLoadingSheetStyle.maxWidthDpFor(screenWidthDp = 412f))
        assertEquals(340, SessionLoadingSheetStyle.maxWidthDpFor(screenWidthDp = 840f))
        assertEquals(340, SessionLoadingSheetStyle.maxWidthDpFor(screenWidthDp = 600f))
    }
}
