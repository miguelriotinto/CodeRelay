import ClaudeRelayKit

/// The host clipboard implementation for the platform the server is built on.
///
/// `WebSocketServer`'s default `clipboardService` used to name
/// `MacClipboardService` directly; this is the one place that choice is made
/// now, so the server and `main.swift` stay platform-neutral.
public enum DefaultClipboardService {
    public static func make() -> ClipboardService {
        #if canImport(AppKit)
        return MacClipboardService()
        #elseif os(Linux)
        return LinuxClipboardService()
        #else
        #error("No ClipboardService for this platform")
        #endif
    }
}
