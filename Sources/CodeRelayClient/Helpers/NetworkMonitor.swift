import Foundation
import Network

@MainActor
public final class NetworkMonitor: ObservableObject {

    public static let connectivityRestored = Notification.Name("com.coderelay.connectivityRestored")

    @Published public private(set) var isConnected = true

    private let monitor = NWPathMonitor()
    private static let queue = DispatchQueue(label: "com.coderelay.networkMonitor")
    // Track prior state to fire reconnection notification only once per transition
    private var wasDisconnected = false

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let priorDisconnected = self.wasDisconnected
                self.isConnected = connected
                if !connected {
                    self.wasDisconnected = true
                } else if priorDisconnected {
                    self.wasDisconnected = false
                    NotificationCenter.default.post(name: Self.connectivityRestored, object: nil)
                }
            }
        }
        monitor.start(queue: Self.queue)
    }

    deinit {
        monitor.cancel()
    }
}
