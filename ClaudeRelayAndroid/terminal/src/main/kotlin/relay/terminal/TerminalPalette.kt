package relay.terminal

/**
 * The 16-color ANSI palette for the terminal engine, ported VALUE-for-VALUE
 * from `ClaudeRelayApp/Views/Components/TerminalPalette.swift`.
 *
 * Colors are packed ARGB ints (`0xAARRGGBB`) so they can be installed directly
 * into the engine's color table later. The 8-bit component values match the
 * Swift source exactly (iOS scales each by 257 to fill SwiftTerm's 16-bit
 * channels; here we keep the canonical 8-bit values). All entries are fully
 * opaque (`0xFF` alpha).
 *
 * Index layout (xterm order): 0–7 are the basic colors, 8–15 the bright set.
 */
object TerminalPalette {

    /** Packs 8-bit RGB components into an opaque ARGB int (`0xFFRRGGBB`). */
    private fun rgb(red: Int, green: Int, blue: Int): Int =
        (0xFF shl 24) or (red shl 16) or (green shl 8) or blue

    /** 16-color ANSI palette: 8 basic (0–7) then 8 bright (8–15). */
    val colors: IntArray = intArrayOf(
        rgb(0x00, 0x00, 0x00), // 0  black
        rgb(0xCC, 0x00, 0x00), // 1  red
        rgb(0x00, 0xCC, 0x00), // 2  green
        rgb(0xCC, 0xCC, 0x00), // 3  yellow
        rgb(0x00, 0x00, 0xCC), // 4  blue
        rgb(0xCC, 0x00, 0xCC), // 5  magenta
        rgb(0x00, 0xCC, 0xCC), // 6  cyan
        rgb(0xE5, 0xE5, 0xE5), // 7  white
        rgb(0x7F, 0x7F, 0x7F), // 8  bright black
        rgb(0xFF, 0x00, 0x00), // 9  bright red
        rgb(0x00, 0xFF, 0x00), // 10 bright green
        rgb(0xFF, 0xFF, 0x00), // 11 bright yellow
        rgb(0x5C, 0x5C, 0xFF), // 12 bright blue
        rgb(0xFF, 0x00, 0xFF), // 13 bright magenta
        rgb(0x00, 0xFF, 0xFF), // 14 bright cyan
        rgb(0xFF, 0xFF, 0xFF)  // 15 bright white
    )

    /**
     * Default terminal background — black. iOS sets this via
     * `RelayTerminalView.nativeBackgroundColor = .black`.
     */
    val background: Int = rgb(0x00, 0x00, 0x00)

    /**
     * Default terminal foreground — white. iOS sets this via
     * `RelayTerminalView.nativeForegroundColor = .white`.
     */
    val foreground: Int = rgb(0xFF, 0xFF, 0xFF)
}
