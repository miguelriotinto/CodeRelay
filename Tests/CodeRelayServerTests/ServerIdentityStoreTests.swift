import XCTest
@testable import CodeRelayKit
@testable import CodeRelayServer

/// `instance.json` (multi-server spec §6.1): minted once, reused forever,
/// `0o600`, and a corrupt file is replaced rather than taking the server down.
final class ServerIdentityStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerIdentityStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent("instance.json") }

    func testMintsAndPersistsOnFirstLoad() throws {
        let first = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, first.id.uuidString)
        XCTAssertNotNil(json["createdAt"] as? String, "createdAt is an ISO-8601 string")
    }

    func testIdIsStableAcrossLoads() {
        let first = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio")
        let second = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio")
        XCTAssertEqual(first.id, second.id)
    }

    func testFileIsOwnerReadWriteOnly() throws {
        _ = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptFileIsReplacedNotFatal() throws {
        try Data(#"{"id":"not-a-uuid""#.utf8).write(to: file)
        let identity = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, identity.id.uuidString, "the corrupt file was overwritten with the new id")
        // And it is now stable.
        XCTAssertEqual(ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio").id, identity.id)
    }

    func testHandWrittenFileWithOnlyAnIdIsHonoured() throws {
        // The file exists to keep the id stable; a missing or oddly formatted
        // createdAt must never cause a valid id to be thrown away.
        let keep = UUID()
        try Data(#"{"id":"\#(keep.uuidString)"}"#.utf8).write(to: file)
        XCTAssertEqual(ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "h").id, keep)
        try Data(#"{"id":"\#(keep.uuidString)","createdAt":"2026-10-28T11:40:06.143Z"}"#.utf8).write(to: file)
        XCTAssertEqual(ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "h").id, keep,
                       "fractional-second timestamps must not read as corruption")
    }

    func testMissingDirectoryIsCreated() {
        let nested = dir.appendingPathComponent("nested/deeper", isDirectory: true)
        let identity = ServerIdentityStore.load(directory: nested, configuredName: nil, hostName: "studio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("instance.json").path))
        XCTAssertEqual(ServerIdentityStore.load(directory: nested, configuredName: nil, hostName: "studio").id, identity.id)
    }

    // MARK: - Name resolution

    func testConfiguredNameWins() {
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: "Studio Relay", hostName: "studio.local"), "Studio Relay")
    }

    func testHostNameDropsTrailingLocal() {
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: nil, hostName: "studio.local"), "studio")
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: "", hostName: "studio.local"), "studio")
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: nil, hostName: "build-box"), "build-box")
    }

    func testEmptyOrBareLocalHostNameFallsBackToCodeRelay() {
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: nil, hostName: ""), "CodeRelay")
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: nil, hostName: ".local"), "CodeRelay")
    }

    func testConfiguredNameIsSanitised() {
        // Control characters and newlines stripped, capped at 60 scalars — the
        // same rule as pairing labels, because the name reaches logs and clients.
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: "\u{1B}[31mEvil\nrelay", hostName: "h"), "[31mEvilrelay")
        let long = String(repeating: "n", count: 80)
        XCTAssertEqual(ServerIdentityStore.resolveName(configured: long, hostName: "h").unicodeScalars.count, 60)
    }

    func testLoadUsesResolvedName() {
        let identity = ServerIdentityStore.load(directory: dir, configuredName: nil, hostName: "studio.local")
        XCTAssertEqual(identity.name, "studio")
    }
}
