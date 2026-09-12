import Foundation

/// Abstraction for clipboard image pasting — allows server (AppKit) and tests to provide different implementations.
public protocol ClipboardService: Sendable {
    func pasteImage(_ imageData: Data) -> Bool
}
