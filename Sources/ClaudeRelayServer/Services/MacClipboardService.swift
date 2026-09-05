#if canImport(AppKit)
import AppKit
import ClaudeRelayKit

public struct MacClipboardService: ClipboardService {
    public init() {}

    public func pasteImage(_ imageData: Data) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(imageData, forType: .png)
        return true
    }
}
#endif
