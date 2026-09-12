package relay.feature.settings

import android.view.KeyEvent

/**
 * Recording-shortcut modifier flags, the Android analog of iOS
 * `UIKeyModifierFlags`. Where iOS stores `recordingShortcutFlags` as the raw
 * `UIKeyModifierFlags.rawValue` Int, Android stores the OR of the relevant
 * `KeyEvent.META_*` device-meta bits — the values a Compose `KeyEvent` reports
 * via `nativeKeyEvent.metaState` / `KeyEvent.isMetaPressed`. Keeping the four
 * modifiers behind these named masks means the migration mapping, the capture
 * control, and the display formatter can't drift apart.
 *
 * On Android keyboards the "Command/GUI" key is the **Meta** key (Search/⌘ on
 * Chromebooks, the Windows/super key on external keyboards), so the iOS
 * `.command` maps to [META] and `.alternate` (Option) maps to [ALT].
 */
object ShortcutFlags {
    /** ⌘ / Meta (Search) — the iOS `.command` analog. */
    const val META = KeyEvent.META_META_ON

    /** ⌥ / Alt (Option) — the iOS `.alternate` analog. */
    const val ALT = KeyEvent.META_ALT_ON

    /** ⇧ / Shift. */
    const val SHIFT = KeyEvent.META_SHIFT_ON

    /** ⌃ / Control. */
    const val CTRL = KeyEvent.META_CTRL_ON

    /** Only the four modifiers we track; masks off lock/function/etc. */
    const val MASK = META or ALT or SHIFT or CTRL

    /**
     * Default recording-shortcut flags. Mirrors the iOS default
     * `UIKeyModifierFlags([.command, .alternate])` (AppSettings.swift:139) →
     * Meta + Alt.
     */
    const val DEFAULT = META or ALT

    /**
     * Human-readable symbol string, e.g. "⌃⌥⇧⌘". Order follows Apple HIG:
     * Control, Option, Shift, Command — matching `UIKeyModifierFlags.symbolString`
     * (AppSettings.swift:163-170) so the display string is identical to iOS.
     */
    fun symbolString(flags: Int): String = buildString {
        if (flags and CTRL != 0) append("⌃")
        if (flags and ALT != 0) append("⌥")
        if (flags and SHIFT != 0) append("⇧")
        if (flags and META != 0) append("⌘")
    }
}
