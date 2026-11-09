import XCTest
import SwiftUI
import UIKit
@testable import CodeRelayApp

/// The top bar shows the session uptime only when it fits on one line beside
/// every tab (closed iPhone Duo: hidden; open: shown). Same numbers as Kotlin
/// `WorkspaceLogicTest`'s showsUptime cases.
final class UptimeRuleTests: XCTestCase {
    private func shows(slot: CGFloat, uptime: CGFloat, tabs: CGFloat) -> Bool {
        UptimeRule.shows(slotWidth: slot, uptimeWidth: uptime, tabsWidth: tabs)
    }

    func testShowsWhenItFitsBesideEveryTab() {
        XCTAssertTrue(shows(slot: 400, uptime: 56, tabs: 58), "open iPhone Duo")
        XCTAssertTrue(shows(slot: 120, uptime: 56, tabs: 58), "exactly enough room")
    }

    func testHidesRatherThanSqueezeTheTabsOrWrap() {
        XCTAssertFalse(shows(slot: 95, uptime: 56, tabs: 58), "closed iPhone Duo")
        XCTAssertFalse(shows(slot: 119, uptime: 56, tabs: 58))
        XCTAssertFalse(shows(slot: 300, uptime: 56, tabs: 400), "tabs already overflow")
        // A day prefix widens the text: the same slot can stop fitting.
        XCTAssertTrue(shows(slot: 150, uptime: 56, tabs: 58))
        XCTAssertFalse(shows(slot: 150, uptime: 90, tabs: 58))
    }

    func testKeepsOneChipOfRoomAndHidesUntilMeasured() {
        XCTAssertFalse(shows(slot: 80, uptime: 56, tabs: 0))
        XCTAssertTrue(shows(slot: 88, uptime: 56, tabs: 0))
        XCTAssertFalse(shows(slot: 1_000, uptime: .infinity, tabs: 58), "uptime not measured yet")
    }
}

/// The real view in a window: the uptime is drawn on a wide slot and absent on
/// a narrow one (where it used to wrap onto two lines).
@MainActor
final class UptimeBesideTabsTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    /// Hosts the view at `width` on black and returns how many pixel columns
    /// contain anything lit (the uptime is the only thing that draws).
    private func litColumns(width: CGFloat) async -> Int {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let root = UptimeBesideTabs(since: Date().addingTimeInterval(-3_725), tabsWidth: 58) { Color.clear.frame(height: 22) }
            .frame(width: width, height: 36)
            .background(Color.black)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        window.makeKeyAndVisible()
        self.window = window
        try? await Task.sleep(for: .seconds(1))

        let size = host.view.bounds.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return -1 }
        let perRow = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        var lit = 0
        for x in 0..<cg.width {
            for y in 0..<cg.height {
                let p = y * perRow + x * bpp
                let sum: Int = Int(bytes[p]) + Int(bytes[p + 1]) + Int(bytes[p + 2])
                if sum > 60 { lit += 1; break }
            }
        }
        return lit
    }

    func testUptimeDrawnWhenWideAndHiddenWhenNarrow() async {
        let wide = await litColumns(width: 300)
        XCTAssertGreaterThan(wide, 20, "01:02:05 is drawn on a wide slot")
        window?.isHidden = true
        // Closed iPhone Duo: the slot holds the tabs but not the uptime too.
        let narrow = await litColumns(width: 95)
        XCTAssertEqual(narrow, 0, "no room beside the tabs: nothing drawn, no wrapped digits")
    }
}
