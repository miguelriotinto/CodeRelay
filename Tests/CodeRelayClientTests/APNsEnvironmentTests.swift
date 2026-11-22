import XCTest
@testable import CodeRelayClient

/// The relay routes each APNs push to the endpoint the device's token belongs
/// to; the device learns which from its own provisioning profile.
final class APNsEnvironmentTests: XCTestCase {
    /// A provisioning profile is a CMS envelope around an XML plist; the bytes
    /// before and after stand in for the signature.
    private func profile(entitlements: String) -> Data {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>Test</string>
        <key>Entitlements</key><dict>\(entitlements)</dict>
        </dict></plist>
        """
        return Data([0x30, 0x82, 0x0F, 0x00, 0x06, 0x09]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x00, 0x00, 0x30])
    }

    func testIOSDevelopmentProfileIsSandbox() {
        XCTAssertEqual(APNsEnvironment.isSandbox(profile: profile(entitlements:
            "<key>aps-environment</key><string>development</string>")), true)
    }

    func testMacProductionProfileIsProduction() {
        XCTAssertEqual(APNsEnvironment.isSandbox(profile: profile(entitlements:
            "<key>com.apple.developer.aps-environment</key><string>production</string>")), false)
    }

    func testProfileWithoutPushIsUnknown() {
        XCTAssertNil(APNsEnvironment.isSandbox(profile: profile(entitlements:
            "<key>com.apple.developer.team-identifier</key><string>T9WF95GC9T</string>")))
    }

    func testGarbageIsUnknown() {
        XCTAssertNil(APNsEnvironment.isSandbox(profile: Data("not a profile".utf8)))
        XCTAssertNil(APNsEnvironment.isSandbox(profile: Data()))
    }

    /// A bundle with no embedded profile (the test runner here) must not crash.
    func testBundleWithoutProfileDoesNotCrash() {
        _ = APNsEnvironment.isSandbox(bundle: Bundle(for: APNsEnvironmentTests.self))
    }
}
