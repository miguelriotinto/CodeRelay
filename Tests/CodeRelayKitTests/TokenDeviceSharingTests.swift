import XCTest
import CodeRelayKit

final class TokenDeviceSharingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFirstDeviceIsNotShared() {
        let (map, shared) = TokenDeviceSharing.record("a", at: t0, in: nil)
        XCTAssertEqual(map, ["a": t0])
        XCTAssertEqual(shared, 0)
    }

    func testSecondDeviceReportsTheFirst() {
        let (map, _) = TokenDeviceSharing.record("a", at: t0, in: nil)
        let (after, shared) = TokenDeviceSharing.record("b", at: t0 + 60, in: map)
        XCTAssertEqual(shared, 1)
        XCTAssertEqual(TokenDeviceSharing.recentCount(after, now: t0 + 60), 2)
    }

    /// Warns once per device joining, not once per reconnect.
    func testReconnectOfAJoinedDeviceIsSilent() {
        var map = TokenDeviceSharing.record("a", at: t0, in: nil).devices
        map = TokenDeviceSharing.record("b", at: t0 + 1, in: map).devices
        XCTAssertEqual(TokenDeviceSharing.record("b", at: t0 + 2, in: map).sharedWith, 0)
        XCTAssertEqual(TokenDeviceSharing.record("a", at: t0 + 3, in: map).sharedWith, 0)
    }

    /// A device not seen for the window no longer counts — re-pairing the other
    /// device clears the flag without anyone editing tokens.json.
    func testStaleDeviceAgesOut() {
        let map = TokenDeviceSharing.record("a", at: t0, in: nil).devices
        let later = t0 + TokenDeviceSharing.window + 1
        XCTAssertEqual(TokenDeviceSharing.record("b", at: later, in: map).sharedWith, 0)
        XCTAssertEqual(TokenDeviceSharing.recentCount(map, now: later), 0)
    }

    /// A device coming back after aging out while another is active warns again.
    func testReturningStaleDeviceWarnsAgain() {
        var map = TokenDeviceSharing.record("a", at: t0, in: nil).devices
        let later = t0 + TokenDeviceSharing.window + 1
        map = TokenDeviceSharing.record("b", at: later, in: map).devices
        XCTAssertEqual(TokenDeviceSharing.record("a", at: later + 1, in: map).sharedWith, 1)
    }

    func testUnrecordableIdsAreIgnored() {
        for id in ["", "unknown", String(repeating: "x", count: 129)] {
            let (map, shared) = TokenDeviceSharing.record(id, at: t0, in: ["a": t0])
            XCTAssertEqual(map, ["a": t0], id)
            XCTAssertEqual(shared, 0, id)
        }
    }

    func testMapIsBoundedByEvictingTheOldest() {
        var map: [String: Date] = [:]
        for i in 0...TokenDeviceSharing.maxDevicesPerToken {
            map = TokenDeviceSharing.record("d\(i)", at: t0 + Double(i), in: map).devices
        }
        XCTAssertEqual(map.count, TokenDeviceSharing.maxDevicesPerToken)
        XCTAssertNil(map["d0"])
    }
}
