package relay.feature.settings

/**
 * Recording-shortcut modifier flags.
 *
 * Linux counterpart of the Android `ShortcutFlags`, which derives its constants
 * from `android.view.KeyEvent.META_*`. **The numeric values are reproduced
 * exactly rather than re-derived from AWT's `InputEvent` masks**, and that is
 * deliberate: `recordingShortcutFlags` is *persisted*, so a value written by one
 * client must mean the same thing when read by another. Using AWT's masks
 * (`CTRL_DOWN_MASK = 0x80`, `META_DOWN_MASK = 0x100`, …) would make a settings
 * file silently mean a different chord across platforms.
 *
 * The values below are Android's, transcribed:
 *
 * | Modifier | Constant | Value |
 * |---|---|---|
 * | Shift | `META_SHIFT_ON` | `0x00001` |
 * | Alt | `META_ALT_ON` | `0x00002` |
 * | Ctrl | `META_CTRL_ON` | `0x01000` |
 * | Meta | `META_META_ON` | `0x10000` |
 *
 * On Linux the "Meta" key is Super (the Windows/⌘ key), which is what a Hyprland
 * user's `SUPER` bindings use — the same physical key Android calls Meta and
 * iOS calls Command.
 */
object ShortcutFlags {

    /** ⇧ Shift — `android.view.KeyEvent.META_SHIFT_ON`. */
    const val SHIFT = 0x00001

    /** ⌥ Alt / Option — `META_ALT_ON`. */
    const val ALT = 0x00002

    /** ⌃ Control — `META_CTRL_ON`. */
    const val CTRL = 0x01000

    /** ⌘ Meta / Super — `META_META_ON`. The iOS `.command` analogue. */
    const val META = 0x10000

    /** Only the four modifiers we track; masks off lock/function bits. */
    const val MASK = META or ALT or SHIFT or CTRL

    /**
     * Default recording shortcut: Meta+Alt, mirroring iOS's
     * `UIKeyModifierFlags([.command, .alternate])`.
     */
    const val DEFAULT = META or ALT

    /**
     * Human-readable symbol string, e.g. `⌃⌥⇧⌘`.
     *
     * Order follows the Apple HIG — Control, Option, Shift, Command — matching
     * iOS's `symbolString` so the three clients render an identical chord.
     */
    fun symbolString(flags: Int): String = buildString {
        if (flags and CTRL != 0) append("⌃")
        if (flags and ALT != 0) append("⌥")
        if (flags and SHIFT != 0) append("⇧")
        if (flags and META != 0) append("⌘")
    }
}
