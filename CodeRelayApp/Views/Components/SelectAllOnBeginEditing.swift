import SwiftUI
import UIKit

/// The begin-editing handler behind ``SwiftUI/View/selectAllOnBeginEditing(while:)``.
///
/// Factored out of the `ViewModifier` so a test can drive it against a real
/// `UIAlertController` text field — the async hop and the `UITextField` cast are
/// the only load-bearing parts, and neither is observable through SwiftUI.
enum AlertFieldSelection {
    /// Selects the whole field so the first keystroke replaces the pre-filled
    /// value instead of appending to it.
    ///
    /// - Parameters:
    ///   - note: a `UITextField.textDidBeginEditingNotification`.
    ///   - isActive: whether the owning alert is presented. See the modifier for
    ///     why this gate is required rather than merely defensive.
    static func handleBeginEditing(_ note: Notification, isActive: Bool) {
        guard isActive, let field = note.object as? UITextField else { return }
        // Deferred by one runloop turn: assigning `text` parks the caret at the
        // end, and selecting while UIKit is still installing the field as first
        // responder gets overwritten by that.
        DispatchQueue.main.async { field.selectAll(nil) }
    }
}

/// Selects the entire contents of an alert's `TextField` as soon as it starts
/// editing, so the first keystroke replaces the pre-filled value.
///
/// SwiftUI's `.alert` `TextField` exposes no selection API — the alert is a
/// `UIAlertController` underneath, so the only seam is UIKit's begin-editing
/// notification, which is app-wide. `isActive` narrows it to the window where
/// the alert is the only thing that *can* be editing; without that gate this
/// would select-all in every text field in the app, terminal input included.
private struct SelectAllOnBeginEditing: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
        ) { note in
            AlertFieldSelection.handleBeginEditing(note, isActive: isActive)
        }
    }
}

extension View {
    /// Pre-selects the text of the alert text field presented by this view.
    ///
    /// - Parameter isActive: the same flag driving the alert's `isPresented`,
    ///   so the observer only fires for that alert's field.
    func selectAllOnBeginEditing(while isActive: Bool) -> some View {
        modifier(SelectAllOnBeginEditing(isActive: isActive))
    }
}
