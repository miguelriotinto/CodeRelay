import XCTest
@testable import CodeRelayClient

/// Labels and the byte formatter are shared verbatim with the Kotlin
/// `relay.session.SessionLoadPhase`, so the four clients say the same thing.
final class SessionLoadPhaseTests: XCTestCase {

    func testLabels() {
        XCTAssertEqual(SessionLoadPhase.connecting.label, "Connecting to server…")
        XCTAssertEqual(SessionLoadPhase.authenticating.label, "Authenticating…")
        XCTAssertEqual(SessionLoadPhase.loadingSessions.label, "Loading sessions…")
        XCTAssertEqual(SessionLoadPhase.attaching.label, "Attaching to session…")
        XCTAssertEqual(SessionLoadPhase.loadingHistory(bytes: 10).label, "Loading session history…")
    }

    func testOnlyHistoryHasADetail() {
        XCTAssertNil(SessionLoadPhase.connecting.detail)
        XCTAssertNil(SessionLoadPhase.authenticating.detail)
        XCTAssertNil(SessionLoadPhase.loadingSessions.detail)
        XCTAssertNil(SessionLoadPhase.attaching.detail)
        XCTAssertEqual(SessionLoadPhase.loadingHistory(bytes: 217_088).detail, "212 KB")
    }

    func testByteFormatting() {
        XCTAssertEqual(SessionLoadPhase.formatBytes(0), "<1 KB")
        XCTAssertEqual(SessionLoadPhase.formatBytes(1023), "<1 KB")
        XCTAssertEqual(SessionLoadPhase.formatBytes(1024), "1 KB")
        XCTAssertEqual(SessionLoadPhase.formatBytes(217_088), "212 KB")
        XCTAssertEqual(SessionLoadPhase.formatBytes(1_048_575), "1024 KB")
        XCTAssertEqual(SessionLoadPhase.formatBytes(1_258_291), "1.2 MB")
    }

    func testHistoryPhasesCompareByBytes() {
        XCTAssertEqual(SessionLoadPhase.loadingHistory(bytes: 5), .loadingHistory(bytes: 5))
        XCTAssertNotEqual(SessionLoadPhase.loadingHistory(bytes: 5), .loadingHistory(bytes: 6))
        XCTAssertNotEqual(SessionLoadPhase.attaching, .connecting)
    }
}
