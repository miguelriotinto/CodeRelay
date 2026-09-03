package relay.terminal.linux

/**
 * `VTermKey` and `VTermModifier` values, transcribed from `vterm_keycodes.h`
 * (libvterm 0.3.3).
 *
 * These cross the JNI boundary as plain ints, so they must match libvterm's
 * enum exactly. Note the enum is **not** contiguous: `FUNCTION_0` jumps to 256,
 * and the keypad block continues from there — so `KP_0` is 512, not 16. Deriving
 * these by counting declaration order would silently produce wrong keys.
 *
 * Letting libvterm encode the key is the point: it knows the terminal's current
 * modes (DECCKM application-cursor keys, keypad mode, bracketed paste) and emits
 * the sequence appropriate to the mode the running program actually set. A
 * hand-rolled table cannot — which is exactly how the iOS client ended up
 * sending arrow keys that recalled shell history instead of scrolling.
 */
object VTermMod {
    const val NONE = 0x00
    const val SHIFT = 0x01
    const val ALT = 0x02
    const val CTRL = 0x04
}

object VTermKey {
    const val NONE = 0

    const val ENTER = 1
    const val TAB = 2
    const val BACKSPACE = 3
    const val ESCAPE = 4

    const val UP = 5
    const val DOWN = 6
    const val LEFT = 7
    const val RIGHT = 8

    const val INS = 9
    const val DEL = 10
    const val HOME = 11
    const val END = 12
    const val PAGEUP = 13
    const val PAGEDOWN = 14

    /** `VTERM_KEY_FUNCTION_0 = 256`; F1 is `FUNCTION_0 + 1`. */
    const val FUNCTION_0 = 256

    /** F-key by number: `function(1)` is F1. */
    fun function(n: Int): Int = FUNCTION_0 + n

    // The keypad block follows FUNCTION_MAX (= FUNCTION_0 + 255 = 511), so it
    // starts at 512 rather than continuing from PAGEDOWN.
    const val KP_0 = 512
    const val KP_1 = 513
    const val KP_2 = 514
    const val KP_3 = 515
    const val KP_4 = 516
    const val KP_5 = 517
    const val KP_6 = 518
    const val KP_7 = 519
    const val KP_8 = 520
    const val KP_9 = 521
    const val KP_MULT = 522
    const val KP_PLUS = 523
    const val KP_COMMA = 524
    const val KP_MINUS = 525
    const val KP_PERIOD = 526
    const val KP_DIVIDE = 527
    const val KP_ENTER = 528
    const val KP_EQUAL = 529
}
