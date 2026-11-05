import XCTest
import SwiftUI
import UIKit
import CodeRelayClient
@testable import CodeRelayApp

/// The dead sidebar button on iPhone Duo: a sheet requested on a presenter
/// while an alert on that same presenter was still animating in left the
/// presenter refusing every later sheet. Alerts now live in
/// `AlertOverlayWindow`, so the app's root presents sheets only. These drive
/// real presentations in a window and read UIKit's presented chain.
@MainActor
final class AlertOverlayWindowTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var sidebar = false
        @Published var other = false
        @Published var plainAlert = false
        @Published var lossAlert: SessionLossAlert?
    }

    /// WorkspaceView's shape: sheets on the root, alerts in the overlay.
    struct Root: View {
        @ObservedObject var m: Model
        var body: some View {
            Group { Color.black.sheet(isPresented: $m.sidebar) { Text("sidebar") } }
                .sheet(isPresented: $m.other) { Text("loading") }
                .alertOverlayWindow { Alerts(m: m) }
        }
    }

    struct Alerts: View {
        @ObservedObject var m: Model
        var body: some View {
            Color.clear
                .alert("Connection Lost", isPresented: $m.plainAlert) { Button("OK", role: .cancel) {} }
                .sessionLossAlert(m.lossAlert, isTopmost: true, onOK: { m.lossAlert = nil })
        }
    }

    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    private var scene: UIWindowScene {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
    }

    private func host(_ m: Model) async {
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Root(m: m))
        window.makeKeyAndVisible()
        self.window = window
        await pause(1)
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func presented(on root: UIViewController?) -> [UIViewController] {
        var out: [UIViewController] = []
        var vc = root?.presentedViewController
        while let current = vc { out.append(current); vc = current.presentedViewController }
        return out
    }

    private var overlay: AlertOverlayWindow? {
        // The test host's own WorkspaceView has an overlay too; pick ours.
        scene.windows.compactMap { $0 as? AlertOverlayWindow }
            .first { !$0.isHidden && $0.rootViewController is UIHostingController<Alerts> }
    }

    /// The race that wedged the root: an alert starts presenting, a sheet is
    /// requested inside its animation, both go away, then the sidebar is
    /// tapped. Every one of these delays wedged with alerts on the root.
    func testSheetRequestedWhileAlertAnimatesInLeavesSheetsWorking() async {
        for (plain, delayMs) in [(true, 30), (true, 150), (false, 100), (false, 300)] {
            let m = Model()
            await host(m)
            if plain { m.plainAlert = true } else { m.lossAlert = SessionLossAlert(title: "t", message: "m") }
            try? await Task.sleep(for: .milliseconds(delayMs))
            m.other = true
            await pause(1.5)
            XCTAssertEqual(presented(on: window?.rootViewController).count, 1,
                           "the loading sheet presents under the alert (plain=\(plain), \(delayMs) ms)")
            m.plainAlert = false
            m.lossAlert = nil
            await pause(1)
            m.other = false
            await pause(1.5)
            XCTAssertTrue(presented(on: window?.rootViewController).isEmpty)
            m.sidebar = true
            await pause(1.5)
            XCTAssertEqual(presented(on: window?.rootViewController).count, 1,
                           "the sidebar must still open (plain=\(plain), \(delayMs) ms)")
            window?.isHidden = true
            window = nil
            await pause(0.3)
        }
    }

    /// The alert really is in the overlay, over an open sheet, and the overlay
    /// takes touches only while it is up.
    func testAlertPresentsInOverlayAndTouchesPassThroughOtherwise() async throws {
        let m = Model()
        await host(m)
        let overlay = try XCTUnwrap(overlay)
        XCTAssertEqual(overlay.windowLevel, .alert)
        XCTAssertFalse(overlay.isKeyWindow)
        let center = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        XCTAssertNil(overlay.hitTest(center, with: nil), "no alert: touches reach the app")

        m.sidebar = true
        await pause(1.2)
        m.lossAlert = SessionLossAlert(title: "Session taken", message: "m")
        await pause(1.2)
        XCTAssertEqual(presented(on: overlay.rootViewController).count, 1, "alert shows over the open sheet")
        XCTAssertEqual(presented(on: window?.rootViewController).count, 1, "the sheet stays up beneath it")
        XCTAssertNotNil(overlay.hitTest(center, with: nil), "alert up: the overlay is modal")
        XCTAssertTrue(window?.isKeyWindow ?? false, "the app window keeps key status")

        m.lossAlert = nil
        await pause(1.2)
        XCTAssertTrue(presented(on: overlay.rootViewController).isEmpty)
        XCTAssertNil(overlay.hitTest(center, with: nil))
    }

    /// Removing the host view tears the overlay window down.
    func testOverlayWindowGoesAwayWithItsHost() async {
        let m = Model()
        await host(m)
        XCTAssertNotNil(overlay)
        window?.rootViewController = UIViewController()
        await pause(0.5)
        XCTAssertNil(overlay)
    }
}
