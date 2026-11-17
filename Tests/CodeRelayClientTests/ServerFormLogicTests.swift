import XCTest
@testable import CodeRelayClient

/// Same cases as Android's `ServerFormLogicTest.portForTLSChange`.
final class ServerFormLogicTests: XCTestCase {
    func testTLSOnSwapsPlaintextDefaultOrBlankTo443() {
        XCTAssertEqual(ServerFormLogic.portForTLSChange("9200", useTLS: true), "443")
        XCTAssertEqual(ServerFormLogic.portForTLSChange("", useTLS: true), "443")
        XCTAssertEqual(ServerFormLogic.portForTLSChange("  9200  ", useTLS: true), "443")
    }

    func testTLSOffSwaps443BackTo9200() {
        XCTAssertEqual(ServerFormLogic.portForTLSChange("443", useTLS: false), "9200")
        XCTAssertEqual(ServerFormLogic.portForTLSChange(" 443 ", useTLS: false), "9200")
    }

    func testCustomPortsAreNeverClobbered() {
        XCTAssertEqual(ServerFormLogic.portForTLSChange("8443", useTLS: true), "8443")
        XCTAssertEqual(ServerFormLogic.portForTLSChange("8080", useTLS: false), "8080")
        XCTAssertEqual(ServerFormLogic.portForTLSChange("443", useTLS: true), "443")
        XCTAssertEqual(ServerFormLogic.portForTLSChange("9200", useTLS: false), "9200")
    }

    @MainActor
    func testToggleBindingSwapsButDirectAssignmentDoesNot() {
        final class Form: TLSPortForm { var port = "9200"; var useTLS = false }
        let form = Form()
        form.useTLSToggle.wrappedValue = true
        XCTAssertEqual(form.port, "443"); XCTAssertTrue(form.useTLS)
        form.useTLSToggle.wrappedValue = false
        XCTAssertEqual(form.port, "9200"); XCTAssertFalse(form.useTLS)
        // A prefilled pairing QR for TLS on 9200 keeps its port.
        form.useTLS = true
        XCTAssertEqual(form.port, "9200")
    }
}
