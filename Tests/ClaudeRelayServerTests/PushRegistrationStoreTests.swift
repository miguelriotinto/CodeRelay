import XCTest
import Foundation
@testable import ClaudeRelayServer
@testable import ClaudeRelayKit

final class PushRegistrationStoreTests: XCTestCase {
    private func tmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func reg(_ token: String, _ device: String, notifyOnFinished: Bool = false,
                     at date: Date = Date()) -> PushRegistration {
        PushRegistration(platform: .apns, token: token, deviceId: device,
                         enabled: true, notifyOnFinished: notifyOnFinished, updatedAt: date)
    }

    func testUpsertAndFetchScopedByRelayToken() async {
        let store = PushRegistrationStore(directory: tmpDir())
        await store.upsert(reg("t1", "d1"), forTokenId: "R")
        let got = await store.registrations(forTokenId: "R")
        XCTAssertEqual(got.map(\.token), ["t1"])
        let other = await store.registrations(forTokenId: "OTHER")
        XCTAssertTrue(other.isEmpty)
    }

    func testReRegisterSameDeviceReplaces() async {
        let store = PushRegistrationStore(directory: tmpDir())
        await store.upsert(reg("old", "d1"), forTokenId: "R")
        await store.upsert(reg("new", "d1"), forTokenId: "R")
        let tokens = await store.registrations(forTokenId: "R").map(\.token)
        XCTAssertEqual(tokens, ["new"])
    }

    func testPerTokenCapEvictsOldest() async {
        let store = PushRegistrationStore(directory: tmpDir(), maxPerToken: 2)
        let base = Date()
        for i in 0..<3 {
            await store.upsert(reg("t\(i)", "d\(i)", at: base.addingTimeInterval(Double(i))),
                               forTokenId: "R")
        }
        let tokens = await store.registrations(forTokenId: "R").map(\.token)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertFalse(tokens.contains("t0"), "oldest should be evicted")
    }

    func testSetPreferencesUpdatesInPlace() async {
        let store = PushRegistrationStore(directory: tmpDir())
        await store.upsert(reg("t1", "d1", notifyOnFinished: false), forTokenId: "R")
        await store.setPreferences(deviceId: "d1", forTokenId: "R", enabled: true, notifyOnFinished: true)
        let updated = await store.registrations(forTokenId: "R").first!
        XCTAssertTrue(updated.notifyOnFinished)
    }

    func testRemoveTokenPurgesEverywhere() async {
        let store = PushRegistrationStore(directory: tmpDir())
        await store.upsert(reg("dead", "d1"), forTokenId: "R")
        await store.upsert(reg("dead", "d2"), forTokenId: "S")
        await store.removeToken("dead")
        let r = await store.registrations(forTokenId: "R")
        let sList = await store.registrations(forTokenId: "S")
        XCTAssertTrue(r.isEmpty)
        XCTAssertTrue(sList.isEmpty)
    }

    func testTTLReapDropsExpired() async {
        var now = Date(timeIntervalSince1970: 0)
        let store = PushRegistrationStore(directory: tmpDir(), ttl: 100, now: { now })
        await store.upsert(reg("t1", "d1", at: Date(timeIntervalSince1970: 0)), forTokenId: "R")
        now = Date(timeIntervalSince1970: 200)   // past ttl
        await store.reap()
        let afterReap = await store.registrations(forTokenId: "R")
        XCTAssertTrue(afterReap.isEmpty)
    }

    func testPersistsAcrossReload() async {
        let dir = tmpDir()
        let store = PushRegistrationStore(directory: dir)
        await store.upsert(reg("t1", "d1"), forTokenId: "R")
        await store.flush()
        let reloaded = PushRegistrationStore(directory: dir)
        let tokens = await reloaded.registrations(forTokenId: "R").map(\.token)
        XCTAssertEqual(tokens, ["t1"])
    }
}
