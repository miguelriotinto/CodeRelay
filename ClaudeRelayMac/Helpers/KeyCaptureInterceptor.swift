import AppKit
import ObjectiveC.runtime

/// Intercepts keyboard events on the live `NSApp` instance so the settings UI
/// can capture modifier+letter shortcut combinations — including combos that
/// match registered menu key equivalents (e.g. ⌘T, ⌘W).
@MainActor
final class KeyCaptureInterceptor {
    static let shared = KeyCaptureInterceptor()

    private var handler: ((NSEvent.ModifierFlags, String) -> Void)?
    private var eventMonitor: Any?

    private init() {}

    var isActive: Bool { handler != nil }

    func begin(handler: @escaping (NSEvent.ModifierFlags, String) -> Void) {
        self.handler = handler
        installMonitor()
        NSLog("[KeyCapture] begin — handler & monitor installed")
    }

    func end() {
        self.handler = nil
        removeMonitor()
        NSLog("[KeyCapture] end — handler & monitor removed")
    }

    private func installMonitor() {
        removeMonitor()
        // Local monitors fire before menu performKeyEquivalent — lets capture intercept Cmd-shortcuts
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let handler = self.handler else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
            switch event.type {
            case .keyDown:
                let pressed = event.charactersIgnoringModifiers?.lowercased() ?? ""
                NSLog("[KeyCapture] monitor keyDown key=\(pressed) mods=0x\(String(mods.rawValue, radix: 16))")
                handler(mods, pressed)
                return nil
            case .keyUp:
                return nil
            case .flagsChanged:
                NSLog("[KeyCapture] monitor flagsChanged mods=0x\(String(mods.rawValue, radix: 16))")
                handler(mods, "")
                return event
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

/// Swizzle-based interceptor that runs BEFORE local monitors. Local monitors
/// already see keyDowns before `performKeyEquivalent:` kicks in, so the swizzle
/// is a belt-and-suspenders fallback for cases (e.g. child panels) where local
/// monitors might miss events.
@objc final class KeyCaptureSwizzle: NSObject {
    @MainActor
    static func install() {
        struct Once { static var done = false }
        guard !Once.done else { return }

        guard let app = NSApp else {
            NSLog("[KeyCapture] swizzle: NSApp nil — deferring")
            DispatchQueue.main.async { install() }
            return
        }
        let cls: AnyClass = object_getClass(app) ?? type(of: app)

        let sendSel = #selector(NSApplication.sendEvent(_:))
        let crmSel = #selector(NSApplication.crm_sendEvent(_:))

        if let inherited = class_getInstanceMethod(cls, sendSel) {
            class_addMethod(cls, sendSel, method_getImplementation(inherited), method_getTypeEncoding(inherited))
        }
        if let crmImpl = class_getInstanceMethod(NSApplication.self, crmSel) {
            class_addMethod(cls, crmSel, method_getImplementation(crmImpl), method_getTypeEncoding(crmImpl))
        }

        guard let targetSend = class_getInstanceMethod(cls, sendSel),
              let targetCrm = class_getInstanceMethod(cls, crmSel) else {
            NSLog("[KeyCapture] swizzle: method lookup failed")
            return
        }
        method_exchangeImplementations(targetSend, targetCrm)
        Once.done = true
        NSLog("[KeyCapture] swizzle installed on \(cls)")
    }
}

extension NSApplication {
    @objc dynamic func crm_sendEvent(_ event: NSEvent) {
        // Just log key events for debugging — the actual capture happens via the
        // local monitor in `KeyCaptureInterceptor`.
        let type = event.type
        if Thread.isMainThread, type == .keyDown || type == .flagsChanged {
            let active = MainActor.assumeIsolated { KeyCaptureInterceptor.shared.isActive }
            if active {
                NSLog("[KeyCapture] swizzle saw event type=\(type.rawValue)")
            }
        }
        self.crm_sendEvent(event)
    }
}
