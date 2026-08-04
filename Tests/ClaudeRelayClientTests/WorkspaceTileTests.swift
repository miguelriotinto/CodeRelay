import XCTest
@testable import ClaudeRelayClient

/// The tile is drawn per-row rather than as a container view (so `.swipeActions`
/// keeps working), which means "does this group look like one continuous card?"
/// reduces to whether each row got the right `WorkspaceTileEdge`. That mapping is
/// pure value logic, so it is testable without rendering anything.
final class WorkspaceTileTests: XCTestCase {

    func testSingleSessionGroupRoundsTopAndBottomAcrossTwoRows() {
        // Header + one session: the header rounds the top, the session the
        // bottom. Neither may round both, or a seam appears mid-tile.
        let header = WorkspaceTileEdge.top
        let only = WorkspaceTileEdge.forSession(index: 0, of: 1)
        XCTAssertEqual(only, .bottom)
        XCTAssertTrue(header.roundsTop)
        XCTAssertFalse(header.roundsBottom)
        XCTAssertFalse(only.roundsTop)
        XCTAssertTrue(only.roundsBottom)
    }

    func testMiddleSessionsRoundNothing() {
        let edges = (0..<3).map { WorkspaceTileEdge.forSession(index: $0, of: 3) }
        XCTAssertEqual(edges, [.middle, .middle, .bottom])
        XCTAssertFalse(edges[0].roundsTop)
        XCTAssertFalse(edges[0].roundsBottom)
    }

    func testCollapsedGroupRoundsAllFourCorners() {
        XCTAssertTrue(WorkspaceTileEdge.only.roundsTop)
        XCTAssertTrue(WorkspaceTileEdge.only.roundsBottom)
    }

    func testTileGapIsTightEnoughToReadAsAStackOfPeers() {
        // 4pt, not the ~35pt SwiftUI section default: the tiles are peers in one
        // list, and a wide gutter made them read as unrelated sections. On iOS
        // this value only bites when applied as `.listSectionSpacing` — the row
        // insets can't influence inter-section spacing.
        XCTAssertEqual(WorkspaceTileMetrics.tileGap, 4)
    }

    #if os(iOS)
    func testRowInsetsCarryNoTileGapOrOuterInsetOnIOS() {
        // On iOS the system inset-grouped section owns the tile's outer inset,
        // corner radius, and inter-tile spacing (it clips the row background to
        // its own shape). Re-adding either here would double-inset the content
        // against the actions card above and double the section spacing.
        for edge in [WorkspaceTileEdge.only, .top, .middle, .bottom] {
            let insets = WorkspaceTileMetrics.rowInsets(for: edge)
            XCTAssertEqual(insets.leading, WorkspaceTileMetrics.contentPadding, "\(edge)")
            XCTAssertEqual(insets.trailing, WorkspaceTileMetrics.contentPadding, "\(edge)")
            XCTAssertEqual(insets.bottom, WorkspaceTileMetrics.rowPadding, "\(edge)")
        }
    }
    #else
    func testTileGapIsAppliedOncePerTileNotPerRow() {
        // macOS draws the tile shape itself (`.listStyle(.sidebar)` does no
        // section clipping), so the inter-tile gap lives in the *last* row's
        // bottom inset. If a middle row also carried it, every session would be
        // visually detached from the next and the group would stop reading as one
        // tile.
        let middle = WorkspaceTileMetrics.rowInsets(for: .middle)
        let bottom = WorkspaceTileMetrics.rowInsets(for: .bottom)
        XCTAssertEqual(middle.bottom, WorkspaceTileMetrics.rowPadding)
        XCTAssertEqual(bottom.bottom, WorkspaceTileMetrics.rowPadding + WorkspaceTileMetrics.tileGap)
        XCTAssertEqual(WorkspaceTileMetrics.rowInsets(for: .top).bottom, WorkspaceTileMetrics.rowPadding)
        XCTAssertEqual(WorkspaceTileMetrics.rowInsets(for: .only).bottom, bottom.bottom)
    }
    #endif

    func testAllRowsShareTheSameHorizontalInsets() {
        // Any divergence here would step the tile's left or right edge in or out
        // partway down the group.
        let insets = [WorkspaceTileEdge.only, .top, .middle, .bottom]
            .map { WorkspaceTileMetrics.rowInsets(for: $0) }
        XCTAssertEqual(Set(insets.map(\.leading)).count, 1)
        XCTAssertEqual(Set(insets.map(\.trailing)).count, 1)
        #if os(iOS)
        // The system section supplies the outer inset; the row only pads content.
        XCTAssertEqual(insets[0].leading, WorkspaceTileMetrics.contentPadding)
        #else
        XCTAssertEqual(insets[0].leading,
                       WorkspaceTileMetrics.horizontalInset + WorkspaceTileMetrics.contentPadding)
        #endif
    }
}
