import XCTest
@testable import ClaudeRelayKit

final class PairingURLTests: XCTestCase {

    func testRoundTripsThroughURLString() throws {
        let original = PairingURL(host: "silverwing.local", port: 9200, useTLS: false, code: "K7QP2M4X")
        let parsed = try XCTUnwrap(PairingURL(string: original.urlString))
        XCTAssertEqual(parsed.host, "silverwing.local")
        XCTAssertEqual(parsed.port, 9200)
        XCTAssertFalse(parsed.useTLS)
        XCTAssertEqual(parsed.code, "K7QP2M4X")
    }

    func testURLStringShape() {
        let url = PairingURL(host: "silverwing.local", port: 9200, useTLS: false, code: "K7QP2M4X")
        XCTAssertEqual(url.urlString,
            "clauderelay://pair?host=silverwing.local&port=9200&tls=0&code=K7QP2M4X")
    }

    func testTLSFlagParsesBothWays() throws {
        let secure = try XCTUnwrap(PairingURL(string:
            "clauderelay://pair?host=example.com&port=443&tls=1&code=K7QP2M4X"))
        XCTAssertTrue(secure.useTLS)
        let plain = try XCTUnwrap(PairingURL(string:
            "clauderelay://pair?host=example.com&port=443&tls=0&code=K7QP2M4X"))
        XCTAssertFalse(plain.useTLS)
    }

    func testNormalizesHyphenatedAndLowercaseCode() throws {
        let parsed = try XCTUnwrap(PairingURL(string:
            "clauderelay://pair?host=a.local&port=9200&tls=0&code=k7qp-2m4x"))
        XCTAssertEqual(parsed.code, "K7QP2M4X")
    }

    func testRejectsWrongSchemeOrAction() {
        XCTAssertNil(PairingURL(string: "https://pair?host=a.local&port=9200&tls=0&code=K7QP2M4X"))
        // The session deep link must not parse as a pairing link.
        XCTAssertNil(PairingURL(string: "clauderelay://session/\(UUID().uuidString)"))
    }

    func testRejectsMissingParameters() {
        XCTAssertNil(PairingURL(string: "clauderelay://pair?port=9200&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=a.local&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=a.local&port=9200&tls=0"))
    }

    func testRejectsOutOfRangeOrNonNumericPort() {
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=a.local&port=0&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=a.local&port=70000&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=a.local&port=abc&tls=0&code=K7QP2M4X"))
    }

    func testRejectsBadCode() {
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=a.local&port=9200&tls=0&code=SHORT"))
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=a.local&port=9200&tls=0&code=K7QP2M4%21"))
    }

    func testRejectsEmptyOrWhitespaceHost() {
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=&port=9200&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=%20&port=9200&tls=0&code=K7QP2M4X"))
    }

    func testRejectsHostThatCannotFormAWebSocketURL() {
        // A host with a space or a slash would produce an invalid ws:// URL.
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=a%20b&port=9200&tls=0&code=K7QP2M4X"))
        XCTAssertNil(PairingURL(string: "clauderelay://pair?host=a%2Fb&port=9200&tls=0&code=K7QP2M4X"))
    }

    // MARK: - isValidHost

    func testIsValidHostAcceptsRealHosts() {
        XCTAssertTrue(PairingURL.isValidHost("silverwing.local"))
        XCTAssertTrue(PairingURL.isValidHost("192.168.1.42"))
        XCTAssertTrue(PairingURL.isValidHost("relay.example.com"))
        XCTAssertTrue(PairingURL.isValidHost("127.0.0.1"))
    }

    func testIsValidHostRejectsEmptyAndIllegalCharacters() {
        XCTAssertFalse(PairingURL.isValidHost(""))
        XCTAssertFalse(PairingURL.isValidHost("   "))
        XCTAssertFalse(PairingURL.isValidHost("a b"))
        XCTAssertFalse(PairingURL.isValidHost("a/b"))
        XCTAssertFalse(PairingURL.isValidHost("a?b"))
        XCTAssertFalse(PairingURL.isValidHost("a#b"))
        XCTAssertFalse(PairingURL.isValidHost("user@host"))
    }

    /// `isValidHost` is the predicate `init?(url:)` uses, so the producer that
    /// calls it pre-mint and the parser that rejects hostile QR input cannot
    /// disagree about what a valid host is.
    func testIsValidHostAgreesWithParser() {
        for host in ["a b", "a/b", "a?b", "a#b", "user@host", "", " "] {
            let encoded = host.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? host
            let parsed = PairingURL(
                string: "clauderelay://pair?host=\(encoded)&port=9200&tls=0&code=K7QP2M4X")
            XCTAssertFalse(PairingURL.isValidHost(host), "isValidHost accepted \(host.debugDescription)")
            XCTAssertNil(parsed, "parser accepted \(host.debugDescription)")
        }

        for host in ["silverwing.local", "192.168.1.42", "relay.example.com"] {
            let parsed = PairingURL(
                string: "clauderelay://pair?host=\(host)&port=9200&tls=0&code=K7QP2M4X")
            XCTAssertTrue(PairingURL.isValidHost(host), "isValidHost rejected \(host)")
            XCTAssertNotNil(parsed, "parser rejected \(host)")
        }
    }
}
