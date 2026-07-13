import AppKit

/// Posts `.toggleSpeechRecording` when the user's configured shortcut is pressed.
///
/// Uses a local `NSEvent.addLocalMonitorForEvents` monitor, which fires BEFORE
/// `performKeyEquivalent:` dispatches menu shortcuts. That means the configured
/// shortcut can use any modifier+letter combo, including ones that collide with
/// menu commands — our monitor sees and consumes them first.
///
/// The monitor is paused whenever `KeyCaptureInterceptor` is mid-capture (so the
/// user's key presses during "Change" flow don't accidentally trigger recording).
@MainActor
final class RecordingShortcutMonitor {
    static let shared = RecordingShortcutMonitor()

    private var monitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        NSLog("[RecordingShortcut] monitor installed")
    }

    func stop() {
        if let current = monitor {
            NSEvent.removeMonitor(current)
            monitor = nil
            NSLog("[RecordingShortcut] monitor removed")
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Skip while KeyCapture is active to avoid triggering during 'Change shortcut' flow
        if KeyCaptureInterceptor.shared.isActive { return event }

        let settings = AppSettings.shared
        guard settings.recordingShortcutEnabled else { return event }

        let savedKey = settings.recordingShortcutKey.lowercased()
        guard !savedKey.isEmpty else { return event }

        let savedMods = settings.shortcutModifierFlags.intersection([.command, .option, .shift, .control])
        let eventMods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let eventKey = event.charactersIgnoringModifiers?.lowercased() ?? ""

        guard eventKey == savedKey, eventMods == savedMods else { return event }

        NSLog("[RecordingShortcut] matched — posting toggleSpeechRecording")
        NotificationCenter.default.post(name: .toggleSpeechRecording, object: nil)
        return nil // consume
    }
}

extension Notification.Name {
    static let toggleSpeechRecording = Notification.Name("toggleSpeechRecording")
    static let showServerList = Notification.Name("com.clauderelay.mac.showServerList")
}
