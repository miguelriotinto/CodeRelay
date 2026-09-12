import XCTest
@testable import CodeRelayClient

final class SavedConnectionStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// Each test gets its own suite-backed UserDefaults so we don't touch
    /// `UserDefaults.standard` or leak state between tests.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SavedConnectionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore(
        key: String = "test.savedConnections",
        legacyKeys: [String] = []
    ) -> SavedConnectionStore {
        SavedConnectionStore(key: key, legacyKeys: legacyKeys, defaults: defaults)
    }

    private func sampleConnection(
        name: String = "Home",
        host: String = "relay.local"
    ) -> ConnectionConfig {
        ConnectionConfig(name: name, host: host, port: 9200, useTLS: false)
    }

    // MARK: - Round-trip

    func testEmptyByDefault() {
        XCTAssertEqual(makeStore().loadAll(), [])
    }

    func testAddPersistsAcrossStoreInstances() {
        let first = makeStore()
        let saved = first.add(sampleConnection(name: "Prod"))
        XCTAssertEqual(saved.count, 1)

        let second = makeStore()
        XCTAssertEqual(second.loadAll().map(\.name), ["Prod"])
    }

    func testAddReplacesByID() {
        let store = makeStore()
        let original = sampleConnection(name: "First")
        store.add(original)

        var updated = original
        updated.name = "Renamed"
        let result = store.add(updated)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Renamed")
    }

    func testAddAppendsWhenIDDiffers() {
        let store = makeStore()
        store.add(sampleConnection(name: "A"))
        store.add(sampleConnection(name: "B"))
        XCTAssertEqual(store.loadAll().map(\.name).sorted(), ["A", "B"])
    }

    func testDeleteByID() {
        let store = makeStore()
        let keep = sampleConnection(name: "Keep")
        let drop = sampleConnection(name: "Drop")
        store.add(keep)
        store.add(drop)

        let result = store.delete(id: drop.id)
        XCTAssertEqual(result.map(\.name), ["Keep"])
        XCTAssertEqual(store.loadAll().map(\.name), ["Keep"])
    }

    func testDeleteUnknownIDIsNoop() {
        let store = makeStore()
        store.add(sampleConnection(name: "Solo"))
        let result = store.delete(id: UUID())
        XCTAssertEqual(result.map(\.name), ["Solo"])
    }

    func testIsolatedByKey() {
        let iosKey = "com.clauderelay.ios.savedConnections"
        let macKey = "com.clauderelay.mac.savedConnections"

        let ios = makeStore(key: iosKey)
        let mac = makeStore(key: macKey)

        ios.add(sampleConnection(name: "Phone"))
        mac.add(sampleConnection(name: "Laptop"))

        XCTAssertEqual(ios.loadAll().map(\.name), ["Phone"])
        XCTAssertEqual(mac.loadAll().map(\.name), ["Laptop"])
    }

    // MARK: - Corrupt / missing data

    func testCorruptDataReturnsEmpty() {
        let key = "corrupt.key"
        defaults.set(Data([0xFF, 0x00, 0x42]), forKey: key)
        let store = makeStore(key: key)
        XCTAssertEqual(store.loadAll(), [])
    }

    // MARK: - Legacy-key migration

    func testLegacyKeyMigratesForwardOnRead() throws {
        let legacyKey = "com.coderemote.savedConnections"
        let currentKey = "com.clauderelay.ios.savedConnections"
        let legacyConnection = sampleConnection(name: "FromLegacy")

        // Seed the legacy key directly.
        let encoded = try JSONEncoder().encode([legacyConnection])
        defaults.set(encoded, forKey: legacyKey)

        let store = makeStore(key: currentKey, legacyKeys: [legacyKey])
        XCTAssertEqual(store.loadAll().map(\.name), ["FromLegacy"])

        // Current key is now populated.
        XCTAssertNotNil(defaults.data(forKey: currentKey))

        // Legacy key is **preserved** (downgrade-safe).
        XCTAssertNotNil(defaults.data(forKey: legacyKey))
    }

    func testLegacyKeyIgnoredWhenCurrentKeyIsPopulated() throws {
        let legacyKey = "com.coderemote.savedConnections"
        let currentKey = "com.clauderelay.ios.savedConnections"

        let legacyEncoded = try JSONEncoder().encode([sampleConnection(name: "OLD")])
        defaults.set(legacyEncoded, forKey: legacyKey)

        let currentEncoded = try JSONEncoder().encode([sampleConnection(name: "NEW")])
        defaults.set(currentEncoded, forKey: currentKey)

        let store = makeStore(key: currentKey, legacyKeys: [legacyKey])
        XCTAssertEqual(store.loadAll().map(\.name), ["NEW"])
    }

    func testLegacyMigrationDoesNothingWhenBothEmpty() {
        let store = makeStore(
            key: "new",
            legacyKeys: ["legacyA", "legacyB"]
        )
        XCTAssertEqual(store.loadAll(), [])
    }

    func testFirstLegacyKeyWithDataWins() throws {
        let currentKey = "current"
        let legacyA = "legacyA"
        let legacyB = "legacyB"

        let bData = try JSONEncoder().encode([sampleConnection(name: "B")])
        defaults.set(bData, forKey: legacyB) // Only B has data

        let store = makeStore(key: currentKey, legacyKeys: [legacyA, legacyB])
        XCTAssertEqual(store.loadAll().map(\.name), ["B"])
    }

    func testMigrationSurvivesSubsequentModifications() throws {
        let legacyKey = "legacy"
        let currentKey = "current"

        let seed = try JSONEncoder().encode([sampleConnection(name: "Seed")])
        defaults.set(seed, forKey: legacyKey)

        let store = makeStore(key: currentKey, legacyKeys: [legacyKey])
        _ = store.loadAll() // triggers migration
        store.add(sampleConnection(name: "AddedAfterMigration"))

        XCTAssertEqual(
            store.loadAll().map(\.name).sorted(),
            ["AddedAfterMigration", "Seed"]
        )
    }
}

extension ConnectionConfig: Equatable {
    public static func == (lhs: ConnectionConfig, rhs: ConnectionConfig) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.host == rhs.host
            && lhs.port == rhs.port
            && lhs.useTLS == rhs.useTLS
    }
}
