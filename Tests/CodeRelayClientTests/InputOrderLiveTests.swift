import XCTest
@testable import CodeRelayClient
@testable import CodeRelayKit

/// Regression: `TerminalViewModel.sendInput`, called once per keystroke at
/// machine speed, must deliver bytes to the PTY in order. With one unordered
/// `Task` per key this burst arrived shuffled (`cabdefghijklnomp…`) on every
/// run. Lines stay under macOS's 1024-byte canonical-mode limit, or the tty
/// discards them and the file comes back empty.
///
/// Live relay only, like `LaunchHandshakeLiveTests`:
///
///     RELAY_LIVE_TOKEN=<raw token> swift test --filter InputOrderLiveTests
@MainActor
final class InputOrderLiveTests: XCTestCase {
    func testBurstOfSingleByteSendsArrivesInOrder() async throws {
        guard let token = ProcessInfo.processInfo.environment["RELAY_LIVE_TOKEN"], !token.isEmpty else {
            throw XCTSkip("Set RELAY_LIVE_TOKEN to run live tests.")
        }
        let connection = RelayConnection()
        try await connection.connect(config: ConnectionConfig(name: "live", host: "127.0.0.1", port: 9200), token: token)
        let coordinator = SharedSessionCoordinator(connection: connection, token: token)
        _ = await coordinator.performHandshake(reason: .launch)
        await coordinator.createNewSession()
        let id = try XCTUnwrap(coordinator.activeSessionId)
        let vm = try XCTUnwrap(coordinator.terminalViewModels[id])
        try await Task.sleep(for: .seconds(2))

        let path = NSTemporaryDirectory() + "cr-order-\(UUID().uuidString).txt"
        vm.sendInput("stty -echo; cat > \(path)\n")
        try await Task.sleep(for: .seconds(1))

        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789~/&|-")
        var expected = ""
        for i in 0..<3000 { expected.append(i % 61 == 60 ? "\n" : alphabet[i % alphabet.count]) }
        for ch in expected { vm.sendInput(Data(String(ch).utf8)) }
        vm.sendInput("\n")
        vm.sendInput(Data([0x04]))
        try await Task.sleep(for: .seconds(2))

        let got = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<missing>"
        try? FileManager.default.removeItem(atPath: path)
        await coordinator.terminateSession(id: id)
        coordinator.tearDown()
        XCTAssertEqual(got, expected + "\n")
    }
}
