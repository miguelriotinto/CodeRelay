import XCTest
@testable import CodeRelayKit

final class SessionRefTests: XCTestCase {
    func testEqualityIsOnBothIds() {
        let s = UUID(), a = UUID(), b = UUID()
        XCTAssertEqual(SessionRef(serverId: a, sessionId: s), SessionRef(serverId: a, sessionId: s))
        XCTAssertNotEqual(SessionRef(serverId: a, sessionId: s), SessionRef(serverId: b, sessionId: s),
                          "the same session UUID on two bookmarks is two refs")
    }

    func testCodableRoundTrip() throws {
        let ref = SessionRef(serverId: UUID(), sessionId: UUID())
        let data = try JSONEncoder().encode(ref)
        XCTAssertEqual(try JSONDecoder().decode(SessionRef.self, from: data), ref)
    }
}
