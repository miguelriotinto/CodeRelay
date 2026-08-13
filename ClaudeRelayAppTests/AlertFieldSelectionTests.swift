import XCTest
import UIKit
@testable import ClaudeRelayApp

/// Canary for the rename alert's pre-selection.
///
/// `AlertFieldSelection` rests on two assumptions about `UIAlertController` that
/// no SwiftUI API exposes: its text fields are plain `UITextField`s that post
/// `textDidBeginEditingNotification`, and `selectAll` only sticks if deferred a
/// runloop turn past that notification. These tests drive a real presented alert
/// so a UIKit change breaks here rather than silently reverting the rename
/// dialog to append-after-the-name behaviour.
@MainActor
final class AlertFieldSelectionTests: XCTestCase {

    private var window: UIWindow!

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        super.tearDown()
    }

    /// Presents an alert pre-filled with `text` and returns its text field once
    /// UIKit has made it first responder.
    private func presentPrefilledAlert(text: String) throws -> UITextField {
        let alert = UIAlertController(title: "Rename Session", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = text }

        let presented = expectation(description: "alert presented")
        window.rootViewController?.present(alert, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)

        let field = try XCTUnwrap(alert.textFields?.first)
        XCTAssertTrue(field.isFirstResponder, "UIAlertController no longer auto-focuses its first text field")
        return field
    }

    /// Runs the observer wiring that `selectAllOnBeginEditing` installs, over a
    /// field that is already editing, and returns after the deferred selection.
    private func runHandler(on field: UITextField, isActive: Bool) {
        let note = Notification(name: UITextField.textDidBeginEditingNotification, object: field)
        AlertFieldSelection.handleBeginEditing(note, isActive: isActive)

        let settled = expectation(description: "deferred selection applied")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }

    private func selectedRange(of field: UITextField) -> (start: Int, length: Int)? {
        guard let range = field.selectedTextRange else { return nil }
        return (
            field.offset(from: field.beginningOfDocument, to: range.start),
            field.offset(from: range.start, to: range.end)
        )
    }

    func testSelectsWholeNameWhenAlertIsActive() throws {
        let field = try presentPrefilledAlert(text: "Daenerys")
        runHandler(on: field, isActive: true)

        let selection = try XCTUnwrap(selectedRange(of: field))
        XCTAssertEqual(selection.start, 0)
        XCTAssertEqual(selection.length, "Daenerys".count)
    }

    /// The whole point of the selection: typing replaces rather than appends.
    func testTypingOverTheSelectionReplacesTheName() throws {
        let field = try presentPrefilledAlert(text: "Daenerys")
        runHandler(on: field, isActive: true)

        let selection = try XCTUnwrap(field.selectedTextRange)
        field.replace(selection, withText: "Drogon")

        XCTAssertEqual(field.text, "Drogon")
    }

    /// The gate is load-bearing, not defensive: the notification is app-wide, so
    /// an ungated observer would select-all in the terminal input field too.
    func testLeavesFieldAloneWhenAlertIsNotActive() throws {
        let field = try presentPrefilledAlert(text: "Daenerys")
        let caretAtEnd = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        field.selectedTextRange = caretAtEnd

        runHandler(on: field, isActive: false)

        let selection = try XCTUnwrap(selectedRange(of: field))
        XCTAssertEqual(selection.length, 0, "an inactive alert must not touch the selection")
    }

    /// Guards the cast in the handler — a non-`UITextField` sender must be a no-op
    /// rather than a crash if UIKit ever reroutes the notification.
    func testIgnoresNotificationWithoutATextField() {
        let note = Notification(name: UITextField.textDidBeginEditingNotification, object: NSObject())
        AlertFieldSelection.handleBeginEditing(note, isActive: true)
    }
}
