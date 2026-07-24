import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Cross-platform write to the device's system clipboard (F11 terminal-copy →
/// device). iOS uses `UIPasteboard`, macOS `NSPasteboard`. A thin seam so the
/// coordinator stays UIKit/AppKit-free and the behavior is swappable in tests.
public enum DeviceClipboard {
    /// Set the system clipboard to `text`. No-op on platforms without a
    /// pasteboard (keeps the shared coordinator compiling everywhere).
    public static func setString(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}
