import SwiftTerm

enum TerminalPalette {
    private static func color(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> Color {
        Color(red: red * 257, green: green * 257, blue: blue * 257)
    }

    static let colors: [Color] = [
        color(0x00, 0x00, 0x00), // black
        color(0xCC, 0x00, 0x00), // red
        color(0x00, 0xCC, 0x00), // green
        color(0xCC, 0xCC, 0x00), // yellow
        color(0x00, 0x00, 0xCC), // blue
        color(0xCC, 0x00, 0xCC), // magenta
        color(0x00, 0xCC, 0xCC), // cyan
        color(0xE5, 0xE5, 0xE5), // white
        color(0x7F, 0x7F, 0x7F), // bright black
        color(0xFF, 0x00, 0x00), // bright red
        color(0x00, 0xFF, 0x00), // bright green
        color(0xFF, 0xFF, 0x00), // bright yellow
        color(0x5C, 0x5C, 0xFF), // bright blue
        color(0xFF, 0x00, 0xFF), // bright magenta
        color(0x00, 0xFF, 0xFF), // bright cyan
        color(0xFF, 0xFF, 0xFF)  // bright white
    ]
}
