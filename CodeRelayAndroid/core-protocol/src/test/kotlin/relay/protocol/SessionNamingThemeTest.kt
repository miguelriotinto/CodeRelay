package relay.protocol

import kotlinx.serialization.encodeToString
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class SessionNamingThemeTest {

    @Test fun `raw values are the expected camelCase strings`() {
        assertEquals("gameOfThrones", SessionNamingTheme.GAME_OF_THRONES.rawValue)
        assertEquals("viking", SessionNamingTheme.VIKING.rawValue)
        assertEquals("starWars", SessionNamingTheme.STAR_WARS.rawValue)
        assertEquals("dune", SessionNamingTheme.DUNE.rawValue)
        assertEquals("lordOfTheRings", SessionNamingTheme.LORD_OF_THE_RINGS.rawValue)
        assertEquals("starTrek", SessionNamingTheme.STAR_TREK.rawValue)
    }

    @Test fun `default theme is game of thrones`() {
        assertEquals(SessionNamingTheme.GAME_OF_THRONES, SessionNamingTheme.DEFAULT)
    }

    @Test fun `fromRaw resolves known and falls back on unknown`() {
        assertEquals(SessionNamingTheme.STAR_WARS, SessionNamingTheme.fromRaw("starWars"))
        assertEquals(SessionNamingTheme.DEFAULT, SessionNamingTheme.fromRaw("nonsense"))
    }

    @Test fun `every theme has a non-empty name pool`() {
        for (theme in SessionNamingTheme.entries) {
            assertTrue(theme.names.isNotEmpty(), "${theme.name} pool must be non-empty")
        }
    }

    @Test fun `serialization round-trips the camelCase raw`() {
        // Encoding a case must produce its camelCase raw (e.g. STAR_WARS -> "starWars").
        val encoded = WireJson.instance.encodeToString(SessionNamingTheme.STAR_WARS)
        assertEquals("\"starWars\"", encoded)

        val decoded = WireJson.instance.decodeFromString<SessionNamingTheme>("\"starWars\"")
        assertEquals(SessionNamingTheme.STAR_WARS, decoded)

        // Full round-trip across all cases.
        for (theme in SessionNamingTheme.entries) {
            val json = WireJson.instance.encodeToString(theme)
            assertEquals("\"${theme.rawValue}\"", json)
            assertEquals(theme, WireJson.instance.decodeFromString<SessionNamingTheme>(json))
        }
    }
}
