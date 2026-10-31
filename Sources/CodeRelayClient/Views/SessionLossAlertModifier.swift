#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// The hub's one session-loss alert. A presenter that already has a sheet up
    /// cannot present an alert over it, so the alert is attached to the root AND
    /// to each sheet's content; the caller enables only the topmost copy, so it
    /// appears promptly over an open sheet and exactly once.
    ///
    /// - Parameter onOK: the hub's `dismissTakenAlert()`, which also forgets
    ///   the announced sessions so the next batch starts a fresh alert.
    public func sessionLossAlert(_ alert: SessionLossAlert?, isTopmost: Bool,
                                 onOK: @escaping @MainActor () -> Void) -> some View {
        self.alert(
            alert?.title ?? "",
            isPresented: Binding(get: { isTopmost && alert != nil },
                                 set: { _ in }),   // only OK clears it: a copy being torn down must not lose an unread alert
            presenting: alert
        ) { _ in
            Button("OK", role: .cancel) { onOK() }
        } message: { item in
            Text(item.message)
        }
    }
}
#endif
