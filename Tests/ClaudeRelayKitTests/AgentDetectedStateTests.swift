import XCTest
@testable import ClaudeRelayKit

final class AgentDetectedStateTests: XCTestCase {

    func testRawValuesAreLowercase() {
        XCTAssertEqual(AgentDetectedState.idle.rawValue, "idle")
        XCTAssertEqual(AgentDetectedState.working.rawValue, "working")
        XCTAssertEqual(AgentDetectedState.blocked.rawValue, "blocked")
        XCTAssertEqual(AgentDetectedState.unknown.rawValue, "unknown")
    }

    func testDecodesKnownValues() throws {
        let decoder = JSONDecoder()
        for (raw, expected): (String, AgentDetectedState) in [
            ("idle", .idle), ("working", .working), ("blocked", .blocked), ("unknown", .unknown)
        ] {
            let decoded = try decoder.decode(AgentDetectedState.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(decoded, expected)
        }
    }

    func testUnknownRawValueDecodesToUnknown() throws {
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AgentDetectedState.self, from: Data("\"waiting_forever\"".utf8))
        XCTAssertEqual(decoded, .unknown, "Forward-compat: an unrecognized state from a newer server maps to .unknown")
    }

    func testEncodesCanonicalRawValue() throws {
        let data = try JSONEncoder().encode(AgentDetectedState.blocked)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"blocked\"")
    }

    func testNeedsAttentionOnlyForBlocked() {
        XCTAssertTrue(AgentDetectedState.blocked.needsAttention)
        XCTAssertFalse(AgentDetectedState.idle.needsAttention)
        XCTAssertFalse(AgentDetectedState.working.needsAttention)
        XCTAssertFalse(AgentDetectedState.unknown.needsAttention)
    }
}
