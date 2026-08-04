import SwiftUI
import ClaudeRelayKit

/// Where a row sits within its workspace group's tile. Drives which corners the
/// tile background rounds, so a group renders as one continuous card even though
/// each of its rows is still an independent `List` row.
///
/// Keeping rows independent is the whole point: wrapping a group in a container
/// view would give a simpler card, but `.swipeActions` only attaches to a direct
/// `List` row, so swipe-to-kill would silently stop working. Hence
/// `listRowBackground` + `listRowInsets` instead.
public enum WorkspaceTileEdge: Equatable, Sendable {
    /// The group's only row (collapsed group — just the header).
    case only
    /// The header row of an expanded group.
    case top
    /// A session row with rows both above and below it.
    case middle
    /// The last session row in an expanded group.
    case bottom

    var roundsTop: Bool { self == .top || self == .only }
    var roundsBottom: Bool { self == .bottom || self == .only }

    /// Edge for the session at `index` of `count`, given the header is above it.
    /// A session row is never `.top`: the header always occupies that slot.
    public static func forSession(index: Int, of count: Int) -> WorkspaceTileEdge {
        index == count - 1 ? .bottom : .middle
    }
}

/// Layout constants shared by the tile background and the row insets that must
/// line up with it. Defined once so the two can't drift apart.
public enum WorkspaceTileMetrics {
    /// Inset from the list's edge to the tile itself.
    public static let horizontalInset: CGFloat = 8
    /// Padding from the tile edge to its content.
    public static let contentPadding: CGFloat = 10
    /// Vertical padding inside a row.
    public static let rowPadding: CGFloat = 7
    /// Gap between one group's tile and the next. Deliberately tight: the tiles
    /// are peers in one list, so a wide gutter made them read as unrelated
    /// sections rather than as a stack of workspaces.
    ///
    /// On iOS this is applied as `.listSectionSpacing`, because each group is its
    /// own `Section` and the *section* spacing (~35pt by default) — not this
    /// value — is what actually separates the tiles.
    public static let tileGap: CGFloat = 4
    /// Corner radius for the platforms that have to draw the tile shape by hand.
    ///
    /// iOS does **not** use this: there the inset-grouped `List` clips a row
    /// background to its own section shape, so the tile inherits the exact radius
    /// of the `New Session` / `Attach Session` card above it for free (verified on
    /// device: a plain `Rectangle()` row background comes out rounded, and a
    /// multi-row section rounds only its outer corners). Hard-coding a measured
    /// radius there could only ever approximate a value Apple is free to change.
    ///
    /// macOS uses `.listStyle(.sidebar)`, which does no such clipping, so it draws
    /// the shape itself with this radius.
    public static let cornerRadius: CGFloat = 10

    /// Row content insets for a row at `edge`. The trailing gap is added below
    /// the tile's last row so consecutive tiles don't touch.
    public static func rowInsets(for edge: WorkspaceTileEdge) -> EdgeInsets {
        #if os(iOS)
        // The system section already insets and rounds the tile, so the row only
        // owns its inner padding. Adding `horizontalInset` here would inset the
        // content *inside* an already-inset card and misalign it with the actions
        // card above; adding `tileGap` would double the section spacing.
        EdgeInsets(
            top: rowPadding,
            leading: contentPadding,
            bottom: rowPadding,
            trailing: contentPadding)
        #else
        EdgeInsets(
            top: rowPadding,
            leading: horizontalInset + contentPadding,
            bottom: rowPadding + (edge.roundsBottom ? tileGap : 0),
            trailing: horizontalInset + contentPadding)
        #endif
    }
}

/// The dark-grey rounded backing for one row of a workspace tile.
///
/// Uses the adaptive `.fill.tertiary` rather than a literal grey: the terminal
/// pane forces `.preferredColorScheme(.dark)` but the sidebar does not, so a
/// hard-coded dark colour would be unreadable for a light-mode user.
public struct WorkspaceTileBackground: View {
    private let edge: WorkspaceTileEdge

    public init(edge: WorkspaceTileEdge) {
        self.edge = edge
    }

    public var body: some View {
        #if os(iOS)
        // A plain fill, deliberately: the inset-grouped `List` clips a row
        // background to its section's shape, so the group inherits the system
        // card's exact corner radius and inset — including rounding only the
        // section's *outer* corners, which is precisely what `edge` encodes.
        // Drawing our own `UnevenRoundedRectangle` here would sit inside that clip
        // and could only approximate the card above it. `edge` is still consumed
        // on macOS, and still drives `rowInsets`.
        Color.clear.background(.fill.tertiary)
        #else
        let radius = WorkspaceTileMetrics.cornerRadius
        UnevenRoundedRectangle(
            topLeadingRadius: edge.roundsTop ? radius : 0,
            bottomLeadingRadius: edge.roundsBottom ? radius : 0,
            bottomTrailingRadius: edge.roundsBottom ? radius : 0,
            topTrailingRadius: edge.roundsTop ? radius : 0,
            style: .continuous)
            .fill(.fill.tertiary)
            // Mirrors `rowInsets`, so the fill sits exactly under the content
            // and the gap below the last row stays empty.
            .padding(.horizontal, WorkspaceTileMetrics.horizontalInset)
            .padding(.bottom, edge.roundsBottom ? WorkspaceTileMetrics.tileGap : 0)
        #endif
    }
}

/// Header row of a workspace tile: folder name, state dot, attention count, and
/// a collapse chevron.
///
/// The chevron is *trailing* and the whole row is the tap target — inside a tile
/// a leading chevron reads as part of the title rather than as a control.
///
/// The dot follows the title rather than leading it. Leading dots put the
/// group's dot and its sessions' dots in the same left-hand column, which read
/// as one flat list of peers and hid the header/child relationship; trailing
/// dots let the text form that column instead.
public struct WorkspaceTileHeader: View {
    private let group: WorkspaceRollup
    private let isCollapsed: Bool
    private let titleFont: Font
    private let onToggle: () -> Void

    public init(
        group: WorkspaceRollup,
        isCollapsed: Bool,
        // Bold, and `.rounded` to match the session rows it sits above — the
        // weight is what separates the tile title from its sessions.
        titleFont: Font = .system(.subheadline, design: .rounded, weight: .bold),
        onToggle: @escaping () -> Void
    ) {
        self.group = group
        self.isCollapsed = isCollapsed
        self.titleFont = titleFont
        self.onToggle = onToggle
    }

    public var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(titleFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Without this the dot is pushed off-screen by a long folder
                    // name instead of the name truncating.
                    .layoutPriority(-1)
                Circle().fill(group.state.badgeColor).frame(width: 8, height: 8)
                Spacer(minLength: 4)
                if group.attentionCount > 0 {
                    Text("\(group.attentionCount)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        .foregroundStyle(.white)
                }
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // Without this the Button only registers taps on the glyphs, so the
            // gap between the title and the chevron would be dead space.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.title)
        .accessibilityHint(isCollapsed ? "Expand group" : "Collapse group")
    }
}

public extension View {
    /// Style this view as row `edge` of a workspace tile: rounded dark backing,
    /// matched insets, and no separator (the tile's own edges do that job).
    func workspaceTileRow(_ edge: WorkspaceTileEdge) -> some View {
        self
            .listRowBackground(WorkspaceTileBackground(edge: edge))
            .listRowInsets(WorkspaceTileMetrics.rowInsets(for: edge))
            .listRowSeparator(.hidden)
    }
}
