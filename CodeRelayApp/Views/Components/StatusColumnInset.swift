import SwiftUI

/// iPhone Duo puts the status bar in a column down one side of each display,
/// and iOS reports it as a horizontal safe-area inset. Every view honouring it
/// left centred text visibly off centre and list rows short of one edge.
///
/// The inset is ignored only while the vertical size class is regular. On an
/// iPhone the only portrait horizontal inset is Duo's status column; in
/// landscape (compact height) the inset is the notch or Dynamic Island, which
/// content must stay clear of, so it is honoured there. iPads report none.
private struct StatusColumnInset: ViewModifier {
    enum Kind { case full, centred, list }
    let kind: Kind
    var enabled = true
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var ignores: Bool { enabled && verticalSizeClass != .compact }

    func body(content: Content) -> some View {
        switch kind {
        case .full:
            content
                .ignoresSafeArea(.container, edges: ignores ? .horizontal : [])
        case .centred:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: ignores ? .horizontal : [])
        case .list:
            content
                .ignoresSafeArea(.container, edges: ignores ? .horizontal : [])
                // Inset-grouped margins are derived from the safe area, so with
                // the inset ignored they must be given; nil keeps the system's.
                .contentMargins(.horizontal, ignores ? 20 : nil, for: .scrollContent)
        }
    }
}

extension View {
    /// Spans iPhone Duo's status bar column without changing the view's own
    /// size: for self-sizing sheets and pills whose content is centred.
    func spansStatusColumn() -> some View {
        modifier(StatusColumnInset(kind: .full))
    }

    /// Centres a message or empty state on the physical display, not beside
    /// iPhone Duo's status bar column (see `StatusColumnInset`).
    func centredOnDisplay() -> some View {
        modifier(StatusColumnInset(kind: .centred))
    }

    /// Lets a list in a sheet span the sheet with even margins instead of
    /// stopping short of iPhone Duo's status bar column. Only where the column
    /// holds nothing but the clock, and the clock is not beside the rows: a
    /// full-height sheet with toolbar items gets them laid out vertically IN
    /// the column by the iOS 27.1 SDK, and rows spanning it slide under them.
    /// Apply to the list, not its NavigationStack, so the bar stays inset.
    func listSpansStatusColumn(_ enabled: Bool = true) -> some View {
        modifier(StatusColumnInset(kind: .list, enabled: enabled))
    }
}
