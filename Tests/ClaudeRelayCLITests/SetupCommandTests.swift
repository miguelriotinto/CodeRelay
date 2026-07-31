import XCTest
@testable import ClaudeRelayCLI
@testable import ClaudeRelayKit

final class SetupCommandTests: XCTestCase {

    private let url = PairingURL(host: "silverwing.local", port: 9200, useTLS: false, code: "K7QP2M4X")
    private let host = HostCandidate(host: "silverwing.local", kind: .bonjour)
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func render(includeQR: Bool = true, secondsLeft: TimeInterval = 298) -> String {
        SetupPresenter.render(
            url: url,
            expiresAt: now.addingTimeInterval(secondsLeft),
            now: now,
            host: host,
            includeQR: includeQR
        )
    }

    func testOutputShowsTheHostAndWhyItWasChosen() {
        let output = render()
        XCTAssertTrue(output.contains("silverwing.local"), output)
        XCTAssertTrue(output.lowercased().contains("bonjour"), output)
    }

    func testOutputShowsTheGroupedCode() {
        XCTAssertTrue(render().contains("K7QP-2M4X"))
    }

    func testOutputShowsRemainingTimeAsMinutesAndSeconds() {
        XCTAssertTrue(render(secondsLeft: 298).contains("4:58"), render(secondsLeft: 298))
    }

    func testNoQRModeStillShowsCodeAndURL() {
        let output = render(includeQR: false)
        XCTAssertTrue(output.contains("K7QP-2M4X"))
        XCTAssertTrue(output.contains(url.urlString), output)
        XCTAssertFalse(output.contains("\u{2588}"), "no-qr mode must not draw blocks")
    }

    func testQRModeDrawsBlocks() {
        let output = render(includeQR: true)
        let hasBlocks = output.contains("\u{2588}") || output.contains("\u{2580}") || output.contains("\u{2584}")
        XCTAssertTrue(hasBlocks, "QR mode should draw half-block glyphs")
    }

    func testOutputMentionsTheOptionalHookCommand() {
        XCTAssertTrue(render().contains("claude-relay hook install"), render())
    }

    func testExpiredGrantSaysSo() {
        let output = render(secondsLeft: -1)
        XCTAssertTrue(output.lowercased().contains("expired"), output)
    }
}
