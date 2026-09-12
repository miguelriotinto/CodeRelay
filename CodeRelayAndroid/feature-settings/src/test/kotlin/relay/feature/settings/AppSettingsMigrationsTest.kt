package relay.feature.settings

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Pure-JVM tests for the two `AppSettings` migration decisions ported from
 * `AppSettings.swift`. The DataStore round-trip + secure-store I/O are
 * instrumented/device tests (DEFERRED — no emulator); the load-bearing logic here
 * is exercised headless.
 */
class AppSettingsMigrationsTest {

    // MARK: - Shortcut-modifier mapping (AppSettings.swift:39-44)

    @Test
    fun `commandShift maps to Meta plus Shift`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.SHIFT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("commandShift"),
        )
    }

    @Test
    fun `commandOption maps to Meta plus Alt`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.ALT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("commandOption"),
        )
    }

    @Test
    fun `commandControl maps to Meta plus Ctrl`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.CTRL,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("commandControl"),
        )
    }

    @Test
    fun `unknown legacy modifier falls back to Meta plus Shift (iOS default branch)`() {
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.SHIFT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier("somethingElse"),
        )
        assertEquals(
            ShortcutFlags.META or ShortcutFlags.SHIFT,
            AppSettingsMigrations.shortcutFlagsForLegacyModifier(""),
        )
    }

    // MARK: - Bedrock-migration decision (AppSettings.swift:82-97)

    @Test
    fun `no legacy value is a no-op`() {
        assertInstanceOf(
            AppSettingsMigrations.BedrockMigrationDecision.NoOp::class.java,
            AppSettingsMigrations.decideBedrockMigration(legacy = null, secureExisting = null),
        )
        assertInstanceOf(
            AppSettingsMigrations.BedrockMigrationDecision.NoOp::class.java,
            AppSettingsMigrations.decideBedrockMigration(legacy = "", secureExisting = "secure"),
        )
    }

    @Test
    fun `legacy present but secure already set just scrubs the legacy copy`() {
        assertInstanceOf(
            AppSettingsMigrations.BedrockMigrationDecision.DeleteLegacyOnly::class.java,
            AppSettingsMigrations.decideBedrockMigration(legacy = "legacy", secureExisting = "already-there"),
        )
    }

    @Test
    fun `legacy present and secure empty writes then confirms`() {
        val decision = AppSettingsMigrations.decideBedrockMigration(legacy = "tok-123", secureExisting = null)
        assertInstanceOf(AppSettingsMigrations.BedrockMigrationDecision.WriteThenConfirm::class.java, decision)
        assertEquals("tok-123", (decision as AppSettingsMigrations.BedrockMigrationDecision.WriteThenConfirm).token)
    }

    // MARK: - Read-back confirmation (AppSettings.swift:92-94)

    @Test
    fun `scrub only when read-back matches the written value`() {
        assertTrue(AppSettingsMigrations.shouldScrubLegacyAfterWrite(wrote = "tok", reread = "tok"))
        assertFalse(AppSettingsMigrations.shouldScrubLegacyAfterWrite(wrote = "tok", reread = "different"))
        // A failed write surfaced as a null re-read must NOT scrub the legacy copy.
        assertFalse(AppSettingsMigrations.shouldScrubLegacyAfterWrite(wrote = "tok", reread = null))
    }

    // MARK: - Read with legacy fallback (AppSettings.swift:106-109)

    @Test
    fun `secure value wins when non-empty`() {
        assertEquals("secure", AppSettingsMigrations.loadBedrockTokenWithFallback(secure = "secure", legacy = "legacy"))
    }

    @Test
    fun `falls back to legacy when secure is empty or null`() {
        assertEquals("legacy", AppSettingsMigrations.loadBedrockTokenWithFallback(secure = "", legacy = "legacy"))
        assertEquals("legacy", AppSettingsMigrations.loadBedrockTokenWithFallback(secure = null, legacy = "legacy"))
    }

    @Test
    fun `empty string when neither is set (treated as not configured)`() {
        assertEquals("", AppSettingsMigrations.loadBedrockTokenWithFallback(secure = null, legacy = null))
        assertEquals("", AppSettingsMigrations.loadBedrockTokenWithFallback(secure = "", legacy = null))
    }
}
