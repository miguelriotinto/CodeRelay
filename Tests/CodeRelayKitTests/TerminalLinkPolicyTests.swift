import XCTest
@testable import CodeRelayKit

/// Runs the vectors shared with Kotlin's `TerminalLinkPolicyTest`, so both
/// implementations of the policy provably agree.
final class TerminalLinkPolicyTests: XCTestCase {
    private struct Vectors: Decodable { let policy: [Case] }
    private struct Case: Decodable {
        let name: String
        let candidate: String
        let source: String
        let visibleText: String?
        let decision: String
        let url: String?
    }

    private func loadVectors() throws -> [Case] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CodeRelayKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let file = root.appendingPathComponent(
            "CodeRelayAndroid/core-protocol/src/test/resources/terminal-link-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file)).policy
    }

    func testSharedVectors() throws {
        let cases = try loadVectors()
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases {
            let source: TerminalLinkSource = c.source == "explicit" ? .explicit : .implicit
            let got = TerminalLinkPolicy.decide(c.candidate, source: source, visibleText: c.visibleText)
            switch (c.decision, got) {
            case ("reject", .reject):
                break
            case ("open", .open(let url)), ("confirm", .confirm(let url)):
                XCTAssertEqual(url.absoluteString, c.url, c.name)
            default:
                XCTFail("\(c.name): expected \(c.decision), got \(got)")
            }
        }
    }

    func testOverLongLinkIsRejected() {
        let link = "https://example.com/" + String(repeating: "a", count: TerminalLinkPolicy.maxLength)
        XCTAssertEqual(TerminalLinkPolicy.decide(link, source: .implicit), .reject)
    }
}
