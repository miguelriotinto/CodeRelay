import SwiftUI
import UIKit

/// A transparent UIView that captures hardware keyboard presses and reports
/// modifier flags + character key in real time via bindings.
/// Becomes first responder when `isCapturing` is true.
struct KeyCaptureView: UIViewRepresentable {
    @Binding var capturedFlags: UIKeyModifierFlags
    @Binding var capturedKey: String
    @Binding var isCapturing: Bool
    var onCommit: (UIKeyModifierFlags, String) -> Void

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: KeyCaptureUIView, context: Context) {
        if isCapturing && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isCapturing && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, KeyCaptureDelegate {
        let parent: KeyCaptureView
        private var lastFlags: UIKeyModifierFlags = []
        private var lastKey: String = ""

        init(_ parent: KeyCaptureView) {
            self.parent = parent
        }

        func keysChanged(flags: UIKeyModifierFlags, key: String) {
            lastFlags = flags
            lastKey = key
            parent.capturedFlags = flags
            parent.capturedKey = key
        }

        func allKeysReleased() {
            // Only commit if at least one modifier was held
            guard !lastFlags.isEmpty else {
                parent.isCapturing = false
                return
            }
            parent.onCommit(lastFlags, lastKey)
            parent.isCapturing = false
        }
    }
}

// MARK: - Delegate Protocol

protocol KeyCaptureDelegate: AnyObject {
    func keysChanged(flags: UIKeyModifierFlags, key: String)
    func allKeysReleased()
}

// MARK: - UIView Subclass

final class KeyCaptureUIView: UIView {
    weak var delegate: KeyCaptureDelegate?

    private var heldModifiers: UIKeyModifierFlags = []
    private var heldKey: String = ""

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let uiKey = press.key else { continue }
            let mod = uiKey.modifierFlags.intersection([.command, .alternate, .shift, .control])
            if !mod.isEmpty {
                heldModifiers.formUnion(mod)
                handled = true
            }
            let chars = uiKey.charactersIgnoringModifiers
            if !chars.isEmpty, !isModifierOnlyKey(uiKey) {
                heldKey = chars.lowercased()
                handled = true
            }
        }
        if handled {
            delegate?.keysChanged(flags: heldModifiers, key: heldKey)
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var anyEnded = false
        for press in presses {
            guard let uiKey = press.key else { continue }
            let mod = uiKey.modifierFlags.intersection([.command, .alternate, .shift, .control])
            if !mod.isEmpty {
                anyEnded = true
            }
            if !isModifierOnlyKey(uiKey) {
                heldKey = ""
                anyEnded = true
            }
        }
        if anyEnded {
            // Check remaining modifiers from the event
            let remaining = event?.modifierFlags.intersection([.command, .alternate, .shift, .control]) ?? []
            heldModifiers = remaining
            if remaining.isEmpty && heldKey.isEmpty {
                delegate?.allKeysReleased()
                heldModifiers = []
                heldKey = ""
            } else {
                delegate?.keysChanged(flags: heldModifiers, key: heldKey)
            }
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        heldModifiers = []
        heldKey = ""
        delegate?.allKeysReleased()
    }

    /// Returns true if the press is a modifier-only key (no character output).
    private func isModifierOnlyKey(_ key: UIKey) -> Bool {
        switch key.keyCode {
        case .keyboardLeftShift, .keyboardRightShift,
             .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftAlt, .keyboardRightAlt,
             .keyboardLeftGUI, .keyboardRightGUI:
            return true
        default:
            return false
        }
    }
}
