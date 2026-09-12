import XCTest
@testable import CodeRelayClient

final class DeviceIdentifierTests: XCTestCase {

    func testReturnsNonEmptyID() {
        // macOS host should get an IOPlatformExpertDevice UUID; tests
        // running on CI/sandbox could get "unknown" but the string is
        // always non-empty.
        let id = DeviceIdentifier().currentID
        XCTAssertFalse(id.isEmpty)
    }

    func testStableAcrossCalls() {
        let id1 = DeviceIdentifier().currentID
        let id2 = DeviceIdentifier().currentID
        XCTAssertEqual(id1, id2)
    }

    func testStableAcrossInstances() {
        // The cache is static-scoped on the type, so two independently-created
        // identifiers must see the same value.
        let a = DeviceIdentifier()
        let b = DeviceIdentifier()
        XCTAssertEqual(a.currentID, b.currentID)
    }

    func testProtocolConformanceIsInjectable() {
        // Prove a test double can satisfy DeviceIdentifying without touching
        // the platform API.
        struct StubIdentifier: DeviceIdentifying {
            let currentID: String
        }
        let stub: any DeviceIdentifying = StubIdentifier(currentID: "test-device-42")
        XCTAssertEqual(stub.currentID, "test-device-42")
    }
}
