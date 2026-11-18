import SwiftUI
import UIKit
import CodeRelayKit

/// Carries a terminal link from the terminal view (UIKit, deep in the tree) to
/// the one place iOS may raise an alert: `WorkspaceAlerts`, hosted in
/// `AlertOverlayWindow`. Presenting from the terminal view's own controller
/// could land on a presenter that is mid-sheet and wedge it (see
/// `AlertOverlayWindow`).
@MainActor
final class TerminalLinkPrompt: ObservableObject {
    static let shared = TerminalLinkPrompt()

    /// A link waiting for Open / Copy / Cancel.
    @Published var pending: URL?

    /// Opens through `UIApplication`, which honours the user's default browser.
    var openURL: (URL) -> Void = { UIApplication.shared.open($0) }

    func handle(_ decision: TerminalLinkDecision) {
        switch decision {
        case .open(let url): openURL(url)
        case .confirm(let url): pending = url
        case .reject: break
        }
    }

    func openPending() {
        if let url = pending { openURL(url) }
        pending = nil
    }

    func copyPending() {
        if let url = pending { UIPasteboard.general.string = url.absoluteString }
        pending = nil
    }
}

extension View {
    /// The Open / Copy / Cancel alert for a terminal link. Attach once, inside
    /// `AlertOverlayWindow`.
    func terminalLinkAlert(_ prompt: TerminalLinkPrompt) -> some View {
        modifier(TerminalLinkAlert(prompt: prompt))
    }
}

private struct TerminalLinkAlert: ViewModifier {
    @ObservedObject var prompt: TerminalLinkPrompt

    func body(content: Content) -> some View {
        content.alert("Open Link?", isPresented: Binding(
            get: { prompt.pending != nil },
            set: { if !$0 { prompt.pending = nil } }
        ), presenting: prompt.pending) { _ in
            Button("Open") { prompt.openPending() }
            Button("Copy Link") { prompt.copyPending() }
            Button("Cancel", role: .cancel) { prompt.pending = nil }
        } message: { url in
            Text(verbatim: url.absoluteString)
        }
    }
}
