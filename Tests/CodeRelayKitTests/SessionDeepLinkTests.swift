import XCTest
@testable import CodeRelayKit

/// `coderelay://session/<uuid>?server=<instanceId>` (multi-server spec §10).
/// The parser is shared by the push tap, the QR scanner and the `onOpenURL`
/// handlers on every Apple client, so there is exactly one place that knows
/// the format.
final class SessionDeepLinkTests: XCTestCase {

    private let session = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let server = UUID(uuidString: "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")!

    func testFormatsWithServerQuery() {
        let link = SessionDeepLink(sessionId: session, serverInstanceId: server)
        XCTAssertEqual(link.urlString,
                       "coderelay://session/11111111-2222-3333-4444-555555555555?server=0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")
    }

    func testFormatsWithoutServerQuery() {
        XCTAssertEqual(SessionDeepLink(sessionId: session).urlString,
                       "coderelay://session/11111111-2222-3333-4444-555555555555")
    }

    func testParsesWhatTheServerSends() {
        let link = SessionDeepLink(string: "coderelay://session/\(session.uuidString)?server=\(server.uuidString)")
        XCTAssertEqual(link, SessionDeepLink(sessionId: session, serverInstanceId: server))
    }

    func testParsesALegacyLinkWithoutServer() {
        XCTAssertEqual(SessionDeepLink(string: "coderelay://session/\(session.uuidString)"),
                       SessionDeepLink(sessionId: session, serverInstanceId: nil))
    }

    func testAcceptsThePreRenameSchemeForOldQRCodes() {
        XCTAssertEqual(SessionDeepLink(string: "clauderelay://session/\(session.uuidString)")?.sessionId, session)
    }

    func testRejectsOtherHostsSchemesAndNonUUIDs() {
        XCTAssertNil(SessionDeepLink(string: "coderelay://pair?host=a&port=1&tls=0&code=ABCDEFGH"))
        XCTAssertNil(SessionDeepLink(string: "https://session/\(session.uuidString)"))
        XCTAssertNil(SessionDeepLink(string: "coderelay://session/not-a-uuid"))
        XCTAssertNil(SessionDeepLink(string: "coderelay://session/"))
    }

    func testMalformedServerQueryIsIgnoredNotFatal() {
        let link = SessionDeepLink(string: "coderelay://session/\(session.uuidString)?server=nope")
        XCTAssertEqual(link?.sessionId, session)
        XCTAssertNil(link?.serverInstanceId)
    }

    func testRoundTrip() {
        let link = SessionDeepLink(sessionId: session, serverInstanceId: server)
        XCTAssertEqual(SessionDeepLink(url: link.url), link)
    }
}
