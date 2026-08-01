import Foundation
import ClaudeRelayKit

/// The subset of `RelayConnection` a `PairingController` needs. Lets tests
/// inject a stub without a live socket. `RelayConnection` satisfies it as-is.
@MainActor
public protocol PairingConnection: AnyObject {
    func connect(config: ConnectionConfig, token: String) async throws
    @discardableResult
    func addServerMessageSubscriber(_ handler: @escaping (ServerMessage) -> Void) -> UUID
    func removeSubscriber(_ id: UUID)
    func send(_ message: ClientMessage) async throws
    func disconnect()
}

extension RelayConnection: PairingConnection {}

public enum PairingError: Error, Equatable {
    case invalidCode        // 401
    case rateLimited        // 429
    case tlsRequired        // ws:// to a host ATS blocks
    case unreachable        // transport failure dialing the host
    case timedOut           // no reply within the deadline
    case server(code: Int, message: String)   // any other server error
}

/// Redeems a pairing code over a fresh, pre-auth WebSocket connection and
/// persists the minted token the same way `AddEditServerViewModel.save()` does.
///
/// One home for the redeem sequence so iOS and macOS share it. It deliberately
/// does NOT authenticate — after `pair()` returns, the caller connects through
/// the normal path with the persisted token, keeping one authenticated path.
@MainActor
public final class PairingController {

    private let store: SavedConnectionStore
    private let deviceName: String
    private let platform: String
    private let connectionFactory: () -> PairingConnection
    private let timeout: Duration

    public init(
        store: SavedConnectionStore,
        deviceName: String,
        platform: String,
        connectionFactory: @escaping @MainActor () -> PairingConnection = { RelayConnection() },
        timeout: Duration = .seconds(10)
    ) {
        self.store = store
        self.deviceName = deviceName
        self.platform = platform
        self.connectionFactory = connectionFactory
        self.timeout = timeout
    }

    /// Dials the host in `url`, redeems `url.code`, persists a `ConnectionConfig`
    /// plus the minted token, and returns the config. Throws `PairingError` on any
    /// failure. Never leaves a dangling socket.
    public func pair(_ url: PairingURL) async throws -> ConnectionConfig {
        let connection = connectionFactory()

        // A pre-auth dial: connect() stores the token but does not send
        // auth_request, so an empty token is correct here — we redeem first.
        let dialConfig = ConnectionConfig(
            name: url.host, host: url.host, port: url.port, useTLS: url.useTLS)
        do {
            try await connection.connect(config: dialConfig, token: "")
        } catch {
            throw PairingError.unreachable
        }
        defer { connection.disconnect() }

        let reply = try await redeem(url.code, on: connection)
        guard case .pairSuccess(let token, _, let label) = reply else {
            throw mapError(reply)
        }

        let config = ConnectionConfig(
            name: label.isEmpty ? url.host : label,
            host: url.host, port: url.port, useTLS: url.useTLS)
        store.add(config)
        try? AuthManager.shared.saveToken(token, for: config.id)
        return config
    }

    /// Installs the response subscriber BEFORE sending (mirrors
    /// SessionController.awaitResponse), matches pair_success or error, and
    /// resolves within the deadline. Only one RPC is ever in flight here.
    private func redeem(_ code: String, on connection: PairingConnection) async throws -> ServerMessage {
        let matchTypes: Set<String> = ["pair_success", "error"]

        return try await withThrowingTaskGroup(of: ServerMessage.self) { group in
            let box = ContinuationBox()
            let subId = connection.addServerMessageSubscriber { message in
                guard matchTypes.contains(message.typeString) else { return }
                box.resume(with: message)
            }
            defer { connection.removeSubscriber(subId) }
            defer { group.cancelAll() }

            group.addTask { @MainActor in
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { cont in
                        box.attach(cont)
                    }
                } onCancel: {
                    box.cancel()
                }
            }
            group.addTask { @MainActor [timeout] in
                try await Task.sleep(for: timeout)
                throw PairingError.timedOut
            }

            do {
                try await connection.send(.pairRequest(
                    code: code, deviceName: deviceName, platform: platform))
            } catch {
                throw PairingError.unreachable
            }

            guard let result = try await group.next() else { throw PairingError.timedOut }
            return result
        }
    }

    private func mapError(_ message: ServerMessage) -> PairingError {
        guard case .error(let code, let text) = message else {
            return .server(code: -1, message: "Unexpected reply")
        }
        switch code {
        case 401: return .invalidCode
        case 429: return .rateLimited
        default:  return .server(code: code, message: text)
        }
    }
}

/// Bridges the subscriber callback (sync) to the awaiting continuation. The
/// subscriber may fire before or after the continuation is attached, so it
/// stores the first value and replays it on attach. Cancellation-aware: when
/// the task is cancelled, resumes the continuation with CancellationError.
@MainActor
private final class ContinuationBox {
    private var continuation: CheckedContinuation<ServerMessage, Error>?
    private var pending: ServerMessage?
    private var done = false

    func attach(_ cont: CheckedContinuation<ServerMessage, Error>) {
        guard !done else { return }
        if let pending {
            done = true
            cont.resume(returning: pending)
        } else {
            continuation = cont
        }
    }

    func resume(with message: ServerMessage) {
        guard !done else { return }
        if let continuation {
            done = true
            continuation.resume(returning: message)
        } else {
            pending = message
        }
    }

    nonisolated func cancel() {
        Task { @MainActor in
            guard !done else { return }
            done = true
            continuation?.resume(throwing: CancellationError())
        }
    }
}
