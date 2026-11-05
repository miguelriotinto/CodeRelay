import SwiftUI
import UIKit

/// Hosts `content` — views that carry only `.alert` modifiers — in a separate,
/// transparent window above the app, so those alerts never share a presenter
/// with the workspace's sheets.
///
/// Why: UIKit presents one view controller per presenter. When a sheet is
/// requested on a presenter while an alert on that SAME presenter is still
/// animating in (~30–300 ms window), UIKit refuses the sheet ("already
/// presenting") but SwiftUI records it as shown. From then on every sheet on
/// that presenter is refused ("only presenting a single sheet is supported")
/// until the app is killed: the sidebar button's haptic fires and nothing
/// opens. Recovery and attach failures raise alerts while the reconnect
/// loading sheet rises on its own, so the overlap happened in normal use.
/// With the alerts here, the workspace's root presents sheets only.
///
/// The window takes touches only while something is presented on it; the rest
/// of the time every touch falls through to the app. It never becomes key, so
/// the terminal keeps the keyboard.
extension View {
    func alertOverlayWindow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        background(AlertOverlayWindowHost(content: content()))
    }
}

/// Passes every touch through unless an alert is up on its root.
final class AlertOverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard rootViewController?.presentedViewController != nil else { return nil }
        return super.hitTest(point, with: event)
    }

    /// Never steal key status (and with it the keyboard) from the app window.
    override var canBecomeKey: Bool { false }
}

private struct AlertOverlayWindowHost<Content: View>: UIViewRepresentable {
    let content: Content

    func makeCoordinator() -> Coordinator { Coordinator(content: content) }

    func makeUIView(context: Context) -> SceneProbe {
        let probe = SceneProbe()
        probe.onScene = { [coordinator = context.coordinator] scene in coordinator.install(in: scene) }
        return probe
    }

    func updateUIView(_ uiView: SceneProbe, context: Context) {
        context.coordinator.host.rootView = content
    }

    static func dismantleUIView(_ uiView: SceneProbe, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor final class Coordinator {
        let host: UIHostingController<Content>
        private(set) var window: AlertOverlayWindow?

        init(content: Content) {
            host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
        }

        /// Called each time the probe lands in a window; a scene change moves
        /// the overlay with it.
        func install(in scene: UIWindowScene) {
            if window?.windowScene === scene { return }
            tearDown()
            let window = AlertOverlayWindow(windowScene: scene)
            window.windowLevel = .alert
            window.backgroundColor = .clear
            window.rootViewController = host
            window.isHidden = false
            self.window = window
        }

        func tearDown() {
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
        }
    }

    /// Zero-size view whose only job is to report the window scene it joins.
    final class SceneProbe: UIView {
        var onScene: ((UIWindowScene) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { onScene?(scene) }
        }
    }
}
