import XCTest
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import CodeRelayServer
@testable import CodeRelayKit

/// The injected `ServerIdentity` must reach the wire on both pre-auth replies
/// (multi-server spec §6.2) exactly as resolved — sanitised name included.
final class ServerIdentityWireTests: SessionManagerTestCase {

    private let identity = ServerIdentity(
        id: UUID(uuidString: "0F2C1D9A-5B8E-4C7D-9A1B-2E3F4A5B6C7D")!,
        name: "studio")

    private func makeChannel(pairingStore: PairingCodeStore = PairingCodeStore()) async throws -> NIOAsyncTestingChannel {
        let handler = RelayMessageHandler(
            sessionManager: makeManager(),
            tokenStore: tokenStore,
            rateLimiter: RateLimiter(maxAttempts: 100, windowSeconds: 60),
            clipboardService: IdentityTestClipboard(),
            pushStore: PushRegistrationStore(directory: tempDir),
            pairingStore: pairingStore,
            identity: identity,
            optimizerBudget: OptimizerBudget())
        let channel = await NIOAsyncTestingChannel(handler: handler)
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9999)).get()
        try await Task.sleep(for: .milliseconds(30))
        return channel
    }

    private func send(_ json: String, on channel: NIOAsyncTestingChannel) async throws {
        var buf = channel.allocator.buffer(capacity: json.utf8.count)
        buf.writeString(json)
        try await channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: buf))
        try await Task.sleep(for: .milliseconds(50))
    }

    private func serverMessages(_ channel: NIOAsyncTestingChannel) async throws -> [ServerMessage] {
        var out: [ServerMessage] = []
        while let frame = try await channel.readOutbound(as: WebSocketFrame.self) {
            guard frame.opcode == .text else { continue }
            var data = frame.unmaskedData
            guard let bytes = data.readBytes(length: data.readableBytes) else { continue }
            if case .server(let message) = try JSONDecoder().decode(MessageEnvelope.self, from: Data(bytes)) {
                out.append(message)
            }
        }
        return out
    }

    func testAuthSuccessCarriesTheInjectedIdentity() async throws {
        let (plaintext, _) = try await tokenStore.create(label: "t")
        let channel = try await makeChannel()
        try await send(#"{"type":"auth_request","payload":{"token":"\#(plaintext)","protocolVersion":3}}"#, on: channel)
        let messages = try await serverMessages(channel)
        guard let auth = messages.first(where: { if case .authSuccess = $0 { return true } else { return false } }),
              case .authSuccess(let version, _, _, let server) = auth else {
            return XCTFail("expected auth_success, got \(messages)")
        }
        XCTAssertEqual(version, 3)
        XCTAssertEqual(server, identity)
    }

    func testPairSuccessCarriesTheInjectedIdentity() async throws {
        let store = PairingCodeStore()
        let grant = await store.mint(label: nil)
        let channel = try await makeChannel(pairingStore: store)
        try await send(#"{"type":"pair_request","payload":{"code":"\#(grant.code)","deviceName":"Phone","platform":"ios"}}"#, on: channel)
        let messages = try await serverMessages(channel)
        guard let paired = messages.first(where: { if case .pairSuccess = $0 { return true } else { return false } }),
              case .pairSuccess(_, _, _, let server) = paired else {
            return XCTFail("expected pair_success, got \(messages)")
        }
        XCTAssertEqual(server, identity)
    }
}

private struct IdentityTestClipboard: ClipboardService {
    func pasteImage(_ imageData: Data) -> Bool { true }
}
