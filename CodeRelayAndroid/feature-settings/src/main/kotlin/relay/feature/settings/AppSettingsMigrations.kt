package relay.feature.settings

/**
 * Pure (side-effect-free) ports of the two `AppSettings` migrations from
 * `AppSettings.swift`. They are factored out of [AppSettings] so the load-bearing
 * decision logic is unit-testable on the JVM without DataStore, the
 * EncryptedSharedPreferences-backed `TokenStore`, or an emulator.
 *
 * ## Android-faithfulness note
 *
 * On iOS these migrations move data written by **older app versions** (a legacy
 * `recordingShortcutModifier` String in `UserDefaults`; a legacy plaintext
 * `bedrockBearerToken` in `UserDefaults`) into the new representations. There has
 * never been a shipped Android client, so on a real device **neither legacy value
 * exists** and both migrations are no-ops today. They are ported in full anyway —
 * as the same kind of best-effort forward-migration hook the M1 `SavedConnectionStore`
 * carries — so that a future Android backup/restore or cross-platform import that
 * seeds the legacy keys migrates cleanly and identically to iOS.
 */
object AppSettingsMigrations {

    // MARK: - Shortcut-modifier migration (AppSettings.swift:31-48)

    /**
     * Legacy DataStore/prefs key that held the recording-shortcut modifier as a
     * String (`"commandShift"` / `"commandOption"` / `"commandControl"`) before it
     * became an Int flags bitmask. Matches the iOS `UserDefaults` key.
     */
    const val LEGACY_SHORTCUT_MODIFIER_KEY = "recordingShortcutModifier"

    /**
     * Maps a legacy `recordingShortcutModifier` String to the new
     * [ShortcutFlags] Int, mirroring the iOS `switch` exactly
     * (AppSettings.swift:39-44):
     *  - `"commandShift"`   → Meta + Shift
     *  - `"commandOption"`  → Meta + Alt   (Option)
     *  - `"commandControl"` → Meta + Control
     *  - anything else      → Meta + Shift (the iOS `default` branch)
     *
     * Pure — no I/O — so the mapping is unit-tested directly.
     */
    fun shortcutFlagsForLegacyModifier(legacyRaw: String): Int = when (legacyRaw) {
        "commandShift" -> ShortcutFlags.META or ShortcutFlags.SHIFT
        "commandOption" -> ShortcutFlags.META or ShortcutFlags.ALT
        "commandControl" -> ShortcutFlags.META or ShortcutFlags.CTRL
        else -> ShortcutFlags.META or ShortcutFlags.SHIFT
    }

    // MARK: - Bedrock-token migration (AppSettings.swift:77-110)

    /**
     * The decision a single migration step makes about the legacy plaintext token,
     * the secure ([TokenStore]) copy, and a post-write read-back confirmation.
     *
     * Mirrors `AppSettings.migrateBedrockToken` (AppSettings.swift:77-98), whose
     * only side-effectful dependencies are the legacy read, a secure read, a secure
     * write, and a legacy delete. By returning the decision instead of performing
     * it, the read-back-confirm logic — "only scrub the legacy copy once a re-read
     * confirms the value landed" — is exercised in tests without touching real
     * storage.
     */
    sealed interface BedrockMigrationDecision {
        /** No legacy value (or it's blank) — nothing to migrate. */
        data object NoOp : BedrockMigrationDecision

        /**
         * The secure store already holds a non-empty token, so just scrub the
         * stale legacy copy (AppSettings.swift:86-89).
         */
        data object DeleteLegacyOnly : BedrockMigrationDecision

        /**
         * Write [token] to the secure store, then re-read; scrub the legacy copy
         * **only if** the read-back confirms the write landed (AppSettings.swift:90-97).
         */
        data class WriteThenConfirm(val token: String) : BedrockMigrationDecision
    }

    /**
     * Pure decision for the Bedrock-token migration. Given the current legacy and
     * secure-store values, returns what should happen. The caller performs the
     * actual write + read-back + delete and feeds the read-back result back through
     * [shouldScrubLegacyAfterWrite].
     *
     * @param legacy the legacy plaintext token (null/blank → no-op)
     * @param secureExisting the value currently in the secure store (null/blank → none)
     */
    fun decideBedrockMigration(legacy: String?, secureExisting: String?): BedrockMigrationDecision {
        if (legacy.isNullOrEmpty()) return BedrockMigrationDecision.NoOp
        if (!secureExisting.isNullOrEmpty()) return BedrockMigrationDecision.DeleteLegacyOnly
        return BedrockMigrationDecision.WriteThenConfirm(legacy)
    }

    /**
     * Whether the legacy plaintext copy may be scrubbed after a
     * [BedrockMigrationDecision.WriteThenConfirm] write. True iff the secure-store
     * re-read returned exactly the value we wrote (AppSettings.swift:92-94). A
     * mismatch (or a failed write surfaced as a null re-read) keeps the legacy copy
     * in place so the fallback reader can still surface it.
     */
    fun shouldScrubLegacyAfterWrite(wrote: String, reread: String?): Boolean = reread == wrote

    // MARK: - Bedrock-token read with legacy fallback (AppSettings.swift:102-110)

    /**
     * Pure read helper with a legacy fallback. Returns the secure-store value when
     * non-empty, else the legacy value, else `""` (AppSettings.swift:106-109).
     * Callers treat `""` as "not configured".
     */
    fun loadBedrockTokenWithFallback(secure: String?, legacy: String?): String =
        secure?.takeIf { it.isNotEmpty() } ?: legacy ?: ""
}
