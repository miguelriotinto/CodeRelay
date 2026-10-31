#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// The hub's one session-loss alert. A presenter that already has a sheet up
    /// cannot present an alert over it, so the alert is attached to the root AND
    /// to each sheet's content; the caller enables only the topmost copy, so it
    /// appears promptly over an open sheet and exactly once.
    public func sessionLossAlert(_ alert: Binding<SessionLossAlert?>, isTopmost: Bool) -> some View {
        self.alert(
            alert.wrappedValue?.title ?? "",
            isPresented: Binding(get: { isTopmost && alert.wrappedValue != nil },
                                 set: { _ in }),   // only OK clears it: a copy being torn down must not lose an unread alert
            presenting: alert.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) { alert.wrappedValue = nil }
        } message: { item in
            Text(item.message)
        }
    }
}
#endif
